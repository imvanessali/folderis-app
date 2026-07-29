#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

DOTNET="${DOTNET:-$HOME/.dotnet/dotnet}"
[ -x "$DOTNET" ] || { echo "Missing .NET SDK: $DOTNET"; exit 1; }
MAKENSIS="${MAKENSIS:-$(command -v makensis || true)}"
INSTALLER_MODE="${INSTALLER_MODE:-auto}"

# 应用版本单一来源：这里的 FOLDERIS_APP_VERSION 同时喂给
# csproj（-p:Version → AssemblyVersion，自动更新比对的就是它）
# 和 makensis（-DAPP_VERSION → 安装器资源版本与卸载项 DisplayVersion）。
# 正式发布（FOLDERIS_APPCAST_REQUIRE=1）必须显式指定：沿用默认值会打出一个
# 与已装机版本相同的包，appcast 照样生成，但没有任何客户端会认为有更新。
if [ -z "${FOLDERIS_APP_VERSION:-}" ]; then
  if [ "${FOLDERIS_APPCAST_REQUIRE:-0}" = "1" ]; then
    echo "FOLDERIS_APPCAST_REQUIRE=1 requires an explicit FOLDERIS_APP_VERSION" >&2
    echo "   例：FOLDERIS_APP_VERSION=1.2.0 FOLDERIS_APPCAST_REQUIRE=1 ./build_release.sh" >&2
    exit 1
  fi
  echo "" >&2
  echo "⚠️  FOLDERIS_APP_VERSION 未设置，使用默认值 1.1.0。" >&2
  echo "   若线上已经是这个版本，自动更新会判定「无更新」，发出去等于没发。" >&2
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

# 自动更新 appcast（NetSparkleUpdater，Ed25519 签名，与 macOS 端 Sparkle 同源格式）。
# 密钥目录默认 ~/.folderis-release/netsparkle，内含 NetSparkle_Ed25519.priv / .pub。
# 首次生成（务必离线备份 .priv，丢了就再也发不出能被老版本接受的更新）：
#   dotnet tool install -g NetSparkleUpdater.Tools.AppCastGenerator --version 2.5.0
#   netsparkle-generate-appcast --generate-keys --key-path "$HOME/.folderis-release/netsparkle"
#   netsparkle-generate-appcast --export --key-path "$HOME/.folderis-release/netsparkle"
#   # 把导出的公钥填进 src/Sider/UpdaterService.cs 的 PublicKey 常量
UPDATE_BASE_URL="${FOLDERIS_UPDATE_BASE_URL:-https://dl.folderis.app}"
NETSPARKLE_KEYS="${FOLDERIS_NETSPARKLE_KEYS:-$HOME/.folderis-release/netsparkle}"
APPCAST_REQUIRE="${FOLDERIS_APPCAST_REQUIRE:-0}"
APPCAST_TOOL="${APPCAST_TOOL:-$(command -v netsparkle-generate-appcast || true)}"
# 全局工具是 apphost，dotnet 不在系统默认位置时要靠 DOTNET_ROOT 找运行时
export DOTNET_ROOT="${DOTNET_ROOT:-$(dirname "$DOTNET")}"
if [ -z "$APPCAST_TOOL" ] && [ -x "$HOME/.dotnet/tools/netsparkle-generate-appcast" ]; then
  APPCAST_TOOL="$HOME/.dotnet/tools/netsparkle-generate-appcast"
fi

# 缺工具/缺密钥时的处理与 Authenticode 一致：默认醒目警告后跳过，
# FOLDERIS_APPCAST_REQUIRE=1 时直接失败（正式发布必须出 appcast）。
appcast_skip() {
  local reason="$1" hint="$2"
  if [ "$APPCAST_REQUIRE" = "1" ]; then
    echo "FOLDERIS_APPCAST_REQUIRE=1 but the app cast cannot be generated: $reason" >&2
    echo "   $hint" >&2
    exit 1
  fi
  echo "" >&2
  echo "⚠️  NO APP CAST: $reason" >&2
  echo "   $hint" >&2
  echo "   自动更新不会看到这个版本（已发布的老版本仍按线上 appcast 走）。" >&2
  echo "   FOLDERIS_APPCAST_REQUIRE=1 可让缺失直接失败。" >&2
}

