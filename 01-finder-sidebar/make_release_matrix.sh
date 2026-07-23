#!/bin/bash
# 一次构建并校验 macOS Full + Lite 两个可分发 DMG。
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

run_variant() {
  local name="$1"
  local mvp="$2"

  echo
  echo "============================================================"
  echo "开始构建 Folderis ${name}（ARCH=${ARCH}）"
  echo "============================================================"
  RUNTIME_SRC="$RUNTIME_SRC" \
    ARCH="$ARCH" \
    MVP="$mvp" \
    SKIP_NOTARIZE="$SKIP_NOTARIZE" \
    ./make_release.sh
}

run_variant "Full" 0
run_variant "Lite" 1

FULL_DMG="dist/Folderis-$DMG_SUFFIX.dmg"
LITE_DMG="dist/Folderis-Lite-$DMG_SUFFIX.dmg"
for artifact in "$FULL_DMG" "$LITE_DMG"; do
  [ -f "$artifact" ] || { echo "缺少发布产物：$artifact"; exit 1; }
  hdiutil verify "$artifact" >/dev/null
done

MANIFEST="dist/Folderis-macOS-$DMG_SUFFIX-SHA256.txt"
(
  cd dist
  shasum -a 256 "$(basename "$FULL_DMG")" "$(basename "$LITE_DMG")"
) > "$MANIFEST"

echo
echo "macOS release matrix 完成："
ls -lh "$FULL_DMG" "$LITE_DMG"
echo "校验文件：$MANIFEST"
cat "$MANIFEST"
