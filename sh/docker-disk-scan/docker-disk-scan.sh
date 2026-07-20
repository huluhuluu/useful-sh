#!/usr/bin/env bash

# Read-only Docker disk usage audit. This script never removes or modifies data.
set -uo pipefail

DIR_THRESHOLD_GIB=5
MAX_DEPTH=4
SHOW_CONTAINED_FILES=0
CONTAINER_FILTER=""
SUDO=()
TMPDIR_PATH=""

usage() {
  cat <<'EOF'
Usage:
  ./docker-disk-scan.sh [options] [container]

Read-only Docker disk usage audit. Lists large writable-layer directories and
files using container-internal paths. No data is modified or removed.

Options:
  -s, --min-size GIB   Minimum directory/file size in GiB (default: 5)
  -d, --depth LEVEL    Maximum directory depth to scan (default: 4)
      --all-files      Show files even when a listed directory contains them
  -h, --help           Show this help message and exit

Optional argument:
  container            Scan only this container name or ID. By default, scan
                       all containers.

Examples:
  ./docker-disk-scan.sh
  ./docker-disk-scan.sh my-container
  ./docker-disk-scan.sh --min-size 1 --depth 5 my-container
  ./docker-disk-scan.sh -s 10 -d 3
  ./docker-disk-scan.sh --all-files my-container
EOF
}

while (( $# > 0 )); do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    -s|--min-size)
      if (( $# < 2 )); then
        printf 'Option %s requires a GiB value.\n' "$1" >&2
        exit 2
      fi
      DIR_THRESHOLD_GIB="$2"
      shift
      ;;
    --min-size=*)
      DIR_THRESHOLD_GIB="${1#*=}"
      ;;
    -d|--depth)
      if (( $# < 2 )); then
        printf 'Option %s requires a depth value.\n' "$1" >&2
        exit 2
      fi
      MAX_DEPTH="$2"
      shift
      ;;
    --depth=*)
      MAX_DEPTH="${1#*=}"
      ;;
    --all-files)
      SHOW_CONTAINED_FILES=1
      ;;
    --)
      shift
      if (( $# > 1 )); then
        echo "Only one container name or ID may be specified." >&2
        exit 2
      fi
      CONTAINER_FILTER="${1:-}"
      break
      ;;
    -*)
      printf 'Unknown option: %s\n\n' "$1" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [[ -n "$CONTAINER_FILTER" ]]; then
        echo "Only one container name or ID may be specified." >&2
        exit 2
      fi
      CONTAINER_FILTER="$1"
      ;;
  esac
  shift
done

section() {
  printf '\n\033[1;36m%s\033[0m\n' "$1"
}

human_size() {
  numfmt --to=iec-i --suffix=B "$1"
}

print_install_hint() {
  case "$1" in
    docker) package="docker.io" ;;
    sudo)
      echo "Install as root on Ubuntu/Debian: apt-get install sudo" >&2
      return
      ;;
    du|sort|numfmt) package="coreutils" ;;
    find) package="findutils" ;;
    awk) package="gawk" ;;
    *) return ;;
  esac
  printf 'Install on Ubuntu/Debian: sudo apt install %s\n' "$package" >&2
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'Missing required command: %s\n' "$1" >&2
    print_install_hint "$1"
    exit 1
  fi
}

cleanup() {
  if [[ -n "${sudo_keepalive_pid:-}" ]]; then
    kill "$sudo_keepalive_pid" 2>/dev/null || true
    wait "$sudo_keepalive_pid" 2>/dev/null || true
  fi
  if [[ -n "$TMPDIR_PATH" ]]; then
    rm -rf "$TMPDIR_PATH"
  fi
}

