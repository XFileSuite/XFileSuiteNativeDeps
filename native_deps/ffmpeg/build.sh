#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────
# FFmpeg LGPL Universal Binary Builder for XFileSuite (macOS)
#
# Based on HashNuke/ffmpeg-legal-shippable, enhanced with:
#   - libmp3lame  (LGPL)        — MP3 encoding
#   - libogg      (BSD)         — OGG container
#   - libvorbis   (BSD)         — Vorbis encoding
#   - libvpx      (BSD)         — VP8/VP9 encoding for WebM
#   - libwebp     (BSD)         — animated WebP encoding
# All additions are LGPL-compatible (no GPL, no nonfree).
#
# Output:
#   dist/ffmpeg-<version>-<stamp>-macos-universal/bin/ffmpeg
#   dist/ffmpeg-<version>-<stamp>-macos-universal/bin/ffprobe
#   dist/ffmpeg-<version>-<stamp>-macos-universal.tar.gz
#
# After build, automatically copies binaries to:
#   ../macos/Runner/Resources/ffmpeg
#   ../macos/Runner/Resources/ffprobe  (optional)
# ─────────────────────────────────────────────────────────────────

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${WORK_DIR:-$ROOT_DIR/work}"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist}"

# Project root (two levels above native_deps/ffmpeg/)
PROJECT_ROOT="$(cd "$ROOT_DIR/../.." && pwd)"
MACOS_RESOURCES="$PROJECT_ROOT/macos/Runner/Resources"

MIN_MACOS="${MIN_MACOS:-11.0}"

FFMPEG_VERSION="${FFMPEG_VERSION:-8.0.1}"
FFMPEG_TARBALL_URL="${FFMPEG_TARBALL_URL:-https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz}"
FFMPEG_TARBALL_PATH="$WORK_DIR/ffmpeg-${FFMPEG_VERSION}.tar.xz"
FFMPEG_SRC_DIR="$WORK_DIR/ffmpeg-${FFMPEG_VERSION}"

LAME_VERSION="${LAME_VERSION:-3.100}"
LAME_TARBALL_URL="https://sourceforge.net/projects/lame/files/lame/${LAME_VERSION}/lame-${LAME_VERSION}.tar.gz/download"
LAME_TARBALL_PATH="$WORK_DIR/lame-${LAME_VERSION}.tar.gz"
LAME_SRC_DIR="$WORK_DIR/lame-${LAME_VERSION}"

OGG_VERSION="${OGG_VERSION:-1.3.5}"
OGG_TARBALL_URL="https://downloads.xiph.org/releases/ogg/libogg-${OGG_VERSION}.tar.xz"
OGG_TARBALL_PATH="$WORK_DIR/libogg-${OGG_VERSION}.tar.xz"
OGG_SRC_DIR="$WORK_DIR/libogg-${OGG_VERSION}"

VORBIS_VERSION="${VORBIS_VERSION:-1.3.7}"
VORBIS_TARBALL_URL="https://downloads.xiph.org/releases/vorbis/libvorbis-${VORBIS_VERSION}.tar.xz"
VORBIS_TARBALL_PATH="$WORK_DIR/libvorbis-${VORBIS_VERSION}.tar.xz"
VORBIS_SRC_DIR="$WORK_DIR/libvorbis-${VORBIS_VERSION}"

VPX_VERSION="${VPX_VERSION:-1.15.2}"
VPX_TARBALL_URL="https://chromium.googlesource.com/webm/libvpx/+archive/v${VPX_VERSION}.tar.gz"
VPX_TARBALL_PATH="$WORK_DIR/libvpx-${VPX_VERSION}.tar.gz"
VPX_SRC_DIR="$WORK_DIR/libvpx-${VPX_VERSION}"

WEBP_VERSION="${WEBP_VERSION:-1.6.0}"
WEBP_TARBALL_URL="https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-${WEBP_VERSION}.tar.gz"
WEBP_TARBALL_PATH="$WORK_DIR/libwebp-${WEBP_VERSION}.tar.gz"
WEBP_SRC_DIR="$WORK_DIR/libwebp-${WEBP_VERSION}"

