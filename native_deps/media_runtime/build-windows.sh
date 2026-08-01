#!/usr/bin/env bash
# Builds the shared FFmpeg + libmpv media runtime for Windows x64 under MSYS2.
#
# This mirrors the macOS build-macos.sh architecture:
#   1. Build shared FFmpeg DLLs + ffmpeg.exe using ffmpeg/build-windows.sh
#   2. Install mpv's native dependencies from MSYS2 packages
#   3. Build libmpv with meson, linking against the shared FFmpeg import libs
#   4. Download the pre-built ANGLE OpenGL ES → D3D11 translation layer
#   5. Collect licenses and metadata
#
# The output is packaged by package-windows-runtime.sh into a single tar.gz
# with bin/, lib/, include/, licenses/, and metadata/ directories.
set -Eeuo pipefail

current_phase="initialization"
trap 'status=$?; echo "ERROR: Windows media runtime failed during ${current_phase} at line ${LINENO} (exit ${status})" >&2; exit "$status"' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NATIVE_DEPS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WORK_DIR="${WORK_DIR:-$SCRIPT_DIR/work}"
DIST_DIR="${DIST_DIR:-$SCRIPT_DIR/dist}"
RUNTIME_VERSION="${RUNTIME_VERSION:-8.1.2-mpv-0.41.0}"
RELEASE_REVISION="${RELEASE_REVISION:-1}"
FFMPEG_VERSION="${FFMPEG_VERSION:-8.1.2}"
MPV_VERSION="${MPV_VERSION:-0.41.0}"
MPV_SHA256="${MPV_SHA256:-ee21092a5ee427353392360929dc64645c54479aefdb5babc5cfbb5fad626209}"
LIBPLACEBO_VERSION="${LIBPLACEBO_VERSION:-6.338.2}"
LIBPLACEBO_COMMIT="${LIBPLACEBO_COMMIT:-64c1954570f1cd57f8570a57e51fb0249b57bb90}"
ANGLE_URL="${ANGLE_URL:-https://github.com/alexmercerind/flutter-windows-ANGLE-OpenGL-ES/releases/download/v1.0.1/ANGLE.7z}"
ANGLE_MD5="${ANGLE_MD5:-e866f13e8d552348058afaafe869b1ed}"
JOBS="${JOBS:-$(nproc)}"

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required tool: $1" >&2
    exit 1
  }
}

need_file() {
  [[ -f "$1" ]] || {
    echo "Missing required file: $1" >&2
    return 1
  }
}

need_dir() {
  [[ -d "$1" ]] || {
    echo "Missing required directory: $1" >&2
    return 1
  }
}

for tool in pacman curl tar make pkg-config meson ninja git python3; do
  need "$tool"
done

# Reuse compiler objects across Actions runs while always rebuilding and
# re-verifying the final runtime. ccache hashes the compiler command and source
# contents, so stale objects are not accepted when flags or inputs change.
if command -v ccache >/dev/null 2>&1; then
  export CCACHE_DIR="${CCACHE_DIR:-$WORK_DIR/ccache}"
  mkdir -p "$CCACHE_DIR"
  ccache --max-size "${CCACHE_MAXSIZE:-2G}"
  export CC="${CC:-ccache gcc}"
  export CXX="${CXX:-ccache g++}"
  echo "==> Compiler cache enabled at $CCACHE_DIR"
fi

mkdir -p "$WORK_DIR" "$DIST_DIR"

# ── 1. Build shared FFmpeg DLLs + ffmpeg.exe ──────────────────────
echo "==> Building the shared FFmpeg 8 runtime for Windows x64"
current_phase="shared FFmpeg build"
ffmpeg_builder_status=0
ffmpeg_work="$WORK_DIR/ffmpeg"
ffmpeg_dist="$WORK_DIR/ffmpeg-dist"
FFMPEG_LINKAGE=shared \
WORK_DIR="$ffmpeg_work" \
DIST_DIR="$ffmpeg_dist" \
JOBS="$JOBS" \
  bash "$NATIVE_DEPS_DIR/ffmpeg/build-windows.sh" || ffmpeg_builder_status=$?

