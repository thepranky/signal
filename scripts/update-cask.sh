#!/usr/bin/env bash
# Update Casks/signal.rb to a released version by fetching its DMG and
# recomputing the checksum. Run after a release is published:
#
#   ./scripts/update-cask.sh 0.1.5
set -euo pipefail

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
  echo "usage: $0 <version>   e.g. $0 0.1.5" >&2
  exit 1
fi
VERSION="${VERSION#v}"

REPO="thepranky/signal"
CASK="$(cd "$(dirname "$0")/.." && pwd)/Casks/signal.rb"
URL="https://github.com/$REPO/releases/download/v$VERSION/Signal-v$VERSION.dmg"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Fetching $URL ..."
curl -fsSL "$URL" -o "$TMP/Signal.dmg"
SHA="$(shasum -a 256 "$TMP/Signal.dmg" | cut -d' ' -f1)"

echo "version $VERSION  sha256 $SHA"

# Portable in-place edits (BSD/macOS sed needs the empty backup arg).
sed -i '' "s/^  version \".*\"/  version \"$VERSION\"/" "$CASK"
sed -i '' "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" "$CASK"

echo "Updated $CASK"
