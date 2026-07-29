#!/bin/bash
# 把已构建的发布产物(macOS DMG / Windows 安装器)连同 appcast 推送到
# Cloudflare R2,存量用户即开始收到自动更新。
#
# 用法(先跑对应平台的构建脚本):
#   ./publish_release.sh mac        # 上传 01-finder-sidebar/dist 里已生成 appcast 的架构
#   ./publish_release.sh win        # 上传 win-explorer-sidebar/dist
#   ./publish_release.sh all
#
# 前置:
#   - npm i -g wrangler 并 wrangler login(或设 CLOUDFLARE_API_TOKEN/CLOUDFLARE_ACCOUNT_ID)
#   - R2 bucket(默认 folderis-updates,可用 FOLDERIS_R2_BUCKET 覆盖),
#     绑定自定义域(默认 https://dl.folderis.app,构建时用
#     FOLDERIS_UPDATE_BASE_URL 保持一致)
#
# 上传顺序刻意为「先包后 appcast」:appcast 是发布开关,包先就位,
# 换 appcast 的瞬间才对用户生效。回滚 = 用旧版本重新生成并上传 appcast。
set -euo pipefail
cd "$(dirname "$0")"

TARGET="${1:?用法: ./publish_release.sh mac|win|all}"
BUCKET="${FOLDERIS_R2_BUCKET:-folderis-updates}"

WRANGLER=(wrangler)
command -v wrangler >/dev/null || {
  command -v npx >/dev/null || { echo "缺少 wrangler:npm i -g wrangler"; exit 1; }
  WRANGLER=(npx wrangler)
}

put_object() {
  local key="$1" file="$2" cache="$3" type="$4"
  echo "上传 r2://$BUCKET/$key  ←  $file"
  "${WRANGLER[@]}" r2 object put "$BUCKET/$key" --remote \
    --file "$file" --cache-control "$cache" --content-type "$type"
}

publish_mac() {
  local dist="01-finder-sidebar/dist" published=0
  for info in "$dist"/RELEASE_INFO-*.env; do
    [ -f "$info" ] || continue
    # shellcheck disable=SC1090
    source "$info"
    [ -f "$dist/$DMG_LOCAL" ] || { echo "缺 $dist/$DMG_LOCAL(先跑 make_release_matrix.sh)"; exit 1; }
    [ -f "$dist/$APPCAST_LOCAL" ] || { echo "缺 $dist/$APPCAST_LOCAL"; exit 1; }
    put_object "mac/$DMG_REMOTE" "$dist/$DMG_LOCAL" \
      "public, max-age=31536000, immutable" "application/octet-stream"
    put_object "mac/$APPCAST_LOCAL" "$dist/$APPCAST_LOCAL" \
      "no-cache" "application/xml"
    echo "macOS $APP_VERSION ($BUILD_VERSION) 已发布:mac/$APPCAST_LOCAL → mac/$DMG_REMOTE"
    published=1
  done
  [ "$published" = "1" ] || { echo "01-finder-sidebar/dist 里没有 RELEASE_INFO-*.env(先构建)"; exit 1; }
}

publish_win() {
  local dist="win-explorer-sidebar/dist"
  local appcast="$dist/appcast.xml"
  [ -f "$appcast" ] || { echo "缺 $appcast(先跑 win-explorer-sidebar/build_release.sh)"; exit 1; }
  # 安装器远端名与 appcast enclosure 保持一致(由 build_release.sh 写入)。
  local remote_name
  remote_name=$(sed -n 's/.*url="[^"]*\/\(Folderis-Setup[^"]*\.exe\)".*/\1/p' "$appcast" | head -1)
  [ -n "$remote_name" ] || { echo "无法从 $appcast 解析安装器文件名"; exit 1; }
  [ -f "$dist/Folderis-Setup.exe" ] || { echo "缺 $dist/Folderis-Setup.exe"; exit 1; }
  # NetSparkle Strict 模式会先下载 <appcast>.signature 验证 appcast 本身,
  # 缺它整条 feed 作废(Sparkle/mac 无此要求)。先传 signature 再传 appcast。
  [ -f "$appcast.signature" ] || { echo "缺 $appcast.signature(build_release.sh 应已生成)"; exit 1; }
  put_object "win/$remote_name" "$dist/Folderis-Setup.exe" \
    "public, max-age=31536000, immutable" "application/octet-stream"
  put_object "win/appcast.xml.signature" "$appcast.signature" "no-cache" "text/plain"
  put_object "win/appcast.xml" "$appcast" "no-cache" "application/xml"
  echo "Windows 已发布:win/appcast.xml → win/$remote_name"
}

case "$TARGET" in
  mac) publish_mac ;;
  win) publish_win ;;
  all) publish_mac; publish_win ;;
  *) echo "未知目标 $TARGET(mac|win|all)"; exit 1 ;;
esac
