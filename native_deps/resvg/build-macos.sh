#!/usr/bin/env bash
# Builds the resvg CLI 0.47.0 as a self-contained macOS universal executable.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="${RESVG_VERSION:-0.47.0}"
WORK_DIR="${WORK_DIR:-$SCRIPT_DIR/work}"
OUTPUT_DIR="${OUTPUT_DIR:-$SCRIPT_DIR/dist}"
TARGETS=(aarch64-apple-darwin x86_64-apple-darwin)

command -v cargo >/dev/null || { echo 'Rust cargo is required.' >&2; exit 1; }
command -v rustup >/dev/null || { echo 'rustup is required.' >&2; exit 1; }
command -v lipo >/dev/null || { echo 'Xcode lipo is required.' >&2; exit 1; }

mkdir -p "$WORK_DIR" "$OUTPUT_DIR"
for target in "${TARGETS[@]}"; do
  rustup target add "$target"
  cargo install resvg --version "$VERSION" --locked --target "$target" --root "$WORK_DIR/$target"
done

output="$OUTPUT_DIR/resvg-macos-universal"
lipo -create "$WORK_DIR/aarch64-apple-darwin/bin/resvg" "$WORK_DIR/x86_64-apple-darwin/bin/resvg" -output "$output"
chmod +x "$output"
lipo "$output" -verify_arch arm64 x86_64
"$output" --version | grep -Fx "$VERSION"
otool -L "$output" | grep -E '(/opt/homebrew/|/usr/local/|/opt/local/)' && { echo 'Unexpected non-system dylib.' >&2; exit 1; } || true
shasum -a 256 "$output" > "$output.sha256"
