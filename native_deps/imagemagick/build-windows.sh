#!/usr/bin/env bash
# Builds a self-contained x64 Windows runtime. ImageMagick and LibRaw remain
# dynamic; JPEG, PNG, WebP, TIFF and GIF are linked statically into MagickCore.
set -euo pipefail
trap 'status=$?; echo "Windows ImageMagick build failed at line ${BASH_LINENO[0]}: ${BASH_COMMAND} (exit ${status})" >&2; exit "$status"' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGEMAGICK_VERSION="${IMAGEMAGICK_VERSION:-7.1.2-29}"
LIBRAW_VERSION="${LIBRAW_VERSION:-0.22.2}"
MOZJPEG_VERSION="${MOZJPEG_VERSION:-4.1.1}"
LIBPNG_VERSION="${LIBPNG_VERSION:-1.6.58}"
LIBWEBP_VERSION="${LIBWEBP_VERSION:-1.6.0}"
LIBTIFF_VERSION="${LIBTIFF_VERSION:-4.7.2}"
GIFLIB_VERSION="${GIFLIB_VERSION:-5.2.2}"
WORK_DIR="${WORK_DIR:-$SCRIPT_DIR/work-windows}"
OUTPUT_DIR="${OUTPUT_DIR:-$SCRIPT_DIR/dist-windows}"
PREFIX="$WORK_DIR/delegate-prefix"
JOBS="${JOBS:-$(nproc)}"
BUNDLE="$OUTPUT_DIR/imagemagick-windows-x64"

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing required tool: $1" >&2; exit 1; }; }
for tool in autoreconf cmake curl find gcc g++ ldd make ninja pkg-config tar unzip zip; do need "$tool"; done
download() { [ -f "$2" ] || curl -fL --retry 6 --retry-all-errors --retry-delay 2 --connect-timeout 20 -o "$2" "$1"; }
extract() { mkdir -p "$2"; tar -xf "$1" -C "$2" --strip-components=1; }
build_cmake_static() {
  local source="$1"; shift
  cmake -S "$source" -B "$source/build-x64" -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DBUILD_SHARED_LIBS=OFF "$@"
  cmake --build "$source/build-x64" --parallel "$JOBS"
  cmake --install "$source/build-x64"
}

# Sources and ImageMagick itself are rebuilt cleanly. The versioned delegate
# prefix is safe to restore from Actions cache after its contents are verified.
rm -rf "$WORK_DIR/sources" "$OUTPUT_DIR"
mkdir -p "$WORK_DIR/downloads" "$WORK_DIR/sources" "$OUTPUT_DIR"
download "https://codeload.github.com/ImageMagick/ImageMagick/tar.gz/refs/tags/${IMAGEMAGICK_VERSION}" "$WORK_DIR/downloads/imagemagick-${IMAGEMAGICK_VERSION}.tar.gz"
download "https://codeload.github.com/LibRaw/LibRaw/tar.gz/refs/tags/${LIBRAW_VERSION}" "$WORK_DIR/downloads/libraw-${LIBRAW_VERSION}.tar.gz"
download "https://github.com/mozilla/mozjpeg/archive/refs/tags/v${MOZJPEG_VERSION}.tar.gz" "$WORK_DIR/downloads/mozjpeg-${MOZJPEG_VERSION}.tar.gz"
download "https://github.com/pnggroup/libpng/archive/refs/tags/v${LIBPNG_VERSION}.tar.gz" "$WORK_DIR/downloads/libpng-${LIBPNG_VERSION}.tar.gz"
download "https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-${LIBWEBP_VERSION}.tar.gz" "$WORK_DIR/downloads/libwebp-${LIBWEBP_VERSION}.tar.gz"
download "https://download.osgeo.org/libtiff/tiff-${LIBTIFF_VERSION}.tar.gz" "$WORK_DIR/downloads/libtiff-${LIBTIFF_VERSION}.tar.gz"
download "https://sourceforge.net/projects/giflib/files/giflib-${GIFLIB_VERSION}.tar.gz/download" "$WORK_DIR/downloads/giflib-${GIFLIB_VERSION}.tar.gz"
for component in imagemagick libraw mozjpeg libpng libwebp libtiff giflib; do
  version_var="$(tr '[:lower:]' '[:upper:]' <<<"$component")_VERSION"
  [ "$component" = imagemagick ] && version_var=IMAGEMAGICK_VERSION
  tarball="$WORK_DIR/downloads/$component-${!version_var}.tar.gz"
  extract "$tarball" "$WORK_DIR/sources/$component"
