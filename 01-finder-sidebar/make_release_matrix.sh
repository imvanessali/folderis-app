#!/bin/bash
# 构建并校验 macOS 可分发 DMG（仅 Full；Lite 已停止维护）。
# 用法：
#   RUNTIME_SRC=<scratch目录> ARCH=arm64 ./make_release_matrix.sh
# 本地流程测试（不公证）：
#   RUNTIME_SRC=<scratch目录> ARCH=arm64 SKIP_NOTARIZE=1 ./make_release_matrix.sh
set -euo pipefail
cd "$(dirname "$0")"

RUNTIME_SRC="${RUNTIME_SRC:?需要 RUNTIME_SRC=<含 pyrt/ helpers/ ffmpeg 的目录>}"
ARCH="${ARCH:-arm64}"
SKIP_NOTARIZE="${SKIP_NOTARIZE:-0}"

case "$ARCH" in
  arm64) DMG_SUFFIX="AppleSilicon" ;;
  x86_64) DMG_SUFFIX="Intel" ;;
  *) echo "未知架构 $ARCH"; exit 1 ;;
esac

echo "============================================================"
echo "开始构建 Folderis（ARCH=${ARCH}）"
echo "============================================================"
RUNTIME_SRC="$RUNTIME_SRC" \
  ARCH="$ARCH" \
  SKIP_NOTARIZE="$SKIP_NOTARIZE" \
  ./make_release.sh

FULL_DMG="dist/Folderis-$DMG_SUFFIX.dmg"
[ -f "$FULL_DMG" ] || { echo "缺少发布产物：$FULL_DMG"; exit 1; }
hdiutil verify "$FULL_DMG" >/dev/null

# 未公证的测试构建不进 Release/：避免同名覆盖正式分发物。
if [ "$SKIP_NOTARIZE" = "1" ]; then
  echo
  echo "SKIP_NOTARIZE=1：测试构建不发布到 Release/，产物保留在 $FULL_DMG"
  exit 0
fi

# 最终分发物统一放仓库根 Release/<版本号>/；dist/ 只是构建暂存
# （dist/Folderis.app 兼任下一次打包的 RUNTIME_SRC 来源，保留）。
BUILD_VERSION=$(sed -n 's/^BUILD_VERSION="\(.*\)"/\1/p' make_release.sh)
[ -n "$BUILD_VERSION" ] || { echo "无法从 make_release.sh 读取 BUILD_VERSION"; exit 1; }
RELEASE_DIR="../Release/$BUILD_VERSION"
mkdir -p "$RELEASE_DIR"
cp "$FULL_DMG" "$RELEASE_DIR/"

MANIFEST="$RELEASE_DIR/Folderis-macOS-$DMG_SUFFIX-SHA256.txt"
(
  cd "$RELEASE_DIR"
  shasum -a 256 "$(basename "$FULL_DMG")"
) > "$MANIFEST"

# 自动更新产物随发布件归档(同时保留在 dist/ 供 publish_release.sh 上传)
[ -f "dist/appcast-$ARCH.xml" ] && cp "dist/appcast-$ARCH.xml" "$RELEASE_DIR/"

echo
echo "macOS release 完成："
ls -lh "$RELEASE_DIR/$(basename "$FULL_DMG")"
echo "校验文件：$MANIFEST"
cat "$MANIFEST"