BUILD_STAMP="${BUILD_STAMP:-$(date -u +%Y%m%d%H%M)}"
BUILD_ID="${BUILD_ID:-}"

JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"

mkdir -p "$WORK_DIR" "$DIST_DIR"

need() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing required tool: $1" >&2; exit 1; }
}

need make
need curl
need tar
need xcrun
need lipo
need otool
need cmake

SDK="$(xcrun --sdk macosx --show-sdk-path)"
CC="$(xcrun --sdk macosx -f clang)"
CXX="$(xcrun --sdk macosx -f clang++)"

OUT_BASENAME() {
  local base="ffmpeg-${FFMPEG_VERSION}"
  if [[ -n "${BUILD_ID}" ]]; then
    base="${base}-b${BUILD_ID}"
  fi
  base="${base}-${BUILD_STAMP}-macos-universal"
  echo "$base"
}

assert_no_third_party_dylibs() {
  local BIN="$1"
  local BAD
  BAD="$(otool -L "$BIN" | grep -E '(/opt/homebrew/|/usr/local/|/opt/local/)' || true)"
  if [[ -n "$BAD" ]]; then
    echo "ERROR: $BIN links against non-system libraries:" >&2
    echo "$BAD" >&2
    exit 1
  fi
}

package_release() {
  local OUT_DIR="$1"
  local BASENAME
  BASENAME="$(basename "$OUT_DIR")"
  local TARBALL="$DIST_DIR/${BASENAME}.tar.gz"
  local STAGE="$WORK_DIR/stage-${BASENAME}"

  echo ""
  echo "==> Packaging release tarball"
  echo ""

  rm -f "$TARBALL" "$TARBALL.sha256"
  rm -rf "$STAGE"
  mkdir -p "$STAGE"
  cp -f "$OUT_DIR/bin/ffmpeg" "$STAGE/ffmpeg"
  cp -f "$OUT_DIR/bin/ffprobe" "$STAGE/ffprobe"
  tar -czf "$TARBALL" -C "$STAGE" ffmpeg ffprobe
  rm -rf "$STAGE"

  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$TARBALL" > "$TARBALL.sha256"
  fi

  echo "Tarball: $TARBALL"
  if [[ -f "$TARBALL.sha256" ]]; then
    echo "SHA256:  $TARBALL.sha256"
  fi
}

install_to_project() {
  local OUT_DIR="$1"

  echo ""
  echo "==> Installing binaries to project"
  echo "    Target: $MACOS_RESOURCES/"
  echo ""

  if [[ ! -d "$MACOS_RESOURCES" ]]; then
    echo "  WARNING: $MACOS_RESOURCES does not exist, skipping install."
    return 0
  fi

  cp -f "$OUT_DIR/bin/ffmpeg" "$MACOS_RESOURCES/ffmpeg"
  cp -f "$OUT_DIR/bin/ffprobe" "$MACOS_RESOURCES/ffprobe"
  chmod +x "$MACOS_RESOURCES/ffmpeg" "$MACOS_RESOURCES/ffprobe"

  # Remove quarantine attribute if present
  if command -v xattr >/dev/null 2>&1; then
    xattr -cr "$MACOS_RESOURCES/ffmpeg" 2>/dev/null || true
    xattr -cr "$MACOS_RESOURCES/ffprobe" 2>/dev/null || true
  fi

  echo "  ✓ ffmpeg  -> $MACOS_RESOURCES/ffmpeg"
  echo "  ✓ ffprobe -> $MACOS_RESOURCES/ffprobe"
}

# ── Fetch functions ──────────────────────────────────────────────

fetch_ffmpeg() {
  if [[ -d "$FFMPEG_SRC_DIR" && -f "$FFMPEG_SRC_DIR/configure" ]]; then
    echo "Using existing FFmpeg source: $FFMPEG_SRC_DIR"
    return 0
  fi
  rm -rf "$FFMPEG_SRC_DIR"
  if [[ ! -f "$FFMPEG_TARBALL_PATH" ]]; then
    echo "Downloading FFmpeg ${FFMPEG_VERSION}..."
    curl -fL --retry 3 --retry-delay 1 -o "$FFMPEG_TARBALL_PATH" "$FFMPEG_TARBALL_URL"
  else
    echo "Using cached tarball: $FFMPEG_TARBALL_PATH"
  fi
  echo "Extracting..."
  tar -xf "$FFMPEG_TARBALL_PATH" -C "$WORK_DIR"
}