done
grep -Fq "PACKAGE_VERSION='${IMAGEMAGICK_VERSION}'" "$WORK_DIR/sources/imagemagick/configure"

delegate_stamp="$PREFIX/.xfilesuite-delegates-${LIBRAW_VERSION}-${MOZJPEG_VERSION}-${LIBPNG_VERSION}-${LIBWEBP_VERSION}-${LIBTIFF_VERSION}-${GIFLIB_VERSION}"
delegate_cache_valid=true
for cached_file in \
  lib/libjpeg.a lib/libpng16.a lib/libwebp.a lib/libsharpyuv.a lib/libtiff.a lib/libgif.a \
  lib/pkgconfig/libjpeg.pc lib/pkgconfig/libpng.pc lib/pkgconfig/libraw_r.pc lib/pkgconfig/libtiff-4.pc lib/pkgconfig/libwebp.pc; do
  test -f "$PREFIX/$cached_file" || delegate_cache_valid=false
done
find "$PREFIX/bin" -maxdepth 1 -type f -iname '*raw*.dll' -print -quit 2>/dev/null | grep -q . || delegate_cache_valid=false
find "$PREFIX/lib" -maxdepth 1 -type f \( -iname '*raw*.dll.a' -o -iname '*raw*.a' \) -print -quit 2>/dev/null | grep -q . || delegate_cache_valid=false
test -f "$delegate_stamp" || delegate_cache_valid=false

if "$delegate_cache_valid"; then
  echo "Using verified cached ImageMagick delegates."
else
rm -rf "$PREFIX"
mkdir -p "$PREFIX/lib/pkgconfig"
echo "Building static ImageMagick delegates..."
build_cmake_static "$WORK_DIR/sources/mozjpeg" \
  -DENABLE_SHARED=OFF -DENABLE_STATIC=ON -DWITH_TURBOJPEG=OFF -DWITH_JAVA=OFF -DPNG_SUPPORTED=OFF
(
  cd "$WORK_DIR/sources/libpng"
  ./configure --prefix="$PREFIX" --disable-shared --enable-static
  make -j"$JOBS" && make install
)
build_cmake_static "$WORK_DIR/sources/libwebp" \
  -DWEBP_BUILD_ANIM_UTILS=OFF -DWEBP_BUILD_CWEBP=OFF -DWEBP_BUILD_DWEBP=OFF \
  -DWEBP_BUILD_GIF2WEBP=OFF -DWEBP_BUILD_IMG2WEBP=OFF -DWEBP_BUILD_VWEBP=OFF \
  -DWEBP_BUILD_WEBPMUX=OFF -DWEBP_BUILD_EXTRAS=OFF
sed -i '/^Libs:/ s/$/ -lsharpyuv/' "$PREFIX/lib/pkgconfig/libwebp.pc"
build_cmake_static "$WORK_DIR/sources/libtiff" \
  -Dtiff-tools=OFF -Dtiff-tests=OFF -Dtiff-contrib=OFF -Dtiff-docs=OFF \
  -Djpeg=OFF -Dwebp=OFF -Djbig=OFF -Dlerc=OFF -Dlzma=OFF -Dzstd=OFF -Dlibdeflate=OFF
(
  cd "$WORK_DIR/sources/giflib"
  make -j"$JOBS" libgif.a
  mkdir -p "$PREFIX/lib" "$PREFIX/include"
  cp libgif.a "$PREFIX/lib/"
  cp gif_lib.h "$PREFIX/include/"
)

