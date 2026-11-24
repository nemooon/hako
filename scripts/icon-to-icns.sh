#!/bin/bash
# アイコンの元データ (SVG または 1024x1024 PNG) を Resources/Hako.icns に変換する
# 使い方: scripts/icon-to-icns.sh [入力ファイル]   (省略時は Resources/Hako.svg)
set -euo pipefail

cd "$(dirname "$0")/.."

SRC="${1:-Resources/Hako.svg}"
[[ -f "$SRC" ]] || { echo "見つかりません: $SRC" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ICONSET="$WORK/Hako.iconset"
mkdir -p "$ICONSET"

case "$SRC" in
    *.svg)
        PNG="$WORK/source.png"
        sips -s format png -z 1024 1024 "$SRC" --out "$PNG" >/dev/null
        ;;
    *)
        PNG="$SRC"
        ;;
esac

for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$PNG" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$PNG" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$ICONSET" -o Resources/Hako.icns
echo "更新しました: Resources/Hako.icns"
