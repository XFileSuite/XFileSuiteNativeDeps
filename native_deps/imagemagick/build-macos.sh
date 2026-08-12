#!/usr/bin/env bash
# Builds a relocatable, dynamically linked universal ImageMagick runtime.
# The resulting directory mirrors macos/Runner/Resources: magick, all dylibs,
# and ImageMagick configuration files are direct Resources children.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGEMAGICK_VERSION="${IMAGEMAGICK_VERSION:-7.1.2-27}"
LIBRAW_VERSION="${LIBRAW_VERSION:-0.21.4}"
MOZJPEG_VERSION="${MOZJPEG_VERSION:-4.1.1}"
LIBPNG_VERSION="${LIBPNG_VERSION:-1.6.51}"
LIBWEBP_VERSION="${LIBWEBP_VERSION:-1.6.0}"
LIBTIFF_VERSION="${LIBTIFF_VERSION:-4.7.1}"
GIFLIB_VERSION="${GIFLIB_VERSION:-5.2.2}"
WORK_DIR="${WORK_DIR:-$SCRIPT_DIR/work}"
OUTPUT_DIR="${OUTPUT_DIR:-$SCRIPT_DIR/dist}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"
ARCHITECTURES=(arm64 x86_64)
BUNDLE_NAME="imagemagick-macos-universal"

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing required tool: $1" >&2; exit 1; }; }
for tool in cmake curl lipo make tar install_name_tool otool; do need "$tool"; done
download() { [ -f "$2" ] || curl -fL --retry 3 --connect-timeout 20 -o "$2" "$1"; }
extract() { mkdir -p "$2"; tar -xf "$1" -C "$2" --strip-components=1; }

build_cmake() {
  local arch="$1" prefix="$2" source="$3"; shift 3
  cmake -S "$source" -B "$source/build-$arch" -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$prefix" -DCMAKE_OSX_ARCHITECTURES="$arch" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0 -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DBUILD_SHARED_LIBS=ON "$@"
  cmake --build "$source/build-$arch" --parallel "$JOBS"
  cmake --install "$source/build-$arch"
}

# Rebuild sources/prefixes, but retain downloads to make CI retries inexpensive.
rm -rf "$WORK_DIR/sources" "$WORK_DIR"/prefix-* "$WORK_DIR"/build-imagemagick-* "$OUTPUT_DIR"
mkdir -p "$WORK_DIR/downloads" "$WORK_DIR/sources" "$OUTPUT_DIR"
download "https://github.com/ImageMagick/ImageMagick/archive/refs/tags/${IMAGEMAGICK_VERSION}.tar.gz" "$WORK_DIR/downloads/imagemagick.tar.gz"
download "https://github.com/LibRaw/LibRaw/archive/refs/tags/${LIBRAW_VERSION}.tar.gz" "$WORK_DIR/downloads/libraw.tar.gz"
download "https://github.com/mozilla/mozjpeg/archive/refs/tags/v${MOZJPEG_VERSION}.tar.gz" "$WORK_DIR/downloads/mozjpeg.tar.gz"
download "https://github.com/pnggroup/libpng/archive/refs/tags/v${LIBPNG_VERSION}.tar.gz" "$WORK_DIR/downloads/libpng.tar.gz"
download "https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-${LIBWEBP_VERSION}.tar.gz" "$WORK_DIR/downloads/libwebp.tar.gz"
download "https://download.osgeo.org/libtiff/tiff-${LIBTIFF_VERSION}.tar.gz" "$WORK_DIR/downloads/libtiff.tar.gz"
download "https://sourceforge.net/projects/giflib/files/giflib-${GIFLIB_VERSION}.tar.gz/download" "$WORK_DIR/downloads/giflib.tar.gz"
for component in imagemagick libraw mozjpeg libpng libwebp libtiff giflib; do
  extract "$WORK_DIR/downloads/$component.tar.gz" "$WORK_DIR/sources/$component"
done

