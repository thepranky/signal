# Signal

A lightweight macOS menu bar app that monitors all your active **AI coding
agent** sessions with a traffic-light system — across the Claude Code
CLI, Claude desktop app, Cursor's agent, and the VS Code extension, all at
once. Each session shows an excerpt of its first prompt and a tag for the client
it came from.

Each session gets its own colored circle:

- 🔴 **Red** — the agent is actively running and doing work.
- 🟡 **Yellow** — the agent is blocked, waiting for your approval (a permission prompt).
- 🟢 **Green** — the agent finished its turn and is idle.

When a session ends, its circle disappears.

## How it works

```
Claude Code + Cursor
   │  
   ▼
signal_hook.py   ──writes──▶   ~/.signal/sessions/<session_id>.json
                                        │  watched by
                                        ▼
                              Signal.app (menu bar)  →  🔴🟡🟢
```

1. **Hooks** — agent lifecycle events write each session's status to a JSON file in `~/.signal/sessions/`.
2. **Menu bar app** — watches that directory and shows one circle per live session.

Plain JSON on disk — no daemon, no network.

## Requirements

- macOS 13 or later.
- [Claude Code](https://claude.com/claude-code) and/or [Cursor](https://cursor.com) installed.

## Install (Option 1: one line — recommended)

```bash
curl -fsSL https://raw.githubusercontent.com/thepranky/signal/master/scripts/install.sh | bash
```

This grabs the latest release, installs `Signal.app` into `/Applications`, and
launches it. Then click **Set up hooks** in the menu.

To update, run the same command again.

## Install (Option 2: Homebrew)

The cask lives in this repo (`Casks/signal-agent.rb`). Homebrew auto-taps it on
install — no separate `homebrew-signal` mirror repo.

```bash
brew install --cask thepranky/signal/signal-agent
```

Same setup step in the menu. To update: `brew upgrade --cask signal-agent`.

If you previously installed the old `signal` cask from the deprecated mirror
tap, remove it first:

```bash
brew uninstall --cask signal 2>/dev/null; brew untap thepranky/signal 2>/dev/null
brew install --cask thepranky/signal/signal-agent
```

## Install (Option 3: download)

1. Download `Signal-vX.Y.Z.dmg` from [Releases](../../releases) and open it.
2. Move `Signal.app` to `/Applications` (or accept the in-app prompt).
3. If macOS blocks launch, clear quarantine:
   ```bash
   xattr -dr com.apple.quarantine /Applications/Signal.app
   ```
4. Click the menu bar icon (top-right, near the clock) → **Set up hooks**.

## Install (Option 4: build from source)

```bash
git clone <your-fork-url> signal
cd signal
python3 install/install.py
cd app && ./build-app.sh && open Signal.app
```

Requires Xcode (not just Command Line Tools). Optionally run `./build-dmg.sh` to package a disk image.

### Preview the hook config without writing anything

```bash
python3 install/install.py --dry-run
```

### Uninstall the hooks

```bash
python3 install/install.py --uninstall
```

This removes only Signal's hooks and leaves the rest of your Claude Code and
Cursor settings untouched.

## Status mapping

| Color | Meaning | Claude Code event(s) | Cursor event(s) |
|-------|---------|----------------------|-----------------|
| 🔴 Red | Actively running | `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `PostToolUseFailure` | `beforeSubmitPrompt`, `preToolUse`, `postToolUse`, `postToolUseFailure` |
| 🟡 Yellow | Waiting for your approval | `Notification` (`permission_prompt`), `PermissionRequest` | — |
| 🟢 Green | Finished turn, idle | `Stop`, `StopFailure` | `stop` |
| (no circle) | Session ended | `SessionEnd`, or staleness timeout | `sessionEnd`, or staleness timeout |

The installed hooks are copied to a stable `~/.signal/signal_hook.py` and tagged
with a `SIGNAL_HOOK=1` marker, so moving the app/repo doesn't break them and
uninstalling only ever removes Signal's own hooks.

> **Note:** agents can't natively distinguish "finished the whole task" from
> "finished by asking you a clarifying question" — both just end a turn, so both
> show green. Only Claude Code permission prompts surface as a distinct "waiting"
> (yellow) state; Cursor has no equivalent event, so Cursor sessions go red →
> green only.

## Which sessions are tracked

Signal installs hooks into both Claude Code's global `~/.claude/settings.json`
and Cursor's native `~/.cursor/hooks.json`, so it tracks the **terminal CLI, the
VS Code extension, the Claude desktop app, and Cursor's agent**. Each session is
shown with a short excerpt of its first prompt, plus a client tag:

- **Claude** — the Claude Code CLI.
- **Cursor** — Cursor's built-in agent.
- **VS Code** / **Claude Desktop** — detected from the transcript's
  `entrypoint` field.

Cursor's hook events don't include a working directory, so Signal falls back to
the workspace root (or the project encoded in the transcript path) to label them.

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

## Known limitations

- **Not notarized.** Distributed builds are only ad-hoc signed, so Gatekeeper
  still warns on first launch (see the bypass above). Full Developer ID signing +
  notarization requires a paid Apple Developer account and is intentionally not
  done; the auto-move-to-Applications step strips quarantine from the relocated
  copy to soften the rough edge.
- **No auto-update.** Downloaded builds don't update themselves yet; grab new
  releases manually (Sparkle integration is a future option).
- **Stale sessions linger up to 12h.** Without a heartbeat, Signal can't tell an
  idle-but-alive session from a force-closed one, so dead sessions are pruned by
  a timeout rather than instantly. Normal exits remove their circle immediately
  via `SessionEnd`.
- **Settings writes aren't locked.** The installer reads, merges, and atomically
  writes `~/.claude/settings.json` (backing it up first). It does not hold a file
  lock, so a simultaneous hand-edit during install could be lost.

## Project layout

```
signal/
├── hooks/signal_hook.py     # records session status to a state file (stdlib only)
├── install/install.py       # merges hooks into ~/.claude/settings.json + ~/.cursor/hooks.json
├── tests/test_signal_hook.py
├── app/                     # SwiftUI MenuBarExtra menu bar app
│   ├── Package.swift
│   ├── Sources/Signal/      # incl. AppRelocator (auto-move) + LoginItem
│   ├── Resources/Info.plist
│   ├── build-app.sh         # build + ad-hoc sign Signal.app
│   └── build-dmg.sh         # package Signal.app into a .dmg
├── scripts/install.sh       # one-line curl installer (no quarantine)
├── scripts/update-cask.sh   # bump the Homebrew cask after a release
├── Casks/signal-agent.rb    # Homebrew cask (tap this repo directly)
├── .github/workflows/       # CI build + tagged releases
├── README.md
└── LICENSE
```

## License

MIT — see [LICENSE](LICENSE).
