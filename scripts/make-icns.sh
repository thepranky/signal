#!/usr/bin/env bash
# Regenerate app/Resources/AppIcon.icns from assets/AppIcon-source.png.
# Requires macOS `sips` and `iconutil` (ships with the Command Line Tools).
set -euo pipefail

cd "$(dirname "$0")/.."

SRC="assets/AppIcon-source.png"
OUT="app/Resources/AppIcon.icns"
WORK="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$WORK"

# Center-crop to a square, then scale that master to each required size.
SQUARE="$(mktemp).png"
sips -c 1024 1024 "$SRC" --out "$SQUARE" >/dev/null

for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$SQUARE" --out "$WORK/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" "$SQUARE" --out "$WORK/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$WORK" -o "$OUT"
echo "Wrote $OUT"
