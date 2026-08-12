#!/usr/bin/env bash
# Creates the corresponding source offer for the Windows media runtime.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${WORK_DIR:-$SCRIPT_DIR/work}"
DIST_DIR="${DIST_DIR:-$SCRIPT_DIR/dist}"
VERSION="${VERSION:-8.1.2-mpv-0.41.0}"
RELEASE_REVISION="${RELEASE_REVISION:-3}"
RELEASE_ID="media-runtime-windows-${VERSION}-xfilesuite.${RELEASE_REVISION}"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/xfilesuite-media-win-source.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$STAGE/build-scripts" "$STAGE/upstream/downloads" "$DIST_DIR"
cp -R "$SCRIPT_DIR"/. "$STAGE/build-scripts/"
rm -rf "$STAGE/build-scripts/work" "$STAGE/build-scripts/dist"
cp -R "$(cd "$SCRIPT_DIR/../ffmpeg" && pwd)" "$STAGE/build-scripts/ffmpeg"
rm -rf "$STAGE/build-scripts/ffmpeg/work" "$STAGE/build-scripts/ffmpeg/dist" "$STAGE/build-scripts/ffmpeg/work-windows" "$STAGE/build-scripts/ffmpeg/dist-windows"

for archive in "$WORK_DIR"/ffmpeg/*.{tar.gz,tar.xz,tar.bz2,zip} "$WORK_DIR"/mpv-*.tar.gz "$WORK_DIR"/ANGLE.7z; do
  [[ -f "$archive" ]] && cp "$archive" "$STAGE/upstream/downloads/"
done
test -f "$STAGE/upstream/downloads/mpv-0.41.0.tar.gz"
test -f "$STAGE/upstream/downloads/ffmpeg-8.1.2.tar.xz"

libplacebo="$WORK_DIR/mpv-0.41.0/subprojects/libplacebo"
test -d "$libplacebo"
cp -R "$libplacebo" "$STAGE/upstream/libplacebo-6.338.2"
find "$STAGE/upstream/libplacebo-6.338.2" -type d -name .git -prune -exec rm -rf {} +

cat > "$STAGE/BUILDINFO.md" <<EOF
# XFileSuite Windows media runtime corresponding source

- Release: $RELEASE_ID
- FFmpeg: 8.1.2, configured with libass subtitle rendering and network playback (HTTP/HTTPS/HLS/DASH/RTMP/RTMPS/RTSP/RTP) via Windows SChannel. Built without GPL, nonfree, version3, Mbed TLS, or non-system TLS libraries.
- mpv: 0.41.0, configured with -Dgpl=false
- libplacebo: 6.338.2 (source included in upstream/)
- Build entry point: build-scripts/build-windows.sh
EOF

(cd "$STAGE" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum) > "$STAGE/SHA256SUMS"
ARCHIVE="$DIST_DIR/xfilesuite-$RELEASE_ID-source.tar.gz"
tar -czf "$ARCHIVE" -C "$STAGE" .
sha256sum "$ARCHIVE" > "$ARCHIVE.sha256"
echo "$ARCHIVE"
