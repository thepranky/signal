#!/usr/bin/env python3
"""Install (or uninstall) Signal's Claude Code hooks.

Merges Signal's traffic-light hooks into ~/.claude/settings.json without
clobbering any hooks you already have. Re-running is safe and idempotent.

Usage:
    python3 install/install.py            # install / update
    python3 install/install.py --uninstall
    python3 install/install.py --dry-run  # print the resulting config, write nothing
"""

import argparse
import json
import os
import shutil
import stat
import sys
import time

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HOOK_SCRIPT = os.path.join(REPO_ROOT, "hooks", "signal_hook.py")
SETTINGS_PATH = os.path.expanduser("~/.claude/settings.json")
STATE_DIR = os.path.expanduser("~/.signal/sessions")

# event name -> (matcher or None, status arg)
MANAGED_HOOKS = [
    ("UserPromptSubmit", None, "running"),
    ("PreToolUse", "*", "running"),
    ("PostToolUse", "*", "running"),
    ("Notification", "permission_prompt", "waiting"),
    ("PermissionRequest", None, "waiting"),
    ("Stop", None, "done"),
    ("SessionEnd", None, "end"),
]


def command_for(status: str) -> str:
    return f"{HOOK_SCRIPT} {status}"


def is_signal_group(group: dict) -> bool:
    """True if a matcher group was added by Signal (references our hook script)."""
    for h in group.get("hooks", []):
        if isinstance(h, dict) and HOOK_SCRIPT in str(h.get("command", "")):
            return True
    return False


def load_settings() -> dict:
    if not os.path.exists(SETTINGS_PATH):
        return {}
    try:
        with open(SETTINGS_PATH) as f:
            data = json.load(f)
        return data if isinstance(data, dict) else {}
    except (ValueError, OSError):
        print(f"warning: could not parse {SETTINGS_PATH}; refusing to overwrite.",
              file=sys.stderr)
        sys.exit(1)


def strip_signal_hooks(settings: dict) -> None:
    """Remove every Signal-managed group from the settings, leaving others intact."""
    hooks = settings.get("hooks")
    if not isinstance(hooks, dict):
        return
    for event in list(hooks.keys()):
        groups = hooks.get(event)
        if not isinstance(groups, list):
            continue
        kept = [g for g in groups if not (isinstance(g, dict) and is_signal_group(g))]
        if kept:
            hooks[event] = kept
        else:
            del hooks[event]
    if not hooks:
        settings.pop("hooks", None)


def add_signal_hooks(settings: dict) -> None:
    hooks = settings.setdefault("hooks", {})
    for event, matcher, status in MANAGED_HOOKS:
        group = {"hooks": [{"type": "command", "command": command_for(status)}]}
        if matcher is not None:
            group["matcher"] = matcher
        hooks.setdefault(event, []).append(group)


def backup(path: str) -> None:
    if os.path.exists(path):
        dst = f"{path}.signal-bak.{int(time.time())}"
        shutil.copy2(path, dst)
        print(f"backed up existing settings to {dst}")


def make_executable(path: str) -> None:
    st = os.stat(path)
    os.chmod(path, st.st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


def write_settings(settings: dict) -> None:
    os.makedirs(os.path.dirname(SETTINGS_PATH), exist_ok=True)
    backup(SETTINGS_PATH)
    with open(SETTINGS_PATH, "w") as f:
        json.dump(settings, f, indent=2)
        f.write("\n")


def main() -> int:
    parser = argparse.ArgumentParser(description="Install Signal's Claude Code hooks.")
    parser.add_argument("--uninstall", action="store_true",
                        help="remove Signal's hooks and exit")
    parser.add_argument("--dry-run", action="store_true",
                        help="print the resulting settings; write nothing")
    args = parser.parse_args()

    if not os.path.exists(HOOK_SCRIPT):
        print(f"error: hook script not found at {HOOK_SCRIPT}", file=sys.stderr)
        return 1

    settings = load_settings()
    strip_signal_hooks(settings)  # always clear stale entries first (idempotent)

    if args.uninstall:
        if args.dry_run:
            print(json.dumps(settings, indent=2))
        else:
            write_settings(settings)
            print("Signal hooks removed.")
        return 0

    make_executable(HOOK_SCRIPT)
    os.makedirs(STATE_DIR, exist_ok=True)
    add_signal_hooks(settings)

    if args.dry_run:
        print(json.dumps(settings, indent=2))
        return 0

    write_settings(settings)
    print(f"Signal hooks installed into {SETTINGS_PATH}")
    print(f"State directory: {STATE_DIR}")
    print("Open a new Claude Code session (any interface) to start tracking.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
