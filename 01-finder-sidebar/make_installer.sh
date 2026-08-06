#!/bin/bash
# 组装可分发安装包：App + 完整技能运行时（独立 Python、ffmpeg、编译组件）。
# 产物：dist/Folderis-安装包.zip（Apple Silicon 专用）
set -euo pipefail
cd "$(dirname "$0")"

RUNTIME_SRC="${RUNTIME_SRC:?需要设置 RUNTIME_SRC=<含 python/ helpers/ ffmpeg 的目录>}"
DIST=dist/Folderis-安装包
rm -rf dist && mkdir -p "$DIST/runtime/bin" "$DIST/runtime/skills"

# 始终用当前源码重建支持页码范围的 PDF 渲染器。
HELPER_BUILD=$(mktemp -d)
xcrun swiftc -O -target arm64-apple-macosx13.0 skills/pdfrender.swift \
  -o "$HELPER_BUILD/pdfrender-arm64"
xcrun swiftc -O -target x86_64-apple-macosx13.0 skills/pdfrender.swift \
  -o "$HELPER_BUILD/pdfrender-x86_64"
lipo -create "$HELPER_BUILD/pdfrender-arm64" "$HELPER_BUILD/pdfrender-x86_64" \
  -output "$RUNTIME_SRC/helpers/pdfrender"
rm -rf "$HELPER_BUILD"

echo "== 1/4 构建 App =="
xcodebuild -project FinderSidebar.xcodeproj -scheme FinderSidebarHost -configuration Release \
  -derivedDataPath .xcbuild -allowProvisioningUpdates \
  DEVELOPMENT_TEAM=2Y5H5X7UQS CODE_SIGN_STYLE=Automatic build 2>&1 | grep -E "error|BUILD"
cp -R .xcbuild/Build/Products/Release/Folderis.app "$DIST/Folderis.app"

echo "== 2/4 运行时 =="
cp -R "$RUNTIME_SRC/pyrt/python" "$DIST/runtime/python"
"$DIST/runtime/python/bin/python3" -c \
  'import encodings, openpyxl, pyzipper, xlrd, PIL; print("Folderis Python runtime OK")' || {
  echo "错误：安装包运行时无法启动或 Excel/图片依赖不完整"
  exit 1
}
cp "$RUNTIME_SRC/helpers/"* "$DIST/runtime/bin/"
cp "$RUNTIME_SRC/ffmpeg" "$RUNTIME_SRC/ffprobe" "$DIST/runtime/bin/"
cp "$HOME/Library/Application Support/FinderSidebar/bin/pngquant" "$DIST/runtime/bin/"
chmod +x "$DIST/runtime/bin/"*
cp skills/skills.py skills/catalog.txt skills/*.swift skills/*.plist "$DIST/runtime/skills/" 2>/dev/null || true

echo "== 3/4 安装脚本与说明 =="
cat > "$DIST/安装.command" <<'INSTALL'
#!/bin/bash
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
SUPPORT="$HOME/Library/Application Support/FinderSidebar"
echo "== 安装 Folderis =="
echo "1/3 复制应用到 /Applications …"
rm -rf "/Applications/Folderis.app" "/Applications/FinderSidebar.app"
cp -R "$DIR/Folderis.app" /Applications/
echo "2/3 安装技能运行时到 ~/Library/Application Support/FinderSidebar …"
mkdir -p "$SUPPORT"
cp -R "$DIR/runtime/python" "$SUPPORT/"
mkdir -p "$SUPPORT/bin" "$SUPPORT/skills"
cp "$DIR/runtime/bin/"* "$SUPPORT/bin/"
cp "$DIR/runtime/skills/"* "$SUPPORT/skills/"
chmod +x "$SUPPORT/bin/"* 2>/dev/null || true
echo "3/3 解除下载隔离标记 …"
xattr -dr com.apple.quarantine "/Applications/Folderis.app" "$SUPPORT" 2>/dev/null || true
echo
echo "✅ 安装完成，正在启动…"
open "/Applications/Folderis.app"
echo
echo "接下来（只需一次）："
echo "  1. 系统会请求「辅助功能」权限 → 允许（面板贴靠 Finder 必需）"
echo "  2. 首次读取文件夹时会请求「自动化控制 Finder」→ 允许"
echo "  3. 点面板右上角 ⚙️ 选择 AI 服务商并粘贴你的 API Key"
echo "  4. 首次用录音转文字时会请求「语音识别」→ 允许"
echo
read -p "按回车关闭本窗口…"
INSTALL
chmod +x "$DIST/安装.command"
cp 使用手册.md "$DIST/"
cat > "$DIST/安装说明.txt" <<'NOTE'
Folderis 安装（仅支持 Apple Silicon 芯片的 Mac，macOS 13+）

1. 右键点击「安装.command」→ 打开 → 再点一次「打开」
   （首次运行来自网络的脚本，系统会提示无法验证开发者，右键打开即可）
2. 按终端窗口里的提示完成系统授权
3. 打开任意 Finder 文件夹即可看到右侧 AI 面板

用法示例见「使用手册.md」。
NOTE

echo "== 4/4 打包 =="
cd dist && zip -rq "Folderis-安装包.zip" "Folderis-安装包"
echo "完成：$(pwd)/Folderis-安装包.zip（$(du -h Folderis-安装包.zip | cut -f1)）"
