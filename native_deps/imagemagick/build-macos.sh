#!/usr/bin/env bash
# Builds a relocatable, dynamically linked universal ImageMagick runtime.
# The resulting directory mirrors macos/Runner/Resources: magick, all dylibs,
# and ImageMagick configuration files are direct Resources children.
# Also ships native-headers/ (MagickWand, LibRaw, MozJPEG, PNG, WebP, TIFF,
# GIF public headers) for App-side FFI; fetch-deps can deploy selected trees
# later and strips the folder from Resources / runtime before shipping.
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

build_cmake_shared() {
  local arch="$1" prefix="$2" source="$3"; shift 3
  cmake -S "$source" -B "$source/build-$arch" -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$prefix" -DCMAKE_OSX_ARCHITECTURES="$arch" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0 -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DBUILD_SHARED_LIBS=ON "$@"
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
  # All pinned image delegates are shared so MagickCore, LibRaw, and future
  # App-side FFI can load the same runtime libraries independently.
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
      LDFLAGS="-arch $arch -mmacosx-version-min=11.0" \
      ./configure --prefix="$prefix" --enable-shared --disable-static
    make -j"$JOBS" && make install
  )
  build_cmake_shared "$arch" "$prefix" "$WORK_DIR/sources/libwebp" \
    -DWEBP_BUILD_ANIM_UTILS=OFF -DWEBP_BUILD_CWEBP=OFF -DWEBP_BUILD_DWEBP=OFF \
    -DWEBP_BUILD_GIF2WEBP=OFF -DWEBP_BUILD_IMG2WEBP=OFF -DWEBP_BUILD_VWEBP=OFF \
    -DWEBP_BUILD_WEBPMUX=OFF -DWEBP_BUILD_EXTRAS=OFF
  build_cmake_shared "$arch" "$prefix" "$WORK_DIR/sources/libtiff" \
    -Dtiff-tools=OFF -Dtiff-tests=OFF -Dtiff-contrib=OFF -Dtiff-docs=OFF \
    -Djpeg=OFF -Dwebp=OFF -Dlzma=OFF -Dzstd=OFF -Dlibdeflate=OFF
  (
    cd "$WORK_DIR/sources/giflib"
    make clean >/dev/null 2>&1 || true
    # giflib's Makefile only emits a static archive; build a proper dylib by hand.
    make -j"$JOBS" CC="clang -arch $arch -mmacosx-version-min=11.0" \
      CFLAGS="-arch $arch -mmacosx-version-min=11.0 -O3 -fPIC" libgif.a
    clang -arch "$arch" -mmacosx-version-min=11.0 -dynamiclib \
      -install_name "$prefix/lib/libgif.7.dylib" \
      -current_version 7.2.0 -compatibility_version 7.0.0 \
      -o libgif.7.dylib *.o
    mkdir -p "$prefix/lib" "$prefix/include"
    cp libgif.7.dylib "$prefix/lib/"
    ln -sfn libgif.7.dylib "$prefix/lib/libgif.dylib"
    cp gif_lib.h "$prefix/include/"
    cat > "$prefix/lib/pkgconfig/giflib.pc" <<EOF
prefix=$prefix
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
      $(pkg-config --libs libjpeg libpng libraw_r libtiff-4 libwebp libwebpmux libwebpdemux) \
      -lgif \
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
# Merge the shared ImageMagick runtime and every shared image delegate.
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

# Lipo a shared library under the basename Magick records as its install name.
# Symlinks are resolved for lipo input but published under the ABI name.
lipo_shared_abi() {
  local abi_name="$1"
  local arm_path="$WORK_DIR/prefix-arm64/lib/$abi_name"
  local x86_path="$WORK_DIR/prefix-x86_64/lib/$abi_name"
  local arm_real x86_real
  test -e "$arm_path" || { echo "Missing arm64 shared library: $abi_name" >&2; return 1; }
  test -e "$x86_path" || { echo "Missing x86_64 shared library: $abi_name" >&2; return 1; }
  arm_real="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$arm_path")"
  x86_real="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$x86_path")"
  lipo -create "$arm_real" "$x86_real" -output "$bundle/$abi_name"
}

