#!/usr/bin/env bash
# Builds a self-contained x64 Windows runtime. ImageMagick, LibRaw, and all
# pinned image delegates (MozJPEG, PNG, WebP, TIFF, GIF) are shared DLLs so
# App-side FFI can load them independently. zlib/bzip2 come from MinGW.
# Also ships native-headers/ (MagickWand, LibRaw, MozJPEG, PNG, WebP, TIFF,
# GIF public headers) for App-side FFI; fetch-deps can deploy selected trees
# later and strips them from the runtime folder.
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
# Prefer MinGW objdump for native PE files (MSYS /usr/bin/objdump is less reliable).
if [[ -x /mingw64/bin/objdump ]]; then
  OBJDUMP=/mingw64/bin/objdump
else
  OBJDUMP="$(command -v objdump)"
fi
export OBJDUMP
# p7zip provides 7z (preferred) or 7za. Info-ZIP zip/unzip has corrupted large MinGW
# DLLs on GHA (PE header becomes "MS-DOS MZ only" after round-trip).
if command -v 7z >/dev/null 2>&1; then
  SEVEN_ZIP=(7z)
elif command -v 7za >/dev/null 2>&1; then
  SEVEN_ZIP=(7za)
else
  echo "Missing required tool: 7z (p7zip)" >&2
  exit 1
