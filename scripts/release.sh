#!/bin/bash
# bundle.sh の APP_NAME / VERSION でビルドし、zip を GitHub リリースとして公開する。
# リリースが published になると bump-cask.yml が tap の cask を更新する。
#
# 手順:
#   1. scripts/bundle.sh の VERSION を上げる
#   2. コミットして push
#   3. scripts/release.sh [リリースノートのファイル]
#      ファイルを省略した場合は gh がエディタを開くのでそこに書く
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME=$(grep -E '^APP_NAME=' scripts/bundle.sh | cut -d'"' -f2)
VERSION=$(grep -E '^VERSION=' scripts/bundle.sh | cut -d'"' -f2)
ZIP="dist/${APP_NAME}-${VERSION}.zip"
NOTES_FILE="${1:-}"

if gh release view "v${VERSION}" >/dev/null 2>&1; then
    echo "エラー: リリース v${VERSION} は既に存在します。scripts/bundle.sh の VERSION を上げてください。" >&2
    exit 1
fi

if [[ -n "$NOTES_FILE" && ! -f "$NOTES_FILE" ]]; then
    echo "エラー: リリースノートのファイルが見つかりません: ${NOTES_FILE}" >&2
    exit 1
fi

scripts/bundle.sh

rm -f "$ZIP"
# .app の拡張属性を保ったまま固める(展開側も ditto -x -k を使うと署名が保たれる)
ditto -c -k --keepParent "dist/${APP_NAME}.app" "$ZIP"

if [[ -n "$NOTES_FILE" ]]; then
    gh release create "v${VERSION}" "$ZIP" --title "${APP_NAME} ${VERSION}" --notes-file "$NOTES_FILE"
else
    gh release create "v${VERSION}" "$ZIP" --title "${APP_NAME} ${VERSION}"
fi

echo "リリースしました: v${VERSION}"
