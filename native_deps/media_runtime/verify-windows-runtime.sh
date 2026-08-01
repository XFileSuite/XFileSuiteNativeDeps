#!/usr/bin/env bash
# Verifies the Windows media runtime archive before publishing.
#
# Mirrors the macOS verify-macos-runtime.sh checks:
#   - Required files exist (DLLs, import libs, headers, licenses)
#   - ffmpeg.exe and libmpv-2.dll both import the shared FFmpeg DLLs
#   - Required decoders/encoders/filters are present
#   - No GPL or nonfree FFmpeg configuration
#   - Optional ProRes 4444 alpha round-trip test
set -euo pipefail

RUNTIME_DIR="${1:?usage: verify-windows-runtime.sh <unpacked-runtime-dir>}"
BIN_DIR="$RUNTIME_DIR/bin"
LIB_DIR="$RUNTIME_DIR/lib"
INCLUDE_DIR="$RUNTIME_DIR/include"
FFMPEG="$BIN_DIR/ffmpeg.exe"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

need_file() {
  if [[ ! -e "$1" ]]; then
    echo "Missing runtime file: $1" >&2
    exit 1
  fi
}

# ── Required files ────────────────────────────────────────────────
need_file "$FFMPEG"
need_file "$BIN_DIR/libmpv-2.dll"
need_file "$BIN_DIR/libEGL.dll"
need_file "$BIN_DIR/libGLESv2.dll"
need_file "$BIN_DIR/libfontconfig-1.dll"
need_file "$LIB_DIR/libmpv.dll.a"

for dll in avcodec avdevice avformat avutil avfilter swresample swscale; do
  match="$(find "$BIN_DIR" -maxdepth 1 -name "${dll}-*.dll" -print -quit)"
  [[ -n "$match" ]] || { echo "Missing shared FFmpeg DLL: ${dll}-*.dll" >&2; exit 1; }
  need_file "$match"
done
need_file "$RUNTIME_DIR/licenses/msys2-libass"
need_file "$RUNTIME_DIR/licenses/msys2-freetype"
need_file "$RUNTIME_DIR/licenses/msys2-fontconfig"
need_file "$RUNTIME_DIR/licenses/msys2-expat"
need_file "$RUNTIME_DIR/licenses/ANGLE-BSD-3-Clause.txt"

for imp in libavcodec.dll.a libavdevice.dll.a libavformat.dll.a libavutil.dll.a libavfilter.dll.a libswresample.dll.a libswscale.dll.a; do
  need_file "$LIB_DIR/$imp"
done

for ffmpeg_header in \
  libavcodec/avcodec.h libavdevice/avdevice.h libavformat/avformat.h \
  libavutil/avutil.h libavfilter/avfilter.h libswresample/swresample.h \
  libswscale/swscale.h; do
  need_file "$INCLUDE_DIR/$ffmpeg_header"
done

for hdr in client.h render.h render_gl.h stream_cb.h; do
  need_file "$INCLUDE_DIR/mpv/$hdr"
done

for license in \
  NOTICE.md FFmpeg-LGPL-2.1.txt mpv-Copyright.txt libplacebo-LICENSE.txt; do
  need_file "$RUNTIME_DIR/licenses/$license"
done

# ── Shared FFmpeg linkage ─────────────────────────────────────────
if command -v objdump >/dev/null 2>&1; then
  for binary in "$FFMPEG" "$BIN_DIR/libmpv-2.dll"; do
    imports="$(objdump -p "$binary" 2>/dev/null)"
    if ! grep -i 'avcodec' <<<"$imports" >/dev/null; then
      echo "$binary does not import the shared avcodec DLL" >&2
      exit 1
    fi
    if ! grep -i 'avformat' <<<"$imports" >/dev/null; then
      echo "$binary does not import the shared avformat DLL" >&2
      exit 1
    fi
  done

  # Every non-system DLL import available from MinGW must be bundled. This
  # catches transitive additions such as Fontconfig -> Expat before release.
  while IFS= read -r binary; do
    while IFS= read -r imported_dll; do
      imported_dll="${imported_dll//$'\r'/}"
      system_dependency="$(find /mingw64/bin -maxdepth 1 -type f -iname "$imported_dll" -print -quit)"
      bundled_dependency="$(find "$BIN_DIR" -maxdepth 1 -type f -iname "$imported_dll" -print -quit)"
      if [[ -n "$system_dependency" && -z "$bundled_dependency" ]]; then
        echo "Missing MinGW runtime dependency: $imported_dll (imported by $(basename "$binary"))" >&2
        exit 1
      fi
    done < <(objdump -p "$binary" 2>/dev/null | awk '/DLL Name:/ { print $3 }')
  done < <(find "$BIN_DIR" -maxdepth 1 -type f \( -iname '*.dll' -o -iname '*.exe' \))
fi

# ── Required codecs ───────────────────────────────────────────────
# Put the shared FFmpeg DLLs in PATH so ffmpeg.exe can run.
export PATH="$BIN_DIR:$PATH"
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

# ── No GPL / nonfree ──────────────────────────────────────────────
build_configuration="$("$FFMPEG" -buildconf 2>&1)"
if grep -Eq -- '--enable-(gpl|nonfree|version3|mbedtls)' <<<"$build_configuration"; then
  echo "GPL, nonfree, version3, or Mbed TLS FFmpeg configuration detected" >&2
  exit 1
fi

protocols="$("$FFMPEG" -hide_banner -protocols 2>&1)"
if grep -Eq '(^|[[:space:]])(https|tls|rtmps|rtmpts)($|[[:space:]])' <<<"$protocols"; then
  echo "TLS protocol support is unexpectedly present" >&2
  exit 1
fi

# ── Optional ProRes 4444 alpha round-trip ─────────────────────────
if [[ "${VERIFY_ALPHA_VIDEO:-0}" == "1" ]]; then
  alpha_work="$(mktemp -d "${TMPDIR:-/tmp}/xfilesuite-alpha-win.XXXXXX")"
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

echo "Windows media runtime verified"
