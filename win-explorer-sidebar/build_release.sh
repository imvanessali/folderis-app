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

PROJECT="src/Sider/Sider.csproj"
DIST="dist"
RID="win-x64"
RUNTIME="runtime-cache/$RID/runtime"
SETUP_PROJECT="src/Setup/Setup.csproj"
SETUP_PAYLOAD="src/Setup/payload.zip"

rm -rf "$DIST/full-$RID" "$DIST/lite-$RID"
mkdir -p "$DIST"
rm -f \
  "$DIST/Folderis-Setup.exe" \
  "$DIST/Folderis-Lite-Setup.exe" \
  "$DIST/Folderis-Setup-dotnet.exe" \
  "$DIST/Folderis-Lite-Setup-dotnet.exe" \
  "$DIST/Folderis-Windows-x64.zip" \
  "$DIST/Folderis-Lite-Windows-x64.zip" \
  "$DIST/Folderis-Windows-x64-fresh.zip" \
  "$DIST/Folderis-Lite-Windows-x64-fresh.zip" \
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
publish_app "$DIST/lite-$RID" -p:Lite=true

if [ "$INSTALLER_MODE" != "dotnet" ] && [ -x "$MAKENSIS" ]; then
  if build_setup "$DIST/full-$RID" "Folderis-Setup" "Folderis" "Folderis.exe" "Folderis" && \
     build_setup "$DIST/lite-$RID" "Folderis-Lite-Setup" "Folderis Lite" "Folderis Lite.exe" "FolderisLite"; then
    echo "Built NSIS installers."
  elif [ "$INSTALLER_MODE" = "nsis" ]; then
    echo "NSIS installer build failed." >&2
    exit 1
  else
    echo "NSIS installer build failed; building the .NET fallback installers." >&2
    rm -f "$DIST/Folderis-Setup.exe" "$DIST/Folderis-Lite-Setup.exe"
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
  build_dotnet_setup "$DIST/lite-$RID" "Folderis-Lite-Setup" "Folderis-Lite-Setup" ".setup-build/lite"
fi

echo "Windows release artifacts are in $DIST"
