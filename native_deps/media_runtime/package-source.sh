#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${WORK_DIR:-$SCRIPT_DIR/work}"
DIST_DIR="${DIST_DIR:-$SCRIPT_DIR/dist}"
VERSION="${VERSION:-8.0.1-mpv-0.41.0}"
RELEASE_REVISION="${RELEASE_REVISION:-1}"
RELEASE_ID="media-runtime-macos-${VERSION}-xfilesuite.${RELEASE_REVISION}"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/xfilesuite-media-source.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$STAGE/build-scripts" "$STAGE/upstream" "$DIST_DIR"
cp -R "$SCRIPT_DIR"/. "$STAGE/build-scripts/"
rm -rf "$STAGE/build-scripts/work" "$STAGE/build-scripts/dist"
cp -R "$(cd "$SCRIPT_DIR/../ffmpeg" && pwd)" "$STAGE/build-scripts/ffmpeg"
rm -rf "$STAGE/build-scripts/ffmpeg/work" "$STAGE/build-scripts/ffmpeg/dist"

if [[ -d "$WORK_DIR/libmpv-darwin-build/.git" ]]; then
  git -C "$WORK_DIR/libmpv-darwin-build" archive --format=tar HEAD |
    tar -xf - -C "$STAGE/upstream"
  git -C "$WORK_DIR/libmpv-darwin-build" diff --binary > "$STAGE/upstream/xfilesuite-build.patch"
fi

mkdir -p "$STAGE/upstream/downloads"
find "$WORK_DIR/ffmpeg" "$WORK_DIR/libmpv-darwin-build/build/intermediate/downloads" \
  -maxdepth 2 -type f \( -name '*.tar.gz' -o -name '*.tar.xz' -o -name '*.tar.bz2' -o -name '*.zip' \) \
  -exec cp {} "$STAGE/upstream/downloads/" \; 2>/dev/null || true

# FreeType's Meson wrap downloads libpng outside downloads.lock. Preserve the
# exact expanded source used by this build so the corresponding-source archive
# is complete even if the wrap URL changes later.
libpng_source="$(find "$WORK_DIR/libmpv-darwin-build/build/tmp" -type d -path '*/subprojects/libpng-1.6.40' -print -quit)"
test -n "$libpng_source"
cp -R "$libpng_source" "$STAGE/upstream/libpng-1.6.40"

cat > "$STAGE/BUILDINFO.md" <<EOF
# XFileSuite media runtime corresponding source

- Release: $RELEASE_ID
- FFmpeg: 8.0.1, configured without GPL or nonfree components
- mpv: 0.41.0, configured with -Dgpl=false
- Build entry point: build-scripts/build-macos.sh
- Exact upstream checksums are recorded by the vendored build scripts and downloads.lock.
EOF

(cd "$STAGE" && find . -type f -print0 | sort -z | xargs -0 shasum -a 256) > "$STAGE/SHA256SUMS"
ARCHIVE="$DIST_DIR/xfilesuite-$RELEASE_ID-source.tar.gz"
tar -czf "$ARCHIVE" -C "$STAGE" .
shasum -a 256 "$ARCHIVE" > "$ARCHIVE.sha256"
echo "$ARCHIVE"
