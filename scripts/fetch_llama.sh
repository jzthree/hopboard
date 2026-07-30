#!/bin/sh
# Downloads the llama.cpp xcframework (with libmtmd audio support) into
# Vendor/ — required to build the app; too big (800 MB) to commit.
set -e
cd "$(dirname "$0")/.."
[ -d Vendor/llama.xcframework ] && { echo "already present"; exit 0; }
mkdir -p Vendor
url=$(gh api repos/ggml-org/llama.cpp/releases/latest \
  --jq '.assets[] | select(.name | test("xcframework")) | .browser_download_url')
echo "fetching $url"
curl -sL -o /tmp/llama-xcf.zip "$url"
unzip -q /tmp/llama-xcf.zip -d /tmp/llama-xcf
mv /tmp/llama-xcf/build-apple/llama.xcframework Vendor/
rm -rf /tmp/llama-xcf /tmp/llama-xcf.zip
echo "Vendor/llama.xcframework ready"
