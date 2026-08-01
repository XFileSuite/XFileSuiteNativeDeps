#!/usr/bin/env bash
# Builds the LGPL-only FFmpeg command-line tools for Windows x64 under MSYS2.
#
# FFMPEG_LINKAGE=static  — standalone CLI tools, statically linked (default)
# FFMPEG_LINKAGE=shared  — shared DLLs + CLI tools + import libraries,
#                          used by the media runtime so libmpv and ffmpeg.exe
#                          resolve the same FFmpeg binaries at runtime.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${WORK_DIR:-$ROOT_DIR/work-windows}"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist-windows}"
FFMPEG_VERSION="${FFMPEG_VERSION:-8.0.1}"
FFMPEG_LINKAGE="${FFMPEG_LINKAGE:-static}"
JOBS="${JOBS:-$(nproc)}"

command -v pacman >/dev/null || { echo "Run this script inside MSYS2." >&2; exit 1; }
for tool in curl tar make pkg-config; do command -v "$tool" >/dev/null || { echo "Missing $tool" >&2; exit 1; }; done

# The workflow installs these exact MSYS2 packages.  Keeping the dependency list
# here makes a local rebuild use the same LGPL/BSD codec set as macOS.
for package in mingw-w64-x86_64-gcc mingw-w64-x86_64-nasm mingw-w64-x86_64-pkgconf \
  mingw-w64-x86_64-lame mingw-w64-x86_64-libogg mingw-w64-x86_64-libvorbis mingw-w64-x86_64-libvpx mingw-w64-x86_64-libwebp; do
  pacman -Q "$package" >/dev/null || { echo "Missing MSYS2 package: $package" >&2; exit 1; }
done

case "$FFMPEG_LINKAGE" in
  static) LINKAGE_CONFIG=(--disable-shared --enable-static) ;;
  shared) LINKAGE_CONFIG=(--enable-shared --disable-static) ;;
  *) echo "FFMPEG_LINKAGE must be static or shared" >&2; exit 2 ;;
esac

mkdir -p "$WORK_DIR" "$DIST_DIR"
archive="$WORK_DIR/ffmpeg-${FFMPEG_VERSION}.tar.xz"
source_dir="$WORK_DIR/ffmpeg-${FFMPEG_VERSION}"
[ -f "$archive" ] || curl -fL --retry 3 -o "$archive" "https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz"
rm -rf "$source_dir"
tar -xf "$archive" -C "$WORK_DIR"

prefix="$WORK_DIR/prefix"
build_dir="$WORK_DIR/build"
rm -rf "$prefix" "$build_dir"
mkdir -p "$build_dir"

(
  cd "$build_dir"
  PKG_CONFIG=/mingw64/bin/pkg-config \
  "$source_dir/configure" \
    --prefix="$prefix" \
    --target-os=mingw32 --arch=x86_64 \
    --pkg-config=/mingw64/bin/pkg-config --pkg-config-flags=--static \
    "${LINKAGE_CONFIG[@]}" --disable-debug --disable-doc --disable-network \
    --disable-gpl --disable-nonfree --disable-version3 \
    --enable-libmp3lame --enable-libvorbis --enable-libvpx --enable-libwebp --enable-libopus \
    --extra-libs='-lstdc++ -lws2_32 -lbcrypt -lz'
  make -j"$JOBS"
  make install
)

out="$DIST_DIR/ffmpeg-${FFMPEG_VERSION}-windows-x64"
rm -rf "$out"
mkdir -p "$out/bin" "$out/lib" "$out/include"
cp "$prefix/bin/ffmpeg.exe" "$out/bin/ffmpeg.exe"
cp "$prefix/bin/ffprobe.exe" "$out/bin/ffprobe.exe"
strip "$out/bin/ffmpeg.exe" "$out/bin/ffprobe.exe" || true

if [[ "$FFMPEG_LINKAGE" == "shared" ]]; then
  # Collect shared DLLs, import libraries, and headers for the media runtime.
  cp "$prefix/bin/"avcodec-*.dll "$prefix/bin/"avformat-*.dll "$prefix/bin/"avutil-*.dll \
     "$prefix/bin/"avfilter-*.dll "$prefix/bin/"swresample-*.dll "$prefix/bin/"swscale-*.dll \
     "$out/bin/" 2>/dev/null || true
  cp "$prefix/bin/"libavcodec.dll.a "$prefix/bin/"libavformat.dll.a "$prefix/bin/"libavutil.dll.a \
     "$prefix/bin/"libavfilter.dll.a "$prefix/bin/"libswresample.dll.a "$prefix/bin/"libswscale.dll.a \
     "$out/lib/" 2>/dev/null || true
  # MSYS2 may install import libs under lib/ instead of bin/.
  for dll_a in "$prefix/lib/"libavcodec.dll.a "$prefix/lib/"libavformat.dll.a \
               "$prefix/lib/"libavutil.dll.a "$prefix/lib/"libavfilter.dll.a \
               "$prefix/lib/"libswresample.dll.a "$prefix/lib/"libswscale.dll.a; do
    [[ -f "$dll_a" ]] && cp "$dll_a" "$out/lib/"
  done
  cp -R "$prefix/include/libavcodec" "$prefix/include/libavformat" "$prefix/include/libavutil" \
        "$prefix/include/libavfilter" "$prefix/include/libswresample" "$prefix/include/libswscale" \
        "$out/include/" 2>/dev/null || true
  cp "$prefix/lib/pkgconfig/"*.pc "$out/lib/" 2>/dev/null || true
fi

# Put the shared DLLs in PATH so ffmpeg.exe can find them at runtime.
export PATH="$out/bin:$PATH"
"$out/bin/ffmpeg.exe" -version
sha256sum "$out/bin/ffmpeg.exe" > "$out/ffmpeg.exe.sha256"
tar -czf "$DIST_DIR/ffmpeg-${FFMPEG_VERSION}-windows-x64.tar.gz" -C "$out" .
sha256sum "$DIST_DIR/ffmpeg-${FFMPEG_VERSION}-windows-x64.tar.gz" > "$DIST_DIR/ffmpeg-${FFMPEG_VERSION}-windows-x64.tar.gz.sha256"