fi
for tool in autoreconf cmake curl find gcc g++ ldd make ninja pkg-config tar unzip; do need "$tool"; done
download() {
  [ -f "$2" ] && return 0
  extra=()
  token="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
  if [[ -n "$token" && "$1" == *github.com* ]]; then
    extra+=(-H "Authorization: Bearer $token" -H "User-Agent: XFileSuiteNativeDeps")
  fi
  curl -fL --retry 6 --retry-all-errors --retry-delay 2 --connect-timeout 20 "${extra[@]}" -o "$2" "$1"
}
extract() { mkdir -p "$2"; tar -xf "$1" -C "$2" --strip-components=1; }
build_cmake_shared() {
  local source="$1"; shift
  cmake -S "$source" -B "$source/build-x64" -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DBUILD_SHARED_LIBS=ON "$@"
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
patch -d "$WORK_DIR/sources/imagemagick" -p1 < "$SCRIPT_DIR/patches/imagemagick-mozjpeg-options.patch"
patch -d "$WORK_DIR/sources/imagemagick" -p1 < "$SCRIPT_DIR/patches/imagemagick-libraw-controls.patch"
for control in half_size bright auto_bright_thr highlight exp_shift exp_preser; do
  grep -Fq "raw_info->params.$control=" "$WORK_DIR/sources/imagemagick/coders/dng.c" || {
    echo "ImageMagick DNG coder is missing LibRaw control: $control" >&2
    exit 1
  }
done
test "$(grep -c 'raw_info->params.exp_correc=1;' "$WORK_DIR/sources/imagemagick/coders/dng.c")" -eq 1 || {
  echo "ImageMagick DNG exposure controls do not enable LibRaw exposure correction." >&2
  exit 1
}
test "$(grep -c 'exposure_correction=MagickTrue;' "$WORK_DIR/sources/imagemagick/coders/dng.c")" -eq 2 || {
  echo "Both ImageMagick DNG exposure controls must activate exposure correction." >&2
  exit 1
}
grep -Fq "PACKAGE_VERSION='${IMAGEMAGICK_VERSION}'" "$WORK_DIR/sources/imagemagick/configure"

delegate_stamp="$PREFIX/.xfilesuite-delegates-shared-v4-${LIBRAW_VERSION}-${MOZJPEG_VERSION}-${LIBPNG_VERSION}-${LIBWEBP_VERSION}-${LIBTIFF_VERSION}-${GIFLIB_VERSION}"
delegate_cache_valid=true
for cached_file in \
  lib/libjpeg.dll.a lib/libpng.dll.a lib/libwebp.dll.a lib/libtiff.dll.a \
  lib/pkgconfig/libjpeg.pc lib/pkgconfig/libpng.pc lib/pkgconfig/libraw_r.pc \
  lib/pkgconfig/libtiff-4.pc lib/pkgconfig/libwebp.pc; do
  test -f "$PREFIX/$cached_file" || delegate_cache_valid=false
done
# libpng may install as libpng16.dll.a depending on version/soname.
if [[ ! -f "$PREFIX/lib/libpng.dll.a" && ! -f "$PREFIX/lib/libpng16.dll.a" ]]; then
  delegate_cache_valid=false
fi
find "$PREFIX/bin" -maxdepth 1 -type f -iname '*jpeg*.dll' -print -quit 2>/dev/null | grep -q . || delegate_cache_valid=false
find "$PREFIX/bin" -maxdepth 1 -type f -iname '*png*.dll' -print -quit 2>/dev/null | grep -q . || delegate_cache_valid=false
find "$PREFIX/bin" -maxdepth 1 -type f -iname '*webp*.dll' -print -quit 2>/dev/null | grep -q . || delegate_cache_valid=false
find "$PREFIX/bin" -maxdepth 1 -type f -iname '*tiff*.dll' -print -quit 2>/dev/null | grep -q . || delegate_cache_valid=false
find "$PREFIX/bin" -maxdepth 1 -type f -iname '*gif*.dll' -print -quit 2>/dev/null | grep -q . || delegate_cache_valid=false
find "$PREFIX/bin" -maxdepth 1 -type f -iname '*raw*.dll' -print -quit 2>/dev/null | grep -q . || delegate_cache_valid=false
find "$PREFIX/lib" -maxdepth 1 -type f \( -iname '*raw*.dll.a' -o -iname '*raw*.a' \) -print -quit 2>/dev/null | grep -q . || delegate_cache_valid=false
test -f "$delegate_stamp" || delegate_cache_valid=false

if "$delegate_cache_valid"; then
  echo "Using verified cached ImageMagick delegates."
else
rm -rf "$PREFIX"
mkdir -p "$PREFIX/lib/pkgconfig"
echo "Building ImageMagick delegates as shared libraries..."
cmake -S "$WORK_DIR/sources/mozjpeg" -B "$WORK_DIR/sources/mozjpeg/build-x64" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DENABLE_SHARED=ON -DENABLE_STATIC=OFF \
  -DWITH_TURBOJPEG=OFF -DWITH_JAVA=OFF -DPNG_SUPPORTED=OFF
cmake --build "$WORK_DIR/sources/mozjpeg/build-x64" --parallel "$JOBS"
cmake --install "$WORK_DIR/sources/mozjpeg/build-x64"
(
  cd "$WORK_DIR/sources/libpng"
  ./configure --prefix="$PREFIX" --enable-shared --disable-static
  make -j"$JOBS" && make install
)
build_cmake_shared "$WORK_DIR/sources/libwebp" \
  -DWEBP_BUILD_ANIM_UTILS=OFF -DWEBP_BUILD_CWEBP=OFF -DWEBP_BUILD_DWEBP=OFF \
  -DWEBP_BUILD_GIF2WEBP=OFF -DWEBP_BUILD_IMG2WEBP=OFF -DWEBP_BUILD_VWEBP=OFF \
  -DWEBP_BUILD_WEBPMUX=OFF -DWEBP_BUILD_EXTRAS=OFF
build_cmake_shared "$WORK_DIR/sources/libtiff" \
  -Dtiff-tools=OFF -Dtiff-tests=OFF -Dtiff-contrib=OFF -Dtiff-docs=OFF \
  -Djpeg=OFF -Dwebp=OFF -Djbig=OFF -Dlerc=OFF -Dlzma=OFF -Dzstd=OFF -Dlibdeflate=OFF
(
  cd "$WORK_DIR/sources/giflib"
  make clean >/dev/null 2>&1 || true
  make -j"$JOBS" libgif.a
  # giflib only ships a static archive; emit a MinGW DLL + import library.
  gcc -shared -o libgif-7.dll *.o -Wl,--out-implib,libgif.dll.a
  mkdir -p "$PREFIX/bin" "$PREFIX/lib" "$PREFIX/include" "$PREFIX/lib/pkgconfig"
  cp libgif-7.dll "$PREFIX/bin/"
  cp libgif.dll.a "$PREFIX/lib/"
  cp gif_lib.h "$PREFIX/include/"
  cat > "$PREFIX/lib/pkgconfig/giflib.pc" <<EOF
prefix=$PREFIX
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: giflib
Description: GIF library
Version: ${GIFLIB_VERSION}
Libs: -L\${libdir} -lgif
Cflags: -I\${includedir}
EOF
)

echo "Building dynamic LibRaw..."
(
  cd "$WORK_DIR/sources/libraw"
  autoreconf -fi
  export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig:/mingw64/lib/pkgconfig"
  CPPFLAGS="-I$PREFIX/include" LDFLAGS="-L$PREFIX/lib" \
    ./configure --prefix="$PREFIX" --enable-shared --disable-static --disable-examples --disable-lcms --enable-jpeg
  grep -Eq '(^|[[:space:]])-DUSE_JPEG([[:space:]]|$)' Makefile || {
    echo "LibRaw did not enable MozJPEG support for lossy DNG." >&2
    exit 1
  }
  make -j"$JOBS" && make install
)
touch "$delegate_stamp"
fi
# ImageMagick is deliberately not part of the delegate cache. Older cache
# entries may contain it because both previously shared a prefix.
rm -rf "$PREFIX/imagemagick"

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
  gcc .xfilesuite-delegate-smoke.c \
    $(pkg-config --libs libjpeg libpng libraw_r libtiff-4 libwebp libwebpmux libwebpdemux) \
    -lgif \
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
  # All image delegates are shared DLLs now. zlib/bzip2 remain MinGW runtime
  # import libraries; Magick's normal link line resolves them.
  make -n MagickCore/libMagickCore-7.Q16HDRI.la >/dev/null
  make -j"$JOBS" && make install
)

