#!/usr/bin/env bash
# Render AppIcon.svg into the .iconset directory at every size macOS asks
# for, then call iconutil to produce AppIcon.icns.
#
# Requires: rsvg-convert (brew install librsvg) or qlmanage as a fallback.
set -euo pipefail

cd "$(dirname "$0")"
SVG="AppIcon.svg"
ICONSET="AppIcon.iconset"

mkdir -p "$ICONSET"

render() {
    local size=$1 file=$2
    if command -v rsvg-convert >/dev/null 2>&1; then
        rsvg-convert -w "$size" -h "$size" -o "$ICONSET/$file" "$SVG"
    else
        # qlmanage emits at a fixed size with .svg.png suffix; postprocess.
        qlmanage -t -s "$size" -o "$ICONSET" "$SVG" >/dev/null 2>&1
        mv "$ICONSET/$SVG.png" "$ICONSET/$file"
    fi
}

# Apple's required sizes — single-resolution + Retina @2x for each.
render 16   icon_16x16.png
render 32   icon_16x16@2x.png
render 32   icon_32x32.png
render 64   icon_32x32@2x.png
render 128  icon_128x128.png
render 256  icon_128x128@2x.png
render 256  icon_256x256.png
render 512  icon_256x256@2x.png
render 512  icon_512x512.png
render 1024 icon_512x512@2x.png

iconutil -c icns "$ICONSET" -o AppIcon.icns
ls -la AppIcon.icns
