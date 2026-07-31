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

need_file "$FFMPEG"
for framework in Mpv Avcodec Avformat Avutil Avfilter Swresample Swscale; do
  binary="$(framework_binary "$framework")"
  need_file "$binary"
  if otool -L "$binary" | grep -Eq '(/opt/homebrew/|/usr/local/|/opt/local/)'; then
    echo "$framework links against a developer-machine dependency" >&2
    otool -L "$binary" >&2
    exit 1
  fi
done

if ! otool -L "$FFMPEG" | grep -q '@rpath/Avcodec.framework/'; then
  echo "ffmpeg does not use the shared Avcodec.framework runtime" >&2
  otool -L "$FFMPEG" >&2
  exit 1
fi
if ! otool -L "$FFMPEG" | grep -q '@rpath/Avformat.framework/'; then
  echo "ffmpeg does not use the shared Avformat.framework runtime" >&2
  otool -L "$FFMPEG" >&2
  exit 1
fi
if otool -L "$FFMPEG" | grep -Eq '(/opt/homebrew/|/usr/local/|/opt/local/)'; then
  echo "ffmpeg links against a developer-machine dependency" >&2
  otool -L "$FFMPEG" >&2
  exit 1
fi

mpv_binary="$(framework_binary Mpv)"
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
decoders="$("$FFMPEG" -hide_banner -decoders 2>&1)"
encoders="$("$FFMPEG" -hide_banner -encoders 2>&1)"
filters="$("$FFMPEG" -hide_banner -filters 2>&1)"
while IFS= read -r requirement; do
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

if "$FFMPEG" -buildconf 2>&1 | grep -Eq -- '--enable-(gpl|nonfree)'; then
  echo "GPL or nonfree FFmpeg configuration detected" >&2
  exit 1
fi

echo "macOS media runtime verified"