for arch in "${ARCHITECTURES[@]}"; do
  prefix="$WORK_DIR/prefix-$arch"
  mkdir -p "$prefix"
  build_cmake "$arch" "$prefix" "$WORK_DIR/sources/mozjpeg" \
    -DENABLE_SHARED=ON -DENABLE_STATIC=OFF -DWITH_TURBOJPEG=OFF -DWITH_JAVA=OFF -DPNG_SUPPORTED=OFF
  (
    cd "$WORK_DIR/sources/libpng"
    make distclean >/dev/null 2>&1 || true
    CC="clang -arch $arch -mmacosx-version-min=11.0" CFLAGS="-arch $arch -mmacosx-version-min=11.0 -O3" \
      LDFLAGS="-arch $arch -mmacosx-version-min=11.0" ./configure --prefix="$prefix" --enable-shared --disable-static
    make -j"$JOBS" && make install
  )
  build_cmake "$arch" "$prefix" "$WORK_DIR/sources/libwebp" \
    -DWEBP_BUILD_ANIM_UTILS=OFF -DWEBP_BUILD_CWEBP=OFF -DWEBP_BUILD_DWEBP=OFF \
    -DWEBP_BUILD_GIF2WEBP=OFF -DWEBP_BUILD_IMG2WEBP=OFF -DWEBP_BUILD_VWEBP=OFF \
    -DWEBP_BUILD_WEBPMUX=OFF -DWEBP_BUILD_EXTRAS=OFF
  build_cmake "$arch" "$prefix" "$WORK_DIR/sources/libtiff" \
    -Dtiff-tools=OFF -Dtiff-tests=OFF -Dtiff-contrib=OFF -Dtiff-docs=OFF -Djpeg=OFF -Dwebp=OFF -Dlzma=OFF -Dzstd=OFF -Dlibdeflate=OFF
  (
    cd "$WORK_DIR/sources/giflib"
    make clean >/dev/null 2>&1 || true
    make -j"$JOBS" CC="clang -arch $arch -mmacosx-version-min=11.0" libgif.a
    mkdir -p "$prefix/lib" "$prefix/include"; cp libgif.a "$prefix/lib/"; cp gif_lib.h "$prefix/include/"
  )
  (
    cd "$WORK_DIR/sources/libraw"
    make distclean >/dev/null 2>&1 || true
    CC="clang -arch $arch -mmacosx-version-min=11.0" CXX="clang++ -arch $arch -mmacosx-version-min=11.0" \
      CFLAGS="-arch $arch -mmacosx-version-min=11.0 -O3" CXXFLAGS="-arch $arch -mmacosx-version-min=11.0 -O3" \
      LDFLAGS="-arch $arch -mmacosx-version-min=11.0" ./configure --prefix="$prefix" --enable-shared --disable-static --disable-examples
    make -j"$JOBS" && make install
  )
  build_dir="$WORK_DIR/build-imagemagick-$arch"; cp -R "$WORK_DIR/sources/imagemagick" "$build_dir"
  (
    cd "$build_dir"
    export CFLAGS="-arch $arch -mmacosx-version-min=11.0 -O3 -I$prefix/include"
    export CXXFLAGS="$CFLAGS" LDFLAGS="-arch $arch -mmacosx-version-min=11.0 -L$prefix/lib"
    export LIBS="-lsharpyuv" PKG_CONFIG_PATH="$prefix/lib/pkgconfig"
    ./configure --prefix="$prefix/imagemagick" --enable-shared --disable-static --without-modules \
      --without-perl --without-x --without-fontconfig --without-freetype --without-heic --without-jp2 \
      --without-xml --without-openexr --without-lcms --without-lqr --with-raw --without-rsvg --without-gslib \
      --without-djvu --without-fftw --without-openmp --without-pango --without-cairo --without-gvc \
      --without-jxl --without-openjp2 --without-zip --without-lzma --without-zstd --disable-docs
    make -j"$JOBS" && make install
  )
done

