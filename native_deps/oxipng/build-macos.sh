#!/usr/bin/env bash
# Packages Oxipng 10.2.0 for macOS:
#   - C FFI library (liboxipng.dylib) + public header under native-headers/
#   - Third-party license text
# App runtime is FFI-only; the upstream CLI binary is not shipped.
set -euo pipefail

VERSION=10.2.0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="$SCRIPT_DIR/dist"
FFI_DIR="$SCRIPT_DIR/ffi"
WORK_DIR="$SCRIPT_DIR/work/ffi"
LICENSE_FILE="$SCRIPT_DIR/LICENSE"
TARGETS=(aarch64-apple-darwin x86_64-apple-darwin)
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-11.0}"
# Keep debug information through lipo so the companion dSYM contains usable
# source locations. The separate symbol archive is never shipped in the App.
export CARGO_PROFILE_RELEASE_DEBUG=1
export CARGO_PROFILE_RELEASE_STRIP=none

# Homebrew may leave an x86_64 cargo first in PATH on Apple Silicon. Prefer a
# working rustup toolchain when it is already installed for the current user.
if ! cargo --version >/dev/null 2>&1 && [[ -x "$HOME/.cargo/bin/cargo" ]]; then
  export PATH="$HOME/.cargo/bin:$PATH"
fi

command -v cargo >/dev/null || { echo 'Rust cargo is required to build liboxipng.' >&2; exit 1; }
command -v rustup >/dev/null || { echo 'rustup is required to build liboxipng.' >&2; exit 1; }
command -v lipo >/dev/null || { echo 'Xcode lipo is required.' >&2; exit 1; }
command -v install_name_tool >/dev/null || { echo 'install_name_tool is required.' >&2; exit 1; }
test -s "$LICENSE_FILE" || { echo "Missing vendored Oxipng LICENSE at $LICENSE_FILE" >&2; exit 1; }

stage="$OUTPUT_DIR/oxipng-macos-universal"
rm -rf "$OUTPUT_DIR"
mkdir -p "$stage/ThirdPartyLicenses/Oxipng" \
  "$stage/native-headers/oxipng-$VERSION" \
  "$WORK_DIR"

cp "$LICENSE_FILE" "$stage/ThirdPartyLicenses/Oxipng/OXIPNG-LICENSE.txt"
test -s "$stage/ThirdPartyLicenses/Oxipng/OXIPNG-LICENSE.txt"

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
"$SCRIPT_DIR/../macos-symbols.sh" "$OUTPUT_DIR/oxipng-macos-universal.symbols.tar.gz" \
  'Contents/Resources/liboxipng.dylib'="$stage/liboxipng.dylib"

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
test ! -e "$verify/oxipng"
test -f "$verify/liboxipng.dylib"
test -f "$verify/native-headers/versions.env"
test -f "$verify/native-headers/oxipng-$VERSION/oxipng.h"
test -f "$verify/ThirdPartyLicenses/Oxipng/OXIPNG-LICENSE.txt"
echo "✓ oxipng macOS universal bundle (liboxipng + headers)"
