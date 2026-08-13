#!/usr/bin/env bash
# Creates the public, corresponding-source archive for the shipped ImageMagick runtime.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="${IMAGEMAGICK_VERSION:-7.1.2-29}"
PLATFORM="${PLATFORM:-macos}"
RELEASE_ID="${RELEASE_ID:-imagemagick-${PLATFORM}-${VERSION}-xfilesuite.1}"
if [ "$PLATFORM" = windows ]; then
  DEFAULT_BINARY="$ROOT/native_deps/imagemagick/dist-windows/imagemagick-windows-x64/magick.exe"
else
  DEFAULT_BINARY="$SCRIPT_DIR/dist/imagemagick-macos-universal/magick"
fi
BINARY="${IMAGEMAGICK_BINARY:-$DEFAULT_BINARY}"
OUT_DIR="${OUT_DIR:-$ROOT/native_deps/imagemagick/dist}"
WORK_DIR="${WORK_DIR:-$ROOT/native_deps/imagemagick/work/source-${VERSION}}"
SOURCE_REPOSITORY="https://github.com/ImageMagick/ImageMagick.git"
LOCAL_SOURCE_DIR="${IMAGEMAGICK_LOCAL_SOURCE_DIR:-}"
BUILT_SOURCES_DIR="${IMAGEMAGICK_BUILT_SOURCES_DIR:-$ROOT/native_deps/imagemagick/work/sources}"

if ! command -v shasum >/dev/null 2>&1; then
  shasum() { while [ "$1" = "-a" ]; do shift; shift; done; sha256sum "$@"; }
fi

test -x "$BINARY"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR/source" "$WORK_DIR/sources" "$WORK_DIR/licenses" "$OUT_DIR"

if [ -n "$LOCAL_SOURCE_DIR" ]; then
  git clone --no-local "$LOCAL_SOURCE_DIR" "$WORK_DIR/source/ImageMagick-${VERSION}"
  git -C "$WORK_DIR/source/ImageMagick-${VERSION}" checkout --detach "$VERSION"
else
  git clone --depth 1 --branch "$VERSION" "$SOURCE_REPOSITORY" "$WORK_DIR/source/ImageMagick-${VERSION}"
fi
SOURCE_DIR="$WORK_DIR/source/ImageMagick-${VERSION}"

cp "$SOURCE_DIR/LICENSE" "$WORK_DIR/licenses/IMAGEMAGICK-LICENSE.txt"
if [ -f "$SOURCE_DIR/NOTICE" ]; then
  cp "$SOURCE_DIR/NOTICE" "$WORK_DIR/licenses/IMAGEMAGICK-NOTICE.txt"
fi

# The macOS and Windows runtimes dynamically ship these delegate libraries. The normal
# publish flow runs build-macos.sh first, so include their exact source and
# licenses in the public archive.
if [ "$PLATFORM" = macos ] || [ "$PLATFORM" = windows ]; then
  components=(libraw mozjpeg libpng libwebp libtiff giflib)
  for component in "${components[@]}"; do
    test -d "$BUILT_SOURCES_DIR/$component" || {
      echo "Missing built dependency source: $BUILT_SOURCES_DIR/$component" >&2
      echo "Run build-macos.sh before package-source.sh." >&2
      exit 1
    }
    cp -R "$BUILT_SOURCES_DIR/$component" "$WORK_DIR/sources/$component"
  done
  find "$BUILT_SOURCES_DIR/libraw" -maxdepth 1 -type f \( -iname 'license*' -o -iname 'copying*' \) -print0 | \
    while IFS= read -r -d '' license; do cp "$license" "$WORK_DIR/licenses/LIBRAW-$(basename "$license")"; done
  cp "$BUILT_SOURCES_DIR/mozjpeg/LICENSE.md" "$WORK_DIR/licenses/MOZJPEG-LICENSE.md"
  cp "$BUILT_SOURCES_DIR/libpng/LICENSE" "$WORK_DIR/licenses/LIBPNG-LICENSE.txt"
  cp "$BUILT_SOURCES_DIR/libwebp/COPYING" "$WORK_DIR/licenses/LIBWEBP-LICENSE.txt"
  cp "$BUILT_SOURCES_DIR/libtiff/LICENSE.md" "$WORK_DIR/licenses/LIBTIFF-LICENSE.md"
  cp "$BUILT_SOURCES_DIR/giflib/COPYING" "$WORK_DIR/licenses/GIFLIB-LICENSE.txt"
