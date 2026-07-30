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
    <string>1.1</string>
    <key>CFBundleVersion</key>
    <string>20260716</string>
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

codesign --force --deep --sign - "$APP_BUNDLE"

echo "Built $APP_BUNDLE"