fetch_lame() {
  if [[ -d "$LAME_SRC_DIR" && -f "$LAME_SRC_DIR/configure" ]]; then
    echo "Using existing LAME source: $LAME_SRC_DIR"
    return 0
  fi
  rm -rf "$LAME_SRC_DIR"
  if [[ ! -f "$LAME_TARBALL_PATH" ]]; then
    echo "Downloading LAME ${LAME_VERSION}..."
    curl -fL --retry 3 --retry-delay 1 -L -o "$LAME_TARBALL_PATH" "$LAME_TARBALL_URL"
  fi
  echo "Extracting LAME..."
  tar -xzf "$LAME_TARBALL_PATH" -C "$WORK_DIR"
}

fetch_ogg() {
  if [[ -d "$OGG_SRC_DIR" && -f "$OGG_SRC_DIR/configure" ]]; then
    echo "Using existing libogg source: $OGG_SRC_DIR"
    return 0
  fi
  rm -rf "$OGG_SRC_DIR"
  if [[ ! -f "$OGG_TARBALL_PATH" ]]; then
    echo "Downloading libogg ${OGG_VERSION}..."
    curl -fL --retry 3 --retry-delay 1 -o "$OGG_TARBALL_PATH" "$OGG_TARBALL_URL"
  fi
  echo "Extracting libogg..."
  tar -xf "$OGG_TARBALL_PATH" -C "$WORK_DIR"
}

fetch_vorbis() {
  if [[ -d "$VORBIS_SRC_DIR" && -f "$VORBIS_SRC_DIR/configure" ]]; then
    echo "Using existing libvorbis source: $VORBIS_SRC_DIR"
    return 0
  fi
  rm -rf "$VORBIS_SRC_DIR"
  if [[ ! -f "$VORBIS_TARBALL_PATH" ]]; then
    echo "Downloading libvorbis ${VORBIS_VERSION}..."
    curl -fL --retry 3 --retry-delay 1 -o "$VORBIS_TARBALL_PATH" "$VORBIS_TARBALL_URL"
  fi
  echo "Extracting libvorbis..."
  tar -xf "$VORBIS_TARBALL_PATH" -C "$WORK_DIR"
  # Patch out obsolete -force_cpusubtype_ALL that breaks on modern Xcode.
  # The corresponding source archive records this adjustment in patches/.
  sed -i '' 's/-force_cpusubtype_ALL//g' "$VORBIS_SRC_DIR/configure"
}

fetch_vpx() {
  if [[ -d "$VPX_SRC_DIR" && -f "$VPX_SRC_DIR/configure" ]]; then
    echo "Using existing libvpx source: $VPX_SRC_DIR"
    return 0
  fi
  rm -rf "$VPX_SRC_DIR"
  mkdir -p "$VPX_SRC_DIR"
  if [[ ! -f "$VPX_TARBALL_PATH" ]]; then
    echo "Downloading libvpx ${VPX_VERSION}..."
    curl -fL --retry 3 --retry-delay 1 -o "$VPX_TARBALL_PATH" "$VPX_TARBALL_URL"
  fi
  echo "Extracting libvpx..."
  tar -xzf "$VPX_TARBALL_PATH" -C "$VPX_SRC_DIR"
}

fetch_webp() {
  if [[ -d "$WEBP_SRC_DIR" && -f "$WEBP_SRC_DIR/CMakeLists.txt" ]]; then
    echo "Using existing libwebp source: $WEBP_SRC_DIR"
    return 0
  fi
  rm -rf "$WEBP_SRC_DIR"
  if [[ ! -f "$WEBP_TARBALL_PATH" ]]; then
    echo "Downloading libwebp ${WEBP_VERSION}..."
    curl -fL --retry 3 --retry-delay 1 -o "$WEBP_TARBALL_PATH" "$WEBP_TARBALL_URL"
  fi
  echo "Extracting libwebp..."
  tar -xzf "$WEBP_TARBALL_PATH" -C "$WORK_DIR"
}

