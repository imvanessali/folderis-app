#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

PY_VERSION="3.12.8"
CACHE="runtime-cache/win-x64"
RUNTIME="$CACHE/runtime"
STAMP="$CACHE/runtime-$PY_VERSION-v4.ready"
PIP_ENV="$CACHE/pip-env"

write_skills_version() {
  {
    printf 'catalog.txt\0'
    cat "$RUNTIME/skills/catalog.txt"
    printf 'skills.py\0'
    cat "$RUNTIME/skills/skills.py"
  } | shasum -a 256 | awk '{print $1}' > "$RUNTIME/SKILLS_VERSION"
}

if [ -f "$STAMP" ] && [ -f "$RUNTIME/python/python.exe" ] && \
   [ -f "$RUNTIME/skills/skills.py" ]; then
  # Python and third-party wheels are cached, but the product skill sources
  # must always follow the current checkout.
  cp ../01-finder-sidebar/skills/skills.py "$RUNTIME/skills/skills.py"
  cp ../01-finder-sidebar/skills/catalog.txt "$RUNTIME/skills/catalog.txt"
  write_skills_version
  exit 0
fi

TMP="$CACHE/build.tmp"
rm -rf "$TMP"
mkdir -p "$TMP/runtime/python/Lib/site-packages" "$TMP/runtime/skills"

PY_ZIP="$TMP/python.zip"
curl -fL --retry 3 --connect-timeout 20 \
  "https://www.python.org/ftp/python/$PY_VERSION/python-$PY_VERSION-embed-amd64.zip" \
  -o "$PY_ZIP"
unzip -q "$PY_ZIP" -d "$TMP/runtime/python"
rm -f "$PY_ZIP"

PTH="$(find "$TMP/runtime/python" -maxdepth 1 -name 'python3*._pth' -print -quit)"
[ -n "$PTH" ] || { echo "Embedded Python path file was not found"; exit 1; }
printf '\nLib/site-packages\nimport site\n' >> "$PTH"

if [ ! -x "$PIP_ENV/bin/pip" ]; then
  python3 -m venv "$PIP_ENV"
fi
"$PIP_ENV/bin/pip" install --quiet --upgrade pip
"$PIP_ENV/bin/pip" install \
  --target "$TMP/runtime/python/Lib/site-packages" \
  --platform win_amd64 --python-version 3.12 --implementation cp --abi cp312 \
  --only-binary=:all: --upgrade \
  pip \
  pypdf==6.14.2 openpyxl==3.1.5 Pillow==12.3.0 chardet==7.4.3 \
  python-docx==1.2.0 pillow-heif==1.4.0 pywin32==312 pymupdf==1.28.0 \
  qrcode==8.2 zxing-cpp==3.1.0 winocr==0.0.15 pyzipper==0.4.0 xlrd==2.0.2

cp ../01-finder-sidebar/skills/skills.py "$TMP/runtime/skills/skills.py"
cp ../01-finder-sidebar/skills/catalog.txt "$TMP/runtime/skills/catalog.txt"
find "$TMP/runtime" -type d -name __pycache__ -prune -exec rm -rf {} +

rm -rf "$RUNTIME"
mv "$TMP/runtime" "$RUNTIME"
rm -rf "$TMP"
write_skills_version
touch "$STAMP"
