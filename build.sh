#!/bin/bash
# 把 Sources/ 编译成一个菜单栏 .app（不需要 Xcode，Command Line Tools 即可）
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Sub2API Quota"
BUNDLE_ID="run.hanxiao.sub2api-quota"
BUILD_DIR="build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
RES_DIR="$APP_DIR/Contents/Resources"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RES_DIR"

echo "==> 编译"
# 13.0 -> 14.0：菜单用 NSMenuItem.sectionHeader，是 macOS 14 才有的原生分节样式
swiftc -O \
  -target "$(uname -m)-apple-macosx14.0" \
  -o "$MACOS_DIR/Sub2APIQuota" \
  Sources/*.swift

echo "==> 生成 Info.plist"
cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>       <string>$APP_NAME</string>
    <key>CFBundleExecutable</key>        <string>Sub2APIQuota</string>
    <key>CFBundleIdentifier</key>        <string>$BUNDLE_ID</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0.0</string>
    <key>CFBundleVersion</key>           <string>1</string>
    <key>LSMinimumSystemVersion</key>    <string>14.0</string>
    <!-- 只在菜单栏出现，不进 Dock -->
    <key>LSUIElement</key>               <true/>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>NSHumanReadableCopyright</key>  <string></string>
</dict>
</plist>
PLIST

echo "==> 签名（ad-hoc）"
codesign --force --deep --sign - "$APP_DIR" 2>/dev/null || echo "    跳过签名"

echo
echo "构建完成：$APP_DIR"
echo "运行：    open \"$APP_DIR\""
echo "安装：    cp -R \"$APP_DIR\" /Applications/"
