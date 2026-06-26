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


def project_name(cwd: str) -> str:
    if not cwd:
        return "unknown"
    name = os.path.basename(os.path.normpath(cwd))
    return name or cwd


def session_file(directory: str, session_id: str) -> str:
    # session_id comes from Claude Code; keep only filesystem-safe chars.
    safe = "".join(c for c in session_id if c.isalnum() or c in "-_") or "unknown"
    return os.path.join(directory, f"{safe}.json")


def atomic_write(path: str, payload: dict) -> None:
    """Write JSON atomically: temp file in the same dir, then os.replace."""
    directory = os.path.dirname(path)
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".tmp-", suffix=".json")
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
    payload = {
        "session_id": session_id,
        "status": status,
        "project": project_name(cwd),
        "cwd": cwd,
        "transcript_path": event.get("transcript_path") or "",
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
