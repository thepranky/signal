#!/usr/bin/env bash
# Write the Homebrew cask for a specific Signal release.
#
#   ./scripts/write-cask.sh 0.1.6 <sha256> Casks/signal-agent.rb
set -euo pipefail

VERSION="${1:-}"
SHA="${2:-}"
OUT="${3:-}"

if [ -z "$VERSION" ] || [ -z "$SHA" ] || [ -z "$OUT" ]; then
  echo "usage: $0 <version> <sha256> <output-cask>" >&2
  exit 1
fi

VERSION="${VERSION#v}"
mkdir -p "$(dirname "$OUT")"

cat > "$OUT" <<EOF
cask "signal-agent" do
  version "$VERSION"
  sha256 "$SHA"

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
EOF
