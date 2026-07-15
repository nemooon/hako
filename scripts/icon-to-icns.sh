#!/bin/bash
# Icon Composer からエクスポートした 1024x1024 PNG を Resources/Hako.icns に変換する
# 使い方: scripts/icon-to-icns.sh <エクスポートした PNG>
set -euo pipefail

cd "$(dirname "$0")/.."

PNG="${1:?使い方: scripts/icon-to-icns.sh <1024x1024 の PNG>}"
ICONSET="$(mktemp -d)/Hako.iconset"
mkdir -p "$ICONSET"

for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$PNG" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$PNG" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$ICONSET" -o Resources/Hako.icns
echo "更新しました: Resources/Hako.icns"
