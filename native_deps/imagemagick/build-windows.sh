#!/usr/bin/env bash
# Builds a self-contained x64 ImageMagick runtime for Windows.  All DLLs are
# co-located with magick.exe, so Windows' standard application-directory DLL
# search resolves only the libraries shipped with the App.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGEMAGICK_VERSION="${IMAGEMAGICK_VERSION:-7.1.2-29}"
LIBRAW_VERSION="${LIBRAW_VERSION:-0.22.2}"
WORK_DIR="${WORK_DIR:-$SCRIPT_DIR/work-windows}"
OUTPUT_DIR="${OUTPUT_DIR:-$SCRIPT_DIR/dist-windows}"
PREFIX="$WORK_DIR/prefix"
JOBS="${JOBS:-$(nproc)}"
BUNDLE="$OUTPUT_DIR/imagemagick-windows-x64"

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing required tool: $1" >&2; exit 1; }; }
for tool in autoreconf curl find gcc g++ ldd make pkg-config tar; do need "$tool"; done
download() { [ -f "$2" ] || curl -fL --retry 6 --retry-all-errors --retry-delay 2 --connect-timeout 20 -o "$2" "$1"; }
extract() { mkdir -p "$2"; tar -xf "$1" -C "$2" --strip-components=1; }

rm -rf "$WORK_DIR/sources" "$PREFIX" "$BUNDLE"
mkdir -p "$WORK_DIR/downloads" "$WORK_DIR/sources" "$OUTPUT_DIR"
download "https://codeload.github.com/ImageMagick/ImageMagick/tar.gz/refs/tags/${IMAGEMAGICK_VERSION}" "$WORK_DIR/downloads/imagemagick-${IMAGEMAGICK_VERSION}.tar.gz"
download "https://codeload.github.com/LibRaw/LibRaw/tar.gz/refs/tags/${LIBRAW_VERSION}" "$WORK_DIR/downloads/libraw-${LIBRAW_VERSION}.tar.gz"
extract "$WORK_DIR/downloads/imagemagick-${IMAGEMAGICK_VERSION}.tar.gz" "$WORK_DIR/sources/imagemagick"
extract "$WORK_DIR/downloads/libraw-${LIBRAW_VERSION}.tar.gz" "$WORK_DIR/sources/libraw"
grep -Fq "PACKAGE_VERSION='${IMAGEMAGICK_VERSION}'" "$WORK_DIR/sources/imagemagick/configure" || {
  echo "Downloaded ImageMagick source does not match ${IMAGEMAGICK_VERSION}." >&2
  exit 1
}

(
  cd "$WORK_DIR/sources/libraw"
  autoreconf -fi
  ./configure --prefix="$PREFIX" --enable-shared --disable-static --disable-examples --disable-lcms
  make -j"$JOBS" && make install
)
(
  cd "$WORK_DIR/sources/imagemagick"
  autoreconf -fi
  export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
  export CPPFLAGS="-I$PREFIX/include" LDFLAGS="-L$PREFIX/lib"
  ./configure --prefix="$PREFIX/imagemagick" --enable-shared --disable-static --without-modules \
    --without-perl --without-x --without-fontconfig --without-freetype --without-heic --without-jp2 \
    --without-xml --without-openexr --without-lcms --without-lqr --with-raw --without-rsvg --without-gslib \
    --without-djvu --without-fftw --without-openmp --without-pango --without-cairo --without-gvc \
    --without-jxl --without-openjp2 --without-zip --without-lzma --without-zstd --disable-docs
  make -j"$JOBS" && make install
)

mkdir -p "$BUNDLE/ThirdPartyLicenses/ImageMagick"
cp "$PREFIX/imagemagick/bin/magick.exe" "$BUNDLE/"
cp -R "$PREFIX/imagemagick/etc/ImageMagick-7" "$BUNDLE/"
cp "$SCRIPT_DIR/colors.xml" "$BUNDLE/colors.xml"
cp "$SCRIPT_DIR/colors.xml" "$BUNDLE/ImageMagick-7/colors.xml"
cp "$WORK_DIR/sources/imagemagick/LICENSE" "$BUNDLE/ThirdPartyLicenses/ImageMagick/IMAGEMAGICK-LICENSE.txt"
find "$WORK_DIR/sources/libraw" -maxdepth 1 -type f \( -iname 'license*' -o -iname 'copying*' \) -exec cp {} "$BUNDLE/ThirdPartyLicenses/ImageMagick/" \;

# Copy the complete non-system DLL closure. MSYS runtime itself is excluded:
# release builds use the MinGW UCRT runtime already installed on Windows.
copy_dlls() {
  local binary="$1"
  while IFS= read -r dll; do
    [ -f "$dll" ] || continue
    cp -n "$dll" "$BUNDLE/"
  done < <(ldd "$binary" | awk '/=> \/mingw64\// {print $3}')
}
copy_dlls "$BUNDLE/magick.exe"
# ldd lists direct dependencies only. Repeat until no new DLL is discovered so
# the packaged closure also contains transitive MinGW and delegate DLLs.
while :; do
  before="$(find "$BUNDLE" -maxdepth 1 -type f -name '*.dll' | wc -l)"
  while IFS= read -r dll; do copy_dlls "$dll"; done < <(find "$BUNDLE" -maxdepth 1 -name '*.dll' -type f)
  after="$(find "$BUNDLE" -maxdepth 1 -type f -name '*.dll' | wc -l)"
  [ "$before" = "$after" ] && break
done

formats="$(PATH="$BUNDLE:$PATH" "$BUNDLE/magick.exe" -list format)"
for coder in GIF JPEG PNG WEBP TIFF BMP ICO PSD DNG CR2 NEF ARW; do
  grep -Eq "^[[:space:]]*$coder\\*?[[:space:]]+r[w-]" <<<"$formats" || { echo "Missing required $coder coder" >&2; exit 1; }
done
test -f "$BUNDLE/libraw"*.dll
test -f "$BUNDLE/ThirdPartyLicenses/ImageMagick/IMAGEMAGICK-LICENSE.txt"
test -n "$(find "$BUNDLE/ThirdPartyLicenses/ImageMagick" -maxdepth 1 -type f \( -iname 'license*' -o -iname 'copying*' \) -print -quit)"
PATH="$BUNDLE:$PATH" "$BUNDLE/magick.exe" -version

archive="$OUTPUT_DIR/imagemagick-$IMAGEMAGICK_VERSION-windows-x64.zip"
rm -f "$archive" "$archive.sha256"
(cd "$OUTPUT_DIR" && zip -qr "$(basename "$archive")" "$(basename "$BUNDLE")")
sha256sum "$archive" > "$archive.sha256"
