#!/usr/bin/env bash
# Packages Oxipng 10.2.0 for macOS:
#   - official universal CLI (lipo of arm64 + x86_64 release binaries)
#   - C FFI library (liboxipng.dylib) + public header under native-headers/
set -euo pipefail

VERSION=10.2.0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DOWNLOAD_DIR="$SCRIPT_DIR/downloads"
OUTPUT_DIR="$SCRIPT_DIR/dist"
FFI_DIR="$SCRIPT_DIR/ffi"
WORK_DIR="$SCRIPT_DIR/work/ffi"
BASE_URL="https://github.com/oxipng/oxipng/releases/download/v$VERSION"
ARM_ARCHIVE="oxipng-$VERSION-aarch64-apple-darwin.tar.gz"
X64_ARCHIVE="oxipng-$VERSION-x86_64-apple-darwin.tar.gz"
ARM_SHA256="9aad3927d095b6ade2aacb92b89ebaca442483c1f7cde5d7a2486b283c2ed5f9"
X64_SHA256="c45acf40a70cc02539c55555ac240bf5ef24544b7ea9959d22da19f606cec205"
TARGETS=(aarch64-apple-darwin x86_64-apple-darwin)
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-11.0}"

command -v cargo >/dev/null || { echo 'Rust cargo is required to build liboxipng.' >&2; exit 1; }
command -v rustup >/dev/null || { echo 'rustup is required to build liboxipng.' >&2; exit 1; }
command -v lipo >/dev/null || { echo 'Xcode lipo is required.' >&2; exit 1; }
command -v install_name_tool >/dev/null || { echo 'install_name_tool is required.' >&2; exit 1; }

download() {
  local name="$1" sha="$2" actual
  mkdir -p "$DOWNLOAD_DIR"
  if [ ! -f "$DOWNLOAD_DIR/$name" ] || [ "$(shasum -a 256 "$DOWNLOAD_DIR/$name" | awk '{print $1}')" != "$sha" ]; then
    curl -fL --retry 5 --retry-all-errors -o "$DOWNLOAD_DIR/$name" "$BASE_URL/$name"
  fi
  actual="$(shasum -a 256 "$DOWNLOAD_DIR/$name" | awk '{print $1}')"
  if [ "$actual" != "$sha" ]; then
    echo "Official Oxipng archive checksum mismatch: $name" >&2
    echo "Expected SHA-256: $sha" >&2
    echo "Actual SHA-256:   $actual" >&2
    echo "Downloaded size: $(wc -c < "$DOWNLOAD_DIR/$name" | tr -d ' ') bytes" >&2
    exit 1
  fi
}

download "$ARM_ARCHIVE" "$ARM_SHA256"
download "$X64_ARCHIVE" "$X64_SHA256"

stage="$OUTPUT_DIR/oxipng-macos-universal"
rm -rf "$OUTPUT_DIR"
mkdir -p "$stage/ThirdPartyLicenses/Oxipng" \
  "$stage/native-headers/oxipng-$VERSION" \
  "$OUTPUT_DIR/arm" \
  "$OUTPUT_DIR/x64" \
  "$WORK_DIR"

tar -xzf "$DOWNLOAD_DIR/$ARM_ARCHIVE" --strip-components=1 -C "$OUTPUT_DIR/arm"
tar -xzf "$DOWNLOAD_DIR/$X64_ARCHIVE" --strip-components=1 -C "$OUTPUT_DIR/x64"
lipo -create "$OUTPUT_DIR/arm/oxipng" "$OUTPUT_DIR/x64/oxipng" -output "$stage/oxipng"
cp "$OUTPUT_DIR/arm/LICENSE" "$stage/ThirdPartyLicenses/Oxipng/OXIPNG-LICENSE.txt"
lipo -archs "$stage/oxipng" | grep -q arm64
lipo -archs "$stage/oxipng" | grep -q x86_64
"$stage/oxipng" --version | grep -Fq "$VERSION"

echo "Building liboxipng.dylib (C FFI)..."
mkdir -p "$WORK_DIR/target"
export CARGO_TARGET_DIR="$WORK_DIR/target"
for target in "${TARGETS[@]}"; do
  rustup target add "$target"
  cargo build --release --manifest-path "$FFI_DIR/Cargo.toml" --target "$target"
done

lipo -create \
  "$CARGO_TARGET_DIR/aarch64-apple-darwin/release/liboxipng.dylib" \
  "$CARGO_TARGET_DIR/x86_64-apple-darwin/release/liboxipng.dylib" \
  -output "$stage/liboxipng.dylib"
install_name_tool -id '@rpath/liboxipng.dylib' "$stage/liboxipng.dylib"
lipo -archs "$stage/liboxipng.dylib" | grep -q arm64
lipo -archs "$stage/liboxipng.dylib" | grep -q x86_64
# Refuse accidental Homebrew /opt linkage in the FFI dylib.
if otool -L "$stage/liboxipng.dylib" | grep -E '(/opt/homebrew/|/usr/local/|/opt/local/)'; then
  echo 'liboxipng.dylib links unexpected non-system dylibs' >&2
  exit 1
fi
nm -gU "$stage/liboxipng.dylib" | grep -q ' _oxipng_optimize_file$'
nm -gU "$stage/liboxipng.dylib" | grep -q ' _oxipng_optimize_memory$'
nm -gU "$stage/liboxipng.dylib" | grep -q ' _oxipng_version$'

cp "$FFI_DIR/include/oxipng.h" "$stage/native-headers/oxipng-$VERSION/oxipng.h"
cat > "$stage/native-headers/versions.env" <<EOF
OXIPNG_VERSION=$VERSION
EOF
test -f "$stage/native-headers/oxipng-$VERSION/oxipng.h"

tar -C "$stage" -czf "$OUTPUT_DIR/oxipng-macos-universal.tar.gz" .

verify="$OUTPUT_DIR/verify"
rm -rf "$verify"
mkdir -p "$verify"
tar -xzf "$OUTPUT_DIR/oxipng-macos-universal.tar.gz" -C "$verify"
test -x "$verify/oxipng"
test -f "$verify/liboxipng.dylib"
test -f "$verify/native-headers/versions.env"
test -f "$verify/native-headers/oxipng-$VERSION/oxipng.h"
test -f "$verify/ThirdPartyLicenses/Oxipng/OXIPNG-LICENSE.txt"
echo "✓ oxipng macOS universal bundle (CLI + liboxipng + headers)"
