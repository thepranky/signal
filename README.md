# Signal

A lightweight macOS menu bar app that monitors all your active **AI coding
agent** sessions with a traffic-light system — across the Claude Code
(CLI + Desktop), Cursor, OpenAI Codex, and the VS Code extensions, all at
once. Each session shows an excerpt of its first prompt and a tag for the client
it came from.

Each session gets its own colored circle:

- 🔴 **Red** — the agent is actively running and doing work.
- 🟡 **Yellow** — the agent is blocked, waiting for your approval (a permission prompt).
- 🟢 **Green** — the agent finished its turn and is idle.

When a session ends, its circle disappears.

## How it works

```
Claude Code + Cursor + Codex
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
- [Claude Code](https://claude.com/claude-code), [Cursor](https://cursor.com), and/or [Codex](https://developers.openai.com/codex) installed.

## Install (Option 1: one line — recommended)

```bash
curl -fsSL https://raw.githubusercontent.com/thepranky/signal/master/scripts/install.sh | bash
```

This grabs the latest release, installs `Signal.app` into `/Applications`, and
launches it. Then click **Set up hooks** in the menu.

Signal checks for app updates automatically. You can also click the refresh icon
in the menu to check immediately.

## Install (Option 2: Homebrew)

```bash
brew install --cask thepranky/signal/signal-agent
```

This installs `Signal.app` into `/Applications` and launches it. Then click
**Set up hooks** in the menu. Signal updates itself after install; you can still
run `brew upgrade --cask signal-agent` if you prefer managing updates through
Homebrew.

## Install (Option 3: download)

1. Download `Signal-vX.Y.Z.dmg` from [Releases](../../releases) and open it.
2. Move `Signal.app` to `/Applications` (or accept the in-app prompt).
3. If macOS blocks launch, clear quarantine:
   ```bash
   xattr -dr com.apple.quarantine /Applications/Signal.app
   ```
4. Click the menu bar icon (top-right, near the clock) → **Set up hooks**.

After the first install, Signal checks for updates in the background. When a new
version is available, macOS shows a standard update prompt; click **Install and
Relaunch** to finish.

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

## Uninstall

`brew uninstall --cask signal-agent` quits Signal, removes its hooks from Claude,
Cursor, and Codex settings, then deletes the app. This leaves the rest of your
agent settings untouched.

```bash
pkill -x Signal 2>/dev/null || true
brew uninstall --cask signal-agent
```

To also remove local session state:

```bash
rm -rf ~/.signal
```

If you installed from a DMG instead of Homebrew, delete `/Applications/Signal.app`
and run `python3 install/install.py --uninstall` from a clone of this repo (or use
the bundled `Signal.app/Contents/Resources/install.py`). If you enabled **Start
at login**, also remove Signal under **System Settings → General → Login Items**.

## Status mapping

| Color | Meaning | Claude Code event(s) | Cursor event(s) | Codex event(s) |
|-------|---------|----------------------|-----------------|----------------|
| 🔴 Red | Actively running | `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `PostToolUseFailure` | `beforeSubmitPrompt`, `preToolUse`, `postToolUse`, `postToolUseFailure` | `UserPromptSubmit`, `PreToolUse`, `PostToolUse` |
| 🟡 Yellow | Waiting for your approval | `Notification` (`permission_prompt`), `PermissionRequest` | — | `PermissionRequest` |
| 🟢 Green | Finished turn, idle | `Stop`, `StopFailure` | `stop` | `Stop` |
| (no circle) | Session ended | `SessionEnd`, or staleness timeout | `sessionEnd`, or staleness timeout | Staleness timeout |

The installed hooks are copied to a stable `~/.signal/signal_hook.py` and tagged
with a `SIGNAL_HOOK=1` marker, so moving the app/repo doesn't break them and
uninstalling only ever removes Signal's own hooks.

> **Note:** agents can't natively distinguish "finished the whole task" from
> "finished by asking you a clarifying question" — both just end a turn, so both
> show green. Only Claude Code permission prompts surface as a distinct "waiting"
> (yellow) state in every Claude surface; Cursor has no equivalent event, so
> Cursor sessions go red → green only. Codex exposes permission requests as a
> hook event, but it does not currently document a session-end hook, so Codex
> sessions are removed by Signal's shorter Codex-done staleness timeout if they
> are left green.

## Which sessions are tracked

Signal installs hooks into Claude Code's global `~/.claude/settings.json`,
Cursor's native `~/.cursor/hooks.json`, and Codex's user-level
`~/.codex/hooks.json`:

- **Claude** — the Claude Code CLI.
- **Cursor** — Cursor's built-in agent.
- **Codex** — OpenAI Codex local sessions.
- **VS Code** / **Claude Desktop** — detected from the transcript's
  `entrypoint` field.

**Note**: Codex treats newly added user command hooks as untrusted until you review them.
After clicking **Set up hooks**, open Codex and run `/hooks` if prompted, then press `t` to trust Signal's command hooks so Codex can run them.