echo "Building dynamic LibRaw..."
(
  cd "$WORK_DIR/sources/libraw"
  autoreconf -fi
  export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig:/mingw64/lib/pkgconfig"
  CPPFLAGS="-I$PREFIX/include" LDFLAGS="-L$PREFIX/lib" \
    ./configure --prefix="$PREFIX" --enable-shared --disable-static --disable-examples --disable-lcms
  make -j"$JOBS" && make install
)
touch "$delegate_stamp"
fi

echo "Building dynamic ImageMagick against the private prefix..."
(
  cd "$WORK_DIR/sources/imagemagick"
  export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig:/mingw64/lib/pkgconfig"
  export CPPFLAGS="-I$PREFIX/include" LDFLAGS="-L$PREFIX/lib"
  unset LIBS
  for module in libjpeg libpng libraw_r libtiff-4 libwebp libwebpmux libwebpdemux; do
    pkg-config --exists "$module" || { pkg-config --print-errors --exists "$module" >&2 || true; exit 1; }
  done
  printf 'int main(void) { return 0; }\n' > .xfilesuite-delegate-smoke.c
  gcc .xfilesuite-delegate-smoke.c $(pkg-config --static --libs libjpeg libpng libraw_r libtiff-4 libwebp libwebpmux libwebpdemux) \
    -L"$PREFIX/lib" -o .xfilesuite-delegate-smoke.exe
  ./.xfilesuite-delegate-smoke.exe
  rm -f .xfilesuite-delegate-smoke.c .xfilesuite-delegate-smoke.exe
  ./configure --prefix="$PREFIX/imagemagick" --enable-shared --disable-static --without-modules \
    --without-perl --without-x --without-fontconfig --without-freetype --without-heic \
    --without-xml --without-openexr --without-lcms --without-lqr --with-raw --without-rsvg --without-gslib \
    --without-djvu --without-fftw --disable-openmp --without-pango --without-gvc --without-jbig \
    --without-jxl --without-openjp2 --without-zip --without-lzma --without-zstd --disable-docs
  for delegate in JPEG PNG TIFF WEBP ZLIB; do
    grep -Eq "^#define ${delegate}_DELEGATE 1$" config/config.h || { echo "Missing $delegate delegate" >&2; exit 1; }
  done
  # GNU libtool refuses ordinary external .a arguments when producing a
  # Windows DLL. Pass the pinned private archives through to ld instead and
  # append them to MagickCore's real LIBADD variable (not the unused top-level
  # LIBS variable). This preserves link order and cannot select MSYS2 import
  # libraries with the same names.
  test -f /mingw64/lib/libz.a
  test -f /mingw64/lib/libbz2.a
  static_delegate_ldflags=" -Wl,--start-group"
  for archive_name in libtiff.a libjpeg.a libpng16.a libwebpmux.a libwebpdemux.a libwebp.a libsharpyuv.a libgif.a; do
    test -f "$PREFIX/lib/$archive_name"
    static_delegate_ldflags+=",$PREFIX/lib/$archive_name"
  done
  static_delegate_ldflags+=",/mingw64/lib/libz.a,/mingw64/lib/libbz2.a,--end-group"
  # Automake emits this assignment as a continued line. Insert before its
  # trailing backslash; appending after it turns the next line into a recipe.
  sed -i "/^MagickCore_libMagickCore_7_Q16HDRI_la_LIBADD =/ s|[[:space:]]*\\\\$|$static_delegate_ldflags \\\\|" Makefile
  make -n MagickCore/libMagickCore-7.Q16HDRI.la >/dev/null
  make -j"$JOBS" && make install
)

