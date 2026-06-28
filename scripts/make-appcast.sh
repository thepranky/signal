#!/usr/bin/env bash
# Create the Sparkle appcast for a released DMG. The private EdDSA key is read
# from SPARKLE_PRIVATE_KEY and should be stored as a GitHub Actions secret.
set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "usage: $0 <version> <dmg-path> <output-appcast>" >&2
  exit 1
fi

VERSION="$1"
DMG="$2"
OUT="$3"
REPO="${GITHUB_REPOSITORY:-thepranky/signal}"

if [ -z "${SPARKLE_PRIVATE_KEY:-}" ]; then
  echo "error: SPARKLE_PRIVATE_KEY is not set." >&2
  exit 1
fi

if [ ! -f "$DMG" ]; then
  echo "error: $DMG not found." >&2
  exit 1
fi

SIGN_UPDATE="$(find app/.build -path '*/Sparkle/bin/sign_update' -type f | head -n 1)"
if [ -z "$SIGN_UPDATE" ]; then
  echo "error: Sparkle sign_update tool not found. Run app/build-app.sh first." >&2
  exit 1
fi

TMP_KEY="$(mktemp)"
trap 'rm -f "$TMP_KEY"' EXIT
printf '%s' "$SPARKLE_PRIVATE_KEY" > "$TMP_KEY"

SIGNATURE="$("$SIGN_UPDATE" --ed-key-file "$TMP_KEY" "$DMG" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')"
if [ -z "$SIGNATURE" ]; then
  echo "error: could not sign $DMG for Sparkle." >&2
  exit 1
fi

LENGTH="$(wc -c < "$DMG" | tr -d ' ')"
PUB_DATE="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S %z')"
URL="https://github.com/$REPO/releases/download/v$VERSION/Signal-v$VERSION.dmg"

cat > "$OUT" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Signal Updates</title>
    <item>
      <title>Signal $VERSION</title>
      <pubDate>$PUB_DATE</pubDate>
      <sparkle:version>$VERSION</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <enclosure
        url="$URL"
        sparkle:edSignature="$SIGNATURE"
        sparkle:version="$VERSION"
        sparkle:shortVersionString="$VERSION"
        length="$LENGTH"
        type="application/octet-stream" />
    </item>
  </channel>
</rss>
EOF