# ── Per-arch build functions for each dependency ─────────────────

build_lame_arch() {
  local ARCH="$1"
  local PREFIX="$WORK_DIR/prefix-$ARCH"
  local BUILD_OUT="$WORK_DIR/build-lame-$ARCH"

  rm -rf "$BUILD_OUT"
  mkdir -p "$BUILD_OUT"

  export MACOSX_DEPLOYMENT_TARGET="$MIN_MACOS"
  export CC CXX SDKROOT="$SDK"

  local CFLAGS="-arch $ARCH -isysroot $SDK -mmacosx-version-min=$MIN_MACOS -O3"
  local LDFLAGS="-arch $ARCH -isysroot $SDK -mmacosx-version-min=$MIN_MACOS"

  echo ""
  echo "==> Building LAME for $ARCH"
  echo ""

  pushd "$BUILD_OUT" >/dev/null

  CC="$CC" CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS" \
    "$LAME_SRC_DIR/configure" \
    --prefix="$PREFIX" \
    --host="${ARCH/arm64/aarch64}-apple-darwin" \
    --disable-shared \
    --enable-static \
    --disable-frontend \
    --disable-debug \
    --disable-dependency-tracking

  make -j"$JOBS"
  make install

  popd >/dev/null
  echo "LAME built for $ARCH -> $PREFIX"
}

build_ogg_arch() {
  local ARCH="$1"
  local PREFIX="$WORK_DIR/prefix-$ARCH"
  local BUILD_OUT="$WORK_DIR/build-ogg-$ARCH"

  rm -rf "$BUILD_OUT"
  mkdir -p "$BUILD_OUT"

  export MACOSX_DEPLOYMENT_TARGET="$MIN_MACOS"
  export CC CXX SDKROOT="$SDK"

  local CFLAGS="-arch $ARCH -isysroot $SDK -mmacosx-version-min=$MIN_MACOS -O3"
  local LDFLAGS="-arch $ARCH -isysroot $SDK -mmacosx-version-min=$MIN_MACOS"

  echo ""
  echo "==> Building libogg for $ARCH"
  echo ""

  pushd "$BUILD_OUT" >/dev/null

  CC="$CC" CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS" \
    "$OGG_SRC_DIR/configure" \
    --prefix="$PREFIX" \
    --host="${ARCH/arm64/aarch64}-apple-darwin" \
    --disable-shared \
    --enable-static \
    --disable-debug \
    --disable-dependency-tracking

  make -j"$JOBS"
  make install

  popd >/dev/null
  echo "libogg built for $ARCH -> $PREFIX"
}

build_vorbis_arch() {
  local ARCH="$1"
  local PREFIX="$WORK_DIR/prefix-$ARCH"
  local BUILD_OUT="$WORK_DIR/build-vorbis-$ARCH"

  rm -rf "$BUILD_OUT"
  mkdir -p "$BUILD_OUT"

  export MACOSX_DEPLOYMENT_TARGET="$MIN_MACOS"
  export CC CXX SDKROOT="$SDK"

  local CFLAGS="-arch $ARCH -isysroot $SDK -mmacosx-version-min=$MIN_MACOS -O3 -I$PREFIX/include"
  local LDFLAGS="-arch $ARCH -isysroot $SDK -mmacosx-version-min=$MIN_MACOS -L$PREFIX/lib"

  echo ""
  echo "==> Building libvorbis for $ARCH"
  echo ""

  pushd "$BUILD_OUT" >/dev/null

  CC="$CC" CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS" \
    PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" \
    "$VORBIS_SRC_DIR/configure" \
    --prefix="$PREFIX" \
    --host="${ARCH/arm64/aarch64}-apple-darwin" \
    --disable-shared \
    --enable-static \
    --disable-debug \
    --disable-dependency-tracking \
    --disable-examples \
    --with-ogg="$PREFIX"

  make -j"$JOBS"
  make install

  popd >/dev/null
  echo "libvorbis built for $ARCH -> $PREFIX"
}

