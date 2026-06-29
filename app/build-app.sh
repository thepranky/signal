#!/usr/bin/env bash
# Build Signal.app from the Swift package.
# Requires a full Xcode install (or a Swift 5.7+ toolchain with the macOS 13+ SDK).
set -euo pipefail

cd "$(dirname "$0")"

echo "Building release binary..."
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)/Signal"
APP="Signal.app"

echo "Assembling $APP ..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_PATH" "$APP/Contents/MacOS/Signal"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Bundle the hook script so the app can install hooks on first launch.
cp ../hooks/signal_hook.py "$APP/Contents/Resources/signal_hook.py"
cp ../install/install.py "$APP/Contents/Resources/install.py"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

SPARKLE_FRAMEWORK="$(find .build -path '*/Sparkle.framework' -type d | head -n 1)"
if [ -z "$SPARKLE_FRAMEWORK" ]; then
  echo "error: Sparkle.framework not found after build." >&2
  exit 1
fi
cp -R "$SPARKLE_FRAMEWORK" "$APP/Contents/Frameworks/"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Signal"

# Ad-hoc sign the bundle. This is free (no Apple Developer account) and does NOT
# notarize — Gatekeeper still warns on first launch — but a valid signature is
# required for SMAppService (the "Start at login" toggle) to register the app.
echo "Ad-hoc signing $APP ..."
codesign --force --deep --sign - "$APP"

echo "Done: $(pwd)/$APP"
echo "Run it with: open $APP"
