#!/usr/bin/env bash
# One-line installer for Signal.
#
#   curl -fsSL https://raw.githubusercontent.com/thepranky/signal/master/scripts/install.sh | bash
#
# Downloads the latest release, installs Signal.app into /Applications, and
# launches it. Because the download happens over curl (not a browser), macOS
# does NOT apply the com.apple.quarantine flag, so there's no "damaged" warning
# and no Gatekeeper bypass needed — we still strip quarantine defensively.
set -euo pipefail

REPO="thepranky/signal"
APP="Signal.app"
DEST="/Applications"

if [ "$(uname -s)" != "Darwin" ]; then
  echo "error: Signal is macOS-only." >&2
  exit 1
fi

echo "Looking up the latest Signal release..."
TAG="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
  | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)"
if [ -z "${TAG:-}" ]; then
  echo "error: couldn't determine the latest release tag." >&2
  exit 1
fi

URL="https://github.com/$REPO/releases/download/$TAG/Signal-$TAG.zip"
echo "Downloading Signal $TAG ..."

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

curl -fsSL "$URL" -o "$TMP/Signal.zip"
ditto -x -k "$TMP/Signal.zip" "$TMP"

if [ ! -d "$TMP/$APP" ]; then
  echo "error: downloaded archive did not contain $APP." >&2
  exit 1
fi

echo "Installing to $DEST/$APP ..."
rm -rf "${DEST:?}/$APP"
mv "$TMP/$APP" "$DEST/"

# Belt-and-suspenders: curl shouldn't have quarantined it, but make sure.
xattr -dr com.apple.quarantine "$DEST/$APP" 2>/dev/null || true

echo "Launching Signal..."
open "$DEST/$APP"

cat <<'EOF'

Signal is installed. Look for its icon in the menu bar (top-right).
Click it, then "Set up Claude Code hooks" to start tracking sessions.
EOF
