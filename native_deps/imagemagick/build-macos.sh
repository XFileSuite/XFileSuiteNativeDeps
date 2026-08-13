#!/usr/bin/env bash
# Builds a relocatable, dynamically linked universal ImageMagick runtime.
# The resulting directory mirrors macos/Runner/Resources: magick, all dylibs,
# and ImageMagick configuration files are direct Resources children.
set -euo pipefail
trap 'status=$?; echo "ImageMagick build failed at line ${BASH_LINENO[0]}: ${BASH_COMMAND} (exit ${status})" >&2; exit "$status"' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGEMAGICK_VERSION="${IMAGEMAGICK_VERSION:-7.1.2-29}"
LIBRAW_VERSION="${LIBRAW_VERSION:-0.22.2}"
MOZJPEG_VERSION="${MOZJPEG_VERSION:-4.1.1}"
LIBPNG_VERSION="${LIBPNG_VERSION:-1.6.58}"
LIBWEBP_VERSION="${LIBWEBP_VERSION:-1.6.0}"
LIBTIFF_VERSION="${LIBTIFF_VERSION:-4.7.2}"
GIFLIB_VERSION="${GIFLIB_VERSION:-5.2.2}"
WORK_DIR="${WORK_DIR:-$SCRIPT_DIR/work}"
OUTPUT_DIR="${OUTPUT_DIR:-$SCRIPT_DIR/dist}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"
ARCHITECTURES=(arm64 x86_64)
BUNDLE_NAME="imagemagick-macos-universal"

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing required tool: $1" >&2; exit 1; }; }
for tool in autoreconf cmake curl lipo make tar install_name_tool otool; do need "$tool"; done
download() { [ -f "$2" ] || curl -fL --retry 6 --retry-all-errors --retry-delay 2 --connect-timeout 20 -o "$2" "$1"; }
extract() { mkdir -p "$2"; tar -xf "$1" -C "$2" --strip-components=1; }

build_cmake_static() {
  local arch="$1" prefix="$2" source="$3"; shift 3
  cmake -S "$source" -B "$source/build-$arch" -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$prefix" -DCMAKE_OSX_ARCHITECTURES="$arch" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0 -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DBUILD_SHARED_LIBS=OFF "$@"
  cmake --build "$source/build-$arch" --parallel "$JOBS"
  cmake --install "$source/build-$arch"
}

