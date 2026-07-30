#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

DOTNET="${DOTNET:-$HOME/.dotnet/dotnet}"
[ -x "$DOTNET" ] || { echo "Missing .NET SDK: $DOTNET"; exit 1; }
MAKENSIS="${MAKENSIS:-$(command -v makensis || true)}"
INSTALLER_MODE="${INSTALLER_MODE:-auto}"

# 应用版本单一来源：这里的 FOLDERIS_APP_VERSION 同时喂给
# csproj（-p:Version → AssemblyVersion，版本公告比对的就是它）
# 和 makensis（-DAPP_VERSION → 安装器资源版本与卸载项 DisplayVersion）。
if [ -z "${FOLDERIS_APP_VERSION:-}" ]; then
  echo "" >&2
  echo "⚠️  FOLDERIS_APP_VERSION 未设置，使用默认值 1.1.0。" >&2
  echo "   若线上已经是这个版本，版本公告会判定「无更新」，发出去等于没发。" >&2
  echo "   正式发布请显式指定版本号。" >&2
fi
APP_VERSION="${FOLDERIS_APP_VERSION:-1.1.0}"
# 构建号（设置页显示用，不参与更新比对）：默认按日期生成，永远不会是过时的写死值。
BUILD_VERSION="${FOLDERIS_BUILD_VERSION:-$(date +%Y%m%d).1}"
[[ "$APP_VERSION" =~ ^[0-9]+(\.[0-9]+){1,3}$ ]] || {
  echo "FOLDERIS_APP_VERSION must look like 1.2 / 1.2.3 / 1.2.3.4: $APP_VERSION" >&2; exit 1; }
# VIProductVersion 必须是四段，补齐 .0
APP_VERSION_FULL="$APP_VERSION"
while [ "$(echo "$APP_VERSION_FULL" | tr -cd '.' | wc -c | tr -d ' ')" -lt 3 ]; do
  APP_VERSION_FULL="$APP_VERSION_FULL.0"
done
case "$INSTALLER_MODE" in
  auto|nsis|dotnet) ;;
  *) echo "INSTALLER_MODE must be auto, nsis, or dotnet"; exit 1 ;;
esac

# Authenticode 签名（QA 2026-07-23 D3）：提供 FOLDERIS_SIGN_PFX（.pfx 路径）
# 和 FOLDERIS_SIGN_PASSWORD 即对内部 App EXE 与安装器签名；
# FOLDERIS_SIGN_REQUIRE=1 时缺证书直接失败（发布件必须签名）。
SIGN_PFX="${FOLDERIS_SIGN_PFX:-}"
SIGN_PASSWORD="${FOLDERIS_SIGN_PASSWORD:-}"
SIGN_TIMESTAMP_URL="${FOLDERIS_SIGN_TIMESTAMP_URL:-http://timestamp.digicert.com}"
SIGN_REQUIRE="${FOLDERIS_SIGN_REQUIRE:-0}"
if [ -n "$SIGN_PFX" ]; then
  [ -f "$SIGN_PFX" ] || { echo "FOLDERIS_SIGN_PFX not found: $SIGN_PFX" >&2; exit 1; }
  command -v osslsigncode >/dev/null || { echo "Missing osslsigncode: brew install osslsigncode" >&2; exit 1; }
elif [ "$SIGN_REQUIRE" = "1" ]; then
  echo "FOLDERIS_SIGN_REQUIRE=1 but FOLDERIS_SIGN_PFX is not set; release artifacts must be Authenticode signed." >&2
  exit 1
fi

sign_file() {
  local file="$1"
  [ -n "$SIGN_PFX" ] || return 0
  osslsigncode sign -pkcs12 "$SIGN_PFX" ${SIGN_PASSWORD:+-pass "$SIGN_PASSWORD"} \
    -n "Folderis" -i "https://folderis.app" \
    -t "$SIGN_TIMESTAMP_URL" -h sha256 \
    -in "$file" -out "$file.signed"
  mv "$file.signed" "$file"
  osslsigncode verify -in "$file" >/dev/null
  echo "Signed: $file"
}

PROJECT="src/Sider/Sider.csproj"
DIST="dist"
RID="win-x64"
RUNTIME="runtime-cache/$RID/runtime"
SETUP_PROJECT="src/Setup/Setup.csproj"
SETUP_PAYLOAD="src/Setup/payload.zip"

rm -rf "$DIST/full-$RID"
mkdir -p "$DIST"
rm -f \
  "$DIST"/Folderis-Setup*.exe \
  "$DIST/Folderis-Windows-x64.zip" \
  "$DIST/Folderis-Windows-x64-fresh.zip" \
  "$DIST/归档.zip"
trap 'rm -f "$SETUP_PAYLOAD"' EXIT

publish_app() {
  local output="$1"
  shift
  "$DOTNET" publish "$PROJECT" -c Release -r "$RID" --self-contained true \
    -p:PublishSingleFile=false -p:DebugType=None -p:DebugSymbols=false \
    -p:Version="$APP_VERSION" -p:FolderisBuild="$BUILD_VERSION" \
    -o "$output" "$@"
  cp -R "$RUNTIME" "$output/runtime"
}