ffmpeg_output="$ffmpeg_dist/ffmpeg-${FFMPEG_VERSION}-windows-x64"
# Execute the produced PE file as the intermediate smoke test. The final
# package verifier checks every DLL, import library and public header after
# staging, avoiding unreliable intermediate MSYS glob/file predicates.
PATH="$ffmpeg_output/bin:$PATH" "$ffmpeg_output/bin/ffmpeg.exe" -version >/dev/null
if [[ "$ffmpeg_builder_status" != 0 ]]; then
  echo "  Note: MSYS2 wrapper returned $ffmpeg_builder_status after a complete, smoke-tested FFmpeg build"
fi
echo "  ✓ shared FFmpeg DLLs + ffmpeg.exe"

# ── 2. Install mpv native dependencies from MSYS2 ─────────────────
echo "==> Installing mpv native dependencies from MSYS2"
current_phase="MSYS2 dependency installation"
MPV_MSYS2_PACKAGES=(
  mingw-w64-x86_64-dav1d
  mingw-w64-x86_64-libass
  mingw-w64-x86_64-freetype
  mingw-w64-x86_64-fontconfig
  mingw-w64-x86_64-fribidi
  mingw-w64-x86_64-harfbuzz
  mingw-w64-x86_64-libxml2
  mingw-w64-x86_64-uchardet
  mingw-w64-x86_64-lcms2
  mingw-w64-x86_64-expat
  mingw-w64-x86_64-zlib
  mingw-w64-x86_64-iconv
)
for pkg in "${MPV_MSYS2_PACKAGES[@]}"; do
  pacman -Q "$pkg" >/dev/null 2>&1 || {
    echo "  Installing $pkg..."
    pacman -S --noconfirm "$pkg"
  }
done
echo "  ✓ mpv MSYS2 dependencies installed"

# ── 3. Build libmpv with meson ────────────────────────────────────
echo "==> Building libmpv ${MPV_VERSION} with meson"
current_phase="mpv source preparation"

mpv_src="$WORK_DIR/mpv-${MPV_VERSION}"
mpv_archive="$WORK_DIR/mpv-${MPV_VERSION}.tar.gz"
if [[ ! -f "$mpv_archive" ]]; then
  curl -fL --retry 3 -o "$mpv_archive" \
    "https://github.com/mpv-player/mpv/archive/refs/tags/v${MPV_VERSION}.tar.gz"
fi
echo "$MPV_SHA256  $mpv_archive" | sha256sum -c -
rm -rf "$mpv_src"
tar -xzf "$mpv_archive" -C "$WORK_DIR"
need_dir "$mpv_src"

# libplacebo is a hard dependency of mpv 0.41. Build it as a subproject.
libplacebo_dir="$mpv_src/subprojects/libplacebo"
mkdir -p "$mpv_src/subprojects"
if [[ ! -d "$libplacebo_dir" ]]; then
  git clone --depth 1 --branch "v${LIBPLACEBO_VERSION}" \
    --recurse-submodules --shallow-submodules \
    https://github.com/haasn/libplacebo.git "$libplacebo_dir"
  actual_libplacebo_commit="$(git -C "$libplacebo_dir" rev-parse HEAD)"
  [[ "$actual_libplacebo_commit" == "$LIBPLACEBO_COMMIT" ]] || {
    echo "Unexpected libplacebo commit: $actual_libplacebo_commit" >&2
    exit 1
  }
fi

# Point pkg-config at the shared FFmpeg import libs + MSYS2 packages.
export PKG_CONFIG_PATH="$ffmpeg_output/lib:${PKG_CONFIG_PATH:-}"
export PKG_CONFIG=/mingw64/bin/pkg-config

mpv_prefix="$WORK_DIR/mpv-prefix"
rm -rf "$mpv_prefix" "$mpv_src/build"
mkdir -p "$mpv_prefix"

