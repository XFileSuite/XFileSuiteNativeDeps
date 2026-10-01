#!/usr/bin/env bash
# Package UUID-verified dSYMs separately from a distributable macOS runtime.
# Arguments after the archive are relative-runtime-path=absolute-binary-path.
set -euo pipefail

archive="${1:?usage: macos-symbols.sh <archive.tar.gz> <relative-path=binary>...}"
shift
(( $# > 0 )) || { echo 'At least one binary is required.' >&2; exit 2; }
command -v dsymutil >/dev/null || { echo 'dsymutil is required.' >&2; exit 1; }
command -v dwarfdump >/dev/null || { echo 'dwarfdump is required.' >&2; exit 1; }

stage="$(mktemp -d "${TMPDIR:-/tmp}/xfilesuite-symbols.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/dSYMs" "$stage/metadata"
# Bash 3.2 expands an empty array as an unset variable under `set -u`.
# Keep a harmless sentinel so this helper works on the macOS system Bash.
declare -a seen_paths=("")

uuid_set() {
  dwarfdump --uuid "$1" | awk '$1 == "UUID:" { gsub(/[()]/, "", $3); print $2 ":" $3 }' | sort
}

for mapping in "$@"; do
  relative="${mapping%%=*}"
  binary="${mapping#*=}"
  [[ "$relative" != "$mapping" && "$relative" != /* && -f "$binary" ]] || {
    echo "Invalid symbol mapping: $mapping" >&2
    exit 2
  }
  for seen in "${seen_paths[@]}"; do
    [[ "$seen" != "$relative" ]] || {
      echo "Duplicate runtime path in symbol mappings: $relative" >&2
      exit 2
    }
  done
  seen_paths+=("$relative")
  destination="$stage/dSYMs/$relative.dSYM"
  mkdir -p "$(dirname "$destination")"
  stderr="$stage/metadata/$(basename "$binary").stderr"
  dsymutil "$binary" -o "$destination" 2>"$stderr"
  if grep -q 'no debug symbols in executable' "$stderr"; then
    echo "Missing DWARF debug information in $binary; refusing an empty dSYM." >&2
    exit 1
  fi
  dsym_binary="$destination/Contents/Resources/DWARF/$(basename "$binary")"
  cmp -s <(uuid_set "$binary") <(uuid_set "$dsym_binary") || {
    echo "dSYM UUID mismatch: $binary" >&2
    exit 1
  }
  {
    printf '%s\n' "path=$relative"
    printf '%s\n' "sha256=$(shasum -a 256 "$binary" | awk '{print $1}')"
    uuid_set "$binary" | sed 's/^/uuid=/'
    printf '\n'
  } >> "$stage/metadata/UUIDS.txt"
done

tar -czf "$archive" -C "$stage" dSYMs metadata
shasum -a 256 "$archive" > "$archive.sha256"
