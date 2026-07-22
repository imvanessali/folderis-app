#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

# The supplied artwork has generous whitespace. Zoom the complete image as one
# piece so the Folderis mark occupies roughly the same proportion as Dia's icon.
SOURCE="${1:-AppIconSource.png}"
MASTER="icon_1024.png"

sips --cropToHeightWidth 768 768 "$SOURCE" --out "$MASTER" >/dev/null
sips --resampleHeightWidth 1024 1024 "$MASTER" --out "$MASTER" >/dev/null

mkdir -p AppIcon.iconset
sips -z 16 16       "$MASTER" --out AppIcon.iconset/icon_16x16.png >/dev/null
sips -z 32 32       "$MASTER" --out AppIcon.iconset/icon_16x16@2x.png >/dev/null
sips -z 32 32       "$MASTER" --out AppIcon.iconset/icon_32x32.png >/dev/null
sips -z 64 64       "$MASTER" --out AppIcon.iconset/icon_32x32@2x.png >/dev/null
sips -z 128 128     "$MASTER" --out AppIcon.iconset/icon_128x128.png >/dev/null
sips -z 256 256     "$MASTER" --out AppIcon.iconset/icon_128x128@2x.png >/dev/null
sips -z 256 256     "$MASTER" --out AppIcon.iconset/icon_256x256.png >/dev/null
sips -z 512 512     "$MASTER" --out AppIcon.iconset/icon_256x256@2x.png >/dev/null
sips -z 512 512     "$MASTER" --out AppIcon.iconset/icon_512x512.png >/dev/null
sips -z 1024 1024   "$MASTER" --out AppIcon.iconset/icon_512x512@2x.png >/dev/null

iconutil -c icns AppIcon.iconset -o AppIcon.icns
echo "Updated AppIcon.icns from $SOURCE"