echo "Assembling and verifying the Windows runtime..."
mkdir -p "$BUNDLE/ThirdPartyLicenses/ImageMagick"

# True PE check via MZ + PE signature (does not depend on objdump).
is_pe_file() {
  local path="$1" pe_offset pe_magic
  [[ -f "$path" && ! -L "$path" ]] || return 1
  [[ "$(od -An -N2 -tx1 "$path" | tr -d ' \n')" == "4d5a" ]] || return 1
  pe_offset="$(od -An -j60 -N4 -tu4 "$path" | tr -d ' ')"
  [[ -n "$pe_offset" && "$pe_offset" -gt 0 && "$pe_offset" -lt 4096 ]] || return 1
  pe_magic="$(od -An -j"$pe_offset" -N4 -tx1 "$path" | tr -d ' \n')"
  [[ "$pe_magic" == "50450000" ]]
}

require_pe_dll() {
  local path="$1"
  local label="$2"
  if [[ ! -f "$path" ]]; then
    echo "Missing $label: $path" >&2
    return 1
  fi
  if [[ -L "$path" ]]; then
    echo "$label is a symlink (refusing to ship libtool link stubs): $path -> $(readlink "$path" 2>/dev/null || true)" >&2
    return 1
  fi
  if ! is_pe_file "$path"; then
    echo "$label is not a PE DLL: $path" >&2
    ls -la "$path" >&2 || true
    file "$path" >&2 || true
    od -An -N64 -tx1 "$path" >&2 || true
    return 1
  fi
  if ! "$OBJDUMP" -p "$path" >/dev/null 2>&1; then
    echo "$label has a PE signature but $OBJDUMP cannot parse it: $path" >&2
    return 1
  fi
}

# Copy only real PE DLLs into the bundle (never libtool symlink stubs).
install_pe_dll() {
  local src="$1"
  local dest="$2"
  local label="${3:-$(basename "$dest")}"
  [[ -e "$src" ]] || { echo "Missing source DLL for $label: $src" >&2; return 1; }
  cp -fL "$src" "$dest"
  require_pe_dll "$dest" "$label"
}

drop_unwanted_runtime_names() {
  rm -f "$BUNDLE"/libraw-[0-9]*.dll \
    "$BUNDLE"/libraw.dll \
    "$BUNDLE"/libraw_r.dll \
    "$BUNDLE"/libjpeg.dll
}

install_pe_dll "$PREFIX/imagemagick/bin/magick.exe" "$BUNDLE/magick.exe" "magick.exe"

# Prefer regular files from the install prefix. Follow links only when the
# resolved target is itself a PE file.
while IFS= read -r -d '' dll; do
  name="$(basename "$dll")"
  case "$name" in
    libraw.dll|libraw_r.dll|libjpeg.dll|libraw-[0-9]*.dll) continue ;;
  esac
  if [[ -L "$dll" ]]; then
    target="$(readlink -f "$dll" 2>/dev/null || readlink "$dll" || true)"
    [[ -n "$target" && -f "$target" ]] || continue
    is_pe_file "$target" || continue
    install_pe_dll "$target" "$BUNDLE/$name" "$name" || continue
  else
    is_pe_file "$dll" || continue
    install_pe_dll "$dll" "$BUNDLE/$name" "$name" || continue
  fi
done < <(find "$PREFIX/imagemagick/bin" "$PREFIX/bin" -maxdepth 1 \( -type f -o -type l \) -iname '*.dll' -print0)

drop_unwanted_runtime_names

# Force the versioned thread-safe LibRaw + MozJPEG sonames we validate against.
raw_src="$(find "$PREFIX/bin" -maxdepth 1 -type f -iname 'libraw_r-[0-9]*.dll' -print -quit)"
test -n "$raw_src" || { echo "PREFIX is missing versioned libraw_r-*.dll" >&2; exit 1; }
install_pe_dll "$raw_src" "$BUNDLE/$(basename "$raw_src")" "LibRaw"
test -f "$PREFIX/bin/libjpeg-62.dll" || { echo "PREFIX is missing libjpeg-62.dll" >&2; exit 1; }
install_pe_dll "$PREFIX/bin/libjpeg-62.dll" "$BUNDLE/libjpeg-62.dll" "MozJPEG"