# ImageMagick links to LibRaw's thread-safe, versioned install name.  The
# unversioned files installed by LibRaw are development symlinks; feeding them
# through lipo would turn them into full duplicate files.  The non-thread-safe
# libraw variant is not referenced by this runtime either.
raw_versioned_arm="$(find "$WORK_DIR/prefix-arm64/lib" -maxdepth 1 -type f -name 'libraw_r.*.dylib' -print -quit)"
test -n "$raw_versioned_arm"
raw_name="$(basename "$raw_versioned_arm")"
lipo_shared_abi "$raw_name"
# MozJPEG installs a real libjpeg.62.3.0.dylib plus ABI/development symlinks,
# while consumers record libjpeg.62.dylib as the install name.
lipo_shared_abi "libjpeg.62.dylib"

# Ship a prefix dylib under the ABI basename Magick / dyld will look up.
# MagickCore may already record @rpath/<soname>.dylib (not an absolute
# prefix path), so absolute-path collection alone misses versioned names
# such as libwebpmux.3.dylib / libwebp.7.dylib / libsharpyuv.0.dylib.
package_prefix_dylib() {
  local abi_name="$1"
  case "$abi_name" in
    libraw*.dylib|libjpeg*.dylib) return 0 ;; # already packaged above
  esac
  [[ -f "$bundle/$abi_name" ]] && return 0
  [[ -e "$WORK_DIR/prefix-arm64/lib/$abi_name" ]] || return 0
  lipo_shared_abi "$abi_name"
}

# Collect every private shared library MagickCore was linked against and ship it.
arm_core="$(find "$WORK_DIR/prefix-arm64/imagemagick/lib" -maxdepth 1 -type f -name 'libMagickCore*.dylib' -print -quit)"
test -n "$arm_core"
while IFS= read -r dep; do
  case "$dep" in
    "$WORK_DIR/prefix-arm64/lib/"*)
      package_prefix_dylib "$(basename "$dep")"
      ;;
    @rpath/*)
      package_prefix_dylib "${dep#@rpath/}"
      ;;
  esac
done < <(otool -L "$arm_core" | tail -n +2 | awk '{print $1}')

# Close the transitive dependency graph (e.g. libwebp → libsharpyuv.0).
# Walk bundled dylibs until no new prefix libraries appear.
changed=1
while [[ "$changed" -eq 1 ]]; do
  changed=0
  while IFS= read -r -d '' bundled; do
    while IFS= read -r dep; do
      case "$dep" in
        @rpath/*|"$WORK_DIR/prefix-"*/lib/*)
          abi_name="$(basename "$dep")"
          if [[ ! -f "$bundle/$abi_name" && -e "$WORK_DIR/prefix-arm64/lib/$abi_name" ]]; then
            package_prefix_dylib "$abi_name"
            changed=1
          fi
          ;;
      esac
    done < <(otool -L "$bundled" | tail -n +2 | awk '{print $1}')
  done < <(find "$bundle" -maxdepth 1 -type f -name '*.dylib' -print0)
done

# Also ship common ABI aliases Magick / App tooling may dlopen by short name.
# Prefer versioned install names first — those are what LC_LOAD_DYLIB records.
for abi_name in \
  libpng16.16.dylib libpng16.dylib libpng.dylib \
  libwebp.7.dylib libwebpmux.3.dylib libwebpdemux.2.dylib libsharpyuv.0.dylib \
  libwebp.dylib libwebpmux.dylib libwebpdemux.dylib libsharpyuv.dylib \
  libtiff.6.dylib libtiff.dylib \
  libgif.7.dylib libgif.dylib
do
  if [[ -e "$WORK_DIR/prefix-arm64/lib/$abi_name" && ! -f "$bundle/$abi_name" ]]; then
    lipo_shared_abi "$abi_name" || true
  fi
done

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

# Public headers for App-side FFI. Staged under native-headers/ so fetch-deps
# can deploy selected trees into packages/*/native/vendor later. Runtime
# dylibs stay at the bundle root; headers never need to ship in Resources.
echo "Packaging MagickWand + shared-delegate public headers..."
headers_root="$bundle/native-headers"
rm -rf "$headers_root"
prefix_include="$WORK_DIR/prefix-arm64/include"
im_include="$WORK_DIR/prefix-arm64/imagemagick/include/ImageMagick-7"
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
# MozJPEG public C API (same set LibRaw / Magick consumers need).
for hdr in jpeglib.h jconfig.h jerror.h jmorecfg.h; do
  test -f "$prefix_include/$hdr"
  cp "$prefix_include/$hdr" "$headers_root/mozjpeg-${MOZJPEG_VERSION}/"
