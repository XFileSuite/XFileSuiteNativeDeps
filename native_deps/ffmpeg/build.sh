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
FFMPEG_LINKAGE="${FFMPEG_LINKAGE:-static}"
# Optional per-architecture prefixes containing libass, FreeType, HarfBuzz
# and FriBidi.  The media-runtime builder supplies these from its pinned mpv
# dependency build.  Keep this explicit: --disable-autodetect must never pull
# a developer-machine copy of libass into a release binary.
LIBASS_PREFIX_ROOT="${LIBASS_PREFIX_ROOT:-}"

FFMPEG_VERSION="${FFMPEG_VERSION:-8.1.2}"
FFMPEG_TARBALL_URL="${FFMPEG_TARBALL_URL:-https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz}"
FFMPEG_TARBALL_PATH="$WORK_DIR/ffmpeg-${FFMPEG_VERSION}.tar.xz"
FFMPEG_TARBALL_SHA256="${FFMPEG_TARBALL_SHA256:-464beb5e7bf0c311e68b45ae2f04e9cc2af88851abb4082231742a74d97b524c}"
FFMPEG_SRC_DIR="$WORK_DIR/ffmpeg-${FFMPEG_VERSION}"

LAME_VERSION="${LAME_VERSION:-3.100}"
LAME_TARBALL_URL="https://sourceforge.net/projects/lame/files/lame/${LAME_VERSION}/lame-${LAME_VERSION}.tar.gz/download"
LAME_TARBALL_PATH="$WORK_DIR/lame-${LAME_VERSION}.tar.gz"
LAME_TARBALL_SHA256="ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e"
LAME_SRC_DIR="$WORK_DIR/lame-${LAME_VERSION}"

OGG_VERSION="${OGG_VERSION:-1.3.5}"
OGG_TARBALL_URL="https://downloads.xiph.org/releases/ogg/libogg-${OGG_VERSION}.tar.xz"
OGG_TARBALL_PATH="$WORK_DIR/libogg-${OGG_VERSION}.tar.xz"
OGG_TARBALL_SHA256="c4d91be36fc8e54deae7575241e03f4211eb102afb3fc0775fbbc1b740016705"
OGG_SRC_DIR="$WORK_DIR/libogg-${OGG_VERSION}"

VORBIS_VERSION="${VORBIS_VERSION:-1.3.7}"
VORBIS_TARBALL_URL="https://downloads.xiph.org/releases/vorbis/libvorbis-${VORBIS_VERSION}.tar.xz"
VORBIS_TARBALL_PATH="$WORK_DIR/libvorbis-${VORBIS_VERSION}.tar.xz"
VORBIS_TARBALL_SHA256="b33cc4934322bcbf6efcbacf49e3ca01aadbea4114ec9589d1b1e9d20f72954b"
VORBIS_SRC_DIR="$WORK_DIR/libvorbis-${VORBIS_VERSION}"

VPX_VERSION="${VPX_VERSION:-1.15.2}"
VPX_TARBALL_URL="https://codeload.github.com/webmproject/libvpx/tar.gz/refs/tags/v${VPX_VERSION}"
VPX_TARBALL_PATH="$WORK_DIR/libvpx-${VPX_VERSION}.tar.gz"
VPX_TARBALL_SHA256="26fcd3db88045dee380e581862a6ef106f49b74b6396ee95c2993a260b4636aa"
VPX_SRC_DIR="$WORK_DIR/libvpx-${VPX_VERSION}"

WEBP_VERSION="${WEBP_VERSION:-1.6.0}"
WEBP_TARBALL_URL="https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-${WEBP_VERSION}.tar.gz"
WEBP_TARBALL_PATH="$WORK_DIR/libwebp-${WEBP_VERSION}.tar.gz"
WEBP_TARBALL_SHA256="e4ab7009bf0629fd11982d4c2aa83964cf244cffba7347ecd39019a9e38c4564"
WEBP_SRC_DIR="$WORK_DIR/libwebp-${WEBP_VERSION}"

OPUS_VERSION="${OPUS_VERSION:-1.5.2}"
OPUS_TARBALL_URL="https://codeload.github.com/xiph/opus/tar.gz/refs/tags/v${OPUS_VERSION}"
OPUS_TARBALL_PATH="$WORK_DIR/opus-${OPUS_VERSION}.tar.gz"
OPUS_TARBALL_SHA256="9480e329e989f70d69886ded470c7f8cfe6c0667cc4196d4837ac9e668fb7404"
OPUS_SRC_DIR="$WORK_DIR/opus-${OPUS_VERSION}"

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