cp -R "$PREFIX/imagemagick/etc/ImageMagick-7" "$BUNDLE/"
cp "$SCRIPT_DIR/colors.xml" "$BUNDLE/colors.xml"
cp "$SCRIPT_DIR/colors.xml" "$BUNDLE/ImageMagick-7/colors.xml"
license_dir="$BUNDLE/ThirdPartyLicenses/ImageMagick"
cp "$WORK_DIR/sources/imagemagick/LICENSE" "$license_dir/IMAGEMAGICK-LICENSE.txt"
libraw_license_count=0
while IFS= read -r -d '' license; do
  cp "$license" "$license_dir/LIBRAW-$(basename "$license")"
  libraw_license_count=$((libraw_license_count + 1))
done < <(find "$WORK_DIR/sources/libraw" -maxdepth 1 -type f \( -iname 'license*' -o -iname 'copying*' \) -print0)
[ "$libraw_license_count" -gt 0 ] || { echo "LibRaw source contains no distributable license files" >&2; exit 1; }
cp "$WORK_DIR/sources/mozjpeg/LICENSE.md" "$license_dir/MOZJPEG-LICENSE.md"
cp "$WORK_DIR/sources/libpng/LICENSE" "$license_dir/LIBPNG-LICENSE.txt"
cp "$WORK_DIR/sources/libwebp/COPYING" "$license_dir/LIBWEBP-LICENSE.txt"
cp "$WORK_DIR/sources/libtiff/LICENSE.md" "$license_dir/LIBTIFF-LICENSE.md"
cp "$WORK_DIR/sources/giflib/COPYING" "$license_dir/GIFLIB-LICENSE.txt"

copy_dlls() {
  local binary="$1"
  local dll name
  while IFS= read -r dll; do
    [ -f "$dll" ] || continue
    name="$(basename "$dll")"
    case "$name" in
      libraw.dll|libraw_r.dll|libjpeg.dll|libraw-[0-9]*.dll) continue ;;
    esac
    if [[ -f "$BUNDLE/$name" ]]; then
      continue
    fi
    is_pe_file "$dll" || continue
    install_pe_dll "$dll" "$BUNDLE/$name" "$name" || true
  done < <(ldd "$binary" | awk '/=> \/mingw64\// {print $3}')
}
while :; do
  before="$(find "$BUNDLE" -maxdepth 1 -type f -iname '*.dll' | wc -l)"
  copy_dlls "$BUNDLE/magick.exe"
  while IFS= read -r dll; do copy_dlls "$dll"; done < <(find "$BUNDLE" -maxdepth 1 -type f -iname '*.dll')
  after="$(find "$BUNDLE" -maxdepth 1 -type f -iname '*.dll' | wc -l)"
  [ "$before" = "$after" ] && break
done
drop_unwanted_runtime_names
# Re-assert critical sonames after dependency walking.
install_pe_dll "$raw_src" "$BUNDLE/$(basename "$raw_src")" "LibRaw"
install_pe_dll "$PREFIX/bin/libjpeg-62.dll" "$BUNDLE/libjpeg-62.dll" "MozJPEG"

# Drop any non-PE *.dll that slipped in (symlink stubs, import libs renamed, etc.).
while IFS= read -r -d '' dll; do
  if ! is_pe_file "$dll"; then
    echo "Removing non-PE file from bundle: $dll" >&2
    rm -f "$dll"
  fi
done < <(find "$BUNDLE" -maxdepth 1 -type f -iname '*.dll' -print0)

echo "Packaging MagickWand + shared-delegate public headers..."
headers_root="$BUNDLE/native-headers"
rm -rf "$headers_root"
prefix_include="$PREFIX/include"
im_include="$PREFIX/imagemagick/include/ImageMagick-7"
mkdir -p \
  "$headers_root/imagemagick-${IMAGEMAGICK_VERSION}" \
  "$headers_root/libraw-${LIBRAW_VERSION}/libraw" \
  "$headers_root/mozjpeg-${MOZJPEG_VERSION}" \
  "$headers_root/libpng-${LIBPNG_VERSION}" \
  "$headers_root/libwebp-${LIBWEBP_VERSION}/webp" \
  "$headers_root/libtiff-${LIBTIFF_VERSION}" \
  "$headers_root/giflib-${GIFLIB_VERSION}"

test -f "$im_include/MagickWand/MagickWand.h"
test -f "$prefix_include/libraw/libraw.h"
test -f "$prefix_include/jpeglib.h"
test -f "$prefix_include/png.h"
test -f "$prefix_include/webp/decode.h"
test -f "$prefix_include/tiffio.h"
test -f "$prefix_include/gif_lib.h"

