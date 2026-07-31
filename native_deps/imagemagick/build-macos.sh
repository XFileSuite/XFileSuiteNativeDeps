#!/usr/bin/env bash
# Builds a self-contained, universal ImageMagick fallback for the macOS App.
#
# Supported and CI-verified formats are GIF, JPEG, PNG, WebP, TIFF, BMP, ICO
# and PSD. JPEG is linked against MozJPEG. ImageMagick may list PDF/PS/SVG
# coders, but this self-contained build deliberately does not bundle their
# runtime delegates (Ghostscript/potrace); do not present those as supported.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGEMAGICK_VERSION="${IMAGEMAGICK_VERSION:-7.1.2-27}"
MOZJPEG_VERSION="${MOZJPEG_VERSION:-4.1.1}"
LIBPNG_VERSION="${LIBPNG_VERSION:-1.6.51}"
LIBWEBP_VERSION="${LIBWEBP_VERSION:-1.6.0}"
LIBTIFF_VERSION="${LIBTIFF_VERSION:-4.7.1}"
GIFLIB_VERSION="${GIFLIB_VERSION:-5.2.2}"
WORK_DIR="${WORK_DIR:-$SCRIPT_DIR/work}"
OUTPUT_DIR="${OUTPUT_DIR:-$SCRIPT_DIR/dist}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"
ARCHITECTURES=(arm64 x86_64)

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing required tool: $1" >&2; exit 1; }; }
for tool in cmake curl git lipo make tar; do need "$tool"; done

download() {
  local url="$1" destination="$2"
  [ -f "$destination" ] || curl -fL --retry 3 --connect-timeout 20 -o "$destination" "$url"
}

extract() {
  local archive="$1" destination="$2"
  mkdir -p "$destination"
  tar -xf "$archive" -C "$destination" --strip-components=1
}

build_giflib() {
  local arch="$1" prefix="$2" source="$3"
  mkdir -p "$prefix/include" "$prefix/lib"
  (cd "$source" && make clean >/dev/null 2>&1 || true
   make -j"$JOBS" CC="clang -arch $arch -mmacosx-version-min=11.0" libgif.a)
  cp "$source/libgif.a" "$prefix/lib/"
  cp "$source/gif_lib.h" "$prefix/include/"
}

build_cmake_static() {
  local arch="$1" prefix="$2" source="$3"; shift 3
  cmake -S "$source" -B "$source/build-$arch" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$prefix" \
    -DCMAKE_OSX_ARCHITECTURES="$arch" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0 \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DBUILD_SHARED_LIBS=OFF "$@"
  cmake --build "$source/build-$arch" --parallel "$JOBS"
  cmake --install "$source/build-$arch"
}

# Keep verified downloads across retries.  Rebuilding must start from clean
# sources/prefixes, but a transient network failure should not re-download all
# six upstream archives.
rm -rf "$WORK_DIR/sources" "$WORK_DIR"/prefix-* "$WORK_DIR"/build-imagemagick-* "$OUTPUT_DIR"
mkdir -p "$WORK_DIR/downloads" "$WORK_DIR/sources" "$OUTPUT_DIR"

download "https://github.com/ImageMagick/ImageMagick/archive/refs/tags/${IMAGEMAGICK_VERSION}.tar.gz" "$WORK_DIR/downloads/imagemagick.tar.gz"
download "https://github.com/mozilla/mozjpeg/archive/refs/tags/v${MOZJPEG_VERSION}.tar.gz" "$WORK_DIR/downloads/mozjpeg.tar.gz"
download "https://github.com/pnggroup/libpng/archive/refs/tags/v${LIBPNG_VERSION}.tar.gz" "$WORK_DIR/downloads/libpng.tar.gz"
download "https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-${LIBWEBP_VERSION}.tar.gz" "$WORK_DIR/downloads/libwebp.tar.gz"
download "https://download.osgeo.org/libtiff/tiff-${LIBTIFF_VERSION}.tar.gz" "$WORK_DIR/downloads/libtiff.tar.gz"
download "https://sourceforge.net/projects/giflib/files/giflib-${GIFLIB_VERSION}.tar.gz/download" "$WORK_DIR/downloads/giflib.tar.gz"

extract "$WORK_DIR/downloads/imagemagick.tar.gz" "$WORK_DIR/sources/imagemagick"
extract "$WORK_DIR/downloads/mozjpeg.tar.gz" "$WORK_DIR/sources/mozjpeg"
extract "$WORK_DIR/downloads/libpng.tar.gz" "$WORK_DIR/sources/libpng"
extract "$WORK_DIR/downloads/libwebp.tar.gz" "$WORK_DIR/sources/libwebp"
extract "$WORK_DIR/downloads/libtiff.tar.gz" "$WORK_DIR/sources/libtiff"
extract "$WORK_DIR/downloads/giflib.tar.gz" "$WORK_DIR/sources/giflib"