echo "Assembling and verifying the Windows runtime..."
mkdir -p "$BUNDLE/ThirdPartyLicenses/ImageMagick"
cp "$PREFIX/imagemagick/bin/magick.exe" "$BUNDLE/"
find "$PREFIX/imagemagick/bin" "$PREFIX/bin" -maxdepth 1 -type f -iname '*.dll' -exec cp {} "$BUNDLE/" \;
cp -R "$PREFIX/imagemagick/etc/ImageMagick-7" "$BUNDLE/"
cp "$SCRIPT_DIR/colors.xml" "$BUNDLE/colors.xml"
cp "$SCRIPT_DIR/colors.xml" "$BUNDLE/ImageMagick-7/colors.xml"
license_dir="$BUNDLE/ThirdPartyLicenses/ImageMagick"
cp "$WORK_DIR/sources/imagemagick/LICENSE" "$license_dir/IMAGEMAGICK-LICENSE.txt"
find "$WORK_DIR/sources/libraw" -maxdepth 1 -type f \( -iname 'license*' -o -iname 'copying*' \) -exec cp {} "$license_dir/" \;
cp "$WORK_DIR/sources/mozjpeg/LICENSE.md" "$license_dir/MOZJPEG-LICENSE.md"
cp "$WORK_DIR/sources/libpng/LICENSE" "$license_dir/LIBPNG-LICENSE.txt"
cp "$WORK_DIR/sources/libwebp/COPYING" "$license_dir/LIBWEBP-LICENSE.txt"
cp "$WORK_DIR/sources/libtiff/LICENSE.md" "$license_dir/LIBTIFF-LICENSE.md"
cp "$WORK_DIR/sources/giflib/COPYING" "$license_dir/GIFLIB-LICENSE.txt"

copy_dlls() {
  local binary="$1"
  while IFS= read -r dll; do [ -f "$dll" ] && cp -n "$dll" "$BUNDLE/"; done \
    < <(ldd "$binary" | awk '/=> \/mingw64\// {print $3}')
}
while :; do
  before="$(find "$BUNDLE" -maxdepth 1 -type f -iname '*.dll' | wc -l)"
  copy_dlls "$BUNDLE/magick.exe"
  while IFS= read -r dll; do copy_dlls "$dll"; done < <(find "$BUNDLE" -maxdepth 1 -type f -iname '*.dll')
  after="$(find "$BUNDLE" -maxdepth 1 -type f -iname '*.dll' | wc -l)"
  [ "$before" = "$after" ] && break
done

unexpected="$(find "$BUNDLE" -maxdepth 1 -type f \( -iname 'libjpeg*.dll' -o -iname 'libpng*.dll' -o -iname 'libwebp*.dll' -o -iname 'libtiff*.dll' -o -iname 'libgif*.dll' \) -print)"
[ -z "$unexpected" ] || { echo "Delegates that must be static were packaged as DLLs:" >&2; echo "$unexpected" >&2; exit 1; }
find "$BUNDLE" -maxdepth 1 -type f -iname '*raw*.dll' -print -quit | grep -q . || { echo "Missing LibRaw DLL" >&2; exit 1; }
formats="$(PATH="$BUNDLE:$PATH" "$BUNDLE/magick.exe" -list format)"
for coder in GIF JPEG PNG WEBP TIFF BMP ICO PSD DNG CR2 NEF ARW; do
  grep -Eq "^[[:space:]]*$coder\\*?[[:space:]]+r[w-]" <<<"$formats" || { echo "Missing required $coder coder" >&2; exit 1; }
done
for license in IMAGEMAGICK-LICENSE.txt MOZJPEG-LICENSE.md LIBPNG-LICENSE.txt LIBWEBP-LICENSE.txt LIBTIFF-LICENSE.md GIFLIB-LICENSE.txt; do
  test -f "$license_dir/$license"
done
PATH="$BUNDLE:$PATH" "$BUNDLE/magick.exe" -version

archive="$OUTPUT_DIR/imagemagick-$IMAGEMAGICK_VERSION-windows-x64.zip"
(cd "$OUTPUT_DIR" && zip -qr "$(basename "$archive")" "$(basename "$BUNDLE")")
verify_dir="$WORK_DIR/archive-verify"
rm -rf "$verify_dir"; mkdir -p "$verify_dir"
unzip -q "$archive" -d "$verify_dir"
verify_bundle="$verify_dir/$(basename "$BUNDLE")"
PATH="$verify_bundle:$PATH" "$verify_bundle/magick.exe" -version
rm -rf "$verify_dir"
sha256sum "$archive" > "$archive.sha256"
