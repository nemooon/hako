#!/bin/bash
# release ビルドを .app バンドルにまとめる
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="Hako"
BUNDLE_ID="com.nemooon.hako"
VERSION="0.7"
DIST="dist/${APP_NAME}.app"

# SwiftBuild がリンク時の SDK を deployment target として記録する環境を回避する。
# Liquid Glass の自動適用には、実際に使用した SDK の記録が必要。
swift build --build-system native -c release

rm -rf "$DIST"
mkdir -p "$DIST/Contents/MacOS" "$DIST/Contents/Resources"

cp ".build/release/${APP_NAME}" "$DIST/Contents/MacOS/${APP_NAME}"

# Icon Composer のアイコンを、macOS 26 以降用の Assets.car と古い macOS 用の icns にコンパイルする
xcrun actool "Resources/${APP_NAME}.icon" \
    --compile "$DIST/Contents/Resources" \
    --platform macosx \
    --minimum-deployment-target 14.4 \
    --app-icon "$APP_NAME" \
    --output-partial-info-plist "$(mktemp -d)/partial.plist" >/dev/null
for f in Assets.car "${APP_NAME}.icns"; do
    [[ -f "$DIST/Contents/Resources/$f" ]] || { echo "actool が $f を出力しませんでした" >&2; exit 1; }
done

cat > "$DIST/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIconFile</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIconName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.4</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
EOF

codesign --force --sign - "$DIST"

echo "Created: $DIST"