ensure_source_archive() {
  local url="$1" archive="$2" expected_sha="$3" label="$4"
  if [[ ! -f "$archive" ]] || [[ "$(shasum -a 256 "$archive" | awk '{print $1}')" != "$expected_sha" ]]; then
    rm -f "$archive"
    echo "Downloading $label..."
    curl --fail --location --retry 5 --retry-all-errors --retry-delay 1 \
      --connect-timeout 30 --output "$archive" "$url"
  else
    echo "Using checksum-verified archive: $archive"
  fi
  test "$(shasum -a 256 "$archive" | awk '{print $1}')" = "$expected_sha"
}

fetch_ffmpeg() {
  ensure_source_archive "$FFMPEG_TARBALL_URL" "$FFMPEG_TARBALL_PATH" "$FFMPEG_TARBALL_SHA256" "FFmpeg ${FFMPEG_VERSION}"
  if [[ -d "$FFMPEG_SRC_DIR" && -f "$FFMPEG_SRC_DIR/configure" ]]; then
    echo "Using existing FFmpeg source: $FFMPEG_SRC_DIR"
    return 0
  fi
  rm -rf "$FFMPEG_SRC_DIR"
  echo "Extracting..."
  tar -xf "$FFMPEG_TARBALL_PATH" -C "$WORK_DIR"
}

fetch_lame() {
  ensure_source_archive "$LAME_TARBALL_URL" "$LAME_TARBALL_PATH" "$LAME_TARBALL_SHA256" "LAME ${LAME_VERSION}"
  if [[ -d "$LAME_SRC_DIR" && -f "$LAME_SRC_DIR/configure" ]]; then
    echo "Using existing LAME source: $LAME_SRC_DIR"
    return 0
  fi
  rm -rf "$LAME_SRC_DIR"
  echo "Extracting LAME..."
  tar -xzf "$LAME_TARBALL_PATH" -C "$WORK_DIR"
}

fetch_ogg() {
  ensure_source_archive "$OGG_TARBALL_URL" "$OGG_TARBALL_PATH" "$OGG_TARBALL_SHA256" "libogg ${OGG_VERSION}"
  if [[ -d "$OGG_SRC_DIR" && -f "$OGG_SRC_DIR/configure" ]]; then
    echo "Using existing libogg source: $OGG_SRC_DIR"
    return 0
  fi
  rm -rf "$OGG_SRC_DIR"
  echo "Extracting libogg..."
  tar -xf "$OGG_TARBALL_PATH" -C "$WORK_DIR"
}

fetch_vorbis() {
  ensure_source_archive "$VORBIS_TARBALL_URL" "$VORBIS_TARBALL_PATH" "$VORBIS_TARBALL_SHA256" "libvorbis ${VORBIS_VERSION}"
  if [[ -d "$VORBIS_SRC_DIR" && -f "$VORBIS_SRC_DIR/configure" ]]; then
    echo "Using existing libvorbis source: $VORBIS_SRC_DIR"
    return 0
  fi
  rm -rf "$VORBIS_SRC_DIR"
  echo "Extracting libvorbis..."
  tar -xf "$VORBIS_TARBALL_PATH" -C "$WORK_DIR"
  # Patch out obsolete -force_cpusubtype_ALL that breaks on modern Xcode.
  # The corresponding source archive records this adjustment in patches/.
  sed -i '' 's/-force_cpusubtype_ALL//g' "$VORBIS_SRC_DIR/configure"
}

fetch_vpx() {
  ensure_source_archive "$VPX_TARBALL_URL" "$VPX_TARBALL_PATH" "$VPX_TARBALL_SHA256" "libvpx ${VPX_VERSION}"
  if [[ -d "$VPX_SRC_DIR" && -f "$VPX_SRC_DIR/configure" ]]; then
    echo "Using existing libvpx source: $VPX_SRC_DIR"
    return 0
  fi
  rm -rf "$VPX_SRC_DIR"
  mkdir -p "$VPX_SRC_DIR"
  echo "Extracting libvpx..."
  tar -xzf "$VPX_TARBALL_PATH" --strip-components=1 -C "$VPX_SRC_DIR"
}

fetch_webp() {
  ensure_source_archive "$WEBP_TARBALL_URL" "$WEBP_TARBALL_PATH" "$WEBP_TARBALL_SHA256" "libwebp ${WEBP_VERSION}"
  if [[ -d "$WEBP_SRC_DIR" && -f "$WEBP_SRC_DIR/CMakeLists.txt" ]]; then
    echo "Using existing libwebp source: $WEBP_SRC_DIR"
    return 0
  fi
  rm -rf "$WEBP_SRC_DIR"
  echo "Extracting libwebp..."
  tar -xzf "$WEBP_TARBALL_PATH" -C "$WORK_DIR"
}

