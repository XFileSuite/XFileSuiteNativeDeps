#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NATIVE_DEPS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WORK_DIR="${WORK_DIR:-$SCRIPT_DIR/work}"
DIST_DIR="${DIST_DIR:-$SCRIPT_DIR/dist}"
UPSTREAM_TAG="${LIBMPV_DARWIN_BUILD_TAG:-v0.6.0}"
UPSTREAM_COMMIT="${LIBMPV_DARWIN_BUILD_COMMIT:-4286f5557bdccc0747030e3c376ce5cd160a96a0}"
RUNTIME_VERSION="${RUNTIME_VERSION:-8.1.2-mpv-0.41.0}"
RELEASE_REVISION="${RELEASE_REVISION:-2}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required tool: $1" >&2
    exit 1
  }
}

for tool in git make meson ninja go ruby curl xcodebuild lipo otool install_name_tool codesign; do
  need "$tool"
done

mkdir -p "$WORK_DIR" "$DIST_DIR"

echo "==> Building the shared FFmpeg 8 runtime"
ffmpeg_build_args=(--no-package --no-install)
if [[ "${FFMPEG_UNIVERSAL_ONLY:-0}" == "1" ]]; then
  ffmpeg_build_args+=(--universal-only)
fi
ffmpeg_work="$WORK_DIR/ffmpeg"
ffmpeg_dist="$WORK_DIR/ffmpeg-dist"
FFMPEG_LINKAGE=shared \
WORK_DIR="$ffmpeg_work" \
DIST_DIR="$ffmpeg_dist" \
JOBS="$JOBS" \
  "$NATIVE_DEPS_DIR/ffmpeg/build.sh" "${ffmpeg_build_args[@]}"

ffmpeg_output="$(find "$ffmpeg_dist" -mindepth 1 -maxdepth 1 -type d -name 'ffmpeg-*-macos-universal' -print | sort | tail -n 1)"
test -n "$ffmpeg_output"
test -x "$ffmpeg_output/bin/ffmpeg"

upstream="$WORK_DIR/libmpv-darwin-build"
if [[ ! -d "$upstream/.git" ]]; then
  git clone --branch "$UPSTREAM_TAG" https://github.com/media-kit/libmpv-darwin-build.git "$upstream"
fi
git -C "$upstream" fetch --tags --force
git -C "$upstream" checkout --detach "$UPSTREAM_COMMIT"
git -C "$upstream" restore --source="$UPSTREAM_COMMIT" -- \
  Makefile \
  cmd/downloads/main.go \
  cross-files/macos-amd64.ini \
  cross-files/macos-arm64.ini \
  downloads.lock \
  scripts/libs-arch/relink-dylibs.sh \
  scripts/mpv/build.sh \
  scripts/pkg-config/build.sh \
  scripts/pkg-config/meson.build \
  scripts/uchardet/build.sh \
  scripts/uchardet/meson.build
git -C "$upstream" apply "$SCRIPT_DIR/patches/libmpv-downloads-retry.patch"
git -C "$upstream" apply "$SCRIPT_DIR/patches/libmpv-pkg-config-clang17.patch"
git -C "$upstream" apply "$SCRIPT_DIR/patches/libmpv-cmake4-policy.patch"
cp "$SCRIPT_DIR/patches/libmpv-hevc-alpha-output.patch" \
  "$upstream/patches/libmpv-hevc-alpha-output.patch"
# The injected FFmpeg prefix lives outside libmpv-darwin-build. Teach its
# per-architecture relinker to normalize those paths before lipo/frameworks.
# The replacement must preserve upstream shell variables.
# shellcheck disable=SC2016
sed -i '' \
  's#grep -E "$SOURCE_PREFIX|\^lib"#grep -E "$SOURCE_PREFIX|/native_deps/media_runtime/work/ffmpeg/prefix-|^lib"#' \
  "$upstream/scripts/libs-arch/relink-dylibs.sh"
