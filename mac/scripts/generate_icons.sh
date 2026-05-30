#!/usr/bin/env bash
# Regenerate AppIcon.appiconset from mac/design/app-icon-1024.png
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${1:-$ROOT/design/app-icon-1024.png}"
DST="$ROOT/OCRReview/Assets.xcassets/AppIcon.appiconset"

if [[ ! -f "$SRC" ]]; then
  echo "Source icon not found: $SRC" >&2
  exit 1
fi

mkdir -p "$DST"
cp "$SRC" "$DST/icon_1024.png"

declare -a SIZES=(
  "16:icon_16x16.png"
  "32:icon_16x16@2x.png"
  "32:icon_32x32.png"
  "64:icon_32x32@2x.png"
  "128:icon_128x128.png"
  "256:icon_128x128@2x.png"
  "256:icon_256x256.png"
  "512:icon_256x256@2x.png"
  "512:icon_512x512.png"
  "1024:icon_512x512@2x.png"
)

for spec in "${SIZES[@]}"; do
  size="${spec%%:*}"
  file="${spec#*:}"
  sips -z "$size" "$size" "$DST/icon_1024.png" --out "$DST/$file" >/dev/null
done

echo "Generated icons in $DST"