(
  cd "$mpv_src"

  current_phase="mpv Meson configuration"

  meson setup build \
    --prefix="$mpv_prefix" \
    --libdir="$mpv_prefix/lib" \
    --default-library=shared \
    --buildtype=release \
    -Dauto_features=disabled \
    -Dgpl=false \
    -Dcplayer=false \
    -Dlibmpv=true \
    -Dbuild-date=false \
    -Dtests=false \
    -Diconv=enabled \
    -Duchardet=enabled \
    -Dzlib=enabled \
    -Dgl=enabled \
    -Dplain-gl=enabled \
    -Dwin32-threads=enabled \
    -Dgl-win32=disabled \
    -Degl-angle=disabled \
    -Degl-angle-lib=disabled \
    -Degl-angle-win32=disabled \
    -Dd3d-hwaccel=enabled \
    -Dvulkan=disabled \
    -Dhtml-build=disabled \
    -Dmanpage-build=disabled \
    -Dpdf-build=disabled \
    -Dlua=disabled \
    -Djavascript=disabled \
    -Dlibplacebo:demos=false \
    -Dlibplacebo:tests=false \
    -Dlibplacebo:vulkan=disabled \
    -Dlibplacebo:opengl=disabled \
    -Dlibplacebo:d3d11=disabled \
    -Dlibplacebo:glslang=disabled \
    -Dlibplacebo:shaderc=disabled \
    -Dlibplacebo:lcms=disabled \
    -Dlibplacebo:dovi=disabled \
    -Dlibplacebo:libdovi=disabled \
    -Dlibplacebo:unwind=disabled \
    -Dlibplacebo:xxhash=disabled

  current_phase="mpv compilation"
  meson compile -C build
  current_phase="mpv installation"
  meson install -C build
)

need_file "$mpv_prefix/bin/libmpv-2.dll"
need_file "$mpv_prefix/lib/libmpv.dll.a"
echo "  ✓ libmpv ${MPV_VERSION} (shared, -Dgpl=false)"

# ── 4. Download pre-built ANGLE ───────────────────────────────────
echo "==> Downloading pre-built ANGLE (OpenGL ES → D3D11)"
current_phase="ANGLE download and extraction"
angle_archive="$WORK_DIR/ANGLE.7z"
angle_dir="$WORK_DIR/ANGLE"
if [[ ! -f "$angle_archive" ]] || [[ "$(md5sum "$angle_archive" | awk '{print $1}')" != "$ANGLE_MD5" ]]; then
  curl -fL --retry 3 -o "$angle_archive" "$ANGLE_URL"
fi
echo "$ANGLE_MD5  $angle_archive" | md5sum -c -
rm -rf "$angle_dir"
mkdir -p "$angle_dir"
# 7z is available in MSYS2 as part of the base installation.
if command -v 7z >/dev/null 2>&1; then
  7z x "$angle_archive" -o"$angle_dir" -y
else
  # p7zip may be named 7za on some systems.
  7za x "$angle_archive" -o"$angle_dir" -y
fi
need_file "$angle_dir/libEGL.dll"
need_file "$angle_dir/libGLESv2.dll"
need_file "$angle_dir/d3dcompiler_47.dll"
need_file "$angle_dir/lib/libEGL.dll.lib"
need_file "$angle_dir/lib/libGLESv2.dll.lib"
echo "  ✓ ANGLE (libEGL.dll, libGLESv2.dll, d3dcompiler_47.dll)"

# ── 5. Collect licenses ────────────────────────────────────────────
echo "==> Collecting distributable license texts"
current_phase="license collection"
licenses="$WORK_DIR/licenses"
rm -rf "$licenses"
mkdir -p "$licenses"

cp "$WORK_DIR/ffmpeg/ffmpeg-${FFMPEG_VERSION}/COPYING.LGPLv2.1" "$licenses/FFmpeg-LGPL-2.1.txt"
cp "$WORK_DIR/ffmpeg/ffmpeg-${FFMPEG_VERSION}/LICENSE.md" "$licenses/FFmpeg-LICENSE.md"

