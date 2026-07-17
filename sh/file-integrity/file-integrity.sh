#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./file-integrity.sh [options] FILE...
  ./file-integrity.sh --check HASH FILE [options]

Options:
  -a, --algo NAME    Hash algorithm: auto, md5, sha1, sha256, sha512, blake3, xxh64 (default: sha256)
  --check HASH       Compare calculated hash with expected HASH (single file only)
  --list             List available algorithms on this machine
  -h, --help         Show this help

Files:
  FILE...            One or more files. Shell-expanded globs are supported

Examples:
  ./file-integrity.sh large.bin another.bin
  ./file-integrity.sh --algo md5 large.bin
  ./file-integrity.sh --algo md5 ~/**/*.pkl
  ./file-integrity.sh --algo blake3 large.bin
  ./file-integrity.sh --check 2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824 large.bin
EOF
}

ALGO="sha256"
CHECK_HASH=""
FILE_PATHS=()

require_file() {
  [ -n "$1" ] || {
    echo "missing file path" >&2
    usage >&2
    exit 1
  }
  [ -f "$1" ] || {
    echo "file not found: $1" >&2
    exit 1
  }
  [ -r "$1" ] || {
    echo "file is not readable: $1" >&2
    exit 1
  }
}

lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

strip_hash() {
  printf '%s' "$1" | awk '{print tolower($1)}'
}

has_command() {
  command -v "$1" >/dev/null 2>&1
}

pick_auto_algo() {
  if has_command b3sum; then
    printf '%s\n' "blake3"
  elif has_command sha256sum || has_command shasum || has_command openssl; then
    printf '%s\n' "sha256"
  elif has_command md5sum || has_command md5 || has_command openssl; then
    printf '%s\n' "md5"
  else
    echo "no supported hash command found" >&2
    exit 1
  fi
}

print_available() {
  printf '%-8s %s\n' "algo" "command"
  if has_command md5sum || has_command md5 || has_command openssl; then
    printf '%-8s %s\n' "md5" "$(first_command md5sum md5 openssl)"
  fi
  if has_command sha1sum || has_command shasum || has_command openssl; then
    printf '%-8s %s\n' "sha1" "$(first_command sha1sum shasum openssl)"
  fi
  if has_command sha256sum || has_command shasum || has_command openssl; then
    printf '%-8s %s\n' "sha256" "$(first_command sha256sum shasum openssl)"
  fi
  if has_command sha512sum || has_command shasum || has_command openssl; then
    printf '%-8s %s\n' "sha512" "$(first_command sha512sum shasum openssl)"
  fi
  if has_command b3sum; then
    printf '%-8s %s\n' "blake3" "b3sum"
  fi
  if has_command xxhsum; then
    printf '%-8s %s\n' "xxh64" "xxhsum"
  fi
}

first_command() {
  for candidate in "$@"; do
    if has_command "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
}

hash_file() {
  algo=$1
  path=$2

  case "$algo" in
    auto)
      hash_file "$(pick_auto_algo)" "$path"
      ;;
    md5)
      if has_command md5sum; then
        md5sum "$path" | awk '{print tolower($1)}'
      elif has_command md5; then
        md5 -q "$path" | awk '{print tolower($1)}'
      elif has_command openssl; then
        openssl dgst -md5 -r "$path" | awk '{print tolower($1)}'
      else
        echo "md5 requires one of: md5sum, md5, openssl" >&2
        exit 1
      fi
      ;;
    sha1)
      if has_command sha1sum; then
        sha1sum "$path" | awk '{print tolower($1)}'
      elif has_command shasum; then
        shasum -a 1 "$path" | awk '{print tolower($1)}'
      elif has_command openssl; then
        openssl dgst -sha1 -r "$path" | awk '{print tolower($1)}'
      else
        echo "sha1 requires one of: sha1sum, shasum, openssl" >&2
        exit 1
      fi
      ;;
    sha256)
      if has_command sha256sum; then
        sha256sum "$path" | awk '{print tolower($1)}'
      elif has_command shasum; then
        shasum -a 256 "$path" | awk '{print tolower($1)}'
      elif has_command openssl; then
        openssl dgst -sha256 -r "$path" | awk '{print tolower($1)}'
      else
        echo "sha256 requires one of: sha256sum, shasum, openssl" >&2
        exit 1
      fi
      ;;
    sha512)
      if has_command sha512sum; then
        sha512sum "$path" | awk '{print tolower($1)}'
      elif has_command shasum; then
        shasum -a 512 "$path" | awk '{print tolower($1)}'
      elif has_command openssl; then
        openssl dgst -sha512 -r "$path" | awk '{print tolower($1)}'
      else
        echo "sha512 requires one of: sha512sum, shasum, openssl" >&2
        exit 1
      fi
      ;;
    blake3)
      if has_command b3sum; then
        b3sum "$path" | awk '{print tolower($1)}'
      else
        echo "blake3 requires: b3sum" >&2
        exit 1
      fi
      ;;
    xxh64)
      if has_command xxhsum; then
        xxhsum -H64 "$path" | awk '{print tolower($1)}'
      else
        echo "xxh64 requires: xxhsum" >&2
        exit 1
      fi
      ;;
    *)
      echo "unsupported algorithm: $algo" >&2
      usage >&2
      exit 1
      ;;
  esac
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -a|--algo)
      [ "$#" -ge 2 ] || { echo "missing value for $1" >&2; exit 1; }
      ALGO="$(lower "$2")"
      shift 2
      ;;
    --check)
      [ "$#" -ge 2 ] || { echo "missing value for --check" >&2; exit 1; }
      CHECK_HASH="$(strip_hash "$2")"
      shift 2
      ;;
    --list)
      print_available
      exit 0
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      FILE_PATHS+=("$@")
      break
      ;;
    -*)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      FILE_PATHS+=("$1")
      shift
      ;;
  esac
done

if (( ${#FILE_PATHS[@]} == 0 )); then
  echo "missing file path" >&2
  usage >&2
  exit 1
fi

if [[ -n "$CHECK_HASH" ]] && (( ${#FILE_PATHS[@]} != 1 )); then
  echo "--check requires exactly one file path" >&2
  exit 1
fi

for file_path in "${FILE_PATHS[@]}"; do
  require_file "$file_path"
done

if [ "$ALGO" = "auto" ]; then
  SELECTED_ALGO="$(pick_auto_algo)"
else
  SELECTED_ALGO="$ALGO"
fi

for file_path in "${FILE_PATHS[@]}"; do
  HASH="$(hash_file "$SELECTED_ALGO" "$file_path")"
  printf '%s  %s  %s\n' "$SELECTED_ALGO" "$HASH" "$file_path"

  if [[ -n "$CHECK_HASH" ]]; then
    if [[ "$HASH" == "$CHECK_HASH" ]]; then
      echo "check: OK"
    else
      echo "check: FAILED" >&2
      echo "expected: $CHECK_HASH" >&2
      echo "actual:   $HASH" >&2
      exit 2
    fi
  fi
done