cp "$SCRIPT_DIR/upstream/mpv-build-0.41.sh" "$upstream/scripts/mpv/build.sh"
cp "$SCRIPT_DIR/upstream/app-bridge-no-swift.m" "$upstream/scripts/mpv/app-bridge-no-swift.m"
chmod +x "$upstream/scripts/mpv/build.sh"
# New Meson versions require CMake to be declared explicitly for cross builds.
for cross_file in macos-arm64.ini macos-amd64.ini; do
  sed -i '' "/pkgconfig = \\['pkg-config'\\]/a\\
cmake = ['cmake']
" "$upstream/cross-files/$cross_file"
done
# Align mpv and all of its static helper libraries with the application and
# shared FFmpeg deployment target.
sed -i '' 's/-mmacosx-version-min=10.9/-mmacosx-version-min=11.0/g' \
  "$upstream/cross-files/macos-arm64.ini" \
  "$upstream/cross-files/macos-amd64.ini"
# SourceForge's redirect endpoint regularly stalls on GitHub macOS runners.
# OSUOSL mirrors the byte-identical, checksum-pinned FreeType release.
sed -i '' \
  's#https://downloads.sourceforge.net/project/freetype/freetype2/2.13.2/#https://ftp.osuosl.org/pub/blfs/conglomeration/freetype/#' \
  "$upstream/downloads.lock"
ruby -ryaml -e '
  path = ARGV.fetch(0)
  lock = YAML.load_file(path)
  keep = %w[dav1d freetype fribidi harfbuzz libass libxml2 mpv pkg-config uchardet]
  missing = keep - lock.keys
  abort "missing locked dependencies: #{missing.join(", ")}" unless missing.empty?
  lock.select! { |name, _| keep.include?(name) }
  lock.fetch("mpv").merge!(
    "version" => "0.41.0",
    "url" => "https://github.com/mpv-player/mpv/archive/refs/tags/v0.41.0.tar.gz",
    "sha256" => "ee21092a5ee427353392360929dc64645c54479aefdb5babc5cfbb5fad626209"
  )
  File.write(path, YAML.dump(lock))
' "$upstream/downloads.lock"

# Keep the distributed runtime under LGPL-2.1: do not build Mbed TLS
# (Apache-2.0) and remove the TLS/HTTPS protocols that require it.  The
# upstream make graph otherwise builds Mbed TLS even though this runtime
# injects XFileSuite's own shared FFmpeg prefix.  Remove both its full target
# rule and its two references; deleting only matching lines would leave the
# rule's continuation lines as invalid top-level make commands.
sed -i '' \
  -e '/^# mbedtls_/,/^# libxml2_/{ /^# libxml2_/!d; }' \
  -e '/mbedtls_/d' \
  "$upstream/Makefile"
sed -i '' \
  -e "/--enable-mbedtls/d" \
  -e "/--enable-version3/d" \
  -e "s/--enable-network/--disable-network/g" \
  -e "/--enable-protocol=https/d" \
  -e "/--enable-protocol=tls/d" \
  -e "/--enable-protocol=rtmps/d" \
  -e "/--enable-protocol=rtmpts/d" \
  "$upstream/scripts/ffmpeg/meson.build"

echo "==> Injecting the ABI-identical shared FFmpeg prefixes into the libmpv build"
for mapping in "arm64:arm64" "amd64:x86_64"; do
  mpv_arch="${mapping%%:*}"
  ffmpeg_arch="${mapping##*:}"
  injected="$upstream/build/intermediate/ffmpeg_macos-${mpv_arch}-video-default"
  rm -rf "$injected"
  mkdir -p "$injected"
  cp -R "$WORK_DIR/ffmpeg/prefix-${ffmpeg_arch}/." "$injected/"
  touch "$injected"
done

arm_ffmpeg="build/intermediate/ffmpeg_macos-arm64-video-default"
amd_ffmpeg="build/intermediate/ffmpeg_macos-amd64-video-default"
xcframework_target="build/intermediate/xcframeworks_macos-universal-video-default"

