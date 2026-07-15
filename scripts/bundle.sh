#!/bin/bash
# release ビルドを .app バンドルにまとめる
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="Hako"
BUNDLE_ID="com.nemooon.hako"
VERSION="0.2"
DIST="dist/${APP_NAME}.app"

swift build -c release

rm -rf "$DIST"
mkdir -p "$DIST/Contents/MacOS" "$DIST/Contents/Resources"

cp ".build/release/${APP_NAME}" "$DIST/Contents/MacOS/${APP_NAME}"
cp "Resources/${APP_NAME}.icns" "$DIST/Contents/Resources/${APP_NAME}.icns"

cat > "$DIST/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIconFile</key>
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