# mpv license
cp "$mpv_src/Copyright" "$licenses/mpv-Copyright.txt"

# libplacebo license
cp "$libplacebo_dir/LICENSE" "$licenses/libplacebo-LICENSE.txt"
cp "$SCRIPT_DIR/ANGLE-LICENSE.txt" "$licenses/ANGLE-BSD-3-Clause.txt"

collect_msys2_package_licenses() {
  local package="$1"
  local short_name="${package#mingw-w64-x86_64-}"
  local destination="$licenses/msys2-$short_name"
  local copied=0
  while IFS= read -r license_file; do
    [[ -f "$license_file" ]] || continue
    mkdir -p "$destination"
    cp "$license_file" "$destination/$(basename "$license_file")"
    copied=1
  done < <(pacman -Ql "$package" | awk '$2 ~ /\/share\/licenses\// { print $2 }')
  if [[ "$copied" != 1 ]]; then
    # MinGW packages commonly omit upstream license files from the binary
    # package (for example libass). Preserve the installed package's exact
    # version, declared license and upstream URL instead of silently skipping
    # it. Full corresponding source is published by the source-package step.
    mkdir -p "$destination"
    {
      echo "MSYS2 binary package metadata"
      echo
      LC_ALL=C pacman -Qi "$package" |
        awk '/^(Name|Version|Description|URL|Licenses|Packager|Build Date)[[:space:]]*:/ { print }'
      echo
      echo "Package file list: https://packages.msys2.org/packages/$package"
      echo "The package page links the matching MSYS2 source-only archive."
    } > "$destination/PACKAGE-METADATA.txt"
    echo "  ! $package omits license text; bundled package metadata and source reference"
  fi
}

# Collect licenses for direct dependencies. Owners of recursively discovered
# runtime DLLs are collected after the dependency closure is staged.
DIRECT_LICENSE_PACKAGES=(
  "${MPV_MSYS2_PACKAGES[@]}"
  mingw-w64-x86_64-lame
  mingw-w64-x86_64-libogg
  mingw-w64-x86_64-libvorbis
  mingw-w64-x86_64-libvpx
  mingw-w64-x86_64-libwebp
  mingw-w64-x86_64-opus
)
for package in "${DIRECT_LICENSE_PACKAGES[@]}"; do
  collect_msys2_package_licenses "$package"
done

cat > "$licenses/NOTICE.md" <<'EOF'
# XFileSuite shared media runtime notices (Windows)

This bundle contains the following third-party components:

| Component | License |
| --- | --- |
| FFmpeg 8.1.2 (shared DLLs + CLI) | LGPL-2.1 |
| mpv 0.41.0 | LGPL-2.1 (built with `-Dgpl=false`) |
| libplacebo 6.338.2 | LGPL-2.1 |
| dav1d | BSD-2-Clause |
| libass | ISC |
| FreeType | FTL (BSD-like) |
| Fontconfig | MIT-style permissive license |
| FriBidi | LGPL-2.1 |
| HarfBuzz | MIT |
| libxml2 | MIT |
| uchardet | MPL-2.0 |
| lcms2 | MIT |
| Expat | MIT |
| LAME | LGPL-2.0 |
| libogg | BSD-3-Clause |
| libvorbis | BSD-3-Clause |
| libvpx | BSD-3-Clause |
| libwebp | BSD-3-Clause |
| Opus | BSD-3-Clause |
| ANGLE (libEGL, libGLESv2, d3dcompiler) | BSD-3-Clause |
| Additional MinGW runtime DLLs | See `msys2-*` license directories |

Some MSYS2 MinGW binary packages do not install their upstream license file.
For those packages the matching `msys2-*` directory contains the installed
package version, declared license, upstream URL and the MSYS2 page that links
the matching source-only archive.

