#!/bin/bash
# ClaudeUsage.app をビルドして ~/Applications にインストールする。
# Xcode プロジェクトは使わず、swiftc で単一バイナリを作って .app バンドルを手組みする。
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="ClaudeUsage"
BUNDLE_ID="local.okada.claudeusage"
VERSION="1.0.0"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"
INSTALL_DIR="$HOME/Applications"

rm -rf "$BUILD_DIR"
mkdir -p "$APP/Contents/MacOS"

echo "==> コンパイル"
swiftc -O -swift-version 5 \
  -target arm64-apple-macosx13.0 \
  -framework Cocoa -framework ServiceManagement \
  -o "$APP/Contents/MacOS/$APP_NAME" \
  Sources/main.swift

echo "==> Info.plist"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>Claude Usage</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <!-- メニューバーだけに常駐し、Dock とアプリスイッチャーには出さない -->
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

echo "==> 署名 (ad-hoc)"
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"

echo "==> インストール: $INSTALL_DIR/$APP_NAME.app"
mkdir -p "$INSTALL_DIR"
# 起動中なら差し替える前に止める
pkill -f "$INSTALL_DIR/$APP_NAME.app/Contents/MacOS/$APP_NAME" 2>/dev/null || true
rm -rf "${INSTALL_DIR:?}/$APP_NAME.app"
cp -R "$APP" "$INSTALL_DIR/"

echo "完了: open '$INSTALL_DIR/$APP_NAME.app' で起動します"
