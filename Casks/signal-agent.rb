cask "signal-agent" do
  version "0.1.8"
  sha256 "5d5cfc5b9afe96b2b8d8efc0c1ac5da6e13ac1cfaea8c54b1a3c78490fdb2f06"

  url "https://github.com/thepranky/signal/releases/download/v#{version}/Signal-v#{version}.dmg"
  name "Signal"
  desc "Menu bar traffic-light monitor for AI coding agent sessions"
  homepage "https://github.com/thepranky/signal"

  # Signal is ad-hoc signed, not notarized; let Homebrew clear quarantine.
  auto_updates false
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
    agent sessions.
  EOS
end
