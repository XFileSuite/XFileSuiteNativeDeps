#!/usr/bin/env bash
set -euo pipefail

RUNTIME_DIR="${1:?usage: verify-macos-runtime.sh <unpacked-runtime-dir>}"
FRAMEWORKS_DIR="$RUNTIME_DIR/Frameworks"
FFMPEG="$RUNTIME_DIR/Tools/ffmpeg"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

need_file() {
  if [[ ! -e "$1" ]]; then
    echo "Missing runtime file: $1" >&2
    exit 1
  fi
}

framework_binary() {
  local name="$1"
  local candidate
  candidate="$(find "$FRAMEWORKS_DIR/$name.xcframework" -type f -path "*/$name.framework/Versions/A/$name" -print -quit)"
  if [[ -z "$candidate" ]]; then
    candidate="$(find "$FRAMEWORKS_DIR/$name.xcframework" -type f -path "*/$name.framework/$name" -print -quit)"
  fi
  printf '%s\n' "$candidate"
}

assert_relocatable() {
  local binary="$1"
  local invalid
  invalid="$(
    otool -L "$binary" |
      awk '/^[[:space:]]/ {print $1}' |
      grep -E '^/' |
      grep -Ev '^(/usr/lib/|/System/Library/)' || true
  )"
  if [[ -n "$invalid" ]]; then
    echo "$binary contains non-system absolute dependencies:" >&2
    echo "$invalid" >&2
    exit 1
  fi
}

need_file "$FFMPEG"
for license in \
  NOTICE.md FFmpeg-LGPL-2.1.txt mpv-Copyright.txt libpng-LICENSE.txt \
  dav1d-COPYING.txt libass-COPYING.txt FreeType-FTL.txt \
  FriBidi-COPYING.txt HarfBuzz-COPYING.txt \
  libxml2-Copyright.txt uchardet-COPYING.txt libplacebo-LICENSE.txt; do
  need_file "$RUNTIME_DIR/licenses/$license"
done
for framework in Mpv Avcodec Avformat Avutil Avfilter Swresample Swscale; do
  binary="$(framework_binary "$framework")"
  need_file "$binary"
  assert_relocatable "$binary"
  if otool -L "$binary" | grep -Eq '(/opt/homebrew/|/usr/local/|/opt/local/)'; then
    echo "$framework links against a developer-machine dependency" >&2
    otool -L "$binary" >&2
    exit 1
  fi
done
while IFS= read -r binary; do
  assert_relocatable "$binary"
done < <(find "$FRAMEWORKS_DIR" -type f -path '*/Versions/A/*' ! -path '*/Resources/*' -print)

if ! otool -L "$FFMPEG" | grep -q '@rpath/libavcodec'; then
  echo "ffmpeg does not use the shared Avcodec.framework runtime" >&2
  otool -L "$FFMPEG" >&2
  exit 1
fi
if ! otool -L "$FFMPEG" | grep -q '@rpath/libavformat'; then
  echo "ffmpeg does not use the shared Avformat.framework runtime" >&2
  otool -L "$FFMPEG" >&2
  exit 1
fi
if otool -L "$FFMPEG" | grep -Eq '(/opt/homebrew/|/usr/local/|/opt/local/)'; then
  echo "ffmpeg links against a developer-machine dependency" >&2
  otool -L "$FFMPEG" >&2
  exit 1
fi
assert_relocatable "$FFMPEG"

for mapping in 'libavcodec*:Avcodec' 'libavformat*:Avformat'; do
  alias_pattern="${mapping%%:*}"
  framework="${mapping##*:}"
  alias_path="$(find "$RUNTIME_DIR/lib" -type l -name "$alias_pattern" -print -quit)"
  need_file "$alias_path"
  if [[ "$(stat -L -f %i "$alias_path")" != "$(stat -f %i "$(framework_binary "$framework")")" ]]; then
    echo "$alias_path does not resolve to $framework.framework" >&2
    exit 1
  fi
done