build_vpx_arch() {
  local ARCH="$1"
  local PREFIX="$WORK_DIR/prefix-$ARCH"
  local BUILD_OUT="$WORK_DIR/build-vpx-$ARCH"

  rm -rf "$BUILD_OUT"
  mkdir -p "$BUILD_OUT"

  export MACOSX_DEPLOYMENT_TARGET="$MIN_MACOS"
  export CC CXX SDKROOT="$SDK"

  local CFLAGS="-arch $ARCH -isysroot $SDK -mmacosx-version-min=$MIN_MACOS -O3"
  local LDFLAGS="-arch $ARCH -isysroot $SDK -mmacosx-version-min=$MIN_MACOS"

  echo ""
  echo "==> Building libvpx for $ARCH"
  echo ""

  pushd "$BUILD_OUT" >/dev/null

  local VPX_TARGET
  if [[ "$ARCH" == "arm64" ]]; then
    VPX_TARGET="arm64-darwin20-gcc"
  else
    VPX_TARGET="x86_64-darwin20-gcc"
  fi

  CC="$CC" CXX="$CXX" CFLAGS="$CFLAGS" CXXFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS" \
    "$VPX_SRC_DIR/configure" \
    --prefix="$PREFIX" \
    --target="$VPX_TARGET" \
    --disable-shared \
    --enable-static \
    --disable-debug \
    --disable-examples \
    --disable-tools \
    --disable-docs \
    --disable-unit-tests \
    --disable-decode-perf-tests \
    --disable-encode-perf-tests \
    --enable-vp8 \
    --enable-vp9 \
    --enable-runtime-cpu-detect

  make -j"$JOBS"
  make install

  popd >/dev/null
  echo "libvpx built for $ARCH -> $PREFIX"
}

build_webp_arch() {
  local ARCH="$1"
  local PREFIX="$WORK_DIR/prefix-$ARCH"
  local BUILD_OUT="$WORK_DIR/build-webp-$ARCH"
  rm -rf "$BUILD_OUT"
  echo "==> Building libwebp for $ARCH"
  cmake -S "$WEBP_SRC_DIR" -B "$BUILD_OUT" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$MIN_MACOS" \
    -DCMAKE_OSX_SYSROOT="$SDK" \
    -DBUILD_SHARED_LIBS=OFF \
    -DWEBP_BUILD_ANIM_UTILS=OFF -DWEBP_BUILD_CWEBP=OFF \
    -DWEBP_BUILD_DWEBP=OFF -DWEBP_BUILD_GIF2WEBP=OFF \
    -DWEBP_BUILD_IMG2WEBP=OFF -DWEBP_BUILD_VWEBP=OFF \
    -DWEBP_BUILD_WEBPMUX=OFF -DWEBP_BUILD_EXTRAS=OFF
  cmake --build "$BUILD_OUT" --parallel "$JOBS"
  cmake --install "$BUILD_OUT"
}

# ── FFmpeg build per arch ────────────────────────────────────────

