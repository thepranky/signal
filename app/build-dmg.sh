#!/usr/bin/env bash
# Package the already-built Signal.app into a distributable .dmg with a drag
# target for /Applications. Run ./build-app.sh first.
#
#   ./build-dmg.sh [output.dmg]
#
# Uses only hdiutil (ships with macOS) so it works unchanged in CI.
set -euo pipefail

cd "$(dirname "$0")"

APP="Signal.app"
DMG="${1:-Signal.dmg}"

if [ ! -d "$APP" ]; then
  echo "error: $APP not found — run ./build-app.sh first." >&2
  exit 1
fi

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

echo "Staging DMG contents ..."
cp -R "$APP" "$STAGING/"
# The Applications symlink is what produces the classic "drag onto Applications"
# affordance when the user opens the mounted image.
ln -s /Applications "$STAGING/Applications"

echo "Creating $DMG ..."
rm -f "$DMG"
hdiutil create \
  -volname "Signal" \
  -srcfolder "$STAGING" \
  -fs HFS+ \
  -format UDZO \
  -ov \
  "$DMG"

echo "Done: $(pwd)/$DMG"
