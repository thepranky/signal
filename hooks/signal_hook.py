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
import sys
import tempfile
import time

VALID_STATUSES = {"running", "waiting", "done", "end"}


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


def session_source(transcript_path: str) -> str:
    """Identify which client produced the session, from its transcript path.

    Returns "cursor", "claude_code", or "" when it can't be determined. Note
    that the CLI, the VS Code extension, and JetBrains all share
    ~/.claude/projects, so they're indistinguishable here and all read as
    "claude_code".
    """
    if not transcript_path:
        return ""
    if f"{os.sep}.cursor{os.sep}" in transcript_path:
        return "cursor"
    if f"{os.sep}.claude{os.sep}" in transcript_path:
        return "claude_code"
    return ""


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
    payload = {
        "session_id": session_id,
        "status": status,
        "project": project_name(cwd, transcript_path),
        "cwd": cwd,
        "transcript_path": transcript_path,
        "source": session_source(transcript_path),
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
