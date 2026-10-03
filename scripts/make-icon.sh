#!/bin/sh
# Regenerates the app icon (#22) from scripts/render-icon.swift:
#   Resources/AppIcon.icns  (copied into the bundle by scripts/bundle.sh)
#   docs/icon.png           (256px rendering shown at the top of the README)
# Both outputs are checked in; rerun this after editing render-icon.swift.
set -eu
cd "$(dirname "$0")/.."
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
swift scripts/render-icon.swift "$TMP/master.png" >/dev/null
SET="$TMP/AppIcon.iconset"
mkdir "$SET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$TMP/master.png" --out "$SET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z $d $d "$TMP/master.png" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o Resources/AppIcon.icns
cp "$SET/icon_128x128@2x.png" docs/icon.png
echo Resources/AppIcon.icns docs/icon.png
