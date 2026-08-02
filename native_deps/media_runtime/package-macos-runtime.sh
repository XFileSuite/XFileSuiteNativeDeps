#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRAMEWORKS_SOURCE="${FRAMEWORKS_SOURCE:?set FRAMEWORKS_SOURCE to the directory containing *.xcframework}"
FFMPEG_BINARY="${FFMPEG_BINARY:?set FFMPEG_BINARY to the shared-runtime ffmpeg executable}"
LICENSES_SOURCE="${LICENSES_SOURCE:?set LICENSES_SOURCE to the collected runtime licenses}"
VERSION="${VERSION:-8.1.2-mpv-0.41.0}"
RELEASE_REVISION="${RELEASE_REVISION:-2}"
DIST_DIR="${DIST_DIR:-$SCRIPT_DIR/dist}"
WORK_DIR="${WORK_DIR:-$SCRIPT_DIR/work}"
RELEASE_ID="media-runtime-macos-${VERSION}-xfilesuite.${RELEASE_REVISION}"
STAGE_DIR="$WORK_DIR/$RELEASE_ID"
ARCHIVE="$DIST_DIR/$RELEASE_ID.tar.gz"

rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR/Frameworks" "$STAGE_DIR/Tools" "$STAGE_DIR/lib" "$STAGE_DIR/licenses" "$STAGE_DIR/metadata" "$DIST_DIR"
cp -R "$FRAMEWORKS_SOURCE"/*.xcframework "$STAGE_DIR/Frameworks/"
cp "$FFMPEG_BINARY" "$STAGE_DIR/Tools/ffmpeg"
chmod +x "$STAGE_DIR/Tools/ffmpeg"
cp -R "$LICENSES_SOURCE"/. "$STAGE_DIR/licenses/"

# FFmpeg already records @rpath/libav*.dylib and searches ../lib. These aliases
# point into the same framework binaries used by libmpv; no dylib is duplicated.
while IFS= read -r dependency; do
  dylib_name="$(basename "$dependency")"
  stem="${dylib_name#lib}"
  stem="${stem%%.*}"
  framework_name="$(tr '[:lower:]' '[:upper:]' <<<"${stem:0:1}")${stem:1}"
  framework_binary="$(find "$STAGE_DIR/Frameworks/$framework_name.xcframework" \
    -type f -path "*/$framework_name.framework/Versions/A/$framework_name" -print -quit)"
  test -n "$framework_binary"
  ln -s "../${framework_binary#"$STAGE_DIR/"}" "$STAGE_DIR/lib/$dylib_name"
done < <(otool -L "$STAGE_DIR/Tools/ffmpeg" | awk '$1 ~ /@rpath\/(libav|libsw).*[.]dylib/ {print $1}' | sort -u)

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
  {
    find Frameworks Tools licenses metadata -type f ! -path 'metadata/SHA256SUMS' -print0
    find lib \( -type f -o -type l \) -print0
  } |
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