bundle="$OUTPUT_DIR/$BUNDLE_NAME"; mkdir -p "$bundle"
# Merge each dynamic library and executable into one universal runtime.
while IFS= read -r -d '' arm_file; do
  relative="${arm_file#"$WORK_DIR/prefix-arm64/imagemagick/"}"
  x86_file="$WORK_DIR/prefix-x86_64/imagemagick/$relative"
  test -f "$x86_file" || continue
  case "$relative" in
    bin/magick) destination="$bundle/magick" ;;
    lib/*) destination="$bundle/$(basename "$relative")" ;;
    *) continue ;;
  esac
  lipo -create "$arm_file" "$x86_file" -output "$destination"
done < <(find "$WORK_DIR/prefix-arm64/imagemagick/bin" "$WORK_DIR/prefix-arm64/imagemagick/lib" -type f -print0)
while IFS= read -r -d '' arm_file; do
  name="$(basename "$arm_file")"; x86_file="$WORK_DIR/prefix-x86_64/lib/$name"
  test -f "$x86_file" || continue
  lipo -create "$arm_file" "$x86_file" -output "$bundle/$name"
done < <(find "$WORK_DIR/prefix-arm64/lib" -maxdepth 1 -type f -name '*.dylib' -print0)
cp -R "$WORK_DIR/prefix-arm64/imagemagick/etc/ImageMagick-7" "$bundle/"
cp "$SCRIPT_DIR/colors.xml" "$bundle/colors.xml"
# MAGICK_CONFIGURE_PATH points at ImageMagick-7 in the App Resources folder.
# Keep the custom colour map there as well as at the legacy Resources root.
cp "$SCRIPT_DIR/colors.xml" "$bundle/ImageMagick-7/colors.xml"
license_dir="$bundle/ThirdPartyLicenses/ImageMagick"
mkdir -p "$license_dir"
cp "$WORK_DIR/sources/imagemagick/LICENSE" "$license_dir/IMAGEMAGICK-LICENSE.txt"
find "$WORK_DIR/sources/libraw" -maxdepth 1 -type f \( -iname 'license*' -o -iname 'copying*' \) -print0 |
  while IFS= read -r -d '' license; do cp "$license" "$license_dir/LIBRAW-$(basename "$license")"; done
cp "$WORK_DIR/sources/mozjpeg/LICENSE.md" "$license_dir/MOZJPEG-LICENSE.md"
cp "$WORK_DIR/sources/libpng/LICENSE" "$license_dir/LIBPNG-LICENSE.txt"
cp "$WORK_DIR/sources/libwebp/COPYING" "$license_dir/LIBWEBP-LICENSE.txt"
cp "$WORK_DIR/sources/libtiff/LICENSE.md" "$license_dir/LIBTIFF-LICENSE.md"
cp "$WORK_DIR/sources/giflib/COPYING" "$license_dir/GIFLIB-LICENSE.txt"

# Remove build-machine absolute paths. The app stages this directory directly
# into Contents/Resources, so both executable and dylibs resolve there.
find "$bundle" -maxdepth 1 -type f \( -name '*.dylib' -o -name magick \) -print0 | while IFS= read -r -d '' file; do
  if [[ "$file" == *.dylib ]]; then install_name_tool -id "@rpath/$(basename "$file")" "$file"; fi
  while IFS= read -r dependency; do
    case "$dependency" in "$WORK_DIR"/*|*/prefix-*/lib/*)
      install_name_tool -change "$dependency" "@rpath/$(basename "$dependency")" "$file";; esac
  done < <(otool -L "$file" | tail -n +2 | awk '{print $1}')
  if [[ "$file" == "$bundle/magick" ]]; then
    install_name_tool -add_rpath '@executable_path' "$file" 2>/dev/null || true
  else
    install_name_tool -add_rpath '@loader_path' "$file" 2>/dev/null || true
  fi
done

chmod +x "$bundle/magick"
tar -czf "$OUTPUT_DIR/$BUNDLE_NAME.tar.gz" -C "$OUTPUT_DIR" "$BUNDLE_NAME"
shasum -a 256 "$OUTPUT_DIR/$BUNDLE_NAME.tar.gz" > "$OUTPUT_DIR/$BUNDLE_NAME.tar.gz.sha256"
for arch in "${ARCHITECTURES[@]}"; do
  lipo "$bundle/magick" -verify_arch "$arch"
  formats="$(arch -"$arch" "$bundle/magick" -list format)"
  for coder in GIF JPEG PNG WEBP TIFF BMP ICO PSD DNG CR2 NEF ARW; do
    grep -Eq "^[[:space:]]*$coder\\*?[[:space:]]+r[w-]" <<<"$formats" || { echo "Missing required $coder coder for $arch" >&2; exit 1; }
  done
done
test -f "$bundle/libraw"*.dylib
while IFS= read -r binary; do
  absolute_dependencies="$(otool -L "$binary" | awk '/^[[:space:]]/ {print $1}' | grep -E '^/' | grep -Ev '^(/usr/lib/|/System/Library/)' || true)"
  test -z "$absolute_dependencies" || { echo "$binary contains non-system absolute dependencies:" >&2; echo "$absolute_dependencies" >&2; exit 1; }
done < <(find "$bundle" -maxdepth 1 -type f \( -name '*.dylib' -o -name magick \) -print)
for license in IMAGEMAGICK-LICENSE.txt MOZJPEG-LICENSE.md LIBPNG-LICENSE.txt LIBWEBP-LICENSE.txt LIBTIFF-LICENSE.txt GIFLIB-LICENSE.txt; do
  test -f "$license_dir/$license"
done
test -n "$(find "$license_dir" -maxdepth 1 -type f -name 'LIBRAW-*' -print -quit)"
"$bundle/magick" -version
