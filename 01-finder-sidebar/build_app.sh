#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

# Builds the core floating-panel app (no Finder Sync extension) with SwiftPM.
# The extension variant still requires building FinderSidebar.xcodeproj in Xcode.
BIN_NAME="FinderSidebarPanel"
APP_NAME="Folderis"
BUILD_DIR=".build/release"
APP_BUNDLE="${APP_NAME}.app"

swift build -c release

rm -rf "$APP_BUNDLE" FinderSidebar.app
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources" "$APP_BUNDLE/Contents/Frameworks"

cp "$BUILD_DIR/$BIN_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp branding/AppIcon.icns "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
cp branding/OrbLogo.png "$APP_BUNDLE/Contents/Resources/OrbLogo.png"
cp branding/OrbLogoTransparent.png "$APP_BUNDLE/Contents/Resources/OrbLogoTransparent.png"

cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>com.local.findersidebar.host</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.1.0</string>
    <key>CFBundleVersion</key>
    <string>20260809.1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>需要与 Finder 通信，以读取当前文件夹和选中的文件。</string>
</dict>
</plist>
PLIST

# TCC（辅助功能/自动化）按 bundle id + 首次授权时的签名要求记账：
# ad-hoc 签名的要求按 cdhash 记，每次重建都会作废已有授权，且系统设置里
# 开关仍显示开启（静默失效）。因此必须始终用 Developer ID 签名——找不到
# 证书直接报错，绝不回退 ad-hoc。
DEV_IDENTITY=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)"/\1/' || true)
if [[ -z "$DEV_IDENTITY" ]]; then
    echo "error: 未找到 Developer ID Application 证书。" >&2
    echo "ad-hoc 签名会让辅助功能授权每次重建后静默失效，已禁止回退。" >&2
    exit 1
fi
codesign --force --deep --sign "$DEV_IDENTITY" "$APP_BUNDLE"

echo "Built $APP_BUNDLE"