# Rebuild sources/prefixes, but retain downloads to make CI retries inexpensive.
rm -rf "$WORK_DIR/sources" "$WORK_DIR"/prefix-* "$WORK_DIR"/build-imagemagick-* "$OUTPUT_DIR"
mkdir -p "$WORK_DIR/downloads" "$WORK_DIR/sources" "$OUTPUT_DIR"
download "https://codeload.github.com/ImageMagick/ImageMagick/tar.gz/refs/tags/${IMAGEMAGICK_VERSION}" "$WORK_DIR/downloads/imagemagick-${IMAGEMAGICK_VERSION}.tar.gz"
download "https://codeload.github.com/LibRaw/LibRaw/tar.gz/refs/tags/${LIBRAW_VERSION}" "$WORK_DIR/downloads/libraw-${LIBRAW_VERSION}.tar.gz"
download "https://github.com/mozilla/mozjpeg/archive/refs/tags/v${MOZJPEG_VERSION}.tar.gz" "$WORK_DIR/downloads/mozjpeg-${MOZJPEG_VERSION}.tar.gz"
download "https://github.com/pnggroup/libpng/archive/refs/tags/v${LIBPNG_VERSION}.tar.gz" "$WORK_DIR/downloads/libpng-${LIBPNG_VERSION}.tar.gz"
download "https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-${LIBWEBP_VERSION}.tar.gz" "$WORK_DIR/downloads/libwebp-${LIBWEBP_VERSION}.tar.gz"
download "https://download.osgeo.org/libtiff/tiff-${LIBTIFF_VERSION}.tar.gz" "$WORK_DIR/downloads/libtiff-${LIBTIFF_VERSION}.tar.gz"
download "https://sourceforge.net/projects/giflib/files/giflib-${GIFLIB_VERSION}.tar.gz/download" "$WORK_DIR/downloads/giflib-${GIFLIB_VERSION}.tar.gz"
extract "$WORK_DIR/downloads/imagemagick-${IMAGEMAGICK_VERSION}.tar.gz" "$WORK_DIR/sources/imagemagick"
extract "$WORK_DIR/downloads/libraw-${LIBRAW_VERSION}.tar.gz" "$WORK_DIR/sources/libraw"
extract "$WORK_DIR/downloads/mozjpeg-${MOZJPEG_VERSION}.tar.gz" "$WORK_DIR/sources/mozjpeg"
extract "$WORK_DIR/downloads/libpng-${LIBPNG_VERSION}.tar.gz" "$WORK_DIR/sources/libpng"
extract "$WORK_DIR/downloads/libwebp-${LIBWEBP_VERSION}.tar.gz" "$WORK_DIR/sources/libwebp"
extract "$WORK_DIR/downloads/libtiff-${LIBTIFF_VERSION}.tar.gz" "$WORK_DIR/sources/libtiff"
extract "$WORK_DIR/downloads/giflib-${GIFLIB_VERSION}.tar.gz" "$WORK_DIR/sources/giflib"
patch -d "$WORK_DIR/sources/imagemagick" -p1 < "$SCRIPT_DIR/patches/imagemagick-mozjpeg-options.patch"
patch -d "$WORK_DIR/sources/imagemagick" -p1 < "$SCRIPT_DIR/patches/imagemagick-libraw-controls.patch"
for control in bright auto_bright_thr highlight exp_shift exp_preser; do
  grep -Fq "raw_info->params.$control=" "$WORK_DIR/sources/imagemagick/coders/dng.c" || {
    echo "ImageMagick DNG coder is missing LibRaw control: $control" >&2
    exit 1
  }
done
test "$(grep -c 'raw_info->params.exp_correc=1;' "$WORK_DIR/sources/imagemagick/coders/dng.c")" -ge 2 || {
  echo "ImageMagick DNG exposure controls do not enable LibRaw exposure correction." >&2
  exit 1
}
grep -Fq "PACKAGE_VERSION='${IMAGEMAGICK_VERSION}'" "$WORK_DIR/sources/imagemagick/configure" || {
  echo "Downloaded ImageMagick source does not match ${IMAGEMAGICK_VERSION}." >&2
  exit 1
}

for arch in "${ARCHITECTURES[@]}"; do
  # macos-14 is Apple Silicon.  The x86_64 half of this universal build must
  # run Autoconf test programs through Rosetta; fail explicitly if it is not
  # available instead of reporting a misleading compiler failure later.
  if [ "$arch" = x86_64 ]; then
    arch -x86_64 /usr/bin/true >/dev/null 2>&1 || {
      echo "Rosetta is required to configure the x86_64 ImageMagick slice." >&2
      exit 1
    }
  fi
  prefix="$WORK_DIR/prefix-$arch"
  mkdir -p "$prefix/lib/pkgconfig"
  # macOS supplies libz as a platform library but no zlib.pc. Our hermetic
  # PKG_CONFIG_LIBDIR must still describe it because libpng, LibRaw and TIFF
  # expose zlib through their pkg-config dependency metadata.
  sed "s|@PREFIX@|$prefix|g" > "$prefix/lib/pkgconfig/zlib.pc" <<'EOF'
prefix=@PREFIX@
exec_prefix=${prefix}
libdir=${exec_prefix}/lib
includedir=${prefix}/include

