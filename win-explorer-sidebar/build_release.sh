#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

DOTNET="${DOTNET:-$HOME/.dotnet/dotnet}"
[ -x "$DOTNET" ] || { echo "Missing .NET SDK: $DOTNET"; exit 1; }
MAKENSIS="${MAKENSIS:-$(command -v makensis || true)}"
INSTALLER_MODE="${INSTALLER_MODE:-auto}"
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
  "$DIST/Folderis-Setup.exe" \
  "$DIST/Folderis-Setup-dotnet.exe" \
  "$DIST/Folderis-Windows-x64.zip" \
  "$DIST/Folderis-Windows-x64-fresh.zip" \
  "$DIST/归档.zip"
trap 'rm -f "$SETUP_PAYLOAD"' EXIT

publish_app() {
  local output="$1"
  shift
  "$DOTNET" publish "$PROJECT" -c Release -r "$RID" --self-contained true \
    -p:PublishSingleFile=false -p:DebugType=None -p:DebugSymbols=false \
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

if [ -z "$SIGN_PFX" ]; then
  echo "" >&2
  echo "⚠️  UNSIGNED BUILD: installers and app EXEs have no Authenticode signature" >&2
  echo "   and will trigger Unknown Publisher / SmartScreen warnings." >&2
  echo "   Set FOLDERIS_SIGN_PFX / FOLDERIS_SIGN_PASSWORD to sign release artifacts" >&2
  echo "   (FOLDERIS_SIGN_REQUIRE=1 makes signing mandatory)." >&2
fi

echo "Windows release artifacts are in $DIST"