cp -R "$im_include/MagickWand" "$headers_root/imagemagick-${IMAGEMAGICK_VERSION}/"
cp -R "$im_include/MagickCore" "$headers_root/imagemagick-${IMAGEMAGICK_VERSION}/"
cp -R "$prefix_include/libraw/." "$headers_root/libraw-${LIBRAW_VERSION}/libraw/"
for hdr in jpeglib.h jconfig.h jerror.h jmorecfg.h; do
  test -f "$prefix_include/$hdr"
  cp "$prefix_include/$hdr" "$headers_root/mozjpeg-${MOZJPEG_VERSION}/"
done
for hdr in png.h pngconf.h pnglibconf.h; do
  test -f "$prefix_include/$hdr"
  cp "$prefix_include/$hdr" "$headers_root/libpng-${LIBPNG_VERSION}/"
done
cp -R "$prefix_include/webp/." "$headers_root/libwebp-${LIBWEBP_VERSION}/webp/"
find "$prefix_include" -maxdepth 1 -type f \( -name 'tiff*.h' -o -name 'tiffconf.h' \) -print0 |
  while IFS= read -r -d '' hdr; do
    cp "$hdr" "$headers_root/libtiff-${LIBTIFF_VERSION}/"
  done
test -f "$headers_root/libtiff-${LIBTIFF_VERSION}/tiffio.h"
cp "$prefix_include/gif_lib.h" "$headers_root/giflib-${GIFLIB_VERSION}/"

cat > "$headers_root/versions.env" <<EOF
IMAGEMAGICK_VERSION=${IMAGEMAGICK_VERSION}
LIBRAW_VERSION=${LIBRAW_VERSION}
MOZJPEG_VERSION=${MOZJPEG_VERSION}
LIBPNG_VERSION=${LIBPNG_VERSION}
LIBWEBP_VERSION=${LIBWEBP_VERSION}
LIBTIFF_VERSION=${LIBTIFF_VERSION}
GIFLIB_VERSION=${GIFLIB_VERSION}
EOF

test -f "$headers_root/imagemagick-${IMAGEMAGICK_VERSION}/MagickWand/MagickWand.h"
test -f "$headers_root/libraw-${LIBRAW_VERSION}/libraw/libraw.h"
test -f "$headers_root/mozjpeg-${MOZJPEG_VERSION}/jpeglib.h"
test -f "$headers_root/libpng-${LIBPNG_VERSION}/png.h"
test -f "$headers_root/libwebp-${LIBWEBP_VERSION}/webp/decode.h"
test -f "$headers_root/libtiff-${LIBTIFF_VERSION}/tiffio.h"
test -f "$headers_root/giflib-${GIFLIB_VERSION}/gif_lib.h"

dll_depends_on() {
  local binary="$1"
  local needed="$2"
  # Prefer the import table — more stable than MSYS ldd path resolution after unzip.
  "$OBJDUMP" -p "$binary" 2>/dev/null | grep -Ei 'DLL Name:' | grep -Fqi "$needed" && return 0
  ldd "$binary" 2>/dev/null | grep -Fqi "$needed"
}

