#!/usr/bin/env bash
# Creates the exact-source archive required for a shipped LGPL FFmpeg binary.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$ROOT_DIR/../.." && pwd)"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/dist}"
WORK_DIR="${WORK_DIR:-$ROOT_DIR/work/source-package}"
PLATFORM="${PLATFORM:-macos}"
RELEASE_ID="${RELEASE_ID:-ffmpeg-${PLATFORM}-8.0.1-xfilesuite.2}"
if [ "$PLATFORM" = windows ]; then
  DEFAULT_FFMPEG_BINARY="$ROOT_DIR/dist-windows/ffmpeg-${FFMPEG_VERSION:-8.0.1}-windows-x64/ffmpeg.exe"
  BUILD_SCRIPT="$ROOT_DIR/build-windows.sh"
  ARCHITECTURES="x86_64"
else
  DEFAULT_FFMPEG_BINARY="$(find "$ROOT_DIR/dist" -path '*/bin/ffmpeg' -print -quit)"
  BUILD_SCRIPT="$ROOT_DIR/build.sh"
  ARCHITECTURES="arm64 and x86_64 (universal binary)"
fi
FFMPEG_BINARY="${FFMPEG_BINARY:-$DEFAULT_FFMPEG_BINARY}"

FFMPEG_VERSION="${FFMPEG_VERSION:-8.0.1}"
LAME_VERSION=3.100
OGG_VERSION=1.3.5
VORBIS_VERSION=1.3.7
VPX_VERSION=1.15.2
WEBP_VERSION=1.6.0
OPUS_VERSION=1.5.2

ARCHIVE_NAME="xfilesuite-${RELEASE_ID}-source.tar.gz"
STAGE_DIR="$WORK_DIR/$RELEASE_ID"
DOWNLOAD_DIR="$WORK_DIR/downloads"

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required tool: $1" >&2
    exit 1
  }
}

need curl
need tar
if ! command -v shasum >/dev/null 2>&1; then
  shasum() { while [ "$1" = "-a" ]; do shift; shift; done; sha256sum "$@"; }
fi

fetch() {
  local url="$1"
  local file="$2"
  if [[ ! -f "$DOWNLOAD_DIR/$file" ]]; then
    curl -fL --retry 3 --retry-delay 1 -o "$DOWNLOAD_DIR/$file" "$url"
  fi
}

copy_license() {
  local source_dir="$1"
  local destination="$2"
  for candidate in COPYING COPYING.LGPLv2.1 LICENSE LICENSE.txt; do
    if [[ -f "$source_dir/$candidate" ]]; then
      cp "$source_dir/$candidate" "$destination"
      return 0
    fi
  done
  echo "No license file found in $source_dir" >&2
  exit 1
}

rm -rf "$STAGE_DIR"
mkdir -p "$DOWNLOAD_DIR" "$STAGE_DIR/sources" "$STAGE_DIR/licenses" "$STAGE_DIR/patches"

fetch "https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz" "ffmpeg-${FFMPEG_VERSION}.tar.xz"
fetch "https://sourceforge.net/projects/lame/files/lame/${LAME_VERSION}/lame-${LAME_VERSION}.tar.gz/download" "lame-${LAME_VERSION}.tar.gz"
fetch "https://downloads.xiph.org/releases/ogg/libogg-${OGG_VERSION}.tar.xz" "libogg-${OGG_VERSION}.tar.xz"
fetch "https://downloads.xiph.org/releases/vorbis/libvorbis-${VORBIS_VERSION}.tar.xz" "libvorbis-${VORBIS_VERSION}.tar.xz"
fetch "https://codeload.github.com/webmproject/libvpx/tar.gz/refs/tags/v${VPX_VERSION}" "libvpx-${VPX_VERSION}.tar.gz"
fetch "https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-${WEBP_VERSION}.tar.gz" "libwebp-${WEBP_VERSION}.tar.gz"
fetch "https://codeload.github.com/xiph/opus/tar.gz/refs/tags/v${OPUS_VERSION}" "opus-${OPUS_VERSION}.tar.gz"

tar -xf "$DOWNLOAD_DIR/ffmpeg-${FFMPEG_VERSION}.tar.xz" -C "$STAGE_DIR/sources"
tar -xzf "$DOWNLOAD_DIR/lame-${LAME_VERSION}.tar.gz" -C "$STAGE_DIR/sources"
tar -xf "$DOWNLOAD_DIR/libogg-${OGG_VERSION}.tar.xz" -C "$STAGE_DIR/sources"
tar -xf "$DOWNLOAD_DIR/libvorbis-${VORBIS_VERSION}.tar.xz" -C "$STAGE_DIR/sources"
mkdir -p "$STAGE_DIR/sources/libvpx-${VPX_VERSION}"
tar -xzf "$DOWNLOAD_DIR/libvpx-${VPX_VERSION}.tar.gz" --strip-components=1 -C "$STAGE_DIR/sources/libvpx-${VPX_VERSION}"
tar -xzf "$DOWNLOAD_DIR/libwebp-${WEBP_VERSION}.tar.gz" -C "$STAGE_DIR/sources"
mkdir -p "$STAGE_DIR/sources/opus-${OPUS_VERSION}"
tar -xzf "$DOWNLOAD_DIR/opus-${OPUS_VERSION}.tar.gz" --strip-components=1 -C "$STAGE_DIR/sources/opus-${OPUS_VERSION}"

