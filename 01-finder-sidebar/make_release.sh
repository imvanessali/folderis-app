#!/bin/bash
# 单版本公证发布：
# 构建 → 内嵌运行时 → Developer ID 加固签名 → App 公证/装订
# → DMG → DMG 公证/装订 → 最终校验。
# 前置（一次性）：
#   1. Xcode 里创建 Developer ID Application 证书
#   2. xcrun notarytool store-credentials notary --apple-id 你的AppleID \
#        --team-id 2Y5H5X7UQS --password <App专用密码>
# 用法：
#   RUNTIME_SRC=<scratch目录> MVP=0 ./make_release.sh  # Full
#   RUNTIME_SRC=<scratch目录> MVP=1 ./make_release.sh  # Lite
# 同时发布 Full + Lite 请使用 make_release_matrix.sh。
set -euo pipefail
cd "$(dirname "$0")"

TEAM=2Y5H5X7UQS
IDENTITY=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)"/\1/')
[ -n "$IDENTITY" ] || { echo "错误：未找到 Developer ID Application 证书（先在 Xcode 里创建）"; exit 1; }
echo "签名身份：$IDENTITY"
RUNTIME_SRC="${RUNTIME_SRC:?需要 RUNTIME_SRC=<含 pyrt/ helpers/ ffmpeg 的目录>}"
ARCH="${ARCH:-arm64}"   # arm64 | x86_64
MVP="${MVP:-0}"         # 1 = Folderis Lite（仅 DeepSeek Key）
APP_VERSION="1.1.0"
BUILD_VERSION="20260724.2"
NOTARY_SCRATCH=""
HELPER_BUILD=""
BG_BUILD=""
RW=""
VOLNAME=""

cleanup_release_scratch() {
  if [ -n "$VOLNAME" ]; then
    hdiutil detach "/Volumes/$VOLNAME" -quiet 2>/dev/null || true
  fi
  if [ -n "$NOTARY_SCRATCH" ]; then
    rm -rf "$NOTARY_SCRATCH"
  fi
  if [ -n "$HELPER_BUILD" ]; then
    rm -rf "$HELPER_BUILD"
  fi
  if [ -n "$BG_BUILD" ]; then
    rm -rf "$BG_BUILD"
  fi
  if [ -n "$RW" ]; then
    rm -f "$RW"
  fi
}
trap cleanup_release_scratch EXIT INT TERM

notarize_artifact() {
  local artifact="$1"
  local label="$2"
  local submission_id=""
  local output=""
  local status=""

  # 只提交一次拿 ID，然后按 ID 轮询到底。仅上传连接失败时重试，
  # 避免同一产物重复进入 Apple 队列。
  for attempt in 1 2 3; do
    output=$(xcrun notarytool submit "$artifact" --keychain-profile notary 2>&1) || true
    submission_id=$(printf '%s\n' "$output" | awk '$1 == "id:" { print $2; exit }')
    [ -n "$submission_id" ] && break
    echo "$label 上传中断（第 $attempt 次）：$(echo "$output" | tail -1)"
    sleep 20
  done
  [ -n "$submission_id" ] || { echo "$label 上传三次失败"; exit 1; }

  echo "$label 提交 ID: $submission_id"
  for poll in $(seq 1 240); do
    status=$(xcrun notarytool info "$submission_id" --keychain-profile notary 2>/dev/null |
      awk '$1 == "status:" { print $2; exit }' || true)
    echo "  $label poll $poll: ${status:-noresp}"
    [ "$status" = "Accepted" ] && break
    if [ "$status" = "Invalid" ]; then
      echo "$label 公证被拒，详情："
      xcrun notarytool log "$submission_id" --keychain-profile notary || true
      exit 1
    fi
    sleep 30
  done
  [ "$status" = "Accepted" ] || { echo "$label 公证 2 小时未出结果，中止"; exit 1; }
}