## Configuration

- **State directory** — defaults to `~/.signal/sessions`. Override with the
  `SIGNAL_STATE_DIR` environment variable (honored by both the hook and the app).
- **Staleness timeout** — sessions whose state file hasn't updated in 12 hours
  are dropped, in case a session dies without firing `SessionEnd`. Done Codex
  sessions are dropped after 30 minutes because Codex does not currently
  document a session-end hook.

## Local data and privacy

Signal does not send session data over the network. The hook writes one JSON file
per live session under `~/.signal/sessions/`, containing the session id, status,
project name, client tag, current working directory, transcript path, update time,
and a short excerpt of the first user prompt. These files are removed when the
session ends, later by the staleness timeout if the agent exits without a normal
end event, or immediately if you clear a row from the menu. A cleared session can
reappear if the agent emits another hook event.

## Tests

The hook handler and Python installer are covered with stdlib `unittest`
subprocess tests, so the tests exercise the same CLI/stdin contract users hit:

```bash
python3 -m unittest discover -s tests -v
```

CI runs these on every push and before every release.

## Continuous integration

- **CI** (`.github/workflows/ci.yml`) runs the hook tests and builds `Signal.app`
  on a macOS runner for every push/PR, uploading the build as a downloadable
  artifact. This means neither maintainers nor users need Xcode locally.
- **Release** (`.github/workflows/release.yml`) builds and attaches
  `Signal-<tag>.zip`, `Signal-<tag>.dmg`, and Sparkle's signed `appcast.xml` to
  a GitHub Release whenever you push a `v*` tag, then updates this repo's
  `Casks/signal-agent.rb` and the Homebrew tap with the matching cask version
  and DMG checksum, e.g.:
  ```bash
  git tag v0.1.0 && git push origin v0.1.0
  ```
  Set the `HOMEBREW_TAP_TOKEN` repo secret (PAT with `contents:write` on
  `thepranky/homebrew-signal`) and keep that mirror repo **unarchived** so
  pushes succeed. Set `SPARKLE_PRIVATE_KEY` to the private EdDSA key exported
  by Sparkle's `generate_keys` tool; only the matching public key is committed
  in `app/Resources/Info.plist`. The separate
  `.github/workflows/sync-homebrew-tap.yml` workflow only mirrors manual changes
  to `Casks/signal-agent.rb`.
  ```bash
  cd app
  .build/artifacts/sparkle/Sparkle/bin/generate_keys --account dev.signal.claudemonitor -x /tmp/signal-sparkle-private-key
  gh secret set SPARKLE_PRIVATE_KEY < /tmp/signal-sparkle-private-key
  rm /tmp/signal-sparkle-private-key
  ```

## Known limitations

- **Not notarized.** Distributed builds are only ad-hoc signed, so Gatekeeper
  still warns on first launch (see the bypass above). Full Developer ID signing +
  notarization requires a paid Apple Developer account and is intentionally not
  done; the auto-move-to-Applications step strips quarantine from the relocated
  copy to soften the rough edge.
- **Update prompts are user-confirmed.** Signal checks for updates automatically
  with Sparkle, but users still approve installation in the standard Sparkle
  prompt before the app relaunches.
- **Stale sessions can linger.** Without a heartbeat, Signal can't always tell
  an idle-but-alive session from a force-closed one, so dead sessions are pruned
  by a timeout rather than instantly. Normal Claude/Cursor exits remove their
  circle immediately via `SessionEnd`; done Codex sessions use a 30-minute
  timeout because Codex does not currently document a session-end hook.
- **Settings writes aren't locked.** The installer reads, merges, and atomically
  writes `~/.claude/settings.json`, `~/.cursor/hooks.json`, and
  `~/.codex/hooks.json` (backing existing files up first). It does not hold a
  file lock, so a simultaneous hand-edit during install could be lost.

## Project layout

```
signal/
├── hooks/signal_hook.py     # records session status to a state file (stdlib only)
├── install/install.py       # merges hooks into Claude, Cursor, and Codex settings
├── tests/test_signal_hook.py
├── app/                     # SwiftUI MenuBarExtra menu bar app
│   ├── Package.swift
│   ├── Sources/Signal/      # incl. AppRelocator (auto-move) + LoginItem
│   ├── Resources/Info.plist
│   ├── build-app.sh         # build + ad-hoc sign Signal.app
│   └── build-dmg.sh         # package Signal.app into a .dmg
├── scripts/install.sh       # one-line curl installer (no quarantine)
├── scripts/update-cask.sh   # manually refresh the repo-local Homebrew cask
├── Casks/signal-agent.rb    # Homebrew cask (tap this repo directly)
├── .github/workflows/       # CI, releases, Homebrew tap sync
├── README.md
└── LICENSE
```

## License

MIT — see [LICENSE](LICENSE).
