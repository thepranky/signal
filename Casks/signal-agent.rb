cask "signal-agent" do
  version "0.1.18"
  sha256 "aa26cce0faeee5fa38bc569ef122e3f0fc02a84536624c96a2f9ac6ab9bbd830"

  url "https://github.com/thepranky/signal/releases/download/v#{version}/Signal-v#{version}.dmg"
  name "Signal"
  desc "Menu bar monitor for Claude, Cursor, and Codex agent sessions"
  homepage "https://github.com/thepranky/signal"

  # Signal is ad-hoc signed, not notarized; let Homebrew clear quarantine.
  auto_updates true
  depends_on macos: :ventura

  app "Signal.app"

  postflight do
    system_command "/usr/bin/xattr",
                   args:         ["-dr", "com.apple.quarantine", "#{appdir}/Signal.app"],
                   must_succeed: false
  end

  caveats <<~EOS
    Signal is a menu bar app (no Dock icon). After installing, click its icon
    in the menu bar (top-right), then "Set up hooks" to begin tracking your
    agent sessions. For Codex, run /hooks and trust Signal's hooks if Codex
    prompts you.
  EOS
end
