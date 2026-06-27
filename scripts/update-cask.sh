#!/usr/bin/env bash
# Manually update Casks/signal-agent.rb to a released version by fetching its
# DMG and recomputing the checksum. Normal tagged releases update the
# thepranky/homebrew-signal tap directly from .github/workflows/release.yml;
# this helper is for backfills or manual cask edits in this repo.
#
#   ./scripts/update-cask.sh 0.1.6
set -euo pipefail

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
  echo "usage: $0 <version>   e.g. $0 0.1.6" >&2
  exit 1
fi
VERSION="${VERSION#v}"

REPO="thepranky/signal"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CASK="$ROOT/Casks/signal-agent.rb"
URL="https://github.com/$REPO/releases/download/v$VERSION/Signal-v$VERSION.dmg"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Fetching $URL ..."
curl -fsSL "$URL" -o "$TMP/Signal.dmg"
SHA="$(shasum -a 256 "$TMP/Signal.dmg" | cut -d' ' -f1)"

echo "version $VERSION  sha256 $SHA"

"$ROOT/scripts/write-cask.sh" "$VERSION" "$SHA" "$CASK"

echo "Updated $CASK"
