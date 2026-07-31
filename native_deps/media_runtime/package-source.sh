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

test -d "$WORK_DIR/libmpv-darwin-build/.git"
git -C "$WORK_DIR/libmpv-darwin-build" archive --format=tar HEAD |
  tar -xf - -C "$STAGE/upstream"
git -C "$WORK_DIR/libmpv-darwin-build" diff --binary > "$STAGE/upstream/xfilesuite-build.patch"
test -s "$STAGE/upstream/xfilesuite-build.patch"

mkdir -p "$STAGE/upstream/downloads"
locked_downloads="$WORK_DIR/libmpv-darwin-build/build/intermediate/downloads"
while IFS=$'\t' read -r filename expected_sha; do
  source="$locked_downloads/$filename"
  test -f "$source"
  test "$(shasum -a 256 "$source" | awk '{print $1}')" = "$expected_sha"
  cp "$source" "$STAGE/upstream/downloads/$filename"
done < <(ruby -ryaml -ruri -e '
  YAML.load_file(ARGV.fetch(0)).each do |name, dep|
    path = URI.parse(dep.fetch("url")).path
    extension = File.extname(path)
    path = path.delete_suffix(extension)
    extension = File.extname(path) + extension
    puts ["#{name}-#{dep.fetch("version")}#{extension}", dep.fetch("sha256")].join("\t")
  end
' "$WORK_DIR/libmpv-darwin-build/downloads.lock")
find "$WORK_DIR/ffmpeg" \
  -maxdepth 2 -type f \( -name '*.tar.gz' -o -name '*.tar.xz' -o -name '*.tar.bz2' -o -name '*.zip' \) \
  -exec cp {} "$STAGE/upstream/downloads/" \; 2>/dev/null || true

while IFS= read -r source; do
  test -f "$STAGE/upstream/downloads/$(basename "$source")"
done < <(find "$WORK_DIR/ffmpeg" \
  -maxdepth 2 -type f \( -name '*.tar.gz' -o -name '*.tar.xz' -o -name '*.tar.bz2' -o -name '*.zip' \) -print)

# These are cached explicitly from FreeType's checksum-pinned Meson wrap by
# build-macos.sh; require them so corresponding source includes both inputs.
cp "$locked_downloads/libpng-1.6.40.tar.gz" "$STAGE/upstream/downloads/"
cp "$locked_downloads/libpng-1.6.40-wrap-patch.zip" "$STAGE/upstream/downloads/"
test -f "$STAGE/upstream/downloads/libpng-1.6.40.tar.gz"
test -f "$STAGE/upstream/downloads/libpng-1.6.40-wrap-patch.zip"
test "$(shasum -a 256 "$STAGE/upstream/downloads/libpng-1.6.40.tar.gz" | awk '{print $1}')" = \
  62d25af25e636454b005c93cae51ddcd5383c40fa14aa3dae8f6576feb5692c2
test "$(shasum -a 256 "$STAGE/upstream/downloads/libpng-1.6.40-wrap-patch.zip" | awk '{print $1}')" = \
  bad558070e0a82faa5c0ae553bcd12d49021fc4b628f232a8e58c3fbd281aae1

cat > "$STAGE/BUILDINFO.md" <<EOF
# XFileSuite media runtime corresponding source

- Release: $RELEASE_ID
- FFmpeg: 8.0.1, configured without GPL or nonfree components
- mpv: 0.41.0, configured with -Dgpl=false
- Build entry point: build-scripts/build-macos.sh
- Exact upstream checksums are recorded by the vendored build scripts and downloads.lock.
EOF

(cd "$STAGE" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 shasum -a 256) > "$STAGE/SHA256SUMS"
ARCHIVE="$DIST_DIR/xfilesuite-$RELEASE_ID-source.tar.gz"
tar -czf "$ARCHIVE" -C "$STAGE" .
shasum -a 256 "$ARCHIVE" > "$ARCHIVE.sha256"
echo "$ARCHIVE"
