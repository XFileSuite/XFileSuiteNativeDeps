#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NATIVE_DEPS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WORK_DIR="${WORK_DIR:-$SCRIPT_DIR/work}"
DIST_DIR="${DIST_DIR:-$SCRIPT_DIR/dist}"
UPSTREAM_TAG="${LIBMPV_DARWIN_BUILD_TAG:-v0.6.0}"
UPSTREAM_COMMIT="${LIBMPV_DARWIN_BUILD_COMMIT:-4286f5557bdccc0747030e3c376ce5cd160a96a0}"
RUNTIME_VERSION="${RUNTIME_VERSION:-8.0.1-mpv-0.41.0}"
RELEASE_REVISION="${RELEASE_REVISION:-1}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required tool: $1" >&2
    exit 1
  }
}

for tool in git make meson ninja go xcodebuild lipo otool install_name_tool; do
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
  cmd/downloads/main.go \
  cross-files/macos-amd64.ini \
  cross-files/macos-arm64.ini \
  downloads.lock \
  scripts/mpv/build.sh \
  scripts/pkg-config/build.sh \
  scripts/pkg-config/meson.build \
  scripts/uchardet/build.sh \
  scripts/uchardet/meson.build
git -C "$upstream" apply "$SCRIPT_DIR/patches/libmpv-downloads-retry.patch"
git -C "$upstream" apply "$SCRIPT_DIR/patches/libmpv-pkg-config-clang17.patch"
git -C "$upstream" apply "$SCRIPT_DIR/patches/libmpv-cmake4-policy.patch"
cp "$SCRIPT_DIR/upstream/mpv-build-0.41.sh" "$upstream/scripts/mpv/build.sh"
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
# Savannah serves the byte-identical, checksum-pinned FreeType release.
sed -i '' \
  's#https://downloads.sourceforge.net/project/freetype/freetype2/2.13.2/#https://download.savannah.gnu.org/releases/freetype/#' \
  "$upstream/downloads.lock"
sed -i '' \
  -e '/^mpv:/,/^[a-zA-Z0-9_-]*:/ s/version: 0.36.0/version: 0.41.0/' \
  -e '/^mpv:/,/^[a-zA-Z0-9_-]*:/ s#v0.36.0.tar.gz#v0.41.0.tar.gz#' \
  -e '/^mpv:/,/^[a-zA-Z0-9_-]*:/ s#29abc44f8ebee013bb2f9fe14d80b30db19b534c679056e4851ceadf5a5e8bf6#ee21092a5ee427353392360929dc64645c54479aefdb5babc5cfbb5fad626209#' \
  "$upstream/downloads.lock"

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

echo "==> Relinking FFmpeg CLI to the same XCFramework binaries used by libmpv"
while IFS= read -r dependency; do
  dylib_name="$(basename "$dependency")"
  stem="${dylib_name#lib}"
  stem="${stem%%.*}"
  framework_name="$(tr '[:lower:]' '[:upper:]' <<<"${stem:0:1}")${stem:1}"
  if [[ -d "$frameworks/$framework_name.xcframework" ]]; then
    install_name_tool -change "$dependency" \
      "@rpath/$framework_name.framework/Versions/A/$framework_name" \
      "$shared_ffmpeg"
  fi
done < <(otool -L "$shared_ffmpeg" | awk '/@rpath\/(libav|libsw).*\.dylib/ {print $1}')
install_name_tool -add_rpath "@executable_path/../Frameworks" "$shared_ffmpeg" 2>/dev/null || true

FRAMEWORKS_SOURCE="$frameworks" \
FFMPEG_BINARY="$shared_ffmpeg" \
VERSION="$RUNTIME_VERSION" \
RELEASE_REVISION="$RELEASE_REVISION" \
DIST_DIR="$DIST_DIR" \
WORK_DIR="$WORK_DIR/package" \
  "$SCRIPT_DIR/package-macos-runtime.sh"