generate_appcast() {
  local installer="$1"
  if [ -z "$APPCAST_TOOL" ]; then
    appcast_skip "netsparkle-generate-appcast not found" \
      "安装：dotnet tool install -g NetSparkleUpdater.Tools.AppCastGenerator --version 2.5.0"
    return 0
  fi
  if [ ! -f "$NETSPARKLE_KEYS/NetSparkle_Ed25519.priv" ]; then
    appcast_skip "missing Ed25519 private key in $NETSPARKLE_KEYS" \
      "生成：netsparkle-generate-appcast --generate-keys --key-path \"$NETSPARKLE_KEYS\"（生成后离线备份 .priv）"
    return 0
  fi

  # 内置公钥必须与签名私钥配对，否则发出去的更新会被客户端 Strict 校验拒绝。
  # 本地用测试密钥试更新流程时可以 FOLDERIS_APPCAST_PUBKEY_CHECK=0 跳过。
  local built_in pub_key
  built_in="$(sed -n 's/.*PublicKey = "\([^"]*\)".*/\1/p' src/Sider/UpdaterService.cs 2>/dev/null | head -1 || true)"
  pub_key="$(tr -d '[:space:]' < "$NETSPARKLE_KEYS/NetSparkle_Ed25519.pub" 2>/dev/null || true)"
  if [ "${FOLDERIS_APPCAST_PUBKEY_CHECK:-1}" = "1" ] && [ "$built_in" != "$pub_key" ]; then
    appcast_skip "UpdaterService.PublicKey does not match $NETSPARKLE_KEYS/NetSparkle_Ed25519.pub" \
      "把公钥填进 src/Sider/UpdaterService.cs 的 PublicKey 常量后重新构建（当前值：${built_in:-空}）"
    return 0
  fi

  # 生成器会把 -b 目录下所有 .exe 都写进 appcast，因此只放本次要发布的那一个。
  local stage="$DIST/.appcast-input"
  rm -rf "$stage"
  mkdir -p "$stage"
  cp "$installer" "$stage/"
  "$APPCAST_TOOL" \
    --appcast-output-directory "$DIST" \
    --binaries "$stage" --ext exe --os windows \
    --product-name "Folderis" \
    --base-url "$UPDATE_BASE_URL/win" \
    --file-version "$APP_VERSION" \
    --key-path "$NETSPARKLE_KEYS" \
    --human-readable
  rm -rf "$stage"
  [ -f "$DIST/appcast.xml" ] && [ -f "$DIST/appcast.xml.signature" ] || {
    echo "App cast generation did not produce appcast.xml(.signature)" >&2; exit 1; }
  echo "Generated app cast for $APP_VERSION: $DIST/appcast.xml (+ .signature)"
}

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
  "$DIST/appcast.xml" \
  "$DIST/appcast.xml.signature" \
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

# 上传/自动更新用的正式产物名：win/Folderis-Setup-<版本>.exe（与 macOS 端同一套约定）。
# 保留不带版本号的 Folderis-Setup.exe，QA 脚本与既有文档仍按老名字取。
RELEASE_INSTALLER="$DIST/Folderis-Setup-$APP_VERSION.exe"
cp "$DIST/Folderis-Setup.exe" "$RELEASE_INSTALLER"

if [ "$INSTALLER_MODE" = "dotnet" ]; then
  # 回退的 .NET 安装器一定会弹窗，不能无人值守安装；此时不产 appcast，
  # 免得推给用户一个装到一半卡在弹窗的更新。
  appcast_skip "the .NET fallback installer cannot install silently (/S)" \
    "装上 NSIS 后重跑：brew install nsis（或 INSTALLER_MODE=nsis 强制失败暴露问题）"
else
  generate_appcast "$RELEASE_INSTALLER"
fi

if [ -z "$SIGN_PFX" ]; then
  echo "" >&2
  echo "⚠️  UNSIGNED BUILD: installers and app EXEs have no Authenticode signature" >&2
  echo "   and will trigger Unknown Publisher / SmartScreen warnings." >&2
  echo "   Set FOLDERIS_SIGN_PFX / FOLDERIS_SIGN_PASSWORD to sign release artifacts" >&2
  echo "   (FOLDERIS_SIGN_REQUIRE=1 makes signing mandatory)." >&2
fi

echo "Windows release artifacts are in $DIST (version $APP_VERSION, build $BUILD_VERSION)"
echo "  上传：$RELEASE_INSTALLER → $UPDATE_BASE_URL/win/Folderis-Setup-$APP_VERSION.exe"
echo "        $DIST/appcast.xml(.signature) → $UPDATE_BASE_URL/win/appcast.xml(.signature)"
