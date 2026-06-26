# Signal

A lightweight macOS menu bar app that monitors all your active **Claude Code**
sessions with a traffic-light system — across Terminal, VS Code, the Cursor
extension, and the desktop app, all at once.

Each session gets its own colored circle:

- 🔴 **Red** — Claude is actively running and doing work.
- 🟡 **Yellow** — Claude is blocked, waiting for your approval (a permission prompt).
- 🟢 **Green** — Claude finished its turn and is idle.

When a session ends, its circle disappears.

## How it works

Signal has two halves:

```
Claude Code (any interface)
   │  global hooks in ~/.claude/settings.json
   ▼
hooks/signal_hook.py   ──writes──▶   ~/.signal/sessions/<session_id>.json
                                            │  watched by
                                            ▼
                                  Signal.app (menu bar)  →  🔴🟡🟢
```

1. **Hooks** — Claude Code fires lifecycle events (`UserPromptSubmit`,
   `PreToolUse`/`PostToolUse`, `Notification`, `PermissionRequest`, `Stop`,
   `SessionEnd`). A tiny Python handler records each session's current status to
   a per-session JSON file. Because the hooks live in your **global** Claude
   settings, every session is tracked regardless of which interface hosts it,
   and each session is keyed by its unique `session_id` so the same session
   open in two windows is never double-counted.
2. **Menu bar app** — a SwiftUI `MenuBarExtra` app watches that directory and
   renders one circle per live session, labeled by project folder name.

State files are plain JSON — no daemon, no network, no background services
beyond the menu bar app itself.

## Requirements

- macOS 13 or later.
- [Claude Code](https://claude.com/claude-code) installed.
- Python 3 (ships with macOS) for the hook handler and installer.
- **To build the app from source:** Xcode (free, from the App Store). The
  Command Line Tools alone are not enough — `MenuBarExtra` needs the macOS 13+
  SDK. **You do _not_ need Xcode to just run a downloaded build.**

## Install (download — no Xcode needed)

The recommended path for most people:

1. Download `Signal-vX.Y.Z.zip` from the [Releases](../../releases) page and
   unzip it (CI builds every release, so you never touch a compiler).
2. Move `Signal.app` to `/Applications` and open it.
   - macOS Gatekeeper may warn about an unidentified developer on first launch.
     Right-click the app → **Open** → **Open** to bypass it once, or run
     `xattr -dr com.apple.quarantine /Applications/Signal.app`.
3. Wire the hooks into Claude Code:
   ```bash
   git clone <your-fork-url> signal && cd signal
   python3 install/install.py
   ```
4. (Optional) Add `Signal.app` to **System Settings → General → Login Items**
   so it starts automatically.

## Install (build from source)

```bash
git clone <your-fork-url> signal
cd signal

# 1. Wire the hooks into Claude Code (idempotent; backs up your settings).
python3 install/install.py

# 2. Build and launch the menu bar app.
cd app
./build-app.sh
open Signal.app
```

Open a new Claude Code session in any interface and watch the circles light up.
To start Signal automatically, add `Signal.app` to **System Settings → General
→ Login Items**.

### Preview the hook config without writing anything

```bash
python3 install/install.py --dry-run
```

### Uninstall the hooks

```bash
python3 install/install.py --uninstall
```

This removes only Signal's hooks and leaves the rest of your Claude settings
untouched.

## Status mapping

| Color | Meaning | Claude Code event(s) |
|-------|---------|----------------------|
| 🔴 Red | Actively running | `UserPromptSubmit`, `PreToolUse`, `PostToolUse` |
| 🟡 Yellow | Waiting for your approval | `Notification` (`permission_prompt`), `PermissionRequest` |
| 🟢 Green | Finished turn, idle | `Stop` |
| (no circle) | Session ended | `SessionEnd`, or staleness timeout |

> **Note:** Claude Code cannot natively distinguish "finished the whole task"
> from "finished by asking you a clarifying question" — both just end a turn, so
> both show green. Only permission prompts surface as a distinct "waiting"
> (yellow) state.

## Configuration

- **State directory** — defaults to `~/.signal/sessions`. Override with the
  `SIGNAL_STATE_DIR` environment variable (honored by both the hook and the app).
- **Staleness timeout** — sessions whose state file hasn't updated in 12 hours
  are dropped, in case a session dies without firing `SessionEnd`.

## Tests

The hook handler is the only piece with real logic, so that's what's tested
(stdlib `unittest`, no dependencies):

```bash
python3 -m unittest discover -s tests -v
```

CI runs these on every push and before every release.

## Continuous integration

- **CI** (`.github/workflows/ci.yml`) runs the hook tests and builds `Signal.app`
  on a macOS runner for every push/PR, uploading the build as a downloadable
  artifact. This means neither maintainers nor users need Xcode locally.
- **Release** (`.github/workflows/release.yml`) builds and attaches
  `Signal-<tag>.zip` to a GitHub Release whenever you push a `v*` tag, e.g.:
  ```bash
  git tag v0.1.0 && git push origin v0.1.0
  ```

## Project layout

```
signal/
├── hooks/signal_hook.py     # records session status to a state file (stdlib only)
├── install/install.py       # merges hooks into ~/.claude/settings.json
├── tests/test_signal_hook.py
├── app/                     # SwiftUI MenuBarExtra menu bar app
│   ├── Package.swift
│   ├── Sources/Signal/
│   ├── Resources/Info.plist
│   └── build-app.sh
├── .github/workflows/       # CI build + tagged releases
├── README.md
└── LICENSE
```

## License

MIT — see [LICENSE](LICENSE).