validate_bundle() {
  local bundle="$1" formats coder test_dir bundled_license_dir license raw_dll core_dll jpeg_dll jpeg_dll_name
  local png_dll webp_dll tiff_dll gif_dll
  # Prefer the versioned soname (libraw_r-25.dll). Unversioned libraw_r.dll is a
  # libtool development symlink / non-PE stub.
  raw_dll="$(find "$bundle" -maxdepth 1 -type f -iname 'libraw_r-[0-9]*.dll' -print -quit)"
  test -n "$raw_dll" || { echo "Missing LibRaw DLL (libraw_r-<ver>.dll)" >&2; return 1; }
  jpeg_dll="$(find "$bundle" -maxdepth 1 -type f -iname 'libjpeg-62.dll' -print -quit)"
  if [[ -z "$jpeg_dll" ]]; then
    jpeg_dll="$(find "$bundle" -maxdepth 1 -type f -iname 'libjpeg-[0-9]*.dll' -print -quit)"
  fi
  test -n "$jpeg_dll" || { echo "Missing shared MozJPEG DLL" >&2; return 1; }
  core_dll="$(find "$bundle" -maxdepth 1 -type f -iname '*MagickCore-[0-9]*.dll' -print -quit)"
  if [[ -z "$core_dll" ]]; then
    core_dll="$(find "$bundle" -maxdepth 1 -type f -iname '*MagickCore*.dll' -print -quit)"
  fi
  test -n "$core_dll" || { echo "Missing MagickCore DLL" >&2; return 1; }
  png_dll="$(find "$bundle" -maxdepth 1 -type f -iname 'libpng*.dll' -print -quit)"
  webp_dll="$(find "$bundle" -maxdepth 1 -type f -iname 'libwebp-*.dll' -print -quit)"
  if [[ -z "$webp_dll" ]]; then
    webp_dll="$(find "$bundle" -maxdepth 1 -type f -iname 'libwebp.dll' -print -quit)"
  fi
  tiff_dll="$(find "$bundle" -maxdepth 1 -type f -iname 'libtiff-*.dll' -print -quit)"
  if [[ -z "$tiff_dll" ]]; then
    tiff_dll="$(find "$bundle" -maxdepth 1 -type f -iname 'libtiff.dll' -print -quit)"
  fi
  gif_dll="$(find "$bundle" -maxdepth 1 -type f -iname 'libgif*.dll' -print -quit)"
  test -n "$png_dll" || { echo "Missing shared libpng DLL" >&2; return 1; }
  test -n "$webp_dll" || { echo "Missing shared libwebp DLL" >&2; return 1; }
  test -n "$tiff_dll" || { echo "Missing shared libtiff DLL" >&2; return 1; }
  test -n "$gif_dll" || { echo "Missing shared libgif DLL" >&2; return 1; }
  find "$bundle" -maxdepth 1 -type f -iname 'libsharpyuv*.dll' -print -quit | grep -q . || {
    echo "Missing shared SharpYUV DLL (libwebp dependency)" >&2
    return 1
  }
  require_pe_dll "$raw_dll" "LibRaw" || return 1
  require_pe_dll "$jpeg_dll" "MozJPEG" || return 1
  require_pe_dll "$core_dll" "MagickCore" || return 1
  require_pe_dll "$png_dll" "libpng" || return 1
  require_pe_dll "$webp_dll" "libwebp" || return 1
  require_pe_dll "$tiff_dll" "libtiff" || return 1
  require_pe_dll "$gif_dll" "libgif" || return 1
  jpeg_dll_name="$(basename "$jpeg_dll")"
  echo "Checking PE imports: $(basename "$raw_dll") → $jpeg_dll_name"
  if ! dll_depends_on "$raw_dll" "$jpeg_dll_name"; then
    echo "LibRaw is not dynamically linked to MozJPEG $jpeg_dll_name" >&2
    echo "--- ldd ---" >&2
    ldd "$raw_dll" >&2 || true
    echo "--- objdump DLL Name ---" >&2
    "$OBJDUMP" -p "$raw_dll" 2>/dev/null | grep -Ei 'DLL Name:' >&2 || true
    return 1
  fi
  if ! dll_depends_on "$core_dll" "$jpeg_dll_name"; then
    echo "MagickCore is not dynamically linked to MozJPEG $jpeg_dll_name" >&2
    echo "--- ldd ---" >&2
    ldd "$core_dll" >&2 || true
    echo "--- objdump DLL Name ---" >&2
    "$OBJDUMP" -p "$core_dll" 2>/dev/null | grep -Ei 'DLL Name:' >&2 || true
    return 1
  fi
  # PNG/WebP/TIFF must be dynamically imported by MagickCore. giflib is shipped
  # for App FFI only: ImageMagick 7 uses its built-in GIF coder and does not
  # import libgif-*.dll (GIF is absent from Magick's DELEGATES / LIBS).
  for needed in "$(basename "$png_dll")" "$(basename "$webp_dll")" "$(basename "$tiff_dll")"; do
    if ! dll_depends_on "$core_dll" "$needed"; then
      echo "MagickCore is not dynamically linked to $needed" >&2
      "$OBJDUMP" -p "$core_dll" 2>/dev/null | grep -Ei 'DLL Name:' >&2 || true
      return 1
    fi
    echo "Checking PE imports: $(basename "$core_dll") → $needed"
  done
  echo "Checking PE presence: standalone giflib → $(basename "$gif_dll")"
  bundled_license_dir="$bundle/ThirdPartyLicenses/ImageMagick"
  for license in IMAGEMAGICK-LICENSE.txt MOZJPEG-LICENSE.md LIBPNG-LICENSE.txt LIBWEBP-LICENSE.txt LIBTIFF-LICENSE.md GIFLIB-LICENSE.txt; do
    test -f "$bundled_license_dir/$license" || { echo "Missing bundled license: $license" >&2; return 1; }
  done
  find "$bundled_license_dir" -maxdepth 1 -type f -iname 'LIBRAW-*' -print -quit | grep -q . || { echo "Missing LibRaw license" >&2; return 1; }
  test -f "$bundle/native-headers/versions.env" || { echo "Missing native-headers/versions.env" >&2; return 1; }
  test -f "$bundle/native-headers/imagemagick-${IMAGEMAGICK_VERSION}/MagickWand/MagickWand.h" || {
    echo "Missing MagickWand headers in native-headers" >&2
    return 1
  }
  test -f "$bundle/native-headers/libraw-${LIBRAW_VERSION}/libraw/libraw.h" || {
    echo "Missing LibRaw headers in native-headers" >&2
    return 1
  }
  test -f "$bundle/native-headers/mozjpeg-${MOZJPEG_VERSION}/jpeglib.h" || {
    echo "Missing MozJPEG headers in native-headers" >&2
    return 1
  }
  test -f "$bundle/native-headers/libpng-${LIBPNG_VERSION}/png.h" || {
    echo "Missing libpng headers in native-headers" >&2
    return 1
  }
  test -f "$bundle/native-headers/libwebp-${LIBWEBP_VERSION}/webp/decode.h" || {
    echo "Missing libwebp headers in native-headers" >&2
    return 1
  }
  test -f "$bundle/native-headers/libtiff-${LIBTIFF_VERSION}/tiffio.h" || {
    echo "Missing libtiff headers in native-headers" >&2
    return 1
  }
  test -f "$bundle/native-headers/giflib-${GIFLIB_VERSION}/gif_lib.h" || {
    echo "Missing giflib headers in native-headers" >&2
    return 1
  }
  while IFS= read -r binary; do
    if ldd "$binary" | grep -q 'not found'; then
      echo "Unresolved DLL dependency in $binary:" >&2
      ldd "$binary" >&2
      return 1
    fi
  done < <(find "$bundle" -maxdepth 1 -type f \( -iname '*.exe' -o -iname '*.dll' \))
  formats="$(PATH="$bundle:$PATH" "$bundle/magick.exe" -list format)"
  for coder in GIF JPEG PNG WEBP TIFF BMP ICO PSD; do
    # Windows output includes a module column (for example: GIF* GIF rw+).
    # Locate the capability field instead of assuming it is column two.
    awk -v wanted="$coder" '
      { format=$1; sub(/\*$/, "", format) }
      format == wanted { for (i=2; i<=NF; i++) if ($i ~ /^rw/) found=1 }
      END { exit(found ? 0 : 1) }
    ' <<<"$formats" || { printf '%s\n' "$formats" >&2; echo "Missing required $coder read/write coder" >&2; return 1; }
  done
  for coder in DNG CR2 NEF ARW; do
    awk -v wanted="$coder" '
      { format=$1; sub(/\*$/, "", format) }
      format == wanted { for (i=2; i<=NF; i++) if ($i ~ /^r/) found=1 }
      END { exit(found ? 0 : 1) }
    ' <<<"$formats" || { printf '%s\n' "$formats" >&2; echo "Missing required $coder RAW reader" >&2; return 1; }
  done
  test_dir="$bundle/.xfilesuite-format-test"
  rm -rf "$test_dir"; mkdir -p "$test_dir"
  for extension in png jpg gif webp tiff; do
    PATH="$bundle:$PATH" "$bundle/magick.exe" -size 2x2 xc:'#336699' "$test_dir/test.$extension"
    PATH="$bundle:$PATH" "$bundle/magick.exe" identify "$test_dir/test.$extension" >/dev/null
  done
  rm -rf "$test_dir"
  PATH="$bundle:$PATH" "$bundle/magick.exe" -version
}

