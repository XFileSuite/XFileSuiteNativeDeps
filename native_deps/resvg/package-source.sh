#!/usr/bin/env bash
# Creates a source, dependency-vendor and license archive for the shipped resvg CLI.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
VERSION="${RESVG_VERSION:-0.47.0}"
RELEASE_ID="${RELEASE_ID:-resvg-macos-${VERSION}-xfilesuite.1}"
BINARY="${RESVG_BINARY:-$SCRIPT_DIR/dist/resvg-macos-universal}"
OUT_DIR="${OUT_DIR:-$SCRIPT_DIR/dist}"
WORK_DIR="${WORK_DIR:-$SCRIPT_DIR/work/source-$VERSION}"
REPOSITORY="https://github.com/linebender/resvg.git"

if ! command -v shasum >/dev/null 2>&1; then
  shasum() { while [ "$1" = "-a" ]; do shift; shift; done; sha256sum "$@"; }
fi

test -x "$BINARY"
command -v cargo >/dev/null
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR/source" "$WORK_DIR/licenses" "$OUT_DIR"
git clone --depth 1 --branch "v$VERSION" "$REPOSITORY" "$WORK_DIR/source/resvg-$VERSION"
SOURCE="$WORK_DIR/source/resvg-$VERSION"
commit="$(git -C "$SOURCE" rev-parse HEAD)"
(cd "$SOURCE" && cargo vendor --locked vendor > .cargo-vendor-config.toml)
rm -rf "$SOURCE/.git"
cp "$SOURCE/LICENSE-APACHE" "$WORK_DIR/licenses/RESVG-APACHE-2.0.txt"
cp "$SOURCE/LICENSE-MIT" "$WORK_DIR/licenses/RESVG-MIT.txt"
cp "$SCRIPT_DIR/build-macos.sh" "$WORK_DIR/build-macos.sh"

sha="$(shasum -a 256 "$BINARY" | awk '{print $1}')"
cat > "$WORK_DIR/BUILDINFO.md" <<EOF
# XFileSuite resvg source correspondence

- Version: $VERSION
- Source repository: $REPOSITORY
- Source commit: $commit
- Distributed binary SHA-256: $sha
- Architectures: arm64 and x86_64
- License: Apache-2.0 OR MIT (not MPL-2.0)

This archive contains the exact tagged resvg source, Cargo.lock, vendored Rust
dependencies, license texts and the macOS universal build script. XFileSuite has
not modified resvg source files.
EOF
(cd "$WORK_DIR" && find . -type f -print0 | sort -z | xargs -0 shasum -a 256 > SHA256SUMS)
archive="$OUT_DIR/xfilesuite-$RELEASE_ID-source.tar.gz"
tar -czf "$archive" -C "$(dirname "$WORK_DIR")" "$(basename "$WORK_DIR")"
shasum -a 256 "$archive" > "$archive.sha256"
