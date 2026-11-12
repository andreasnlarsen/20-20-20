#!/bin/bash
# Makes Resources/AppIcon.icns from Resources/AppIcon.png, the app icon's artwork
# (1024 pixels square, the tile 824 pixels wide in the middle, as macOS icons are laid out).
# Run it after the artwork changes, then build.
set -euo pipefail
cd "$(dirname "$0")"

iconset="build/AppIcon.iconset"
mkdir -p "$iconset"
while read -r name pixels; do
  sips -z "$pixels" "$pixels" Resources/AppIcon.png --out "$iconset/$name.png" >/dev/null
done <<'SIZES'
icon_16x16 16
icon_16x16@2x 32
icon_32x32 32
icon_32x32@2x 64
icon_128x128 128
icon_128x128@2x 256
icon_256x256 256
icon_256x256@2x 512
icon_512x512 512
icon_512x512@2x 1024
SIZES
iconutil -c icns "$iconset" -o Resources/AppIcon.icns
echo "Resources/AppIcon.icns"
