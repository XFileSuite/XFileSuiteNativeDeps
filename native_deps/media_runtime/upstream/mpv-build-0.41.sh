#!/bin/bash

set -euo pipefail

cd "${SRC_DIR}"

# mpv 0.41 requires libplacebo. Keep it as a static implementation detail of
# libmpv: the public runtime remains libmpv + the shared FFmpeg frameworks.
libplacebo_version="6.338.2"
libplacebo_commit="64c1954570f1cd57f8570a57e51fb0249b57bb90"
mkdir -p subprojects
if [[ ! -d subprojects/libplacebo ]]; then
    git clone \
        --depth 1 \
        --branch "v${libplacebo_version}" \
        --recurse-submodules \
        --shallow-submodules \
        https://github.com/haasn/libplacebo.git \
        subprojects/libplacebo
    test "$(git -C subprojects/libplacebo rev-parse HEAD)" = "${libplacebo_commit}"
fi

# mpv 0.41 adds the macOS clipboard Objective-C bridge whenever Cocoa is
# enabled, although that file requires the Swift header which is only
# generated with swift-build. media-kit uses libmpv and does not need the
# standalone player's system clipboard backend.
sed -i '' \
    -e '/player\/clipboard\/clipboard-mac\.m/d' \
    -e "s#'osdep/mac/app_bridge.m',#'osdep/mac/app_bridge.m'#" \
    meson.build

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
