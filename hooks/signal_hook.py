#!/usr/bin/env python3
"""Signal hook handler for Claude Code.

Invoked by Claude Code hooks. Reads the hook event JSON from stdin and records
the session's current traffic-light status into a per-session state file that
the Signal menu bar app watches.

Usage:
    signal_hook.py <status>

Where <status> is one of:
    running  - Claude is actively working (UserPromptSubmit / Pre|PostToolUse)
    waiting  - Claude is blocked waiting for your approval (permission prompt)
    done     - Claude finished its turn and is idle (Stop)
    end      - the session terminated; remove its state file (SessionEnd)

The handler is intentionally dependency-free (stdlib only) and fails quietly:
a hook must never disrupt the Claude Code session it is observing.
"""

import json
import os
import re
import sys
import tempfile
import time

VALID_STATUSES = {"running", "waiting", "done", "end"}

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
        name = os.path.basename(os.path.normpath(cwd))
        return name or cwd
    # Some clients (notably Cursor's agent) fire hooks without a cwd. Fall back
    # to the project encoded in the transcript path so the session still gets a
    # meaningful label instead of "unknown".
    return project_from_transcript(transcript_path) or "unknown"


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


def session_source(transcript_path: str, entrypoint: str = "") -> str:
    """Identify which client produced the session.

    Cursor uses its own transcript tree, so the path is authoritative there.
    For Claude Code we prefer the transcript's `entrypoint` field (cli / vscode
    / claude-desktop), falling back to the path. Returns one of "cursor",
    "vscode", "claude_desktop", "cli", or "" (unknown).
    """
    if transcript_path and f"{os.sep}.cursor{os.sep}" in transcript_path:
        return "cursor"
    if entrypoint:
        return ENTRYPOINT_SOURCES.get(entrypoint, "cli")
    if transcript_path and f"{os.sep}.claude{os.sep}" in transcript_path:
        return "cli"
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


def main() -> int:
    if len(sys.argv) < 2 or sys.argv[1] not in VALID_STATUSES:
        # Misconfiguration: don't break the session, just no-op.
        return 0

    status = sys.argv[1]
    event = read_event()

    session_id = str(event.get("session_id") or "unknown")
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

    cwd = event.get("cwd") or ""
    transcript_path = event.get("transcript_path") or ""
    meta = read_transcript_meta(transcript_path)
    payload = {
        "session_id": session_id,
        "status": status,
        "project": project_name(cwd, transcript_path),
        "title": meta["title"],
        "cwd": cwd,
        "transcript_path": transcript_path,
        "source": session_source(transcript_path, meta["entrypoint"]),
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