Name: zlib
Description: macOS SDK zlib
Version: 1.2.12
Libs: -lz
EOF
  # MozJPEG is the single shared JPEG implementation used by both LibRaw and
  # ImageMagick. Other image delegates remain static.
  cmake -S "$WORK_DIR/sources/mozjpeg" -B "$WORK_DIR/sources/mozjpeg/build-$arch" \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$prefix" \
    -DCMAKE_OSX_ARCHITECTURES="$arch" -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0 \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DENABLE_SHARED=ON -DENABLE_STATIC=OFF \
    -DWITH_TURBOJPEG=OFF -DWITH_JAVA=OFF -DPNG_SUPPORTED=OFF
  cmake --build "$WORK_DIR/sources/mozjpeg/build-$arch" --parallel "$JOBS"
  cmake --install "$WORK_DIR/sources/mozjpeg/build-$arch"
  (
    cd "$WORK_DIR/sources/libpng"
    make distclean >/dev/null 2>&1 || true
    CC="clang -arch $arch -mmacosx-version-min=11.0" CFLAGS="-arch $arch -mmacosx-version-min=11.0 -O3 -fPIC" \
      LDFLAGS="-arch $arch -mmacosx-version-min=11.0" ./configure --prefix="$prefix" --disable-shared --enable-static
    make -j"$JOBS" && make install
  )
  build_cmake_static "$arch" "$prefix" "$WORK_DIR/sources/libwebp" \
    -DWEBP_BUILD_ANIM_UTILS=OFF -DWEBP_BUILD_CWEBP=OFF -DWEBP_BUILD_DWEBP=OFF \
    -DWEBP_BUILD_GIF2WEBP=OFF -DWEBP_BUILD_IMG2WEBP=OFF -DWEBP_BUILD_VWEBP=OFF \
    -DWEBP_BUILD_WEBPMUX=OFF -DWEBP_BUILD_EXTRAS=OFF
  # ImageMagick asks for libwebp without pkg-config's --static flag. Promote
  # SharpYUV from Libs.private so the static archive is linked into MagickCore
  # without contaminating Autoconf's global LIBS compiler probes.
  sed -i '' '/^Libs:/ s/$/ -lsharpyuv/' "$prefix/lib/pkgconfig/libwebp.pc"
  build_cmake_static "$arch" "$prefix" "$WORK_DIR/sources/libtiff" \
    -Dtiff-tools=OFF -Dtiff-tests=OFF -Dtiff-contrib=OFF -Dtiff-docs=OFF -Djpeg=OFF -Dwebp=OFF -Dlzma=OFF -Dzstd=OFF -Dlibdeflate=OFF
  (
    cd "$WORK_DIR/sources/giflib"
    make clean >/dev/null 2>&1 || true
    make -j"$JOBS" CC="clang -arch $arch -mmacosx-version-min=11.0 -fPIC" libgif.a
    mkdir -p "$prefix/lib" "$prefix/include"; cp libgif.a "$prefix/lib/"; cp gif_lib.h "$prefix/include/"
  )
  (
    cd "$WORK_DIR/sources/libraw"
    # GitHub tag archives do not ship the generated Autotools configure script.
    autoreconf -fi
    make distclean >/dev/null 2>&1 || true
    CC="clang -arch $arch -mmacosx-version-min=11.0" CXX="clang++ -arch $arch -mmacosx-version-min=11.0" \
      CFLAGS="-arch $arch -mmacosx-version-min=11.0 -O3" CXXFLAGS="-arch $arch -mmacosx-version-min=11.0 -O3" \
      CPPFLAGS="-I$prefix/include" LDFLAGS="-arch $arch -mmacosx-version-min=11.0 -L$prefix/lib" \
      ./configure --prefix="$prefix" --enable-shared --disable-static --disable-examples --disable-lcms --enable-jpeg
    grep -Eq '(^|[[:space:]])-DUSE_JPEG([[:space:]]|$)' Makefile || {
      echo "LibRaw did not enable MozJPEG support for lossy DNG on $arch." >&2
      exit 1
    }
    make -j"$JOBS" && make install
  )
  build_dir="$WORK_DIR/build-imagemagick-$arch"; cp -R "$WORK_DIR/sources/imagemagick" "$build_dir"
  (
    cd "$build_dir"
    # Autoconf otherwise selects the runner's GNU gcc shim, which can produce
    # a target probe that macOS cannot execute. Keep every configure probe on
    # the same Apple Clang/toolchain and deployment target as its delegates.
    # Do not use Xcode's clang-cpp wrapper: unlike $CC it does not receive
    # the target/SDK flags from this environment and fails Autoconf's CPP
    # sanity check.  clang -E is the supported preprocessor invocation.
    export CC=clang CXX=clang++ CPP='clang -E'
    export CFLAGS="-arch $arch -mmacosx-version-min=11.0 -O3 -I$prefix/include"
    export CXXFLAGS="$CFLAGS -std=c++11" LDFLAGS="-arch $arch -mmacosx-version-min=11.0 -L$prefix/lib"
    # Keep Autoconf's compiler probes independent from runtime delegates.
    # Delegate libraries are discovered by pkg-config during their individual
    # feature checks; adding a delegate to LIBS globally also affects the
    # AC_EXEEXT executable probe.
    unset LIBS
    export PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig"
    for module in libjpeg libpng libraw_r libtiff-4 libwebp libwebpmux libwebpdemux; do
      pkg-config --exists "$module" || {
        echo "Incomplete $arch delegate metadata: $module" >&2
        pkg-config --print-errors --exists "$module" >&2 || true
        exit 1
      }
    done
    # Metadata presence is insufficient: prove that every required delegate
    # can link for the current target before running ImageMagick configure.
    printf 'int main(void) { return 0; }\n' > .xfilesuite-delegate-smoke.c
    "$CC" $CFLAGS .xfilesuite-delegate-smoke.c \
      $(pkg-config --libs libjpeg) \
      $(pkg-config --static --libs libpng libraw_r libtiff-4 libwebp libwebpmux libwebpdemux) \
      $LDFLAGS -o .xfilesuite-delegate-smoke
    rm -f .xfilesuite-delegate-smoke.c .xfilesuite-delegate-smoke
    printf 'int main(void) { return 0; }\n' > .xfilesuite-compiler-smoke.c
    "$CC" $CFLAGS $LDFLAGS .xfilesuite-compiler-smoke.c -o .xfilesuite-compiler-smoke
    if [ "$arch" = x86_64 ]; then
      arch -x86_64 ./.xfilesuite-compiler-smoke
    else
      ./.xfilesuite-compiler-smoke
    fi
    rm -f .xfilesuite-compiler-smoke.c .xfilesuite-compiler-smoke
    trap 'status=$?; if [ $status -ne 0 ] && [ -f config.log ]; then cat config.log >&2; fi; exit $status' EXIT
    ./configure --prefix="$prefix/imagemagick" --enable-shared --disable-static --without-modules \
      --without-perl --without-x --without-fontconfig --without-freetype --without-heic \
      --without-xml --without-openexr --without-lcms --without-lqr --with-raw --without-rsvg --without-gslib \
      --without-djvu --without-fftw --without-pango --without-gvc \
      --without-jxl --without-openjp2 --without-zip --without-lzma --without-zstd --disable-docs
    trap - EXIT
    # These are the actual symbols emitted by ImageMagick's config.h.  RAW
    # intentionally has no RAW_DELEGATE symbol in 7.1.2; its availability is
    # proved by the libraw_r link test above and by the installed RAW coders
    # exercised below after the universal runtime has been assembled.
    for delegate in JPEG PNG TIFF WEBP ZLIB; do
      grep -Eq "^#define ${delegate}_DELEGATE 1$" config/config.h || {
        echo "ImageMagick did not enable required $delegate delegate for $arch." >&2
        exit 1
      }
    done
    make -j"$JOBS" && make install
  )