staple_with_retry() {
  local artifact="$1"
  local label="$2"

  # 装订偶发被代理/VPN 掐断 TLS（api.apple-cloudkit.com），自动重试。
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    if xcrun stapler staple "$artifact"; then
      xcrun stapler validate "$artifact"
      return
    fi
    echo "$label staple 失败（第 $attempt 次），30 秒后重试…"
    sleep 30
  done
  echo "$label 装订重试耗尽"
  exit 68
}
case "$ARCH" in
  arm64)  PY_DIR="pyrt/python";     FF_DIR="$RUNTIME_SRC";       DMG_SUFFIX="AppleSilicon" ;;
  x86_64) PY_DIR="pyrt-x64/python"; FF_DIR="$RUNTIME_SRC/intel"; DMG_SUFFIX="Intel" ;;
  *) echo "未知架构 $ARCH"; exit 1 ;;
esac

EXTRA_BUILD=("SWIFT_ACTIVE_COMPILATION_CONDITIONS=")
BUILD_PRODUCT="Folderis.app"
if [ "$MVP" = "1" ]; then
  EXTRA_BUILD=("SWIFT_ACTIVE_COMPILATION_CONDITIONS=MVP_DEEPSEEK")
fi

echo "== 1/8 构建 =="
xcodebuild -project FinderSidebar.xcodeproj -scheme FinderSidebarHost -configuration Release \
  -derivedDataPath .xcbuild -allowProvisioningUpdates \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  DEVELOPMENT_TEAM=$TEAM CODE_SIGN_STYLE=Automatic "${EXTRA_BUILD[@]}" build 2>&1 | grep -E "error|BUILD"

if [ "$MVP" = "1" ]; then
  APP="dist/Folderis Lite.app"
  DMG_NAME="Folderis-Lite-$DMG_SUFFIX"
  VOLNAME="Folderis Lite"
else
  APP=dist/Folderis.app
  DMG_NAME="Folderis-$DMG_SUFFIX"
  VOLNAME="Folderis"
fi
mkdir -p dist && rm -rf "$APP" dist/dmgroot "dist/$DMG_NAME.dmg"
cp -R ".xcbuild/Build/Products/Release/$BUILD_PRODUCT" "$APP"
plutil -replace CFBundleShortVersionString -string "$APP_VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD_VERSION" "$APP/Contents/Info.plist"
if [ "$MVP" = "1" ]; then
  # Lite 独立身份：可与完整版共存，各自独立的 TCC 授权与偏好设置
  plutil -replace CFBundleIdentifier -string com.local.findersidebar.lite "$APP/Contents/Info.plist"
  plutil -replace CFBundleName -string "Folderis Lite" "$APP/Contents/Info.plist"
  plutil -replace CFBundleDisplayName -string "Folderis Lite" "$APP/Contents/Info.plist"
  mv "$APP/Contents/MacOS/Folderis" "$APP/Contents/MacOS/Folderis Lite"
  plutil -replace CFBundleExecutable -string "Folderis Lite" "$APP/Contents/Info.plist"
  # Lite 不带 Finder 工具栏扩展
  rm -rf "$APP/Contents/PlugIns"
fi

echo "== 2/8 内嵌运行时 =="
RT="$APP/Contents/Resources/runtime"
mkdir -p "$RT/bin" "$RT/skills"
cp -R "$RUNTIME_SRC/$PY_DIR" "$RT/python"
[ -d "$RT/python/lib/python3.12/site-packages/xlrd" ] || {
  echo "错误：发布运行时缺少 xlrd，旧式 XLS 转换将不可用"
  exit 1
}
# 签名和公证只能证明文件未被篡改，不能证明 Python 标准库完整。
# 必须实际启动嵌入式运行时，阻止缺失 encodings 等源文件的坏包进入签名流程。
"$RT/python/bin/python3" -c \
  'import encodings, openpyxl, xlrd, PIL; print("Folderis Python runtime OK")' || {
  echo "错误：发布运行时无法启动或 Excel/图片依赖不完整"
  exit 1
}

# pdfrender 的页码选择属于技能协议的一部分。发布时从当前源码重建，
# 避免 scratch 目录里的旧二进制静默忽略新增参数。
HELPER_BUILD=$(mktemp -d)
xcrun swiftc -O -target arm64-apple-macosx13.0 skills/pdfrender.swift \
  -o "$HELPER_BUILD/pdfrender-arm64"