fi
if [ "$PLATFORM" = windows ]; then
  cp "$SCRIPT_DIR/build-windows.sh" "$WORK_DIR/build-windows.sh"
else
  cp "$SCRIPT_DIR/build-macos.sh" "$WORK_DIR/build-macos.sh"
fi
mkdir -p "$WORK_DIR/patches"
cp "$SCRIPT_DIR/patches/imagemagick-mozjpeg-options.patch" "$WORK_DIR/patches/"

binary_sha="$(shasum -a 256 "$BINARY" | awk '{print $1}')"
source_commit="$(git -C "$SOURCE_DIR" rev-parse HEAD)"
"$BINARY" -version > "$WORK_DIR/MAGICK-VERSION.txt"
if [ "$PLATFORM" = windows ]; then
  runtime_archive="$SCRIPT_DIR/dist-windows/imagemagick-${VERSION}-windows-x64.zip"
else
  runtime_archive="$SCRIPT_DIR/dist/imagemagick-macos-universal.tar.gz"
fi
test -f "$runtime_archive"

cat > "$WORK_DIR/BUILDINFO.md" <<EOF
# XFileSuite ${PLATFORM} ImageMagick source correspondence

- Release identifier: $RELEASE_ID
- Shipped binary: $BINARY
- Binary SHA-256: $binary_sha
- Runtime archive: $runtime_archive
- Source repository: $SOURCE_REPOSITORY
- Source tag: $VERSION
- Source commit: $source_commit

The distributed runtime's magick -version output is recorded in MAGICK-VERSION.txt.
For Windows, the release artifact is a source-built runtime directory, including
magick.exe, all DLLs and configuration files next to it.

ImageMagick is distributed under the ImageMagick License. The license and upstream
NOTICE are in licenses/. For macOS, the release artifact is a relocatable tar.gz
runtime directory containing magick, its dylibs and configuration files as
direct macOS Resources children, including ThirdPartyLicenses/ImageMagick. This
archive also includes the exact LibRaw source tree and license. The macOS and
Windows archives additionally include MozJPEG, libpng, libwebp,
libtiff and giflib, which are statically linked into MagickCore.
XFileSuite is proprietary software and does not claim ownership of any of these
components.
EOF

cat > "$WORK_DIR/README.md" <<EOF
# ImageMagick corresponding source for XFileSuite

This archive records the ImageMagick $VERSION source and metadata corresponding to
the ImageMagick runtime shipped with XFileSuite for $PLATFORM.

ImageMagick's license does not require source publication when redistributing its
binary. XFileSuite publishes this archive so that native dependencies are auditable
in one public GitHub location.
EOF

(
  cd "$WORK_DIR"
  # SHA256SUMS is explicitly excluded from find.
  # shellcheck disable=SC2094
  while IFS= read -r -d '' file; do
    shasum -a 256 "$file"
  done < <(find . -type f ! -name SHA256SUMS -print0 | sort -z) > SHA256SUMS
)
tar -czf "$OUT_DIR/xfilesuite-${RELEASE_ID}-source.tar.gz" -C "$(dirname "$WORK_DIR")" "$(basename "$WORK_DIR")"
(cd "$OUT_DIR" && shasum -a 256 "xfilesuite-${RELEASE_ID}-source.tar.gz" > "xfilesuite-${RELEASE_ID}-source.tar.gz.sha256")
echo "$OUT_DIR/xfilesuite-${RELEASE_ID}-source.tar.gz"