echo "==> Building LGPL libmpv and the XCFramework set"
(
  cd "$upstream"
  make -j"$JOBS" \
    -o "$arm_ffmpeg" \
    -o "$amd_ffmpeg" \
    "$xcframework_target"
)

frameworks="$WORK_DIR/Frameworks"
rm -rf "$frameworks"
mkdir -p "$frameworks"
cp -R "$upstream/$xcframework_target/"*.xcframework "$frameworks/"

shared_ffmpeg="$WORK_DIR/ffmpeg-shared"
cp "$ffmpeg_output/bin/ffmpeg" "$shared_ffmpeg"
chmod +x "$shared_ffmpeg"

echo "==> Ad-hoc signing the relocatable runtime"
while IFS= read -r framework; do
  codesign --force --sign - --timestamp=none "$framework"
done < <(find "$frameworks" -type d -name '*.framework' -print)
codesign --force --sign - --timestamp=none "$shared_ffmpeg"

echo "==> Collecting distributable license texts"
licenses="$WORK_DIR/licenses"
rm -rf "$licenses"
mkdir -p "$licenses"
cp "$ffmpeg_work/ffmpeg-8.1.2/COPYING.LGPLv2.1" "$licenses/FFmpeg-LGPL-2.1.txt"
cp "$ffmpeg_work/ffmpeg-8.1.2/LICENSE.md" "$licenses/FFmpeg-LICENSE.md"
cp "$ffmpeg_work/lame-3.100/COPYING" "$licenses/LAME-LGPL-2.0.txt"
cp "$ffmpeg_work/opus-1.5.2/COPYING" "$licenses/Opus-COPYING.txt"
cp "$ffmpeg_work/libogg-1.3.5/COPYING" "$licenses/libogg-COPYING.txt"
cp "$ffmpeg_work/libvorbis-1.3.7/COPYING" "$licenses/libvorbis-COPYING.txt"
cp "$ffmpeg_work/libvpx-1.15.2/LICENSE" "$licenses/libvpx-LICENSE.txt"
cp "$ffmpeg_work/libwebp-1.6.0/COPYING" "$licenses/libwebp-COPYING.txt"
cp "$upstream/LICENSE.txt" "$licenses/libmpv-darwin-build-LICENSE.txt"

# Upstream moves the verified downloads from tmp/ into intermediate/ before
# compiling. Keep license collection on the canonical cached archive set.
downloads="$upstream/build/intermediate/downloads"
extract_license() {
  archive="$1" pattern="$2" destination="$3"
  member="$(tar -tf "$archive" | grep -E "$pattern" | sed -n '1p')"
  test -n "$member"
  tar -xOf "$archive" "$member" > "$licenses/$destination"
}
extract_license "$downloads/mpv-0.41.0.tar.gz" '/Copyright$' mpv-Copyright.txt
extract_license "$downloads/dav1d-1.2.1.tar.bz2" '/COPYING$' dav1d-COPYING.txt
extract_license "$downloads/freetype-2.13.2.tar.xz" '/docs/FTL.TXT$' FreeType-FTL.txt
extract_license "$downloads/fribidi-1.0.13.tar.xz" '/COPYING$' FriBidi-COPYING.txt
extract_license "$downloads/harfbuzz-8.1.1.tar.gz" '/COPYING$' HarfBuzz-COPYING.txt
extract_license "$downloads/libass-0.17.1.tar.xz" '/COPYING$' libass-COPYING.txt
extract_license "$downloads/libxml2-2.11.5.tar.xz" '/Copyright$' libxml2-Copyright.txt
extract_license "$downloads/uchardet-0.0.8.tar.xz" '/COPYING$' uchardet-COPYING.txt

# libplacebo is cloned directly by the mpv build script (not through
# downloads.lock) and its source tree is cleaned up after the build.
# Fetch the LICENSE from the pinned tag to avoid depending on tmp dirs.
libplacebo_version="6.338.2"
curl --fail --location --retry 3 \
  "https://raw.githubusercontent.com/haasn/libplacebo/v${libplacebo_version}/LICENSE" \
  --output "$licenses/libplacebo-LICENSE.txt"

