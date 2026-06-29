cask "signal-agent" do
  version "0.1.26"
  sha256 "e324a5c2bc54811fe9880e6e7909e5913663a3d01c5ff82ae3ba1089f3cb14db"

  url "https://github.com/thepranky/signal/releases/download/v#{version}/Signal-v#{version}.dmg"
  name "Signal"
  desc "Menu bar monitor for Claude, Cursor, and Codex agent sessions"
  homepage "https://github.com/thepranky/signal"

  # Signal is ad-hoc signed, not notarized; let Homebrew clear quarantine.
  auto_updates true
  depends_on macos: :ventura

  app "Signal.app"

  uninstall quit: "Signal"

  uninstall_preflight do
    uninstall_script = "#{appdir}/Signal.app/Contents/Resources/install.py"
    if File.exist?(uninstall_script)
      system_command "/usr/bin/python3",
                     args:         [uninstall_script, "--uninstall"],
                     must_succeed: false
    end
  end

  postflight do
    system_command "/usr/bin/xattr",
                   args:         ["-dr", "com.apple.quarantine", "#{appdir}/Signal.app"],
                   must_succeed: false
    system_command "/usr/bin/open",
                   args:         ["-a", "#{appdir}/Signal.app"],
                   must_succeed: false
  end

  caveats <<~EOS
    Signal is a menu bar app (no Dock icon). After installing, click its icon
    in the menu bar (top-right), then "Set up hooks" to begin tracking your
    agent sessions. For Codex, run /hooks and trust Signal's hooks if Codex
    prompts you.
  EOS
end