xcrun swiftc -O -target x86_64-apple-macosx13.0 skills/pdfrender.swift \
  -o "$HELPER_BUILD/pdfrender-x86_64"
lipo -create "$HELPER_BUILD/pdfrender-arm64" "$HELPER_BUILD/pdfrender-x86_64" \
  -output "$RUNTIME_SRC/helpers-universal/pdfrender"
rm -rf "$HELPER_BUILD"
HELPER_BUILD=""

cp "$RUNTIME_SRC/helpers-universal/"* "$FF_DIR/ffmpeg" "$FF_DIR/ffprobe" "$RT/bin/"
PNGQUANT="$RUNTIME_SRC/pngquant"
if [ ! -f "$PNGQUANT" ]; then
  PNGQUANT="$HOME/Library/Application Support/FinderSidebar/bin/pngquant"
fi
[ -f "$PNGQUANT" ] || { echo "错误：发布运行时缺少 pngquant"; exit 1; }
cp "$PNGQUANT" "$RT/bin/"
chmod +x "$RT/bin/"*
cp skills/skills.py skills/catalog.txt skills/*.swift skills/*.plist "$RT/skills/"
# python-build-standalone may leave optional developer-tool symlinks whose
# targets were stripped from the compact runtime. They are unused by Folderis,
# but a broken symlink makes `codesign --verify --strict` fail.
while IFS= read -r -d '' runtime_link; do
  [ -e "$runtime_link" ] || rm "$runtime_link"
done < <(find "$RT/python" -type l -print0)
# Skills update independently from the 180MB Python/binary runtime. The app
# checks this content marker synchronously before loading its static catalog.
(
  for skill_file in "$RT/skills/"*; do
    printf '%s\0' "$(basename "$skill_file")"
    cat "$skill_file"
  done
) | shasum -a 256 | awk '{print $1}' > "$RT/SKILLS_VERSION"
# 手册随 App 走（菜单栏可打开），DMG 根目录保持 App+Applications 极简布局
cp 使用手册.md "User Guide.md" "$APP/Contents/Resources/"
cp branding/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp branding/OrbLogo.png "$APP/Contents/Resources/OrbLogo.png"
cp branding/OrbLogoTransparent.png "$APP/Contents/Resources/OrbLogoTransparent.png"
if [ -d "$APP/Contents/PlugIns/FinderSidebarExt.appex" ]; then
  mkdir -p "$APP/Contents/PlugIns/FinderSidebarExt.appex/Contents/Resources"
  cp branding/OrbLogo.png "$APP/Contents/PlugIns/FinderSidebarExt.appex/Contents/Resources/ToolbarIcon.png"
fi
date +%Y%m%d%H%M%S > "$RT/VERSION"

echo "== 3/8 签名（全部 Mach-O，加固运行时）=="
# 内层：python 的动态库与可执行文件、组件二进制
find "$RT" -type f \( -name "*.dylib" -o -name "*.so" \) -print0 | \
  xargs -0 -n 20 codesign --force --timestamp -s "$IDENTITY"
find "$RT/python/bin" "$RT/bin" -type f -perm +111 -print0 | \
  xargs -0 -n 1 codesign --force --timestamp --options runtime -s "$IDENTITY"
# 内嵌 Finder 扩展：必须先于外层用 Developer ID 重签
# （用发布权限文件，自动剥离 Xcode 构建带上的 get-task-allow 调试权限）
if [ -d "$APP/Contents/PlugIns/FinderSidebarExt.appex" ]; then
codesign --force --timestamp --options runtime \
  --entitlements FinderExtension/FinderExtension.entitlements \
  -s "$IDENTITY" "$APP/Contents/PlugIns/FinderSidebarExt.appex"
fi
# 外层：整个 App（带权限文件）
codesign --force --timestamp --options runtime \
  --entitlements HostApp/HostApp.entitlements \
  -s "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"
echo "签名校验通过"

if [ "${SKIP_NOTARIZE:-0}" = "1" ]; then
  echo "== 4/8 跳过 App 公证（SKIP_NOTARIZE=1）=="
else
  echo "== 4/8 App 公证与装订 =="
  NOTARY_SCRATCH=$(mktemp -d)
  ditto -c -k --keepParent "$APP" "$NOTARY_SCRATCH/Folderis.zip"
  notarize_artifact "$NOTARY_SCRATCH/Folderis.zip" "App"
  rm -rf "$NOTARY_SCRATCH"
  NOTARY_SCRATCH=""
  staple_with_retry "$APP" "App"
  codesign --verify --deep --strict "$APP"
  spctl --assess --type execute --verbose=2 "$APP"
fi

echo "== 5/8 打 DMG =="
DMG="dist/$DMG_NAME.dmg"
mkdir -p dist/dmgroot
# ditto 显式保留 App 的扩展属性，其中包含 stapler 写入的公证票据。
ditto --rsrc --extattr "$APP" "dist/dmgroot/$(basename "$APP")"
ln -s /Applications dist/dmgroot/Applications
cp branding/AppIcon.icns dist/dmgroot/.VolumeIcon.icns
SetFile -a C dist/dmgroot 2>/dev/null || true
# 安装引导页背景图（纯箭头，无文字，语言中立）；图标布局在最终卷上现场排版
mkdir -p dist/dmgroot/.background
BG_BUILD=$(mktemp -d)
xcrun swift branding/make_dmg_background.swift \
  "$BG_BUILD/bg-1x.png" "$BG_BUILD/bg-2x.png"
tiffutil -cathidpicheck "$BG_BUILD/bg-1x.png" "$BG_BUILD/bg-2x.png" \
  -out dist/dmgroot/.background/bg.tiff >/dev/null
rm -rf "$BG_BUILD"
BG_BUILD=""
# 先出可写镜像 → Finder 现场排版（背景别名必须指向最终卷）→ 转只读压缩
RW=dist/rw-tmp.dmg
rm -f "$RW"
hdiutil detach "/Volumes/$VOLNAME" -quiet 2>/dev/null || true
hdiutil create -volname "$VOLNAME" -srcfolder dist/dmgroot -ov -format UDRW "$RW" >/dev/null
hdiutil attach "$RW" -noautoopen >/dev/null
sleep 1
APPBASE=$(basename "$APP")
osascript <<LAYOUT
tell application "Finder"
  tell disk "$VOLNAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 140, 900, 605}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 128
    set text size of viewOptions to 13
    set background picture of viewOptions to file ".background:bg.tiff"
    set position of item "$APPBASE" of container window to {175, 205}
    set position of item "Applications" of container window to {525, 205}
    update without registering applications
    delay 1
    close
  end tell
end tell
LAYOUT
sync
hdiutil detach "/Volumes/$VOLNAME" -quiet
VOLNAME=""
hdiutil convert "$RW" -format UDZO -o "$DMG" -ov >/dev/null
rm -f "$RW"
RW=""
codesign --force --timestamp -s "$IDENTITY" "$DMG"

if [ "${SKIP_NOTARIZE:-0}" = "1" ]; then
  echo "== 6/8 跳过 DMG 公证（SKIP_NOTARIZE=1）=="
  echo "== 7/8 跳过装订（SKIP_NOTARIZE=1）=="
  echo "== 8/8 本地校验 =="
  codesign --verify --deep --strict "$APP"
  hdiutil verify "$DMG" >/dev/null
  echo "完成：${DMG}（未公证，仅本机测试用）"
  exit 0
fi
echo "== 6/8 DMG 公证（等待 Apple 审核；队列拥堵时可能较久）=="
notarize_artifact "$DMG" "DMG"

echo "== 7/8 DMG 装订 =="
staple_with_retry "$DMG" "DMG"

echo "== 8/8 最终校验 =="
xcrun stapler validate "$APP"
codesign --verify --deep --strict "$APP"
spctl --assess --type execute --verbose=2 "$APP"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
hdiutil verify "$DMG" >/dev/null
echo "完成：${DMG}（$(du -h "$DMG" | cut -f1)）——可直接分发，下载后双击即用，无任何警告。"