build_one_arch() {
  local ARCH="$1"
  local PREFIX="$WORK_DIR/prefix-$ARCH"
  local BUILD_OUT="$WORK_DIR/build-$ARCH"
  local HOST_MACHINE
  HOST_MACHINE="$(uname -m)"

  rm -rf "$PREFIX" "$BUILD_OUT"
  mkdir -p "$PREFIX" "$BUILD_OUT"

  # Build all dependency libs into the same prefix
  build_lame_arch "$ARCH"
  build_ogg_arch "$ARCH"
  build_vorbis_arch "$ARCH"
  build_vpx_arch "$ARCH"
  build_webp_arch "$ARCH"

  export MACOSX_DEPLOYMENT_TARGET="$MIN_MACOS"
  export CC CXX SDKROOT="$SDK"
  export HOSTCC="$CC"
  export HOSTCFLAGS="-isysroot $SDK"
  export HOSTLDFLAGS="-isysroot $SDK"
  # Use real pkg-config but only look in our prefix to avoid pulling brew libs
  export PKG_CONFIG="$(command -v pkg-config || echo /usr/bin/pkg-config)"
  export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
  export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
  unset CPATH LIBRARY_PATH DYLD_LIBRARY_PATH

  local CFLAGS="-arch $ARCH -isysroot $SDK -mmacosx-version-min=$MIN_MACOS -O3"
  local LDFLAGS="-arch $ARCH -isysroot $SDK -mmacosx-version-min=$MIN_MACOS"

  # Point FFmpeg at all the static libs we just built
  local LIB_CFLAGS="-I$PREFIX/include"
  local LIB_LDFLAGS="-L$PREFIX/lib -lvorbisenc -lvorbis -logg -lvpx -lwebp -lsharpyuv -lmp3lame -lm"

  local CROSS_CONFIG=()
  if [[ "$ARCH" != "$HOST_MACHINE" ]]; then
    if [[ "$ARCH" == "arm64" ]]; then
      CROSS_CONFIG+=(--enable-cross-compile --arch=aarch64 --target-os=darwin)
    else
      CROSS_CONFIG+=(--enable-cross-compile --arch="$ARCH" --target-os=darwin)
    fi
  fi

  local EXTRA_CONFIG=()
  if [[ "$ARCH" == "x86_64" ]]; then
    if ! command -v nasm >/dev/null 2>&1 && ! command -v yasm >/dev/null 2>&1; then
      echo "Note: nasm/yasm not found; disabling x86 asm for the x86_64 build."
      EXTRA_CONFIG+=(--disable-x86asm)
    fi
  fi

  echo ""
  echo "==> Configuring FFmpeg for $ARCH (min macOS $MIN_MACOS)"
  echo ""

  pushd "$BUILD_OUT" >/dev/null

  "$FFMPEG_SRC_DIR/configure" \
    --prefix="$PREFIX" \
    --cc="$CC" \
    --extra-cflags="$CFLAGS $LIB_CFLAGS" \
    --extra-ldflags="$LDFLAGS $LIB_LDFLAGS" \
    ${CROSS_CONFIG[@]+"${CROSS_CONFIG[@]}"} \
    \
    --disable-debug \
    --disable-doc \
    \
    --disable-shared \
    --enable-static \
    --enable-pic \
    \
    --disable-autodetect \
    \
    --disable-gpl \
    --disable-nonfree \
    --disable-version3 \
    \
    --enable-libmp3lame \
    --enable-libvorbis \
    --enable-libvpx \
    --enable-libwebp \
    \
    --enable-videotoolbox \
    --enable-audiotoolbox \
    --enable-securetransport \
    \
    --enable-zlib \
    \
    --enable-ffmpeg \
    --enable-ffprobe \
    --disable-ffplay \
    \
    --enable-network \
    ${EXTRA_CONFIG[@]+"${EXTRA_CONFIG[@]}"}

  echo ""
  echo "==> Building FFmpeg for $ARCH"
  echo ""
  make -j"$JOBS"
  make install

  popd >/dev/null
}

# ── Universal binary creation ────────────────────────────────────