hash_runtime_binaries() {
  local root="$1"
  (
    cd "$root"
    find . -maxdepth 1 -type f \( -iname '*.dll' -o -iname '*.exe' \) -print | LC_ALL=C sort | while IFS= read -r rel; do
      sha256sum "$rel"
    done
  )
}

validate_bundle "$BUNDLE"
trellis_test_dir="$WORK_DIR/trellis-verify"
rm -rf "$trellis_test_dir"; mkdir -p "$trellis_test_dir"
PATH="$BUNDLE:$PATH" "$BUNDLE/magick.exe" -size 256x256 gradient:'#123456-#f0c080' \
  -quality 72 -interlace JPEG -define jpeg:trellis-quantization=on \
  -define jpeg:optimize-scans=on "$trellis_test_dir/on.jpg"
PATH="$BUNDLE:$PATH" "$BUNDLE/magick.exe" -size 256x256 gradient:'#123456-#f0c080' \
  -quality 72 -interlace JPEG -define jpeg:trellis-quantization=off \
  -define jpeg:optimize-scans=off "$trellis_test_dir/off.jpg"
test -s "$trellis_test_dir/on.jpg"; test -s "$trellis_test_dir/off.jpg"
cmp -s "$trellis_test_dir/on.jpg" "$trellis_test_dir/off.jpg" && {
  echo "MozJPEG trellis controls did not affect JPEG output." >&2
  exit 1
}
rm -rf "$trellis_test_dir"

