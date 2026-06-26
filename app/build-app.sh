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
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH" "$APP/Contents/MacOS/Signal"
cp Resources/Info.plist "$APP/Contents/Info.plist"

echo "Done: $(pwd)/$APP"
echo "Run it with: open $APP"
