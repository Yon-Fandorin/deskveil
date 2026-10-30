#!/bin/zsh
# Generate the same artwork, including on systems where iconutil rejects a PNG iconset.
set -euo pipefail
iconset="$1"
destination="$2"
swift Tools/Distribution/artwork.swift icon "$iconset"
if ! iconutil -c icns "$iconset" -o "$destination"; then
    print -u2 "iconutil could not convert the iconset; using the native ImageIO converter."
    sips -s format icns "$iconset/icon_512x512@2x.png" --out "$destination" >/dev/null
fi
[[ -s "$destination" ]] || { print -u2 "App icon generation failed."; exit 1; }