done

bundle="$OUTPUT_DIR/$BUNDLE_NAME"; mkdir -p "$bundle"
echo "Assembling universal ImageMagick runtime..."
# Merge the shared ImageMagick runtime. PNG, WebP, TIFF and GIF are already
# incorporated into libMagickCore; MozJPEG remains shared with LibRaw.
while IFS= read -r -d '' arm_file; do
  relative="${arm_file#"$WORK_DIR/prefix-arm64/imagemagick/"}"
  x86_file="$WORK_DIR/prefix-x86_64/imagemagick/$relative"
  test -f "$x86_file" || continue
  case "$relative" in
    bin/magick) destination="$bundle/magick" ;;
    lib/*.dylib) destination="$bundle/$(basename "$relative")" ;;
    *) continue ;;
  esac
  lipo -create "$arm_file" "$x86_file" -output "$destination"
done < <(find "$WORK_DIR/prefix-arm64/imagemagick/bin" "$WORK_DIR/prefix-arm64/imagemagick/lib" -type f -print0)
# ImageMagick links to LibRaw's thread-safe, versioned install name.  The
# unversioned files installed by LibRaw are development symlinks; feeding them
# through lipo would turn them into full duplicate files.  The non-thread-safe
# libraw variant is not referenced by this runtime either.
raw_versioned_arm="$(find "$WORK_DIR/prefix-arm64/lib" -maxdepth 1 -type f -name 'libraw_r.*.dylib' -print -quit)"
test -n "$raw_versioned_arm"
raw_name="$(basename "$raw_versioned_arm")"
raw_versioned_x86="$WORK_DIR/prefix-x86_64/lib/$raw_name"
test -f "$raw_versioned_x86"
lipo -create "$raw_versioned_arm" "$raw_versioned_x86" -output "$bundle/$raw_name"
# MozJPEG installs a real libjpeg.62.3.0.dylib plus ABI/development symlinks,
# while consumers record libjpeg.62.dylib as the install name. Resolve the ABI
# symlink for lipo input but publish it under the exact recorded install name.
jpeg_name="libjpeg.62.dylib"
jpeg_versioned_arm="$WORK_DIR/prefix-arm64/lib/$jpeg_name"
jpeg_versioned_x86="$WORK_DIR/prefix-x86_64/lib/$jpeg_name"
test -e "$jpeg_versioned_arm"; test -e "$jpeg_versioned_x86"
lipo -create "$jpeg_versioned_arm" "$jpeg_versioned_x86" -output "$bundle/$jpeg_name"
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
echo "Rewriting bundled Mach-O install names..."
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
echo "Verifying universal runtime formats and delegates..."
for arch in "${ARCHITECTURES[@]}"; do
  lipo "$bundle/magick" -verify_arch "$arch"
  formats="$(arch -"$arch" "$bundle/magick" -list format)"
  for coder in GIF JPEG PNG WEBP TIFF BMP ICO PSD DNG CR2 NEF ARW; do
    grep -Eq "^[[:space:]]*$coder\\*?[[:space:]]+r[w-]" <<<"$formats" || { echo "Missing required $coder coder for $arch" >&2; exit 1; }
  done
done
raw_library="$(find "$bundle" -maxdepth 1 -type f -name 'libraw_r.*.dylib' -print -quit)"
test -n "$raw_library" || {
  echo "Missing versioned thread-safe LibRaw runtime library." >&2
  exit 1
}
test "$(find "$bundle" -maxdepth 1 -type f -name 'libraw*.dylib' | wc -l | tr -d ' ')" = 1 || {
  echo "The runtime must contain only the versioned thread-safe LibRaw library." >&2
  find "$bundle" -maxdepth 1 -type f -name 'libraw*.dylib' -print >&2
  exit 1
}
jpeg_library="$(find "$bundle" -maxdepth 1 -type f -name 'libjpeg.*.dylib' -print -quit)"
test -n "$jpeg_library" || { echo "Missing shared MozJPEG runtime library." >&2; exit 1; }
otool -L "$raw_library" | grep -q '@rpath/libjpeg\..*\.dylib' || {
  echo "$raw_library is not dynamically linked to the bundled MozJPEG library." >&2
  exit 1
}
otool -L "$bundle/libMagickCore-7.Q16HDRI.10.dylib" | grep -q '@rpath/libjpeg\..*\.dylib' || {
  echo "MagickCore is not dynamically linked to the bundled MozJPEG library." >&2
  exit 1
}
nm "$jpeg_library" | grep -q '[[:space:]]_jpeg_mem_src$' || { echo "Bundled MozJPEG decoder is invalid." >&2; exit 1; }
unexpected_delegates="$(find "$bundle" -maxdepth 1 -type f \( -name 'libpng*.dylib' -o -name 'libwebp*.dylib' -o -name 'libtiff*.dylib' -o -name 'libgif*.dylib' \) -print)"
test -z "$unexpected_delegates" || {
  echo "Delegates that must be static were packaged as dylibs:" >&2
  echo "$unexpected_delegates" >&2
  exit 1
}
while IFS= read -r binary; do
  absolute_dependencies="$(otool -L "$binary" | awk '/^[[:space:]]/ {print $1}' | grep -E '^/' | grep -Ev '^(/usr/lib/|/System/Library/)' || true)"
  test -z "$absolute_dependencies" || { echo "$binary contains non-system absolute dependencies:" >&2; echo "$absolute_dependencies" >&2; exit 1; }
  while IFS= read -r dependency; do
    case "$dependency" in
      @rpath/*)
        dependency_name="${dependency#@rpath/}"
        test -f "$bundle/$dependency_name" || {
          echo "$binary references missing bundled library $dependency_name" >&2
          exit 1
        }
        ;;
    esac
  done < <(otool -L "$binary" | tail -n +2 | awk '{print $1}')
done < <(find "$bundle" -maxdepth 1 -type f \( -name '*.dylib' -o -name magick \) -print)
for license in IMAGEMAGICK-LICENSE.txt MOZJPEG-LICENSE.md LIBPNG-LICENSE.txt LIBWEBP-LICENSE.txt LIBTIFF-LICENSE.md GIFLIB-LICENSE.txt; do
  test -f "$license_dir/$license"
done
test -n "$(find "$license_dir" -maxdepth 1 -type f -name 'LIBRAW-*' -print -quit)"
"$bundle/magick" -version
trellis_test_dir="$(mktemp -d "$WORK_DIR/trellis-verify.XXXXXX")"
"$bundle/magick" -size 256x256 gradient:'#123456-#f0c080' \
  -quality 72 -interlace JPEG -define jpeg:trellis-quantization=on \
  -define jpeg:optimize-scans=on "$trellis_test_dir/on.jpg"
"$bundle/magick" -size 256x256 gradient:'#123456-#f0c080' \
  -quality 72 -interlace JPEG -define jpeg:trellis-quantization=off \
  -define jpeg:optimize-scans=off "$trellis_test_dir/off.jpg"
test -s "$trellis_test_dir/on.jpg"; test -s "$trellis_test_dir/off.jpg"
cmp -s "$trellis_test_dir/on.jpg" "$trellis_test_dir/off.jpg" && {
  echo "MozJPEG trellis controls did not affect JPEG output." >&2
  exit 1
}
rm -rf "$trellis_test_dir"

# Publish only an archive that behaves identically after extraction. This also
# catches missing compatibility names and tar layout mistakes before R2 upload.
echo "Verifying the final archive after extraction..."
archive="$OUTPUT_DIR/$BUNDLE_NAME.tar.gz"
tar -czf "$archive" -C "$OUTPUT_DIR" "$BUNDLE_NAME"
verify_dir="$(mktemp -d "$WORK_DIR/archive-verify.XXXXXX")"
trap 'rm -rf "$verify_dir"' EXIT
tar -xzf "$archive" -C "$verify_dir"
verify_bundle="$verify_dir/$BUNDLE_NAME"
test -x "$verify_bundle/magick"
MAGICK_CONFIGURE_PATH="$verify_bundle/ImageMagick-7" "$verify_bundle/magick" -version
for arch in "${ARCHITECTURES[@]}"; do
  arch -"$arch" "$verify_bundle/magick" -version >/dev/null
done
rm -rf "$verify_dir"
trap - EXIT
shasum -a 256 "$archive" > "$archive.sha256"
