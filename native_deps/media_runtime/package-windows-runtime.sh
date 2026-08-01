#!/usr/bin/env bash
# Packages the Windows media runtime into a distributable tar.gz archive.
#
# Mirrors the macOS package-macos-runtime.sh layout but uses bin/lib/include
# instead of Frameworks/Tools/lib to match Windows DLL conventions.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAGE="${FRAMEWORKS_SOURCE:?set FRAMEWORKS_SOURCE to the staged runtime directory}"
FFMPEG_BINARY="${FFMPEG_BINARY:?set FFMPEG_BINARY to the shared ffmpeg.exe}"
LICENSES_SOURCE="${LICENSES_SOURCE:?set LICENSES_SOURCE to the collected licenses}"
VERSION="${VERSION:-8.1.2-mpv-0.41.0}"
RELEASE_REVISION="${RELEASE_REVISION:-1}"
DIST_DIR="${DIST_DIR:-$SCRIPT_DIR/dist}"
WORK_DIR="${WORK_DIR:-$SCRIPT_DIR/work}"
RELEASE_ID="media-runtime-windows-${VERSION}-xfilesuite.${RELEASE_REVISION}"
ARCHIVE="$DIST_DIR/$RELEASE_ID.tar.gz"

test -d "$STAGE/bin"
test -f "$STAGE/bin/libmpv-2.dll"
test -f "$STAGE/bin/ffmpeg.exe"
test -f "$STAGE/bin/libEGL.dll"

# Verify that ffmpeg.exe and libmpv-2.dll both link the shared FFmpeg DLLs.
# On Windows, `objdump -p` lists DLL imports.
if command -v objdump >/dev/null 2>&1; then
  for binary in "$STAGE/bin/ffmpeg.exe" "$STAGE/bin/libmpv-2.dll"; do
    if ! objdump -p "$binary" | grep -qi 'avcodec'; then
      echo "$binary does not import the shared avcodec DLL" >&2
      exit 1
    fi
  done
fi

# Run the verification script if it exists.
if [[ -x "$SCRIPT_DIR/verify-windows-runtime.sh" ]]; then
  "$SCRIPT_DIR/verify-windows-runtime.sh" "$STAGE"
fi

rm -f "$ARCHIVE" "$ARCHIVE.sha256"
mkdir -p "$DIST_DIR"
tar -czf "$ARCHIVE" -C "$(dirname "$STAGE")" "$(basename "$STAGE")"
sha256sum "$ARCHIVE" > "$ARCHIVE.sha256"
echo "$ARCHIVE"