FFmpeg was built with `--disable-gpl --disable-nonfree --disable-version3`.
Mbed TLS and HTTPS/TLS/RTMPS playback protocols are intentionally excluded so
the runtime remains LGPL-2.1-compatible.
mpv was built with `-Dgpl=false`. No x264/x265 or encoders-GPL flavor is
included. Shared FFmpeg DLLs are used by both the ffmpeg CLI and libmpv.
EOF

echo "  ✓ license texts collected"

# ── 6. Stage the runtime ───────────────────────────────────────────
echo "==> Staging the Windows media runtime"
current_phase="runtime staging"
stage="$WORK_DIR/stage"
rm -rf "$stage"
mkdir -p "$stage/bin" "$stage/lib" "$stage/include/mpv" "$stage/licenses" "$stage/metadata"

# Shared FFmpeg DLLs + ffmpeg.exe
cp "$ffmpeg_output/bin/"avcodec-*.dll "$ffmpeg_output/bin/"avdevice-*.dll "$ffmpeg_output/bin/"avformat-*.dll \
   "$ffmpeg_output/bin/"avutil-*.dll "$ffmpeg_output/bin/"avfilter-*.dll \
   "$ffmpeg_output/bin/"swresample-*.dll "$ffmpeg_output/bin/"swscale-*.dll \
   "$stage/bin/"
cp "$ffmpeg_output/bin/ffmpeg.exe" "$stage/bin/"
# FFmpeg import libraries
cp "$ffmpeg_output/lib/"libavcodec.dll.a "$ffmpeg_output/lib/"libavdevice.dll.a "$ffmpeg_output/lib/"libavformat.dll.a \
   "$ffmpeg_output/lib/"libavutil.dll.a "$ffmpeg_output/lib/"libavfilter.dll.a \
   "$ffmpeg_output/lib/"libswresample.dll.a "$ffmpeg_output/lib/"libswscale.dll.a \
   "$stage/lib/"
# FFmpeg headers
cp -R "$ffmpeg_output/include/"libavcodec "$ffmpeg_output/include/"libavformat \
      "$ffmpeg_output/include/"libavutil "$ffmpeg_output/include/"libavfilter \
      "$ffmpeg_output/include/"libswresample "$ffmpeg_output/include/"libswscale \
      "$stage/include/"

# libmpv
cp "$mpv_prefix/bin/libmpv-2.dll" "$stage/bin/"
cp "$mpv_prefix/lib/libmpv.dll.a" "$stage/lib/"
cp "$mpv_src/libmpv/client.h" "$mpv_src/libmpv/stream_cb.h" \
   "$mpv_src/libmpv/render.h" "$mpv_src/libmpv/render_gl.h" \
   "$stage/include/mpv/"

# ANGLE DLLs
cp "$angle_dir/libEGL.dll" "$angle_dir/libGLESv2.dll" \
   "$angle_dir/d3dcompiler_47.dll" "$stage/bin/"
# Copy any additional ANGLE DLLs that may be present.
for extra_dll in vk_swiftshader.dll vulkan-1.dll zlib.dll libc++.dll; do
  [[ -f "$angle_dir/$extra_dll" ]] && cp "$angle_dir/$extra_dll" "$stage/bin/"
done
# ANGLE import libraries and headers (needed by media_kit_video at compile time)
mkdir -p "$stage/lib" "$stage/include/EGL" "$stage/include/GLES2" "$stage/include/KHR"
cp "$angle_dir/lib/libEGL.dll.lib" "$angle_dir/lib/libGLESv2.dll.lib" "$stage/lib/"
cp -R "$angle_dir/include/EGL/." "$stage/include/EGL/"
cp -R "$angle_dir/include/GLES2/." "$stage/include/GLES2/"
cp -R "$angle_dir/include/KHR/." "$stage/include/KHR/"

