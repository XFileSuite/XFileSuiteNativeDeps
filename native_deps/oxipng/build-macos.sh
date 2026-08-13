#!/usr/bin/env bash
set -euo pipefail
VERSION=9.1.5
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DOWNLOAD_DIR="$SCRIPT_DIR/downloads"
OUTPUT_DIR="$SCRIPT_DIR/dist"
BASE_URL="https://github.com/oxipng/oxipng/releases/download/v$VERSION"
ARM_ARCHIVE="oxipng-$VERSION-aarch64-apple-darwin.tar.gz"
X64_ARCHIVE="oxipng-$VERSION-x86_64-apple-darwin.tar.gz"
ARM_SHA256="a3fbb890c934ca785302d8533d5f076c053cc61946d52b728bca5df7f47cb2e8"
X64_SHA256="3e55de868eeea1ea41fe5ecddd5790871669c7e2527d996827e91bba8004c289"

download() { local name="$1" sha="$2"; mkdir -p "$DOWNLOAD_DIR"; if [ ! -f "$DOWNLOAD_DIR/$name" ] || [ "$(shasum -a 256 "$DOWNLOAD_DIR/$name" | awk '{print $1}')" != "$sha" ]; then curl -fL --retry 5 --retry-all-errors -o "$DOWNLOAD_DIR/$name" "$BASE_URL/$name"; fi; echo "$sha  $DOWNLOAD_DIR/$name" | shasum -a 256 -c -; }
download "$ARM_ARCHIVE" "$ARM_SHA256"
download "$X64_ARCHIVE" "$X64_SHA256"
stage="$OUTPUT_DIR/oxipng-macos-universal"; rm -rf "$OUTPUT_DIR"; mkdir -p "$stage/ThirdPartyLicenses/Oxipng" "$OUTPUT_DIR/arm" "$OUTPUT_DIR/x64"
tar -xzf "$DOWNLOAD_DIR/$ARM_ARCHIVE" --strip-components=1 -C "$OUTPUT_DIR/arm"
tar -xzf "$DOWNLOAD_DIR/$X64_ARCHIVE" --strip-components=1 -C "$OUTPUT_DIR/x64"
lipo -create "$OUTPUT_DIR/arm/oxipng" "$OUTPUT_DIR/x64/oxipng" -output "$stage/oxipng"
cp "$OUTPUT_DIR/arm/LICENSE" "$stage/ThirdPartyLicenses/Oxipng/OXIPNG-LICENSE.txt"
lipo -archs "$stage/oxipng" | grep -q arm64; lipo -archs "$stage/oxipng" | grep -q x86_64
"$stage/oxipng" --version | grep -Fq "$VERSION"
tar -C "$stage" -czf "$OUTPUT_DIR/oxipng-macos-universal.tar.gz" .
