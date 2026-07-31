#!/bin/bash

set -euo pipefail

cd "${SRC_DIR}"

# mpv 0.41 requires libplacebo. Keep it as a static implementation detail of
# libmpv: the public runtime remains libmpv + the shared FFmpeg frameworks.
libplacebo_version="6.338.2"
libplacebo_sha256="2f1e624e09d72a8c9db70f910f7560e764a1c126dae42acc5b3bcef836a7aec6"
libplacebo_archive="${BUILD_DIR}/libplacebo-${libplacebo_version}.tar.gz"
mkdir -p subprojects
if [[ ! -d subprojects/libplacebo ]]; then
    curl -L --fail --retry 5 --retry-all-errors \
        -o "${libplacebo_archive}" \
        "https://github.com/haasn/libplacebo/archive/refs/tags/v${libplacebo_version}.tar.gz"
    echo "${libplacebo_sha256}  ${libplacebo_archive}" | shasum -a 256 -c -
    tar -xzf "${libplacebo_archive}" -C subprojects
    mv "subprojects/libplacebo-${libplacebo_version}" subprojects/libplacebo
fi

options=(
    -Dauto_features=disabled
    -Dgpl=false
    -Dcplayer=false
    -Dlibmpv=true
    -Dbuild-date=false
    -Dtests=false
    -Diconv=enabled
    -Duchardet=enabled
    -Dzlib=enabled
    -Dcoreaudio=enabled
    -Dcocoa=enabled
    -Dgl=enabled
    -Dplain-gl=enabled
    -Dgl-cocoa=enabled
    -Dvideotoolbox-gl=enabled
    -Dvulkan=disabled
    -Dswift-build=disabled
    -Dhtml-build=disabled
    -Dmanpage-build=disabled
    -Dpdf-build=disabled
    -Dlibplacebo:demos=false
    -Dlibplacebo:tests=false
    -Dlibplacebo:vulkan=disabled
    -Dlibplacebo:opengl=enabled
    -Dlibplacebo:d3d11=disabled
    -Dlibplacebo:glslang=disabled
    -Dlibplacebo:shaderc=disabled
    -Dlibplacebo:lcms=disabled
    -Dlibplacebo:dovi=disabled
    -Dlibplacebo:libdovi=disabled
    -Dlibplacebo:unwind=disabled
    -Dlibplacebo:xxhash=disabled
)

meson setup build \
    --cross-file "${PROJECT_DIR}/cross-files/${OS}-${ARCH}.ini" \
    --prefix="${OUTPUT_DIR}" \
    "${options[@]}" |
    tee configure.log

meson compile -C build
meson install -C build

mkdir -p "${OUTPUT_DIR}/share/mpv"
cp configure.log "${OUTPUT_DIR}/share/mpv/"
