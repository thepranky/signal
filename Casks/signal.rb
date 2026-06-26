cask "signal" do
  version "0.1.4"
  sha256 "5a2b788594d27e58fe2b469bc36f4a61627e2831a565d49427cd6e4d04ef8cd4"

  url "https://github.com/thepranky/signal/releases/download/v#{version}/Signal-v#{version}.dmg"
  name "Signal"
  desc "Menu bar traffic-light monitor for Claude Code sessions"
  homepage "https://github.com/thepranky/signal"

  # Signal is ad-hoc signed, not notarized; let Homebrew clear quarantine.
  auto_updates false
  depends_on macos: ">= :ventura"

  app "Signal.app"

  caveats <<~EOS
    Signal is a menu bar app (no Dock icon). After installing, click its icon
    in the menu bar (top-right), then "Set up Claude Code hooks" to begin
    tracking your sessions.
  EOS
end
