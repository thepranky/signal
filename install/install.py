#!/usr/bin/env python3
"""Install (or uninstall) Signal's hooks.

Merges Signal's traffic-light hooks into Claude Code's ~/.claude/settings.json
(used by the Claude Code CLI, VS Code, and Claude Desktop), Cursor's native
~/.cursor/hooks.json, and Codex's ~/.codex/hooks.json, without clobbering any
hooks you already have. Installing Cursor's native hooks means Cursor tracking
doesn't depend on Cursor's optional Claude-compatibility bridge. Re-running is
safe and idempotent.

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
SOURCE_HOOK = os.path.join(REPO_ROOT, "hooks", "signal_hook.py")
SETTINGS_PATH = os.path.expanduser("~/.claude/settings.json")
# Cursor's native hooks file, so Cursor tracking doesn't rely on Cursor's
# optional Claude-compatibility bridge being enabled.
CURSOR_SETTINGS_PATH = os.path.expanduser("~/.cursor/hooks.json")
# Codex's user-level hooks file. Keep the first implementation intentionally
# simple: always target the documented default, ~/.codex/hooks.json.
CODEX_HOOKS_PATH = os.path.expanduser("~/.codex/hooks.json")
SIGNAL_HOME = os.path.expanduser("~/.signal")
STATE_DIR = os.path.join(SIGNAL_HOME, "sessions")
# The hook is copied to a stable location so the installed commands keep working
# even if this repo (or the app bundle) is later moved or deleted.
INSTALLED_HOOK = os.path.join(SIGNAL_HOME, "signal_hook.py")

# Unique token embedded in every command we install, so we can identify and
# safely remove only our own hooks.
MARKER = "SIGNAL_HOOK=1"

# Claude Code hooks: event name -> (matcher or None, status arg)
MANAGED_HOOKS = [
    ("UserPromptSubmit", None, "running"),
    ("PreToolUse", "*", "running"),
    ("PostToolUse", "*", "running"),
    ("PostToolUseFailure", "*", "running"),
    ("Notification", "permission_prompt", "waiting"),
    ("PermissionRequest", None, "waiting"),
    ("Stop", None, "done"),
    ("StopFailure", None, "done"),
    ("SessionEnd", None, "end"),
]

# Cursor's native hooks: event name -> status arg. Cursor has no equivalent to
# Claude's permission-prompt event, so Cursor sessions only go running -> done
# (never "waiting"/yellow). Matchers are omitted so tool hooks fire for all tools.
MANAGED_CURSOR_HOOKS = [
    ("beforeSubmitPrompt", "running"),
    ("preToolUse", "running"),
    ("postToolUse", "running"),
    ("postToolUseFailure", "running"),
    ("stop", "done"),
    ("sessionEnd", "end"),
]

# Codex user hooks use the same nested shape as Claude Code. Codex does not
# document a session-end event for hooks today, so Codex sessions age out via
# Signal's normal staleness timeout.
MANAGED_CODEX_HOOKS = [
    ("UserPromptSubmit", None, "running"),
    ("PreToolUse", "*", "running"),
    ("PostToolUse", "*", "running"),
    ("PermissionRequest", None, "waiting"),
    ("Stop", None, "done"),
]


def command_for(status: str, source: str = "") -> str:
    # MARKER identifies our hooks; /usr/bin/env avoids depending on the script's
    # +x bit; quotes guard against spaces in the path. Mirrors HookInstaller.swift.
    suffix = f" {source}" if source else ""
    return f'{MARKER} /usr/bin/env python3 "{INSTALLED_HOOK}" {status}{suffix}'


def is_signal_group(group: dict) -> bool:
    """True if a matcher group was added by Signal (carries our unique marker)."""
    for h in group.get("hooks", []):
        if isinstance(h, dict) and MARKER in str(h.get("command", "")):
            return True
    return False


def is_signal_cursor_entry(entry: dict) -> bool:
    """True if a Cursor hook entry (flat `{command}`) was added by Signal."""
    return isinstance(entry, dict) and MARKER in str(entry.get("command", ""))


def load_settings(path: str) -> dict:
    if not os.path.exists(path):
        return {}
    try:
        with open(path) as f:
            data = json.load(f)
        return data if isinstance(data, dict) else {}
    except (ValueError, OSError):
        print(f"warning: could not parse {path}; refusing to overwrite.",
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


def strip_signal_cursor_hooks(settings: dict) -> None:
    """Remove every Signal-managed entry from a Cursor hooks file."""
    hooks = settings.get("hooks")
    if not isinstance(hooks, dict):
        return
    for event in list(hooks.keys()):
        entries = hooks.get(event)
        if not isinstance(entries, list):
            continue
        kept = [e for e in entries if not is_signal_cursor_entry(e)]
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


def add_signal_cursor_hooks(settings: dict) -> None:
    settings.setdefault("version", 1)
    hooks = settings.setdefault("hooks", {})
    for event, status in MANAGED_CURSOR_HOOKS:
        hooks.setdefault(event, []).append({"command": command_for(status)})


def add_signal_codex_hooks(settings: dict) -> None:
    hooks = settings.setdefault("hooks", {})
    for event, matcher, status in MANAGED_CODEX_HOOKS:
        group = {"hooks": [{"type": "command", "command": command_for(status, "codex")}]}
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


def write_settings(path: str, settings: dict) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    backup(path)
    with open(path, "w") as f:
        json.dump(settings, f, indent=2)
        f.write("\n")


def provider_directory_exists(path: str) -> bool:
    return os.path.isdir(os.path.dirname(path))


def main() -> int:
    parser = argparse.ArgumentParser(description="Install Signal's hooks.")
    parser.add_argument("--uninstall", action="store_true",
                        help="remove Signal's hooks and exit")
    parser.add_argument("--dry-run", action="store_true",
                        help="print the resulting settings; write nothing")
    args = parser.parse_args()

    if not os.path.exists(SOURCE_HOOK):
        print(f"error: hook script not found at {SOURCE_HOOK}", file=sys.stderr)
        return 1

    install_claude = provider_directory_exists(SETTINGS_PATH)
    install_cursor = provider_directory_exists(CURSOR_SETTINGS_PATH)
    install_codex = provider_directory_exists(CODEX_HOOKS_PATH)

    # Always clear stale entries first so the operation is idempotent.
    settings = load_settings(SETTINGS_PATH) if install_claude else {}
    strip_signal_hooks(settings)
    cursor = load_settings(CURSOR_SETTINGS_PATH) if install_cursor else {}
    strip_signal_cursor_hooks(cursor)
    codex = load_settings(CODEX_HOOKS_PATH) if install_codex else {}
    strip_signal_hooks(codex)

    if args.uninstall:
        if args.dry_run:
            print(f"# {SETTINGS_PATH}")
            print(json.dumps(settings, indent=2))
            print(f"# {CURSOR_SETTINGS_PATH}")
            print(json.dumps(cursor, indent=2))
            print(f"# {CODEX_HOOKS_PATH}")
            print(json.dumps(codex, indent=2))
        else:
            if os.path.exists(SETTINGS_PATH):
                write_settings(SETTINGS_PATH, settings)
            # Only rewrite Cursor's file if it already exists; never create an
            # empty one for users who never had Cursor hooks.
            if os.path.exists(CURSOR_SETTINGS_PATH):
                write_settings(CURSOR_SETTINGS_PATH, cursor)
            # Same for Codex: uninstall should not create a hooks file for users
            # who never had one.
            if os.path.exists(CODEX_HOOKS_PATH):
                write_settings(CODEX_HOOKS_PATH, codex)
            print("Signal hooks removed.")
        return 0

    if install_claude:
        add_signal_hooks(settings)
    if install_cursor:
        add_signal_cursor_hooks(cursor)
    if install_codex:
        add_signal_codex_hooks(codex)

    if args.dry_run:
        if install_claude:
            print(f"# {SETTINGS_PATH}")
            print(json.dumps(settings, indent=2))
        if install_cursor:
            print(f"# {CURSOR_SETTINGS_PATH}")
            print(json.dumps(cursor, indent=2))
        if install_codex:
            print(f"# {CODEX_HOOKS_PATH}")
            print(json.dumps(codex, indent=2))
        if not (install_claude or install_cursor or install_codex):
            print("No Claude, Cursor, or Codex config directories found.")
        return 0

    if not (install_claude or install_cursor or install_codex):
        print("error: no Claude, Cursor, or Codex config directories found.",
              file=sys.stderr)
        print("Open at least one supported agent, then run setup again.",
              file=sys.stderr)
        return 1

    # Copy the hook to its stable home so installed commands survive a moved repo.
    os.makedirs(STATE_DIR, exist_ok=True)
    shutil.copy2(SOURCE_HOOK, INSTALLED_HOOK)
    make_executable(INSTALLED_HOOK)
    if install_claude:
        write_settings(SETTINGS_PATH, settings)
        print(f"Signal hooks installed into {SETTINGS_PATH}")
    if install_cursor:
        write_settings(CURSOR_SETTINGS_PATH, cursor)
        print(f"Cursor hooks installed into {CURSOR_SETTINGS_PATH}")
    if install_codex:
        write_settings(CODEX_HOOKS_PATH, codex)
        print(f"Codex hooks installed into {CODEX_HOOKS_PATH}")
    print(f"State directory: {STATE_DIR}")
    print("Open a new session in Claude Code, Cursor, or Codex to start tracking.")
    print("For Codex, run /hooks and trust Signal's hooks if Codex prompts you.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