# Refresh critical DLLs from PREFIX after magick exercised them, then package.
install_pe_dll "$raw_src" "$BUNDLE/$(basename "$raw_src")" "LibRaw"
install_pe_dll "$PREFIX/bin/libjpeg-62.dll" "$BUNDLE/libjpeg-62.dll" "MozJPEG"
core_src="$(find "$PREFIX/imagemagick/bin" -maxdepth 1 -type f -iname '*MagickCore-[0-9]*.dll' -print -quit)"
if [[ -z "$core_src" ]]; then
  core_src="$(find "$PREFIX/imagemagick/bin" -maxdepth 1 -type f -iname '*MagickCore*.dll' -print -quit)"
fi
test -n "$core_src" || { echo "PREFIX is missing MagickCore DLL" >&2; exit 1; }
install_pe_dll "$core_src" "$BUNDLE/$(basename "$core_src")" "MagickCore"
install_pe_dll "$PREFIX/imagemagick/bin/magick.exe" "$BUNDLE/magick.exe" "magick.exe"

pre_archive_hashes="$WORK_DIR/pre-archive-binaries.sha256"
hash_runtime_binaries "$BUNDLE" > "$pre_archive_hashes"
echo "Pre-archive runtime binary hashes:"
cat "$pre_archive_hashes"

archive="$OUTPUT_DIR/imagemagick-$IMAGEMAGICK_VERSION-windows-x64.zip"
rm -f "$archive"
echo "Creating release zip with ${SEVEN_ZIP[*]} (avoiding Info-ZIP zip)..."
(
  cd "$OUTPUT_DIR"
  "${SEVEN_ZIP[@]}" a -tzip -mx=5 -bd -y "$(basename "$archive")" "$(basename "$BUNDLE")" >/dev/null
)
test -f "$archive"

# Extract with 7z (same tool family as create). MSYS Info-ZIP unzip has been
# observed to yield non-PE "MZ-only" bytes for large MinGW DLLs even when the
# zip payload is intact; do not gate release validation on that unzip.
verify_dir="$WORK_DIR/archive-verify"
rm -rf "$verify_dir"; mkdir -p "$verify_dir"
"${SEVEN_ZIP[@]}" x -y "-o${verify_dir}" "$archive" >/dev/null
verify_bundle="$verify_dir/$(basename "$BUNDLE")"
test -d "$verify_bundle"
post_archive_hashes="$WORK_DIR/post-archive-binaries.sha256"
hash_runtime_binaries "$verify_bundle" > "$post_archive_hashes"
if ! cmp -s "$pre_archive_hashes" "$post_archive_hashes"; then
  echo "Archive round-trip changed runtime binary contents (7z extract):" >&2
  diff -u "$pre_archive_hashes" "$post_archive_hashes" >&2 || true
  exit 1
fi
echo "Archive round-trip preserved all top-level exe/dll SHA-256 digests."
validate_bundle "$verify_bundle"

# MSYS Info-ZIP `unzip` corrupts every MinGW PE in this archive on GHA (SHA-256
# of all exe/dll change; PE headers become MZ-only). The zip payload itself is
# fine — proven by the 7z round-trip above. Do not gate publish on that unzip.
#
# App fetch-deps must extract with Python zipfile or 7z (see extract_zip_safe),
# never MSYS Info-ZIP unzip.
# Prefer MinGW Python when present (MSYS2 MINGW64 CI).
if [[ -x /mingw64/bin/python3 ]]; then
  py_bin=/mingw64/bin/python3
elif [[ -x /mingw64/bin/python ]]; then
  py_bin=/mingw64/bin/python
elif command -v python3 >/dev/null 2>&1; then
  py_bin="$(command -v python3)"
elif command -v python >/dev/null 2>&1; then
  py_bin="$(command -v python)"
else
  py_bin=""
fi
if [[ -n "$py_bin" ]]; then
  py_dir="$WORK_DIR/archive-verify-python"
  rm -rf "$py_dir"; mkdir -p "$py_dir"
  "$py_bin" - "$archive" "$py_dir" <<'PY'
import sys, zipfile
zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])
PY
  py_bundle="$py_dir/$(basename "$BUNDLE")"
  py_hashes="$WORK_DIR/post-python-binaries.sha256"
  hash_runtime_binaries "$py_bundle" > "$py_hashes"
  if ! cmp -s "$pre_archive_hashes" "$py_hashes"; then
    echo "Python zipfile extract changed runtime binary contents:" >&2
    diff -u "$pre_archive_hashes" "$py_hashes" >&2 || true
    exit 1
  fi
  echo "Python zipfile extract preserved runtime binary digests (fetch-deps path)."
  rm -rf "$py_dir"
else
  echo "python3 unavailable in PATH; relying on 7z extract validation only."
fi
rm -rf "$verify_dir"
sha256sum "$archive" > "$archive.sha256"
(cd "$OUTPUT_DIR" && sha256sum -c "$(basename "$archive.sha256")")
