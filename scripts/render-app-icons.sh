#!/usr/bin/env bash
# Render the app icon sets from their SVG sources in design/app-icons.
#
# 16pt and 32pt use the small drawings, whose thicker lines stay apart at
# those sizes. Needs Google Chrome, which draws the SVG, and sips, which scales it.
#
# Usage: scripts/render-app-icons.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

draw() { # svg, png
  "$CHROME" --headless=new --disable-gpu --hide-scrollbars \
    --user-data-dir="$TMP/chrome" --force-device-scale-factor=1 \
    --window-size=1024,1024 --screenshot="$2" "file://$1" >/dev/null 2>&1
}

render_set() { # regular svg, small svg, icon set
  local master="$TMP/master.png" small="$TMP/small.png" set="$ROOT/Weir/Resources/Assets.xcassets/$3"
  draw "$ROOT/design/app-icons/$1" "$master"
  draw "$ROOT/design/app-icons/$2" "$small"
  scale() { sips -z "$2" "$2" "$1" --out "$set/$3" >/dev/null; }
  scale "$small" 16 icon_16x16.png
  scale "$small" 32 icon_16x16@2x.png
  scale "$small" 32 icon_32x32.png
  scale "$small" 64 icon_32x32@2x.png
  scale "$master" 128 icon_128x128.png
  scale "$master" 256 icon_128x128@2x.png
  scale "$master" 256 icon_256x256.png
  scale "$master" 512 icon_256x256@2x.png
  scale "$master" 512 icon_512x512.png
  scale "$master" 1024 icon_512x512@2x.png
}

render_set weir-app.svg weir-app-small.svg AppIcon.appiconset
render_set weir-dev.svg weir-dev-small.svg AppIcon-Dev.appiconset
