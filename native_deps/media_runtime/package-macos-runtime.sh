#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRAMEWORKS_SOURCE="${FRAMEWORKS_SOURCE:?set FRAMEWORKS_SOURCE to the directory containing *.xcframework}"
FFMPEG_BINARY="${FFMPEG_BINARY:?set FFMPEG_BINARY to the shared-runtime ffmpeg executable}"
LICENSES_SOURCE="${LICENSES_SOURCE:?set LICENSES_SOURCE to the collected runtime licenses}"
VERSION="${VERSION:-8.1.2-mpv-0.41.0}"
RELEASE_REVISION="${RELEASE_REVISION:-3}"
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
- Network playback (HTTP/HTTPS/HLS/DASH/RTMP/RTMPS/RTSP/RTP) is enabled via the
  macOS SecureTransport framework. The private API SecIdentityCreate is patched
  out so the runtime can be submitted to the Mac App Store.
- mpv is built with \`-Dgpl=false\`.
EOF

# XCFrameworks contain the same universal framework binaries that CocoaPods
# embeds in Contents/Frameworks.  Generate dSYMs from this final, relocated
# runtime (after all lipo/install-name changes) and keep them out of ARCHIVE.
symbol_mappings=("Contents/Resources/ffmpeg=$STAGE_DIR/Tools/ffmpeg")
while IFS= read -r -d '' framework; do
  name="$(basename "$framework" .framework)"
  binary="$framework/Versions/A/$name"
  [[ -f "$binary" ]] || {
    echo "Missing framework executable for symbols: $binary" >&2
    exit 1
  }
  symbol_mappings+=("Contents/Frameworks/${name}.framework/Versions/A/${name}=$binary")
done < <(find "$STAGE_DIR/Frameworks" -type d -name '*.framework' -print0 | sort -z)
"$SCRIPT_DIR/../macos-symbols.sh" "$DIST_DIR/$RELEASE_ID.symbols.tar.gz" "${symbol_mappings[@]}"

# The dSYM helper has already checked every dSYM against these unstripped
# binaries. Strip only after that check, then require the UUID to remain
# identical so the private dSYM continues to match the shipped Release file.
uuid_set() {
  dwarfdump --uuid "$1" | awk '$1 == "UUID:" { gsub(/[()]/, "", $3); print $2 ":" $3 }' | sort
}

command -v strip >/dev/null || { echo 'strip is required for the release runtime.' >&2; exit 1; }
for mapping in "${symbol_mappings[@]}"; do
  binary="${mapping#*=}"
  before_uuid="$(uuid_set "$binary")"
  test -n "$before_uuid"
  strip -S "$binary"
  test "$(uuid_set "$binary")" = "$before_uuid" || {
    echo "Stripping changed the UUID for $binary; refusing a mismatched dSYM." >&2
    exit 1
  }
done

# Stripping invalidates the earlier ad-hoc signatures. Re-sign the staged
# runtime; the final App packaging performs its own Developer ID signing.
while IFS= read -r framework; do
  codesign --force --sign - --timestamp=none "$framework"
done < <(find "$STAGE_DIR/Frameworks" -type d -name '*.framework' -print)
codesign --force --sign - --timestamp=none "$STAGE_DIR/Tools/ffmpeg"

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