# This is the only source-tree adjustment made by build.sh. Record the exact
# patch against the extracted upstream source in every compliance archive.
VORBIS_CONFIGURE="$STAGE_DIR/sources/libvorbis-${VORBIS_VERSION}/configure"
cp "$VORBIS_CONFIGURE" "$WORK_DIR/libvorbis-configure.orig"
sed -i.bak 's/-force_cpusubtype_ALL//g' "$VORBIS_CONFIGURE"
rm -f "$VORBIS_CONFIGURE.bak"
diff -u "$WORK_DIR/libvorbis-configure.orig" "$VORBIS_CONFIGURE" \
  > "$STAGE_DIR/patches/libvorbis-configure-macos-xcode.patch" || true
cp "$BUILD_SCRIPT" "$STAGE_DIR/build.sh"
chmod +x "$STAGE_DIR/build.sh"

copy_license "$STAGE_DIR/sources/ffmpeg-${FFMPEG_VERSION}" "$STAGE_DIR/licenses/FFmpeg-LGPL-2.1.txt"
copy_license "$STAGE_DIR/sources/lame-${LAME_VERSION}" "$STAGE_DIR/licenses/LAME-LGPL.txt"
copy_license "$STAGE_DIR/sources/libogg-${OGG_VERSION}" "$STAGE_DIR/licenses/libogg-BSD.txt"
copy_license "$STAGE_DIR/sources/libvorbis-${VORBIS_VERSION}" "$STAGE_DIR/licenses/libvorbis-BSD.txt"
copy_license "$STAGE_DIR/sources/libvpx-${VPX_VERSION}" "$STAGE_DIR/licenses/libvpx-BSD.txt"
copy_license "$STAGE_DIR/sources/libwebp-${WEBP_VERSION}" "$STAGE_DIR/licenses/libwebp-BSD-3-Clause.txt"
copy_license "$STAGE_DIR/sources/opus-${OPUS_VERSION}" "$STAGE_DIR/licenses/libopus-BSD-3-Clause.txt"

cat > "$STAGE_DIR/SOURCE-URLS.txt" <<EOF
FFmpeg ${FFMPEG_VERSION}
https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz
LAME ${LAME_VERSION}
https://sourceforge.net/projects/lame/files/lame/${LAME_VERSION}/lame-${LAME_VERSION}.tar.gz/download
libogg ${OGG_VERSION}
https://downloads.xiph.org/releases/ogg/libogg-${OGG_VERSION}.tar.xz
libvorbis ${VORBIS_VERSION}
https://downloads.xiph.org/releases/vorbis/libvorbis-${VORBIS_VERSION}.tar.xz
libvpx ${VPX_VERSION}
https://codeload.github.com/webmproject/libvpx/tar.gz/refs/tags/v${VPX_VERSION}
libwebp ${WEBP_VERSION}
https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-${WEBP_VERSION}.tar.gz
libopus ${OPUS_VERSION}
https://codeload.github.com/xiph/opus/tar.gz/refs/tags/v${OPUS_VERSION}
EOF

if [[ -f "$FFMPEG_BINARY" ]]; then
  BINARY_SHA256="$(shasum -a 256 "$FFMPEG_BINARY" | awk '{print $1}')"
else
  BINARY_SHA256="NOT AVAILABLE: set FFMPEG_BINARY to the distributed ffmpeg executable"
fi

cat > "$STAGE_DIR/BUILDINFO.md" <<EOF
# XFileSuite ${PLATFORM} FFmpeg source correspondence record

- Compliance release: ${RELEASE_ID}
- Shipped FFmpeg version: ${FFMPEG_VERSION}
- Shipped binary SHA-256: ${BINARY_SHA256}
- Architectures: ${ARCHITECTURES}

## Components

| Component | Version | License |
| --- | --- | --- |
| FFmpeg | ${FFMPEG_VERSION} | LGPL-2.1-or-later |
| LAME | ${LAME_VERSION} | LGPL-2.0-or-later |
| libogg | ${OGG_VERSION} | BSD-style |
| libvorbis | ${VORBIS_VERSION} | BSD-style |
| libvpx | ${VPX_VERSION} | BSD-style |
| libwebp | ${WEBP_VERSION} | BSD-3-Clause |
| libopus | ${OPUS_VERSION} | BSD-3-Clause |

## Build and modification information

build.sh is the build script used for this binary family. It configures FFmpeg with
--disable-gpl --disable-nonfree --disable-version3 and statically links the listed
libraries into the standalone FFmpeg executable. No FFmpeg source files were modified.

For macOS, the only source-tree adjustment is documented in
patches/libvorbis-configure-macos-xcode.patch: it removes the obsolete
-force_cpusubtype_ALL flag from libvorbis' configure script for modern Xcode.

Run ./build.sh with the toolchain documented in the script to rebuild.
EOF

cat > "$STAGE_DIR/NOTICE.md" <<'EOF'
# Third-party notices

This archive provides the corresponding source and build material for the FFmpeg
executable distributed with XFileSuite for macOS. FFmpeg is licensed under GNU
Lesser General Public License version 2.1 or later. LAME is LGPL-licensed. The
remaining bundled libraries have BSD-style licenses; their license texts are in
the `licenses/` directory. XFileSuite does not claim ownership of these components.
EOF

(
  cd "$STAGE_DIR"
  while IFS= read -r -d '' file; do
    shasum -a 256 "$file"
  done < <(find . -type f -print0 | sort -z) > SHA256SUMS
)
mkdir -p "$OUTPUT_DIR"
tar -czf "$OUTPUT_DIR/$ARCHIVE_NAME" -C "$WORK_DIR" "$RELEASE_ID"
shasum -a 256 "$OUTPUT_DIR/$ARCHIVE_NAME" > "$OUTPUT_DIR/$ARCHIVE_NAME.sha256"

echo "Created: $OUTPUT_DIR/$ARCHIVE_NAME"
echo "Created: $OUTPUT_DIR/$ARCHIVE_NAME.sha256"