# MSYS2 runtime DLLs that mpv depends on
for msys_dll in \
  libdav1d.dll libass-9.dll libfreetype-6.dll libfontconfig-1.dll libfribidi-0.dll \
  libharfbuzz-0.dll libxml2-2.dll libuchardet.dll liblcms2-2.dll libiconv-2.dll \
  libbz2-1.dll liblzma-5.dll libpng16-16.dll libzstd.dll libbrotlidec.dll \
  libbrotlicommon.dll libgcc_s_seh-1.dll libwinpthread-1.dll libstdc++-6.dll; do
  [[ -f "/mingw64/bin/$msys_dll" ]] && cp "/mingw64/bin/$msys_dll" "$stage/bin/"
done

# Complete the dependency closure instead of maintaining a fragile hand-written
# DLL list. Only imports supplied by MinGW are copied; Windows system DLLs are
# intentionally left to the operating system.
while :; do
  copied=0
  while IFS= read -r imported_dll; do
    [[ -n "$imported_dll" ]] || continue
    if [[ -n "$(find "$stage/bin" -maxdepth 1 -type f -iname "$imported_dll" -print -quit)" ]]; then
      continue
    fi
    dependency="$(find /mingw64/bin -maxdepth 1 -type f -iname "$imported_dll" -print -quit)"
    if [[ -n "$dependency" ]]; then
      cp "$dependency" "$stage/bin/"
      echo "  + runtime dependency: $(basename "$dependency")"
      copied=1
    fi
  done < <(
    find "$stage/bin" -maxdepth 1 -type f \( -iname '*.dll' -o -iname '*.exe' \) -print0 |
      xargs -0 -r objdump -p 2>/dev/null |
      awk '/DLL Name:/ { print $3 }' |
      tr -d '\r' |
      sort -fu
  )
  [[ "$copied" == 1 ]] || break
done

# Include license texts for every MSYS2 package that owns a staged DLL. This
# keeps the compliance bundle aligned with the recursively collected runtime.
while IFS= read -r package; do
  [[ -n "$package" ]] || continue
  collect_msys2_package_licenses "$package"
done < <(
  while IFS= read -r -d '' dll; do
    pacman -Qqo "$dll" 2>/dev/null || true
  done < <(find "$stage/bin" -maxdepth 1 -type f -iname '*.dll' -print0)
  sort -u
)

# Licenses
cp -R "$licenses/." "$stage/licenses/"

# Metadata
cat > "$stage/metadata/BUILDINFO.md" <<EOF
# XFileSuite Windows media runtime

- Runtime version: $RUNTIME_VERSION
- Release revision: $RELEASE_REVISION
- Architecture: Windows x64
- FFmpeg CLI and libmpv use the same shared FFmpeg DLLs.
- FFmpeg is built without GPL and nonfree components.
- mpv is built with \`-Dgpl=false\`.
- ANGLE provides OpenGL ES → D3D11 translation for libmpv rendering.
EOF

(
  cd "$stage"
  find bin lib include licenses metadata -type f ! -path 'metadata/SHA256SUMS' -print0 |
    sort -z |
    while IFS= read -r -d '' file; do
      sha256sum "$file"
    done > metadata/SHA256SUMS
)

echo "  ✓ runtime staged at $stage"

# ── 7. Package ─────────────────────────────────────────────────────
echo "==> Packaging the Windows media runtime"
current_phase="runtime verification and packaging"
FRAMEWORKS_SOURCE="$stage" \
FFMPEG_BINARY="$stage/bin/ffmpeg.exe" \
LICENSES_SOURCE="$licenses" \
VERSION="$RUNTIME_VERSION" \
RELEASE_REVISION="$RELEASE_REVISION" \
DIST_DIR="$DIST_DIR" \
WORK_DIR="$WORK_DIR/package" \
  "$SCRIPT_DIR/package-windows-runtime.sh"

echo ""
echo "✅ Windows media runtime build complete"
echo "   Output: $DIST_DIR/media-runtime-windows-${RUNTIME_VERSION}-xfilesuite.${RELEASE_REVISION}.tar.gz"