# FreeType declares libpng as a checksum-pinned Meson wrap rather than in the
# parent downloads.lock. Cache both wrap assets beside the other verified
# sources so licenses and corresponding source never depend on cleaned tmp dirs.
freetype_archive="$downloads/freetype-2.13.2.tar.xz"
wrap_member="$(tar -tf "$freetype_archive" | grep -E '/subprojects/libpng[.]wrap$' | sed -n '1p')"
test -n "$wrap_member"
wrap_contents="$(tar -xOf "$freetype_archive" "$wrap_member")"
wrap_value() {
  printf '%s\n' "$wrap_contents" | awk -F= -v key="$1" '$1 ~ "^[[:space:]]*" key "[[:space:]]*$" {sub(/^[[:space:]]*/, "", $2); sub(/[[:space:]]*$/, "", $2); print $2; exit}'
}
cache_wrap_asset() {
  url="$1" expected_sha="$2" output="$3"
  if [[ ! -f "$output" ]] || [[ "$(shasum -a 256 "$output" | awk '{print $1}')" != "$expected_sha" ]]; then
    rm -f "$output"
    curl --fail --location --retry 5 --retry-all-errors --connect-timeout 30 "$url" --output "$output"
  fi
  test "$(shasum -a 256 "$output" | awk '{print $1}')" = "$expected_sha"
}
libpng_archive="$downloads/libpng-1.6.40.tar.gz"
libpng_patch="$downloads/libpng-1.6.40-wrap-patch.zip"
cache_wrap_asset "$(wrap_value source_url)" "$(wrap_value source_hash)" "$libpng_archive"
cache_wrap_asset "$(wrap_value patch_url)" "$(wrap_value patch_hash)" "$libpng_patch"
extract_license "$libpng_archive" '/LICENSE$' libpng-LICENSE.txt

cat > "$licenses/NOTICE.md" <<'EOF'
# XFileSuite shared media runtime notices

This bundle contains the following third-party components:

| Component | License |
| --- | --- |
| FFmpeg 8.1.2 (shared libs + CLI) | LGPL-2.1 |
| mpv 0.41.0 | LGPL-2.1 (built with `-Dgpl=false`) |
| libplacebo 6.338.2 | LGPL-2.1 |
| LAME | LGPL-2.0 |
| libass | ISC |
| dav1d | BSD-2-Clause |
| FreeType | FTL (BSD-like) |
| FriBidi | LGPL-2.1 |
| HarfBuzz | MIT |
| libxml2 | MIT |
| libpng | BSD-2-Clause |
| uchardet | **MPL-2.0** (file-level weak copyleft; source included in corresponding-source archive) |
| Opus | BSD-3-Clause |
| libogg | BSD-3-Clause |
| libvorbis | BSD-3-Clause |
| libvpx | BSD-3-Clause |
| libwebp | BSD-3-Clause |

FFmpeg was built with `--disable-gpl --disable-nonfree --disable-version3`.
Mbed TLS and the HTTPS/TLS/RTMPS protocols are intentionally excluded so the
runtime remains LGPL-2.1-compatible.
mpv was built with `-Dgpl=false`. No x264/x265 or encoders-GPL flavor is
included. Exact source archives, patches, checksums, and build scripts are
published in the corresponding-source GitHub Release named in the manifest.
EOF

FRAMEWORKS_SOURCE="$frameworks" \
FFMPEG_BINARY="$shared_ffmpeg" \
LICENSES_SOURCE="$licenses" \
VERSION="$RUNTIME_VERSION" \
RELEASE_REVISION="$RELEASE_REVISION" \
DIST_DIR="$DIST_DIR" \
WORK_DIR="$WORK_DIR/package" \
  "$SCRIPT_DIR/package-macos-runtime.sh"
