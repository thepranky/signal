#!/usr/bin/env python3
"""Signal hook handler for AI coding agents.

Invoked by AI coding agent hook systems: Claude Code, Cursor, and Codex. Reads
the hook event JSON from stdin and records the session's current traffic-light
status into a per-session state file that the Signal menu bar app watches.

Usage:
    signal_hook.py <status> [source]

Where <status> is one of:
    running  - the agent is actively working (UserPromptSubmit / Pre|PostToolUse)
    waiting  - the agent is blocked waiting for your approval (permission prompt)
    done     - the agent finished its turn and is idle (Stop)
    end      - the session terminated; remove its state file (SessionEnd)

The handler is intentionally dependency-free (stdlib only) and fails quietly:
a hook must never disrupt the session it is observing.
"""

import json
import os
import re
import sys
import tempfile
import time

VALID_STATUSES = {"running", "waiting", "done", "end"}
VALID_SOURCES = {"codex", "cursor", "cli", "vscode", "claude_desktop"}

# Cap how much of a transcript we scan for the first user message, so a huge
# transcript never turns a hook into a slow file read.
TRANSCRIPT_SCAN_LINES = 80
TITLE_MAX_LEN = 60

# Map a Claude Code `entrypoint` value to Signal's source token. The plain CLI
# is intentionally left unlabelled (the common case shouldn't add noise).
ENTRYPOINT_SOURCES = {
    "cli": "cli",
    "vscode": "vscode",
    "claude-desktop": "claude_desktop",
}


def state_dir() -> str:
    """Directory where per-session state files live.

    Overridable via SIGNAL_STATE_DIR so the app and tests can agree on a path.
    """
    override = os.environ.get("SIGNAL_STATE_DIR")
    if override:
        return os.path.expanduser(override)
    return os.path.expanduser("~/.signal/sessions")


def read_event() -> dict:
    """Read and parse the hook event JSON from stdin. Returns {} on any error."""
    try:
        raw = sys.stdin.read()
    except Exception:
        return {}
    if not raw or not raw.strip():
        return {}
    try:
        data = json.loads(raw)
        return data if isinstance(data, dict) else {}
    except (ValueError, TypeError):
        return {}


def project_name(cwd: str, transcript_path: str = "") -> str:
    if cwd:
        name = repo_root_name(cwd) or os.path.basename(os.path.normpath(cwd))
        return name or cwd
    # Some clients (notably Cursor's agent) fire hooks without a cwd. Fall back
    # to the project encoded in the transcript path so the session still gets a
    # meaningful label instead of "unknown".
    return project_from_transcript(transcript_path) or "unknown"


def repo_root_name(cwd: str) -> str:
    """Find a nearby git repository root without invoking git from the hook."""
    if not cwd:
        return ""
    path = os.path.abspath(os.path.expanduser(cwd))
    while True:
        marker = os.path.join(path, ".git")
        if os.path.isdir(marker) or os.path.isfile(marker):
            return os.path.basename(path) or path
        parent = os.path.dirname(path)
        if parent == path:
            return ""
        path = parent


def project_from_transcript(transcript_path: str) -> str:
    """Best-effort project name from a transcript path.

    Both Claude Code (~/.claude/projects/<enc>/...) and Cursor
    (~/.cursor/projects/<enc>/agent-transcripts/...) encode the project's
    absolute path in <enc> by replacing path separators with '-'. We can't undo
    that encoding unambiguously, so we strip the home-directory prefix and use
    whatever folder name remains — good enough for a menu label.
    """
    if not transcript_path:
        return ""
    parts = transcript_path.split(os.sep)
    try:
        enc = parts[parts.index("projects") + 1]
    except (ValueError, IndexError):
        return ""
    enc = enc.lstrip("-")
    home_enc = os.path.expanduser("~").lstrip(os.sep).replace(os.sep, "-")
    if home_enc and enc.startswith(home_enc + "-"):
        enc = enc[len(home_enc) + 1:]
    return enc


def session_source(transcript_path: str, entrypoint: str = "",
                   is_cursor: bool = False, forced_source: str = "") -> str:
    """Identify which client produced the session.

    Signal's installed Codex hooks pass `codex` as an explicit source argument
    because Codex hook payload details may change independently of Claude and
    Cursor. Cursor's own hooks carry a `cursor_version` field, which is the most
    reliable signal (it survives even when transcripts are disabled); its
    transcript tree is a secondary heuristic. For Claude Code we prefer the
    transcript's `entrypoint` field (cli / vscode / claude-desktop), falling
    back to the path. Returns one of "codex", "cursor", "vscode",
    "claude_desktop", "cli", or "" (unknown).
    """
    if forced_source in VALID_SOURCES:
        return forced_source
    if is_cursor:
        return "cursor"
    if transcript_path and f"{os.sep}.cursor{os.sep}" in transcript_path:
        return "cursor"
    if transcript_path and f"{os.sep}.codex{os.sep}" in transcript_path:
        return "codex"
    if entrypoint:
        return ENTRYPOINT_SOURCES.get(entrypoint, "cli")
    if transcript_path and f"{os.sep}.claude{os.sep}" in transcript_path:
        return "cli"
    return ""


def first_workspace_root(event: dict) -> str:
    """Cursor hooks omit `cwd` on most events but provide `workspace_roots`
    (the open folders). Use the first one as the working directory so Cursor
    sessions get a real project name instead of falling back to "unknown".
    """
    roots = event.get("workspace_roots")
    if isinstance(roots, list):
        for root in roots:
            if isinstance(root, str) and root:
                return root
    return ""