done
# libpng public headers (pnglibconf.h is generated at build time).
for hdr in png.h pngconf.h pnglibconf.h; do
  test -f "$prefix_include/$hdr"
  cp "$prefix_include/$hdr" "$headers_root/libpng-${LIBPNG_VERSION}/"
done
cp -R "$prefix_include/webp/." "$headers_root/libwebp-${LIBWEBP_VERSION}/webp/"
# libtiff public headers (skip private tif_*.h if any landed in include/).
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
  if ! formats="$(arch -"$arch" "$bundle/magick" -list format 2>"$bundle/.magick-list-format.$arch.err")"; then
    echo "magick -list format failed for $arch (exit $?)." >&2
    cat "$bundle/.magick-list-format.$arch.err" >&2 || true
    echo "--- bundle root ---" >&2
    ls -la "$bundle" >&2 || true
    echo "--- magick / MagickCore load commands ---" >&2
    otool -L "$bundle/magick" >&2 || true
    otool -L "$bundle"/libMagickCore*.dylib >&2 || true
    exit 1
  fi
  rm -f "$bundle/.magick-list-format.$arch.err"
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

# Shared image delegates must be present and referenced by MagickCore.
require_shared_delegate() {
  local pattern="$1"
  local label="$2"
  local lib regex
  lib="$(find "$bundle" -maxdepth 1 -type f -name "$pattern" -print -quit)"
  test -n "$lib" || { echo "Missing shared $label runtime library ($pattern)." >&2; return 1; }
  regex="@rpath/${pattern//\*/.*}"
  otool -L "$bundle/libMagickCore-7.Q16HDRI.10.dylib" | grep -Eq "$regex" || {
    echo "MagickCore is not dynamically linked to bundled $label ($regex)." >&2
    otool -L "$bundle/libMagickCore-7.Q16HDRI.10.dylib" >&2
    return 1
  }
  echo "  ✓ shared $label → $(basename "$lib")"
}
require_shared_delegate 'libpng*.dylib' PNG
require_shared_delegate 'libwebp*.dylib' WebP
require_shared_delegate 'libtiff*.dylib' TIFF
# giflib is shipped for App FFI. ImageMagick 7 uses its built-in GIF coder and
# does not put gif in DELEGATES / does not LC_LOAD external libgif — so only
# require the dylib to be present, not referenced by MagickCore.
gif_library="$(find "$bundle" -maxdepth 1 -type f -name 'libgif*.dylib' -print -quit)"
test -n "$gif_library" || { echo "Missing shared giflib runtime library." >&2; exit 1; }
echo "  ✓ shared giflib (standalone FFI) → $(basename "$gif_library")"
# SharpYUV is part of the WebP shared runtime.
if ! find "$bundle" -maxdepth 1 -type f -name 'libsharpyuv*.dylib' -print -quit | grep -q .; then
  echo "Missing shared SharpYUV (libwebp dependency)." >&2
  exit 1
fi

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
test -f "$verify_bundle/native-headers/versions.env"
test -f "$verify_bundle/native-headers/imagemagick-${IMAGEMAGICK_VERSION}/MagickWand/MagickWand.h"
test -f "$verify_bundle/native-headers/libraw-${LIBRAW_VERSION}/libraw/libraw.h"
test -f "$verify_bundle/native-headers/mozjpeg-${MOZJPEG_VERSION}/jpeglib.h"
test -f "$verify_bundle/native-headers/libpng-${LIBPNG_VERSION}/png.h"
test -f "$verify_bundle/native-headers/libwebp-${LIBWEBP_VERSION}/webp/decode.h"
test -f "$verify_bundle/native-headers/libtiff-${LIBTIFF_VERSION}/tiffio.h"
test -f "$verify_bundle/native-headers/giflib-${GIFLIB_VERSION}/gif_lib.h"
MAGICK_CONFIGURE_PATH="$verify_bundle/ImageMagick-7" "$verify_bundle/magick" -version
for arch in "${ARCHITECTURES[@]}"; do
  arch -"$arch" "$verify_bundle/magick" -version >/dev/null
done
rm -rf "$verify_dir"
trap - EXIT
shasum -a 256 "$archive" > "$archive.sha256"