for arch in "${ARCHITECTURES[@]}"; do
  prefix="$WORK_DIR/prefix-$arch"
  mkdir -p "$prefix"
  build_giflib "$arch" "$prefix" "$WORK_DIR/sources/giflib"
  build_cmake_static "$arch" "$prefix" "$WORK_DIR/sources/mozjpeg" \
    -DENABLE_SHARED=OFF -DENABLE_STATIC=ON -DWITH_TURBOJPEG=OFF -DWITH_JAVA=OFF \
    -DPNG_SUPPORTED=OFF
  (
    cd "$WORK_DIR/sources/libpng"
    make distclean >/dev/null 2>&1 || true
    CC="clang -arch $arch -mmacosx-version-min=11.0" \
      CFLAGS="-arch $arch -mmacosx-version-min=11.0 -O3" \
      LDFLAGS="-arch $arch -mmacosx-version-min=11.0" \
      ./configure --prefix="$prefix" --disable-shared --enable-static
    make -j"$JOBS" && make install
  )
  build_cmake_static "$arch" "$prefix" "$WORK_DIR/sources/libwebp" \
    -DWEBP_BUILD_ANIM_UTILS=OFF -DWEBP_BUILD_CWEBP=OFF -DWEBP_BUILD_DWEBP=OFF \
    -DWEBP_BUILD_GIF2WEBP=OFF -DWEBP_BUILD_IMG2WEBP=OFF -DWEBP_BUILD_VWEBP=OFF \
    -DWEBP_BUILD_WEBPMUX=OFF -DWEBP_BUILD_EXTRAS=OFF
  build_cmake_static "$arch" "$prefix" "$WORK_DIR/sources/libtiff" \
    -Dtiff-tools=OFF -Dtiff-tests=OFF -Dtiff-contrib=OFF -Dtiff-docs=OFF \
    -Djpeg=OFF -Dwebp=OFF -Dlzma=OFF -Dzstd=OFF -Dlibdeflate=OFF

  build_dir="$WORK_DIR/build-imagemagick-$arch"
  cp -R "$WORK_DIR/sources/imagemagick" "$build_dir"
  (
    cd "$build_dir"
    export CFLAGS="-arch $arch -mmacosx-version-min=11.0 -O3 -I$prefix/include"
    export CXXFLAGS="$CFLAGS"
    export LDFLAGS="-arch $arch -mmacosx-version-min=11.0 -L$prefix/lib"
    # libwebp 1.6 splits SharpYUV into its own static archive.  pkg-config
    # does not propagate this private dependency for ImageMagick's link.
    export LIBS="-lsharpyuv"
    export PKG_CONFIG_PATH="$prefix/lib/pkgconfig"
    ./configure --prefix="$prefix/imagemagick" --disable-shared --enable-static --without-modules \
      --without-perl --without-x --without-fontconfig --without-freetype \
      --without-heic --without-jp2 --without-xml --without-openexr --without-lcms \
      --without-lqr --without-raw --without-rsvg --without-gslib --without-djvu \
      --without-fftw --without-openmp --without-pango --without-cairo --without-gvc \
      --without-jxl --without-openjp2 --without-zip --without-lzma --without-zstd \
      --disable-docs
    make -j"$JOBS"
    make install
  )
done

lipo -create "$WORK_DIR/prefix-arm64/imagemagick/bin/magick" "$WORK_DIR/prefix-x86_64/imagemagick/bin/magick" \
  -output "$OUTPUT_DIR/imagemagick-macos-universal"
chmod +x "$OUTPUT_DIR/imagemagick-macos-universal"
cp "$SCRIPT_DIR/colors.xml" "$OUTPUT_DIR/colors.xml"
shasum -a 256 "$OUTPUT_DIR/imagemagick-macos-universal" > "$OUTPUT_DIR/imagemagick-macos-universal.sha256"
lipo "$OUTPUT_DIR/imagemagick-macos-universal" -verify_arch arm64 x86_64

for arch in "${ARCHITECTURES[@]}"; do
  formats="$(arch -"$arch" "$OUTPUT_DIR/imagemagick-macos-universal" -list format)"
  for coder in GIF JPEG PNG WEBP TIFF BMP ICO PSD; do
    grep -Eq "^[[:space:]]*$coder\\*?[[:space:]]+r[w-]" <<<"$formats" || {
      echo "Missing required $coder coder for $arch" >&2; exit 1;
    }
  done
done

# A listed coder is not enough: verify every supported source/target pair can
# really convert a small image for both architectures. Static destinations
# intentionally select frame zero, matching the app's conversion service and
# avoiding ImageMagick's numbered multi-image output convention for PSD/GIF.
for arch in "${ARCHITECTURES[@]}"; do
  verification_dir="$WORK_DIR/format-smoke-$arch"
  mkdir -p "$verification_dir"
  source_extensions=(jpg png webp gif bmp tiff ico psd)
  target_extensions=(jpg png webp gif bmp tiff ico)
  for source_extension in "${source_extensions[@]}"; do
    source="$verification_dir/source.$source_extension"
    arch -"$arch" "$OUTPUT_DIR/imagemagick-macos-universal" -size 16x12 gradient: "$source"
    test -s "$source"
    for target_extension in "${target_extensions[@]}"; do
      output="$verification_dir/$source_extension-to-$target_extension.$target_extension"
      input="${source}[0]"
      if [ "$target_extension" = gif ] || [ "$target_extension" = webp ]; then
        input="$source"
      fi
      arguments=("$input" -auto-orient)
      if [ "$target_extension" = jpg ]; then
        arguments+=(-background '#ffffff' -alpha remove -alpha off -sampling-factor 4:2:0 -interlace JPEG -define jpeg:optimize-coding=on -quality 80)
      elif [ "$target_extension" = webp ]; then
        if [ "$source_extension" = gif ]; then
          arguments+=(-coalesce)
        fi
        arguments+=(-quality 80)
      elif [ "$target_extension" = gif ]; then
        arguments+=(-coalesce -set delay 10 -layers Optimize)
      fi
      arguments+=("$output")
      arch -"$arch" "$OUTPUT_DIR/imagemagick-macos-universal" "${arguments[@]}"
      test -s "$output"
    done
  done
done

"$OUTPUT_DIR/imagemagick-macos-universal" -version