def _clean_title(text: str) -> str:
    """Turn a raw first-prompt string into a short, single-line label.

    Cursor wraps the user's text in <user_query> tags and prepends a
    <timestamp> block, so unwrap those when present, then collapse whitespace
    and truncate. This is a plain excerpt, not an AI-generated summary.
    """
    if not text:
        return ""
    match = re.search(r"<user_query>\s*(.*?)\s*</user_query>", text, re.DOTALL)
    if match:
        text = match.group(1)
    # Drop any other angle-bracket wrapper tags (e.g. <timestamp>...</timestamp>).
    text = re.sub(r"<[^>]+>", " ", text)
    text = " ".join(text.split())
    if len(text) > TITLE_MAX_LEN:
        text = text[: TITLE_MAX_LEN - 1].rstrip() + "\u2026"
    return text


def _message_text(message) -> str:
    """Extract plain text from a transcript message's `content`.

    Handles both Claude's string content and the list-of-blocks form used by
    Cursor (and newer Claude transcripts).
    """
    if isinstance(message, str):
        return message
    if not isinstance(message, dict):
        return ""
    content = message.get("content")
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        for block in content:
            if isinstance(block, dict) and block.get("type", "text") == "text":
                if block.get("text"):
                    return block["text"]
    return ""


def read_transcript_meta(transcript_path: str) -> dict:
    """Best-effort title + entrypoint from a transcript's first user message.

    Scans only the first TRANSCRIPT_SCAN_LINES lines and stops at the first
    user message. Always returns a dict and never raises — a hook must not fail
    the session it observes.
    """
    meta = {"title": "", "entrypoint": ""}
    if not transcript_path or not os.path.isfile(transcript_path):
        return meta
    try:
        with open(transcript_path, "r", encoding="utf-8", errors="replace") as f:
            for _ in range(TRANSCRIPT_SCAN_LINES):
                line = f.readline()
                if not line:
                    break
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except (ValueError, TypeError):
                    continue
                if not isinstance(obj, dict):
                    continue
                if not meta["entrypoint"] and isinstance(obj.get("entrypoint"), str):
                    meta["entrypoint"] = obj["entrypoint"]
                message = obj.get("message", obj)
                role = obj.get("role") or (message.get("role") if isinstance(message, dict) else None)
                if role == "user":
                    meta["title"] = _clean_title(_message_text(message))
                    break
    except OSError:
        pass
    return meta


def session_file(directory: str, session_id: str) -> str:
    # session_id comes from Claude Code; keep only filesystem-safe chars.
    safe = "".join(c for c in session_id if c.isalnum() or c in "-_") or "unknown"
    return os.path.join(directory, f"{safe}.json")


def atomic_write(path: str, payload: dict) -> None:
    """Write JSON atomically: temp file in the same dir, then os.replace."""
    directory = os.path.dirname(path)
    # Use a non-.json suffix so the menu bar app (which loads *.json) never reads
    # a half-written temp file during the brief window before os.replace.
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".tmp-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(payload, f)
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def read_existing_state(path: str) -> dict:
    """Best-effort read of the previous state for stable labels."""
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError, TypeError):
        return {}


def main() -> int:
    if len(sys.argv) < 2 or sys.argv[1] not in VALID_STATUSES:
        # Misconfiguration: don't break the session, just no-op.
        return 0

    status = sys.argv[1]
    forced_source = sys.argv[2] if len(sys.argv) > 2 and sys.argv[2] in VALID_SOURCES else ""
    event = read_event()

    # Claude Code events carry `session_id`; Cursor events carry
    # `conversation_id` (stable across turns) on every event but only expose
    # `session_id` on sessionStart/sessionEnd, where the two are equal. Falling
    # back to `conversation_id` keeps every Cursor event mapped to one file.
    session_id = str(event.get("session_id") or event.get("conversation_id") or "unknown")
    directory = state_dir()

    try:
        os.makedirs(directory, exist_ok=True)
    except OSError:
        return 0

    path = session_file(directory, session_id)

    if status == "end":
        try:
            os.unlink(path)
        except OSError:
            pass
        return 0

    cwd = event.get("cwd") or first_workspace_root(event)
    transcript_path = event.get("transcript_path") or ""
    meta = read_transcript_meta(transcript_path)
    previous = read_existing_state(path)
    previous_project = previous.get("project") if isinstance(previous.get("project"), str) else ""
    previous_title = previous.get("title") if isinstance(previous.get("title"), str) else ""
    project = (previous_project if previous_project and previous_project != "unknown"
               else project_name(cwd, transcript_path))
    payload = {
        "session_id": session_id,
        "status": status,
        "project": project,
        "title": meta["title"] or previous_title,
        "cwd": cwd,
        "transcript_path": transcript_path,
        "source": session_source(transcript_path, meta["entrypoint"],
                                 is_cursor=bool(event.get("cursor_version")),
                                 forced_source=forced_source),
        "updated_at": time.time(),
    }

    try:
        atomic_write(path, payload)
    except OSError:
        return 0

    return 0


if __name__ == "__main__":
    # Never propagate a failure exit code to Claude Code.
    try:
        sys.exit(main())
    except Exception:
        sys.exit(0)
