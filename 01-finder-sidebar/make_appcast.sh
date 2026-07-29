#!/bin/bash
# 为一个已构建好的 DMG 生成 Sparkle appcast(EdDSA 签名)。
# 由 make_release.sh 在发布收尾自动调用,也可单独运行:
#   ARCH=arm64 APP_VERSION=1.1.0 BUILD_VERSION=20260727.2 ./make_appcast.sh dist/Folderis-AppleSilicon.dmg
#
# 密钥:默认用发布机钥匙串里的 Sparkle EdDSA 私钥(一次性生成:
#   ./generate_keys —— 在 Sparkle 工具目录下,见下方 find_sparkle_bin);
# 也可用 FOLDERIS_SPARKLE_KEY_FILE=<私钥文件> 指定。
# 私钥丢失 = 永远无法再给存量用户推送更新,务必备份进密码管理器。
set -euo pipefail
cd "$(dirname "$0")"

DMG="${1:?用法: ./make_appcast.sh <dmg路径>（需 ARCH/APP_VERSION/BUILD_VERSION 环境变量）}"
ARCH="${ARCH:?需要 ARCH=arm64|x86_64}"
APP_VERSION="${APP_VERSION:?需要 APP_VERSION}"
BUILD_VERSION="${BUILD_VERSION:?需要 BUILD_VERSION}"
BASE_URL="${FOLDERIS_UPDATE_BASE_URL:-https://dl.folderis.app}"
REQUIRE="${FOLDERIS_APPCAST_REQUIRE:-0}"

case "$ARCH" in
  arm64)  DMG_SUFFIX="AppleSilicon" ;;
  x86_64) DMG_SUFFIX="Intel" ;;
  *) echo "未知架构 $ARCH"; exit 1 ;;
esac

