#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRAMEWORKS_SOURCE="${FRAMEWORKS_SOURCE:?set FRAMEWORKS_SOURCE to the directory containing *.xcframework}"
FFMPEG_BINARY="${FFMPEG_BINARY:?set FFMPEG_BINARY to the shared-runtime ffmpeg executable}"
VERSION="${VERSION:-8.0.1-mpv-0.36.0}"
RELEASE_REVISION="${RELEASE_REVISION:-1}"
DIST_DIR="${DIST_DIR:-$SCRIPT_DIR/dist}"
WORK_DIR="${WORK_DIR:-$SCRIPT_DIR/work}"
RELEASE_ID="media-runtime-macos-${VERSION}-xfilesuite.${RELEASE_REVISION}"
STAGE_DIR="$WORK_DIR/$RELEASE_ID"
ARCHIVE="$DIST_DIR/$RELEASE_ID.tar.gz"

rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR/Frameworks" "$STAGE_DIR/Tools" "$STAGE_DIR/metadata" "$DIST_DIR"
cp -R "$FRAMEWORKS_SOURCE"/*.xcframework "$STAGE_DIR/Frameworks/"
cp "$FFMPEG_BINARY" "$STAGE_DIR/Tools/ffmpeg"
chmod +x "$STAGE_DIR/Tools/ffmpeg"

cat > "$STAGE_DIR/metadata/BUILDINFO.md" <<EOF
# XFileSuite macOS media runtime

- Runtime version: $VERSION
- Release revision: $RELEASE_REVISION
- Architecture: macOS universal (arm64 and x86_64)
- FFmpeg CLI and libmpv use the same FFmpeg shared frameworks.
- FFmpeg is built without GPL and nonfree components.
- mpv is built with \`-Dgpl=false\`.
EOF

(
  cd "$STAGE_DIR"
  find Frameworks Tools metadata -type f -print0 |
    sort -z |
    while IFS= read -r -d '' file; do
      shasum -a 256 "$file"
    done > metadata/SHA256SUMS
)

"$SCRIPT_DIR/verify-macos-runtime.sh" "$STAGE_DIR"
rm -f "$ARCHIVE" "$ARCHIVE.sha256"
tar -czf "$ARCHIVE" -C "$WORK_DIR" "$RELEASE_ID"
shasum -a 256 "$ARCHIVE" > "$ARCHIVE.sha256"
echo "$ARCHIVE"