make_universal() {
  local OUT="$DIST_DIR/$(OUT_BASENAME)"
  {
    rm -rf "$OUT"
    mkdir -p "$OUT/bin"

    local FFMPEG_ARM="$WORK_DIR/prefix-arm64/bin/ffmpeg"
    local FFMPEG_X64="$WORK_DIR/prefix-x86_64/bin/ffmpeg"
    local FFPROBE_ARM="$WORK_DIR/prefix-arm64/bin/ffprobe"
    local FFPROBE_X64="$WORK_DIR/prefix-x86_64/bin/ffprobe"

    echo ""
    echo "==> Creating universal binaries"
    echo ""

    lipo -create "$FFMPEG_ARM" "$FFMPEG_X64" -output "$OUT/bin/ffmpeg"
    lipo -create "$FFPROBE_ARM" "$FFPROBE_X64" -output "$OUT/bin/ffprobe"

    chmod +x "$OUT/bin/ffmpeg" "$OUT/bin/ffprobe"

    if command -v strip >/dev/null 2>&1; then
      strip -x "$OUT/bin/ffmpeg" "$OUT/bin/ffprobe" || true
    fi

    echo ""
    echo "==> Verifying arch slices"
    file "$OUT/bin/ffmpeg"
    file "$OUT/bin/ffprobe"

    echo ""
    echo "==> Checking that we didn't accidentally link Homebrew/MacPorts dylibs"
    echo ""
    echo "ffmpeg deps:"
    otool -L "$OUT/bin/ffmpeg" | sed 's/^/  /'
    assert_no_third_party_dylibs "$OUT/bin/ffmpeg"
    echo ""
    echo "ffprobe deps:"
    otool -L "$OUT/bin/ffprobe" | sed 's/^/  /'
    assert_no_third_party_dylibs "$OUT/bin/ffprobe"

    echo ""
    echo "==> Printing build configuration (license flags sanity-check)"
    "$OUT/bin/ffmpeg" -buildconf | sed 's/^/  /'
    echo ""
    echo "==> Printing version"
    "$OUT/bin/ffmpeg" -version | head -n 1 | sed 's/^/  /'

    echo ""
    echo "==> Verifying encoders"
    for enc in libmp3lame libvorbis libvpx-vp8 libvpx-vp9 libwebp; do
      "$OUT/bin/ffmpeg" -hide_banner -encoders 2>&1 | grep -i "$enc" | sed 's/^/  /' || echo "  WARNING: $enc not found!"
    done

    cat >"$OUT/BUILDINFO.txt" <<EOF
name=$(basename "$OUT")
ffmpeg_version=$FFMPEG_VERSION
lame_version=$LAME_VERSION
ogg_version=$OGG_VERSION
vorbis_version=$VORBIS_VERSION
vpx_version=$VPX_VERSION
webp_version=$WEBP_VERSION
build_stamp_utc=$BUILD_STAMP
build_id=${BUILD_ID:-}
min_macos=$MIN_MACOS
sdk=$SDK
cc=$CC
date_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)

$( "$OUT/bin/ffmpeg" -buildconf )
EOF

    echo ""
    echo "Done."
    echo "Binaries are in: $OUT/bin"
  } >&2
  echo "$OUT"
}

# ── Main ─────────────────────────────────────────────────────────

main() {
  local DO_PACKAGE=1
  local DO_INSTALL=1
  for arg in "$@"; do
    case "$arg" in
      -h|--help)
        cat <<EOF
Usage:
  ./build.sh [--help] [--no-package] [--no-install]

Env vars:
  MIN_MACOS=11.0          Minimum target macOS (default: 11.0)
  FFMPEG_VERSION=8.0.1    FFmpeg version (default: 8.0.1)
  LAME_VERSION=3.100      LAME version (default: 3.100)
  OGG_VERSION=1.3.5       libogg version (default: 1.3.5)
  VORBIS_VERSION=1.3.7    libvorbis version (default: 1.3.7)
  VPX_VERSION=1.15.2      libvpx version (default: 1.15.2)
  WEBP_VERSION=1.6.0      libwebp version (default: 1.6.0)
  BUILD_STAMP=YYYYMMDDHHMM  Stamp used in output name (default: current UTC)
  BUILD_ID=123            Optional build number/id appended after version
  WORK_DIR=... DIST_DIR=... JOBS=...
EOF
        exit 0
        ;;
      --no-package)
        DO_PACKAGE=0
        ;;
      --no-install)
        DO_INSTALL=0
        ;;
      *)
        echo "Unknown argument: $arg" >&2
        exit 2
        ;;
    esac
  done

  fetch_lame
  fetch_ogg
  fetch_vorbis
  fetch_vpx
  fetch_webp
  fetch_ffmpeg
  build_one_arch arm64
  build_one_arch x86_64
  local OUT_DIR
  OUT_DIR="$(make_universal)"
  if [[ "$DO_PACKAGE" -eq 1 ]]; then
    package_release "$OUT_DIR"
  fi
  if [[ "$DO_INSTALL" -eq 1 ]]; then
    install_to_project "$OUT_DIR"
  fi
}

main "$@"
