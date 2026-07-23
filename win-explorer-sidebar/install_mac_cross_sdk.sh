#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

if [ "$(uname -s)" != "Darwin" ]; then
  echo "This installer is only needed on macOS." >&2
  exit 1
fi

sdk_version="8.0.423"
sdk_arch="$(uname -m)"
case "$sdk_arch" in
  arm64)
    package_arch="arm64"
    sdk_sha512="8fa82f2dce5fd44982a7d11d231417b4ebe43b31c817865aa52dbe2fca1775dd3be5bdbbbfc7d29db20578a6a15bc86a2c4ed47cee2e3a29de877be20e666877"
    ;;
  x86_64)
    package_arch="x64"
    sdk_sha512="de242fe11a026d7d4efec15d29dd37bb0cd9802fb396ae990199dc3e7df86eb1fb0d28ef52bdaf6cc8a798fddc6f54132fb2245d63bd83c8997d2f0f20de8826"
    ;;
  *)
    echo "Unsupported Mac architecture: $sdk_arch" >&2
    exit 1
    ;;
esac

folderis_dotnet_dir="${FOLDERIS_DOTNET_DIR:-$HOME/.dotnet-folderis}"
windows_desktop_targets="$folderis_dotnet_dir/sdk/$sdk_version/Sdks/Microsoft.NET.Sdk.WindowsDesktop/targets/Microsoft.NET.Sdk.WindowsDesktop.targets"
if [ -x "$folderis_dotnet_dir/dotnet" ] && [ -f "$windows_desktop_targets" ]; then
  echo "Folderis macOS cross-build SDK $sdk_version is already installed."
  exit 0
fi

temporary_dir="$(mktemp -d /tmp/folderis-dotnet-sdk.XXXXXX)"
trap 'rm -rf "$temporary_dir"' EXIT

package_name="dotnet-sdk-$sdk_version-osx-$package_arch.pkg"
package_path="$temporary_dir/$package_name"
package_url="https://builds.dotnet.microsoft.com/dotnet/Sdk/$sdk_version/$package_name"

echo "Downloading official Microsoft .NET SDK $sdk_version..."
curl --fail --location --progress-bar --output "$package_path" "$package_url"

actual_sha512="$(shasum -a 512 "$package_path" | awk '{print $1}')"
if [ "$actual_sha512" != "$sdk_sha512" ]; then
  echo "SDK checksum mismatch; refusing to install." >&2
  exit 1
fi

expanded_path="$temporary_dir/expanded"
pkgutil --expand-full "$package_path" "$expanded_path"
mkdir -p "$folderis_dotnet_dir"

while IFS= read -r -d '' payload; do
  ditto "$payload" "$folderis_dotnet_dir"
done < <(find "$expanded_path" -type d -name Payload -print0)

if [ ! -x "$folderis_dotnet_dir/dotnet" ] || [ ! -f "$windows_desktop_targets" ]; then
  echo "SDK extraction did not produce the required WPF build tools." >&2
  exit 1
fi

echo "Installed Folderis macOS cross-build SDK in $folderis_dotnet_dir"