build_setup() {
  local payload_dir="$1"
  local setup_name="$2"
  local app_name="$3"
  local app_exe="$4"
  local app_id="$5"
  local root
  root="$(pwd)"
  "$MAKENSIS" -V2 \
    "-DAPP_VERSION=$APP_VERSION" \
    "-DAPP_VERSION_FULL=$APP_VERSION_FULL" \
    "-DAPP_NAME=$app_name" \
    "-DAPP_EXE=$app_exe" \
    "-DAPP_ID=$app_id" \
    "-DPAYLOAD_DIR=$root/$payload_dir" \
    "-DOUTPUT_FILE=$root/$DIST/$setup_name.exe" \
    "-DAPP_ICON=$root/src/Sider/Assets/app.ico" \
    installer.nsi
}

build_dotnet_setup() {
  local payload_dir="$1"
  local setup_name="$2"
  local assembly_name="$3"
  local output_dir="$4"

  rm -f "$SETUP_PAYLOAD"
  (
    cd "$payload_dir"
    zip -qry "$(pwd)/../../src/Setup/payload.zip" .
  )
  rm -rf "$output_dir"
  "$DOTNET" publish "$SETUP_PROJECT" -c Release -r "$RID" --self-contained true \
    -p:PublishSingleFile=true -p:DebugType=None -p:DebugSymbols=false \
    -p:Version="$APP_VERSION" \
    -p:SetupName="$assembly_name" -o "$output_dir"
  cp "$output_dir/$assembly_name.exe" "$DIST/$setup_name.exe"
  rm -f "$SETUP_PAYLOAD"
}

./prepare_windows_runtime.sh

publish_app "$DIST/full-$RID"
sign_file "$DIST/full-$RID/Folderis.exe"

if [ "$INSTALLER_MODE" != "dotnet" ] && [ -x "$MAKENSIS" ]; then
  if build_setup "$DIST/full-$RID" "Folderis-Setup" "Folderis" "Folderis.exe" "Folderis"; then
    sign_file "$DIST/Folderis-Setup.exe"
    echo "Built NSIS installer."
  elif [ "$INSTALLER_MODE" = "nsis" ]; then
    echo "NSIS installer build failed." >&2
    exit 1
  else
    echo "NSIS installer build failed; building the .NET fallback installer." >&2
    rm -f "$DIST/Folderis-Setup.exe"
    INSTALLER_MODE="dotnet"
  fi
elif [ "$INSTALLER_MODE" = "nsis" ]; then
  echo "Missing NSIS compiler: brew install nsis" >&2
  exit 1
else
  INSTALLER_MODE="dotnet"
fi

if [ "$INSTALLER_MODE" = "dotnet" ]; then
  build_dotnet_setup "$DIST/full-$RID" "Folderis-Setup" "Folderis-Setup" ".setup-build/full"
  sign_file "$DIST/Folderis-Setup.exe"
fi

# 带版本号的正式产物名：Folderis-Setup-<版本>.exe（与 macOS 端同一套约定）。
# 保留不带版本号的 Folderis-Setup.exe，QA 脚本与既有文档仍按老名字取。
RELEASE_INSTALLER="$DIST/Folderis-Setup-$APP_VERSION.exe"
cp "$DIST/Folderis-Setup.exe" "$RELEASE_INSTALLER"

if [ -z "$SIGN_PFX" ]; then
  echo "" >&2
  echo "⚠️  UNSIGNED BUILD: installers and app EXEs have no Authenticode signature" >&2
  echo "   and will trigger Unknown Publisher / SmartScreen warnings." >&2
  echo "   Set FOLDERIS_SIGN_PFX / FOLDERIS_SIGN_PASSWORD to sign release artifacts" >&2
  echo "   (FOLDERIS_SIGN_REQUIRE=1 makes signing mandatory)." >&2
fi

# 最终分发物统一放仓库根 Release/<版本号>/（与 mac 共用 make_release.sh 里的
# BUILD_VERSION，保证同一版本的两端产物落在同一目录）；dist/ 只是构建暂存。
# 注意：这个目录名版本与本脚本自身的 BUILD_VERSION（App 设置页构建号）是两回事，
# 用独立变量名避免覆盖。
RELEASE_TAG=$(sed -n 's/^BUILD_VERSION="\(.*\)"/\1/p' ../01-finder-sidebar/make_release.sh)
[ -n "$RELEASE_TAG" ] || { echo "无法从 ../01-finder-sidebar/make_release.sh 读取 BUILD_VERSION" >&2; exit 1; }
RELEASE_DIR="../Release/$RELEASE_TAG"
mkdir -p "$RELEASE_DIR"
cp "$DIST/Folderis-Setup.exe" "$RELEASE_DIR/"
(
  cd "$RELEASE_DIR"
  shasum -a 256 Folderis-Setup.exe
) > "$RELEASE_DIR/Folderis-Windows-x64-SHA256.txt"

echo "Windows release artifacts are in $RELEASE_DIR (version $APP_VERSION, build $BUILD_VERSION)"
echo "通知用户更新：改 announce/public/announce.json 的 win.version 与下载页，跑根目录 publish_notice.sh。"
