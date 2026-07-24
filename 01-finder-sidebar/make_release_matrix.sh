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

MANIFEST="dist/Folderis-macOS-$DMG_SUFFIX-SHA256.txt"
(
  cd dist
  shasum -a 256 "$(basename "$FULL_DMG")"
) > "$MANIFEST"

echo
echo "macOS release 完成："
ls -lh "$FULL_DMG"
echo "校验文件：$MANIFEST"
cat "$MANIFEST"