# Sparkle 命令行工具随 SPM 二进制包分发,SwiftPM 与 xcodebuild 的
# 缓存位置不同,两处都找。
find_sparkle_bin() {
  local candidate
  for candidate in \
    ".build/artifacts/sparkle/Sparkle/bin" \
    ".xcbuild/SourcePackages/artifacts/sparkle/Sparkle/bin"; do
    if [ -x "$candidate/sign_update" ]; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

SPARKLE_BIN=$(find_sparkle_bin) || {
  echo "找不到 Sparkle 工具(sign_update)。先构建一次让 SPM 拉取二进制包:"
  echo "  swift build 或 xcodebuild -project FinderSidebar.xcodeproj -scheme FinderSidebarHost"
  [ "$REQUIRE" = "1" ] && exit 1
  echo "⚠️  跳过 appcast 生成(FOLDERIS_APPCAST_REQUIRE=1 可改为强制失败)"
  exit 0
}

# sign_update 输出形如:sparkle:edSignature="…" length="…"
# (不用数组传参:macOS 自带 bash 3.2 在 set -u 下展开空数组会报 unbound variable)
if [ -n "${FOLDERIS_SPARKLE_KEY_FILE:-}" ]; then
  SIGNATURE_ATTRS=$("$SPARKLE_BIN/sign_update" -f "$FOLDERIS_SPARKLE_KEY_FILE" "$DMG")
else
  SIGNATURE_ATTRS=$("$SPARKLE_BIN/sign_update" "$DMG")
fi || {
  echo "EdDSA 签名失败。若还没生成密钥,先运行:"
  echo "  $SPARKLE_BIN/generate_keys"
  echo "并把私钥备份进密码管理器(丢失=存量用户永久失联)。"
  [ "$REQUIRE" = "1" ] && exit 1
  echo "⚠️  跳过 appcast 生成(FOLDERIS_APPCAST_REQUIRE=1 可改为强制失败)"
  exit 0
}

# —— 公私钥配对自检 ——
# 灾难场景:App 里嵌的 SUPublicEDKey 和签 DMG 的私钥不配对时,构建、公证、
# 上传全部成功,只有存量用户端静默验签失败且毫无信号。这里把「实际嵌入
# App 的公钥」与「实际签名私钥推导出的公钥」硬比对,不配对直接失败。
# 本地测试可 FOLDERIS_APPCAST_PUBKEY_CHECK=0 跳过(与 Windows 端约定一致)。
if [ "${FOLDERIS_APPCAST_PUBKEY_CHECK:-1}" = "1" ]; then
  EMBEDDED_KEY=""
  if [ -f "dist/Folderis.app/Contents/Info.plist" ]; then
    EMBEDDED_KEY=$(plutil -extract SUPublicEDKey raw "dist/Folderis.app/Contents/Info.plist" 2>/dev/null || true)
  fi
  SIGNING_PUB=""
  if [ -n "${FOLDERIS_SPARKLE_KEY_FILE:-}" ]; then
    # Sparkle 私钥文件是 base64 的 32 字节 ed25519 seed(实测 2.9.4)。
    # 拼上 PKCS8 头让 openssl 推导出公钥。
    KEYTMP=$(mktemp)
    {
      printf '302e020100300506032b657004220420' | xxd -r -p
      base64 -d < "$FOLDERIS_SPARKLE_KEY_FILE" | head -c 32
    } > "$KEYTMP" 2>/dev/null
    SIGNING_PUB=$(openssl pkey -inform DER -in "$KEYTMP" -pubout -outform DER 2>/dev/null \
      | tail -c 32 | base64 || true)
    rm -f "$KEYTMP"
  else
    SIGNING_PUB=$("$SPARKLE_BIN/generate_keys" -p 2>/dev/null || true)
  fi
  if [ -n "$EMBEDDED_KEY" ] && [ -n "$SIGNING_PUB" ]; then
    if [ "$EMBEDDED_KEY" != "$SIGNING_PUB" ]; then
      echo "错误:App 内嵌的 SUPublicEDKey 与签名私钥不配对!"
      echo "  App 嵌入:  $EMBEDDED_KEY"
      echo "  签名公钥:  $SIGNING_PUB"
      echo "这样发出去的更新所有用户都验不过签。检查 FOLDERIS_SPARKLE_PUBLIC_KEY /"
      echo "FOLDERIS_SPARKLE_KEY_FILE 与钥匙串里的密钥是否一致。"
      exit 1
    fi
    echo "公私钥配对校验通过($EMBEDDED_KEY)"
  else
    echo "⚠️  无法完成公私钥配对校验(缺 dist/Folderis.app 或无法推导签名公钥),请人工确认。"
  fi
fi

ENCLOSURE_URL="$BASE_URL/mac/Folderis-$DMG_SUFFIX-$BUILD_VERSION.dmg"
PUB_DATE=$(LC_ALL=en_US.UTF-8 date -R)
APPCAST="dist/appcast-$ARCH.xml"
mkdir -p dist

cat > "$APPCAST" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Folderis (macOS $DMG_SUFFIX)</title>
    <item>
      <title>Folderis $APP_VERSION</title>
      <pubDate>$PUB_DATE</pubDate>
      <sparkle:version>$BUILD_VERSION</sparkle:version>
      <sparkle:shortVersionString>$APP_VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
      <enclosure url="$ENCLOSURE_URL" $SIGNATURE_ATTRS type="application/octet-stream"/>
    </item>
  </channel>
</rss>
XML

# 供 publish_release.sh 读取:本次要上传什么、传到哪个远端名字。
cat > "dist/RELEASE_INFO-$ARCH.env" <<ENV
APP_VERSION=$APP_VERSION
BUILD_VERSION=$BUILD_VERSION
DMG_LOCAL=$(basename "$DMG")
DMG_REMOTE=Folderis-$DMG_SUFFIX-$BUILD_VERSION.dmg
APPCAST_LOCAL=appcast-$ARCH.xml
ENV

echo "appcast 已生成:$APPCAST"
echo "  enclosure: $ENCLOSURE_URL"