run_privileged() {
  if (( ${#SUDO[@]} > 0 )); then
    sudo -n "$@"
  else
    "$@"
  fi
}

for command_name in docker du find sort awk numfmt mktemp; do
  require_command "$command_name"
done

if (( EUID != 0 )); then
  require_command sudo
  SUDO=(sudo)
fi

if ! [[ "$DIR_THRESHOLD_GIB" =~ ^[0-9]+$ ]]; then
  echo "--min-size must be a non-negative integer." >&2
  exit 1
fi

if ! [[ "$MAX_DEPTH" =~ ^[0-9]+$ ]]; then
  echo "--depth must be a non-negative integer." >&2
  exit 1
fi

DIR_THRESHOLD_BYTES=$((DIR_THRESHOLD_GIB * 1024 * 1024 * 1024))

echo "Docker disk audit (read-only)"
echo "Size threshold:      ${DIR_THRESHOLD_GIB} GiB"
echo "Maximum depth:       ${MAX_DEPTH}"
if [[ -n "$CONTAINER_FILTER" ]]; then
  echo "Container:           ${CONTAINER_FILTER}"
fi

TMPDIR_PATH="$(mktemp -d "${TMPDIR:-/tmp}/docker-disk-scan.XXXXXX")"
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if (( ${#SUDO[@]} > 0 )); then
  # Refresh and retain sudo credentials during long directory traversals.
  sudo -v
  while true; do
    sudo -n true
    sleep 30
  done 2>/dev/null &
  sudo_keepalive_pid=$!
fi

if ! run_privileged docker info >/dev/null 2>&1; then
  echo "Docker daemon is unavailable." >&2
  exit 1
fi

if [[ -n "$CONTAINER_FILTER" ]]; then
  if ! run_privileged docker inspect "$CONTAINER_FILTER" >/dev/null 2>&1; then
    printf 'Container not found: %s\n' "$CONTAINER_FILTER" >&2
    exit 1
  fi
  if ! container_id="$(run_privileged docker inspect -f '{{.Id}}' "$CONTAINER_FILTER")"; then
    printf 'Failed to resolve container ID: %s\n' "$CONTAINER_FILTER" >&2
    exit 1
  fi
  container_ids=("$container_id")
else
  if ! container_output="$(run_privileged docker ps -aq)"; then
    echo "Failed to list Docker containers." >&2
    exit 1
  fi
  container_ids=()
  if [[ -n "$container_output" ]]; then
    mapfile -t container_ids <<< "$container_output"
  fi
fi

if (( ${#container_ids[@]} == 0 )); then
  echo "No Docker containers found."
  exit 0
fi

section "Large writable-layer directories and files"

scanned_containers=0
failed_containers=0
inspect_raw="$TMPDIR_PATH/inspect.raw"
inspect_file="$TMPDIR_PATH/inspect.sorted"
if ! run_privileged docker inspect --size \
  --format '{{.SizeRw}}|{{.Name}}|{{index .GraphDriver.Data "UpperDir"}}' \
  "${container_ids[@]}" > "$inspect_raw"; then
  echo "Failed to inspect one or more Docker containers." >&2
  exit 1
fi
if ! sort -t'|' -k1,1nr "$inspect_raw" > "$inspect_file"; then
  echo "Failed to sort Docker inspection data." >&2
  exit 1
fi

scan_index=0
while IFS='|' read -r size_rw name upper_dir; do
  scan_index=$((scan_index + 1))
  name="${name#/}"
  if [[ -z "$upper_dir" ]] || ! run_privileged test -d "$upper_dir"; then
    printf '\n\033[1;33m===== %s | writable layer unavailable =====\033[0m\n' "$name"
    failed_containers=$((failed_containers + 1))
    continue
  fi

  printf '\n\033[1;33m===== %s | writable=%s =====\033[0m\n' \
    "$name" "$(human_size "$size_rw")"

  echo "  Large directories:"
  unset matched_directory_paths
  declare -A matched_directory_paths=()
  matched_directories=0
  du_raw="$TMPDIR_PATH/du.$scan_index.raw"
  directories_file="$TMPDIR_PATH/du.$scan_index.filtered"
  if ! run_privileged du -x -B1 --max-depth="$MAX_DEPTH" "$upper_dir" > "$du_raw" 2>/dev/null; then
    echo "  Failed to scan directories for $name." >&2
    failed_containers=$((failed_containers + 1))
    continue
  fi
  if ! sort -nr "$du_raw" |
    awk -v threshold="$DIR_THRESHOLD_BYTES" '$1 >= threshold' > "$directories_file"; then
    echo "  Failed to process directory sizes for $name." >&2
    failed_containers=$((failed_containers + 1))
    continue
  fi
  while read -r bytes path; do
    [[ -n "$bytes" ]] || continue
    relative_path="${path#"$upper_dir"}"
    [[ -n "$relative_path" ]] || relative_path="/"
    matched_directory_paths["$relative_path"]=1
    printf '    %8s  %s\n' "$(human_size "$bytes")" "$relative_path"
    matched_directories=$((matched_directories + 1))
  done < "$directories_file"

  if (( matched_directories == 0 )); then
    printf '  No directories at least %s GiB.\n' "$DIR_THRESHOLD_GIB"
  else
    printf '  Matched directories: %d\n' "$matched_directories"
  fi

  echo "  Standalone large files:"
  standalone_files=0
  collapsed_files=0
  find_raw="$TMPDIR_PATH/find.$scan_index.raw"
  files_file="$TMPDIR_PATH/find.$scan_index.filtered"
  if ! run_privileged find "$upper_dir" -xdev -type f -printf '%s\t%p\n' > "$find_raw" 2>/dev/null; then
    echo "  Failed to scan files for $name." >&2
    failed_containers=$((failed_containers + 1))
    continue
  fi
  if ! awk -v threshold="$DIR_THRESHOLD_BYTES" '$1 >= threshold' "$find_raw" |
    sort -nr > "$files_file"; then
    echo "  Failed to process file sizes for $name." >&2
    failed_containers=$((failed_containers + 1))
    continue
  fi
  while IFS=$'\t' read -r bytes path; do
    [[ -n "$bytes" ]] || continue
    relative_path="${path#"$upper_dir"}"

    if (( SHOW_CONTAINED_FILES == 0 )); then
      ancestor="${relative_path%/*}"
      collapsed=0
      while [[ -n "$ancestor" && "$ancestor" != "/" ]]; do
        if [[ "$ancestor" != "/root" ]] && \
          [[ -n "${matched_directory_paths["$ancestor"]+present}" ]]; then
          collapsed=1
          break
        fi
        ancestor="${ancestor%/*}"
        [[ -n "$ancestor" ]] || ancestor="/"
      done

      if (( collapsed == 1 )); then
        collapsed_files=$((collapsed_files + 1))
        continue
      fi
    fi

    printf '    %8s  %s\n' "$(human_size "$bytes")" "$relative_path"
    standalone_files=$((standalone_files + 1))
  done < "$files_file"

  if (( standalone_files == 0 )); then
    printf '  No standalone files at least %s GiB.\n' "$DIR_THRESHOLD_GIB"
  else
    printf '  Matched standalone files: %d\n' "$standalone_files"
  fi

  if (( collapsed_files > 0 )); then
    printf '  Collapsed files covered by directories above: %d\n' "$collapsed_files"
  fi
  scanned_containers=$((scanned_containers + 1))
done < "$inspect_file"

section "Scan summary"
accounted_containers=$((scanned_containers + failed_containers))
if (( accounted_containers < ${#container_ids[@]} )); then
  missing_containers=$((${#container_ids[@]} - accounted_containers))
  printf 'Inspection data missing for %d container(s).\n' "$missing_containers" >&2
  failed_containers=$((failed_containers + missing_containers))
fi
printf 'Scanned containers: %d/%d\n' "$scanned_containers" "${#container_ids[@]}"
printf 'Failed containers:  %d\n' "$failed_containers"

section "Commands for manual inspection"
echo "Container directories over 1 GiB, depth 4:"
echo "  sudo docker exec <container> du -x -B1 --max-depth=4 /path/to/scan 2>/dev/null | sort -nr | awk '\$1 >= 1073741824' | numfmt --field=1 --to=iec-i --suffix=B | less"
echo
echo "Container files over 1 GiB:"
printf '%s\n' "  sudo docker exec <container> find /path/to/scan -xdev -type f -printf '%s\\t%p\\n' 2>/dev/null | awk '\$1 >= 1073741824' | sort -nr | numfmt --field=1 --to=iec-i --suffix=B | less"

echo
if (( failed_containers > 0 )); then
  echo "Audit incomplete: one or more container layers could not be scanned." >&2
  exit 1
fi
echo "Audit complete. No Docker data was modified."
