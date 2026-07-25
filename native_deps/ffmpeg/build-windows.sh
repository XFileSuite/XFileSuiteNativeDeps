#!/usr/bin/env bash
# Builds the LGPL-only FFmpeg command-line tools for Windows x64 under MSYS2.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${WORK_DIR:-$ROOT_DIR/work-windows}"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist-windows}"
FFMPEG_VERSION="${FFMPEG_VERSION:-8.0.1}"
JOBS="${JOBS:-$(nproc)}"

command -v pacman >/dev/null || { echo "Run this script inside MSYS2." >&2; exit 1; }
for tool in curl tar make pkg-config; do command -v "$tool" >/dev/null || { echo "Missing $tool" >&2; exit 1; }; done

# The workflow installs these exact MSYS2 packages.  Keeping the dependency list
# here makes a local rebuild use the same LGPL/BSD codec set as macOS.
for package in mingw-w64-x86_64-gcc mingw-w64-x86_64-nasm mingw-w64-x86_64-pkgconf \
  mingw-w64-x86_64-lame mingw-w64-x86_64-libogg mingw-w64-x86_64-libvorbis mingw-w64-x86_64-libvpx; do
  pacman -Q "$package" >/dev/null || { echo "Missing MSYS2 package: $package" >&2; exit 1; }
done

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
    --disable-shared --enable-static --disable-debug --disable-doc --disable-network \
    --disable-gpl --disable-nonfree --disable-version3 \
    --enable-libmp3lame --enable-libvorbis --enable-libvpx \
    --extra-libs='-lstdc++ -lws2_32 -lbcrypt -lz'
  make -j"$JOBS"
  make install
)

out="$DIST_DIR/ffmpeg-${FFMPEG_VERSION}-windows-x64"
rm -rf "$out"
mkdir -p "$out"
cp "$prefix/bin/ffmpeg.exe" "$out/ffmpeg.exe"
cp "$prefix/bin/ffprobe.exe" "$out/ffprobe.exe"
strip "$out/ffmpeg.exe" "$out/ffprobe.exe" || true
"$out/ffmpeg.exe" -version
sha256sum "$out/ffmpeg.exe" > "$out/ffmpeg.exe.sha256"
tar -czf "$DIST_DIR/ffmpeg-${FFMPEG_VERSION}-windows-x64.tar.gz" -C "$out" ffmpeg.exe ffprobe.exe
sha256sum "$DIST_DIR/ffmpeg-${FFMPEG_VERSION}-windows-x64.tar.gz" > "$DIST_DIR/ffmpeg-${FFMPEG_VERSION}-windows-x64.tar.gz.sha256"