mpv_binary="$(framework_binary Mpv)"
if nm -u "$mpv_binary" | grep -Eq '_(clipboard_backend_mac|cocoa_(init|uninit|set)_)'; then
  echo "libmpv contains an unresolved macOS application bridge" >&2
  exit 1
fi
if ! otool -L "$mpv_binary" | grep -q '@rpath/Avcodec.framework/'; then
  echo "Mpv.framework does not use the shared Avcodec.framework runtime" >&2
  otool -L "$mpv_binary" >&2
  exit 1
fi

framework_search_path="$(
  find "$FRAMEWORKS_DIR" -maxdepth 2 -type d -path "*.xcframework/*" -print |
    paste -sd: -
)"
export DYLD_FRAMEWORK_PATH="$framework_search_path"
decoders="$("$FFMPEG" -hide_banner -decoders 2>&1 | tr -d '\r')"
encoders="$("$FFMPEG" -hide_banner -encoders 2>&1 | tr -d '\r')"
filters="$("$FFMPEG" -hide_banner -filters 2>&1 | tr -d '\r')"
while IFS= read -r requirement; do
  requirement="${requirement%$'\r'}"
  [[ -z "$requirement" || "$requirement" == \#* ]] && continue
  kind="${requirement%%:*}"
  name="${requirement#*:}"
  case "$kind" in
    decoder)
      grep -Eq "[[:space:]]${name}([[:space:]]|$)" <<<"$decoders" || {
        echo "Missing required decoder: $name" >&2
        exit 1
      }
      ;;
    encoder)
      grep -Eq "[[:space:]]${name}([[:space:]]|$)" <<<"$encoders" || {
        echo "Missing required encoder: $name" >&2
        exit 1
      }
      ;;
    filter)
      grep -Eq "[[:space:]]${name}([[:space:]]|$)" <<<"$filters" || {
        echo "Missing required filter: $name" >&2
        exit 1
      }
      ;;
  esac
done < "$SCRIPT_DIR/runtime-codecs.txt"

if [[ "${VERIFY_ALPHA_VIDEO:-0}" == "1" ]]; then
  # Stage-three verification: prove that a semi-transparent pixel survives a
  # ProRes 4444 encode/decode round trip. Playback only requires its decoder.
  alpha_work="$(mktemp -d "${TMPDIR:-/tmp}/xfilesuite-alpha.XXXXXX")"
  trap 'rm -rf "$alpha_work"' EXIT
  for _ in {1..256}; do
    printf '\377\000\000\200'
  done > "$alpha_work/source.rgba"
  "$FFMPEG" -hide_banner -loglevel error \
    -f rawvideo -pixel_format rgba -video_size 16x16 -framerate 1 \
    -i "$alpha_work/source.rgba" \
    -frames:v 1 -c:v prores_ks -profile:v 4 -alpha_bits 16 \
    "$alpha_work/prores-4444-alpha.mov"
  "$FFMPEG" -hide_banner -loglevel error \
    -i "$alpha_work/prores-4444-alpha.mov" -frames:v 1 \
    -pix_fmt rgba -f rawvideo "$alpha_work/frame.rgba"
  alpha_byte="$(od -An -tu1 -j3 -N1 "$alpha_work/frame.rgba" | tr -d '[:space:]')"
  if [[ -z "$alpha_byte" || "$alpha_byte" -lt 96 || "$alpha_byte" -gt 160 ]]; then
    echo "ProRes 4444 alpha round-trip failed: alpha=$alpha_byte" >&2
    exit 1
  fi
fi

if "$FFMPEG" -buildconf 2>&1 | grep -Eq -- '--enable-(gpl|nonfree|version3|mbedtls)'; then
  echo "GPL, nonfree, version3, or Mbed TLS FFmpeg configuration detected" >&2
  exit 1
fi

protocols="$("$FFMPEG" -hide_banner -protocols 2>&1)"
if grep -Eq '(^|[[:space:]])(https|tls|rtmps|rtmpts)($|[[:space:]])' <<<"$protocols"; then
  echo "TLS protocol support is unexpectedly present" >&2
  exit 1
fi

echo "macOS media runtime verified"
