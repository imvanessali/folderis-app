#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

if [ "$(uname -s)" != "Darwin" ]; then
  echo "This helper is for macOS. On Windows, run dotnet build directly." >&2
  exit 1
fi

dotnet_candidates=()
if [ -n "${DOTNET:-}" ]; then
  dotnet_candidates+=("$DOTNET")
fi
dotnet_candidates+=(
  "$HOME/.dotnet-folderis/dotnet"
  "/usr/local/share/dotnet/dotnet"
  "$HOME/.dotnet/dotnet"
  "/opt/homebrew/opt/dotnet@8/libexec/dotnet"
  "/usr/local/opt/dotnet@8/libexec/dotnet"
)
if command -v dotnet >/dev/null 2>&1; then
  dotnet_candidates+=("$(command -v dotnet)")
fi

dotnet_command=""
for candidate in "${dotnet_candidates[@]}"; do
  [ -x "$candidate" ] || continue
  sdk_line="$("$candidate" --list-sdks | awk '$1 ~ /^8\.0\.4[0-9][0-9]$/ { line = $0 } END { print line }')"
  [ -n "$sdk_line" ] || continue
  sdk_version="${sdk_line%% *}"
  sdk_root="${sdk_line#*[}"
  sdk_root="${sdk_root%]}"
  windows_desktop_targets="$sdk_root/$sdk_version/Sdks/Microsoft.NET.Sdk.WindowsDesktop/targets/Microsoft.NET.Sdk.WindowsDesktop.targets"
  if [ -f "$windows_desktop_targets" ]; then
    dotnet_command="$candidate"
    break
  fi
done

if [ -z "$dotnet_command" ]; then
  echo "Missing the official .NET 8 SDK with WPF cross-build tools." >&2
  echo "Install it with: ./win-explorer-sidebar/install_mac_cross_sdk.sh" >&2
  exit 1
fi

project="src/Sider/Sider.csproj"

echo "Using $("$dotnet_command" --version) from $dotnet_command"
"$dotnet_command" restore "$project"
"$dotnet_command" build "$project" -c Release --no-restore -p:Lite=false
"$dotnet_command" build "$project" -c Release --no-restore -p:Lite=true

echo "Windows cross-build passed for Folderis Full and Lite."
