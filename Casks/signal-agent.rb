cask "signal-agent" do
  version "0.1.6"
  sha256 "7b8ad633ccdab84918ac2ad8d29df5d2188370ddb4531e456cc6bee4130d97b6"

  url "https://github.com/thepranky/signal/releases/download/v#{version}/Signal-v#{version}.dmg"
  name "Signal"
  desc "Menu bar traffic-light monitor for AI coding agent sessions"
  homepage "https://github.com/thepranky/signal"

  # Signal is ad-hoc signed, not notarized; let Homebrew clear quarantine.
  auto_updates false
  depends_on macos: :ventura

  app "Signal.app"

  caveats <<~EOS
    Signal is a menu bar app (no Dock icon). After installing, click its icon
    in the menu bar (top-right), then "Set up hooks" to begin tracking your
    agent sessions.
  EOS
end