fetch_opus() {
  ensure_source_archive "$OPUS_TARBALL_URL" "$OPUS_TARBALL_PATH" "$OPUS_TARBALL_SHA256" "libopus ${OPUS_VERSION}"
  if [[ -d "$OPUS_SRC_DIR" && -f "$OPUS_SRC_DIR/CMakeLists.txt" ]]; then
    echo "Using existing libopus source: $OPUS_SRC_DIR"
    return 0
  fi
  rm -rf "$OPUS_SRC_DIR"
  echo "Extracting libopus..."
  mkdir -p "$OPUS_SRC_DIR"
  tar -xzf "$OPUS_TARBALL_PATH" --strip-components=1 -C "$OPUS_SRC_DIR"
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

  local VPX_FLAGS="-arch $ARCH -isysroot $SDK -mmacosx-version-min=$MIN_MACOS -O3"
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

  CC="$CC" CXX="$CXX" CFLAGS="$VPX_FLAGS" CXXFLAGS="$VPX_FLAGS" LDFLAGS="$LDFLAGS" \
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
  # libvpx does not consistently install the archive for cross-compiled
  # Darwin targets. Install its public development files explicitly.
  mkdir -p "$PREFIX/lib/pkgconfig" "$PREFIX/include/vpx"
  cp -f "$BUILD_OUT/libvpx.a" "$PREFIX/lib/libvpx.a"
  cp -f "$BUILD_OUT/vpx.pc" "$PREFIX/lib/pkgconfig/vpx.pc"
  cp -f "$VPX_SRC_DIR"/vpx/*.h "$PREFIX/include/vpx/"

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

build_opus_arch() {
  local ARCH="$1"
  local PREFIX="$WORK_DIR/prefix-$ARCH"
  local BUILD_OUT="$WORK_DIR/build-opus-$ARCH"
  rm -rf "$BUILD_OUT"
  cmake -S "$OPUS_SRC_DIR" -B "$BUILD_OUT" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$MIN_MACOS" \
    -DCMAKE_OSX_SYSROOT="$SDK" \
    -DBUILD_SHARED_LIBS=OFF \
    -DOPUS_BUILD_PROGRAMS=OFF \
    -DOPUS_BUILD_TESTING=OFF
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
  build_opus_arch "$ARCH"

  if [[ -n "$LIBASS_PREFIX_ROOT" ]]; then
    local LIBASS_PREFIX="$LIBASS_PREFIX_ROOT/$ARCH"
    [[ -d "$LIBASS_PREFIX" ]] || {
      echo "Missing libass prefix for $ARCH: $LIBASS_PREFIX" >&2
      exit 1
    }
    # Merge the pinned subtitle-rendering dependency prefix after the codec
    # dependencies. Its pkg-config files are then visible to FFmpeg below.
    cp -R "$LIBASS_PREFIX/." "$PREFIX/"
  fi

  export MACOSX_DEPLOYMENT_TARGET="$MIN_MACOS"
  export CC CXX SDKROOT="$SDK"
  export HOSTCC="$CC"
  export HOSTCFLAGS="-isysroot $SDK"
  export HOSTLDFLAGS="-isysroot $SDK"
  # Use real pkg-config but only look in our prefix to avoid pulling brew libs
  PKG_CONFIG="$(command -v pkg-config || echo /usr/bin/pkg-config)"
  export PKG_CONFIG
  export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
  export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
  unset CPATH LIBRARY_PATH DYLD_LIBRARY_PATH

  local CFLAGS="-arch $ARCH -isysroot $SDK -mmacosx-version-min=$MIN_MACOS -O3"
  local LDFLAGS="-arch $ARCH -isysroot $SDK -mmacosx-version-min=$MIN_MACOS"

  # Point FFmpeg at all the static libs we just built
  local LIB_CFLAGS="-I$PREFIX/include"
  local LIB_LDFLAGS="-L$PREFIX/lib -lvorbisenc -lvorbis -logg -lvpx -lwebp -lsharpyuv -lmp3lame -lopus -lm"

  local CROSS_CONFIG=()
  if [[ "$ARCH" != "$HOST_MACHINE" ]]; then
    if [[ "$ARCH" == "arm64" ]]; then
      CROSS_CONFIG+=(--enable-cross-compile --arch=aarch64 --target-os=darwin)
    else
      CROSS_CONFIG+=(--enable-cross-compile --arch="$ARCH" --target-os=darwin)
    fi
  fi

  local EXTRA_CONFIG=()
  local LINKAGE_CONFIG=()
  if [[ "$FFMPEG_LINKAGE" == "shared" ]]; then
    LINKAGE_CONFIG+=(--enable-shared --disable-static)
  elif [[ "$FFMPEG_LINKAGE" == "static" ]]; then
    LINKAGE_CONFIG+=(--disable-shared --enable-static)
  else
    echo "FFMPEG_LINKAGE must be static or shared" >&2
    exit 2
  fi
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
    "${LINKAGE_CONFIG[@]}" \
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
    --enable-libopus \
    ${LIBASS_PREFIX_ROOT:+--enable-libass} \
    ${LIBASS_PREFIX_ROOT:+--enable-filter=subtitles} \
    ${LIBASS_PREFIX_ROOT:+--enable-filter=ass} \
    \
    --enable-videotoolbox \
    --enable-audiotoolbox \
    \
    --enable-zlib \
    \
    --enable-ffmpeg \
    --enable-ffprobe \
    --disable-ffplay \
    \
    --disable-network \
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
  local OUT
  OUT="$DIST_DIR/$(OUT_BASENAME)"
  {
    rm -rf "$OUT"
    mkdir -p "$OUT/bin" "$OUT/lib"

    local FFMPEG_ARM="$WORK_DIR/prefix-arm64/bin/ffmpeg"
    local FFMPEG_X64="$WORK_DIR/prefix-x86_64/bin/ffmpeg"
    local FFPROBE_ARM="$WORK_DIR/prefix-arm64/bin/ffprobe"
    local FFPROBE_X64="$WORK_DIR/prefix-x86_64/bin/ffprobe"

    echo ""
    echo "==> Creating universal binaries"
    echo ""

    lipo -create "$FFMPEG_ARM" "$FFMPEG_X64" -output "$OUT/bin/ffmpeg"
    lipo -create "$FFPROBE_ARM" "$FFPROBE_X64" -output "$OUT/bin/ffprobe"

    if [[ "$FFMPEG_LINKAGE" == "shared" ]]; then
      local arm_lib x64_lib lib_name output_lib dependency old_path
      while IFS= read -r arm_lib; do
        lib_name="$(basename "$(otool -D "$arm_lib" | tail -n 1)")"
        x64_lib="$WORK_DIR/prefix-x86_64/lib/$lib_name"
        [[ -f "$x64_lib" ]] || {
          echo "Missing x86_64 shared library matching $lib_name" >&2
          exit 1
        }
        output_lib="$OUT/lib/$lib_name"
        lipo -create "$arm_lib" "$x64_lib" -output "$output_lib"
        install_name_tool -id "@rpath/$lib_name" "$output_lib"
      done < <(
        find "$WORK_DIR/prefix-arm64/lib" -maxdepth 1 -type f \
          \( -name 'libav*.dylib' -o -name 'libsw*.dylib' \) |
          sort
      )

      for output_lib in "$OUT"/lib/*.dylib "$OUT"/bin/ffmpeg "$OUT"/bin/ffprobe; do
        while IFS= read -r old_path; do
          [[ -n "$old_path" ]] || continue
          dependency="$(basename "$old_path")"
          if [[ -f "$OUT/lib/$dependency" ]]; then
            install_name_tool -change "$old_path" "@rpath/$dependency" "$output_lib" 2>/dev/null || true
          fi
        done < <(
          otool -L "$output_lib" |
            awk '/prefix-(arm64|x86_64)\/lib\/(libav|libsw)/ {print $1}' |
            sort -u
        )
      done
      install_name_tool -add_rpath "@executable_path/../lib" "$OUT/bin/ffmpeg" 2>/dev/null || true
      install_name_tool -add_rpath "@executable_path/../lib" "$OUT/bin/ffprobe" 2>/dev/null || true
    fi

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
    if [[ "$FFMPEG_LINKAGE" == "shared" ]]; then
      otool -L "$OUT/bin/ffmpeg" | grep -q '@rpath/libavcodec' || {
        echo "Shared ffmpeg does not link libavcodec through @rpath" >&2
        exit 1
      }
    fi

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
opus_version=$OPUS_VERSION
linkage=$FFMPEG_LINKAGE
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
  local UNIVERSAL_ONLY=0
  for arg in "$@"; do
    case "$arg" in
      -h|--help)
        cat <<EOF
Usage:
  ./build.sh [--help] [--no-package] [--no-install] [--universal-only]

Env vars:
  MIN_MACOS=11.0          Minimum target macOS (default: 11.0)
  FFMPEG_LINKAGE=static   static (legacy CLI) or shared (media runtime)
  FFMPEG_VERSION=8.1.2    FFmpeg version (default: 8.1.2)
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
      --universal-only)
        UNIVERSAL_ONLY=1
        ;;
      *)
        echo "Unknown argument: $arg" >&2
        exit 2
        ;;
    esac
  done

  if [[ "$UNIVERSAL_ONLY" -eq 0 ]]; then
    fetch_lame
    fetch_ogg
    fetch_vorbis
    fetch_vpx
    fetch_webp
    fetch_opus
    fetch_ffmpeg
    build_one_arch arm64
    build_one_arch x86_64
  fi
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
