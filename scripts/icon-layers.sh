#!/bin/bash
# Resources/Hako.svg のグループ (box / tape / label) を
# Icon Composer 用のレイヤー PNG (1024x1024、背景透明) として Resources/Hako.icon/Assets に書き出す
# 使い方: scripts/icon-layers.sh
set -euo pipefail

cd "$(dirname "$0")/.."

SVG="Resources/Hako.svg"
OUT="Resources/Hako.icon/Assets"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUT"

for layer in box tape label; do
    # 対象以外の <g id="..."> を取り除いた SVG を作る (sips は display="none" を無視する)
    python3 -I - "$SVG" "$layer" "$WORK/$layer.svg" <<'PY'
import sys, xml.etree.ElementTree as ET
src, keep, dst = sys.argv[1:]
NS = "http://www.w3.org/2000/svg"
ET.register_namespace("", NS)
tree = ET.parse(src)
ids = {"box", "tape", "label"}
found = False
for parent in list(tree.iter()):
    for g in list(parent):
        gid = g.get("id")
        if g.tag == f"{{{NS}}}g" and gid in ids and gid != keep:
            parent.remove(g)
        found |= gid == keep
if not found:
    sys.exit(f"{src} に <g id=\"{keep}\"> がありません")
tree.write(dst, encoding="utf-8", xml_declaration=True)
PY
    sips -s format png -z 1024 1024 "$WORK/$layer.svg" --out "$OUT/$layer.png" >/dev/null
    echo "書き出しました: $OUT/$layer.png"
done
