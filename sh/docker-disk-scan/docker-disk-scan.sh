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

Read-only Docker disk usage audit. Groups writable-layer and persistent
bind/volume data by container, using container-internal paths. Shared sources
are detected from mount sources, scanned once, and shown with short references.
Run on the Docker daemon host.
No data is modified or removed.

Options:
  -s, --min-size GIB   Minimum directory/file size in GiB (default: 5)
  -d, --depth LEVEL    Directory depth from container / (default: 4)
      --all-files      Show files even when a listed directory contains them
  -h, --help           Show this help message and exit

Optional argument:
  container            Scan only this container name or ID. By default, scan
                       all containers. Includes their persistent mounts.

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
    du|sort|numfmt|realpath|stat) package="coreutils" ;;
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

report_scan_error() {
  local stage="$1" scan_root="$2" error_file="$3" message count=0
  printf '    %s failed for %s; keeping available results.\n' "$stage" "$scan_root" >&2
  while IFS= read -r message; do
    if (( count == 5 )); then
      echo "      Additional errors omitted." >&2
      break
    fi
    printf '      %s\n' "$message" >&2
    count=$((count + 1))
  done < "$error_file"
}

collect_path() {
  local scan_root="$1" cache_prefix="$2" scan_depth="$3" failed=0
  if ! run_privileged du -x -B1 --max-depth="$scan_depth" "$scan_root" \
    > "$cache_prefix.du.raw" 2> "$cache_prefix.du.err"; then
    : > "$cache_prefix.directories.incomplete"
    report_scan_error du "$scan_root" "$cache_prefix.du.err"
    failed=1
  fi
  if ! { sort -nr "$cache_prefix.du.raw" |
    awk -v threshold="$DIR_THRESHOLD_BYTES" '$1 >= threshold' > "$cache_prefix.directories"; } \
    2> "$cache_prefix.directories.err"; then
    : > "$cache_prefix.directories.incomplete"
    report_scan_error "Directory processing" "$scan_root" "$cache_prefix.directories.err"
    failed=1
  fi
  if ! run_privileged find "$scan_root" -xdev -type f -printf '%s\t%p\n' \
    > "$cache_prefix.find.raw" 2> "$cache_prefix.find.err"; then
    : > "$cache_prefix.files.incomplete"
    report_scan_error find "$scan_root" "$cache_prefix.find.err"
    failed=1
  fi
  if ! { awk -v threshold="$DIR_THRESHOLD_BYTES" '$1 >= threshold' "$cache_prefix.find.raw" |
    sort -nr > "$cache_prefix.files"; } 2> "$cache_prefix.files.err"; then
    : > "$cache_prefix.files.incomplete"
    report_scan_error "File processing" "$scan_root" "$cache_prefix.files.err"
    failed=1
  fi
  return "$failed"
}

print_path() {
  local source="$1" destination="$2" cache_prefix="$3" path_mode="$4"
  local bytes path relative_path display_path separators ancestor collapsed
  local matched_directories=0 standalone_files=0 collapsed_files=0
  local -A matched_directory_paths=()
  echo "    Large directories:"
  while read -r bytes path; do
    [[ -n "$bytes" ]] || continue
    if [[ "$path" == "$source" ]]; then
      relative_path=""
    elif [[ "$path" == "${source%/}/"* ]]; then
      relative_path="${path#"${source%/}"}"
    else
      continue
    fi
    display_path="${destination%/}$relative_path"
    [[ -n "$display_path" ]] || display_path="/"
    separators="${display_path%/}"
    separators="${separators//[^\/]/}"
    (( ${#separators} <= MAX_DEPTH )) || continue
    matched_directory_paths["${relative_path:-/}"]=1
    printf '      %8s  %s\n' "$(human_size "$bytes")" "$display_path"
    matched_directories=$((matched_directories + 1))
  done < "$cache_prefix.directories"

  if (( matched_directories == 0 )); then
    if [[ -f "$cache_prefix.directories.incomplete" ]]; then
      echo "    No matching directories in available results (scan incomplete)."
    else
      printf '    No directories at least %s GiB.\n' "$DIR_THRESHOLD_GIB"
    fi
  else
    printf '    Matched directories: %d\n' "$matched_directories"
  fi

  echo "    Standalone large files:"
  while IFS=$'\t' read -r bytes path; do
    [[ -n "$bytes" ]] || continue
    if [[ "$path" == "$source" ]]; then
      relative_path=""
    elif [[ "$path" == "${source%/}/"* ]]; then
      relative_path="${path#"${source%/}"}"
    else
      continue
    fi
    if (( SHOW_CONTAINED_FILES == 0 )); then
      ancestor="${relative_path%/*}"
      collapsed=0
      while [[ -n "$ancestor" && "$ancestor" != "/" ]]; do
        if [[ "$path_mode" != "container" || "$ancestor" != "/root" ]] &&
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
    display_path="${destination%/}$relative_path"
    [[ -n "$display_path" ]] || display_path="/"
    printf '      %8s  %s\n' "$(human_size "$bytes")" "$display_path"
    standalone_files=$((standalone_files + 1))
  done < "$cache_prefix.files"

  if (( standalone_files == 0 )); then
    if [[ -f "$cache_prefix.files.incomplete" ]]; then
      echo "    No matching standalone files in available results (scan incomplete)."
    else
      printf '    No standalone files at least %s GiB.\n' "$DIR_THRESHOLD_GIB"
    fi
  else
    printf '    Matched standalone files: %d\n' "$standalone_files"
  fi
  if (( collapsed_files > 0 )); then
    printf '    Collapsed files covered by directories above: %d\n' "$collapsed_files"
  fi
  return 0
}

for command_name in docker du find sort awk numfmt mktemp realpath stat; do
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

mounts_file="$TMPDIR_PATH/mounts"
scanned_mounts=0
failed_mounts=0
declare -A container_mounts=() container_mount_notes=()
declare -A mount_sources=() mount_devices=() mount_aliases=()
declare -A mount_containers=() mount_container_counts=() mount_shared_ids=()
declare -A mount_detail_container=() mount_detail_destination=() mount_detail_depth=() mount_overlaps=()
declare -A mount_cache=() mount_failed=() mount_sizes=()
declare -a scan_roots=()
shared_sources=0
if ! run_privileged docker inspect \
  --format '{{range .Mounts}}{{if or (eq .Type "bind") (eq .Type "volume")}}{{printf "%s\x1f%s\x1f%s\x1f%s\n" .Type .Source .Destination $.Name}}{{end}}{{end}}' \
  "${container_ids[@]}" > "$mounts_file"; then
  echo "Failed to inspect persistent mounts." >&2
  failed_mounts=$((failed_mounts + 1))
else
  while IFS=$'\x1f' read -r mount_type source destination name; do
    [[ -n "$mount_type" ]] || continue
    name="${name#/}"
    if [[ -z "$source" ]] || ! canonical_source="$(run_privileged realpath -e -- "$source")" ||
      ! source_identity="$(run_privileged stat -Lc '%d:%i' -- "$canonical_source")"; then
      container_mount_notes["$name"]+="  Persistent mount: $destination [$mount_type] - source unavailable"$'\n'
      failed_mounts=$((failed_mounts + 1))
      continue
    fi
    if ! run_privileged test -d "$canonical_source" && ! run_privileged test -f "$canonical_source"; then
      container_mount_notes["$name"]+="  Persistent mount: $destination [$mount_type] - skipped (not a file/directory)"$'\n'
      continue
    fi
    # Device + inode also identifies aliases of the same source.
    if [[ -n "${mount_aliases["$source_identity"]+present}" ]]; then
      canonical_source="${mount_aliases["$source_identity"]}"
    else
      mount_aliases["$source_identity"]="$canonical_source"
    fi
    # A shared source can appear at different depths in different containers.
    separators="${destination%/}"
    separators="${separators//[^\/]/}"
    destination_depth=${#separators}
    source_depth=$((MAX_DEPTH - destination_depth))
    (( source_depth >= 0 )) || source_depth=0
    if [[ -z "${mount_sources["$canonical_source"]+present}" ]] ||
      (( source_depth > ${mount_sources["$canonical_source"]} )); then
      mount_sources["$canonical_source"]="$source_depth"
    fi
    if [[ -z "${mount_detail_depth["$canonical_source"]+present}" ]] ||
      (( destination_depth < ${mount_detail_depth["$canonical_source"]} )); then
      mount_detail_depth["$canonical_source"]="$destination_depth"
      mount_detail_container["$canonical_source"]="$name"
      mount_detail_destination["$canonical_source"]="$destination"
    fi
    # Count different containers, regardless of mount destination names or aliases.
    container_key="$source_identity"$'\x1f'"$name"
    if [[ -z "${mount_containers["$container_key"]+present}" ]]; then
      mount_containers["$container_key"]=1
      mount_container_counts["$canonical_source"]=$((${mount_container_counts["$canonical_source"]:-0} + 1))
    fi
    mount_devices["$canonical_source"]="${source_identity%%:*}"
    container_mounts["$name"]+="$mount_type"$'\x1f'"$canonical_source"$'\x1f'"$destination"$'\n'
  done < "$mounts_file"

  # Only identical sources share a scan. Containment is an overlap, not identity.
  if (( ${#mount_sources[@]} > 0 )); then
    if ! printf '%s\n' "${!mount_sources[@]}" | LC_ALL=C sort > "$TMPDIR_PATH/mount-sources"; then
      echo "Failed to sort persistent mount sources." >&2
      exit 1
    fi
    while IFS= read -r source; do
      if (( ${mount_container_counts["$source"]} > 1 )); then
        shared_sources=$((shared_sources + 1))
        mount_shared_ids["$source"]="$shared_sources"
      fi
      for other_source in "${scan_roots[@]}"; do
        if [[ "$source" == "${other_source%/}/"* &&
          "${mount_devices["$source"]}" == "${mount_devices["$other_source"]}" ]]; then
          mount_overlaps["$source"]=1
          mount_overlaps["$other_source"]=1
        fi
      done
      scan_roots+=("$source")
    done < "$TMPDIR_PATH/mount-sources"
  fi
fi

section "Large writable-layer and persistent-mount directories and files"
scan_index=0
while IFS='|' read -r size_rw name upper_dir; do
  name="${name#/}"
  printf '\n\033[1;33m===== %s | writable=%s =====\033[0m\n' \
    "$name" "$(human_size "$size_rw")"
  echo "  Writable layer:"
  if [[ -z "$upper_dir" ]] || ! run_privileged test -d "$upper_dir"; then
    echo "    Writable layer unavailable."
    failed_containers=$((failed_containers + 1))
  else
    scan_index=$((scan_index + 1))
    cache_prefix="$TMPDIR_PATH/scan.$scan_index"
    if collect_path "$upper_dir" "$cache_prefix" "$MAX_DEPTH"; then
      scanned_containers=$((scanned_containers + 1))
    else
      echo "    Writable scan incomplete; available results may undercount usage."
      failed_containers=$((failed_containers + 1))
    fi
    print_path "$upper_dir" / "$cache_prefix" container
  fi

  if [[ -n "${container_mount_notes["$name"]:-}" ]]; then
    printf '%s' "${container_mount_notes["$name"]}"
  fi
  while IFS=$'\x1f' read -r mount_type source destination; do
    [[ -n "$mount_type" ]] || continue
    shared_id="${mount_shared_ids["$source"]:-}"
    if [[ -n "$shared_id" ]]; then
      printf '\n  Persistent mount: %s [%s, shared #%s]\n' "$destination" "$mount_type" "$shared_id"
    else
      printf '\n  Persistent mount: %s [%s]\n' "$destination" "$mount_type"
    fi
    if [[ -n "${mount_overlaps["$source"]+present}" ]]; then
      echo "    Overlapping source ranges; sizes are not additive."
    fi
    if [[ -z "${mount_cache["$source"]+present}" ]]; then
      scan_index=$((scan_index + 1))
      mount_cache["$source"]="$TMPDIR_PATH/scan.$scan_index"
      if collect_path "$source" "${mount_cache["$source"]}" "${mount_sources["$source"]}"; then
        scanned_mounts=$((scanned_mounts + 1))
      else
        mount_failed["$source"]=1
        failed_mounts=$((failed_mounts + 1))
      fi
      # Keep a size even below the display threshold; a missing result stays unknown.
      mount_sizes["$source"]=""
      while read -r bytes path; do
        if [[ "$path" == "$source" && "$bytes" =~ ^[0-9]+$ ]]; then
          mount_sizes["$source"]="$bytes"
          break
        fi
      done < "${mount_cache["$source"]}.du.raw"
    fi
    if [[ -n "${mount_failed["$source"]+present}" ]]; then
      echo "    Persistent scan incomplete; available results may undercount usage."
    fi
    if [[ -n "$shared_id" &&
      ( "$name" != "${mount_detail_container["$source"]}" ||
        "$destination" != "${mount_detail_destination["$source"]}" ) ]]; then
      if [[ -n "${mount_sizes["$source"]}" ]]; then
        printf '      %8s  %s\n' "$(human_size "${mount_sizes["$source"]}")" "$destination"
      else
        echo "    Source size unavailable."
      fi
      printf '    Details: shared #%s at %s:%s\n' "$shared_id" \
        "${mount_detail_container["$source"]}" "${mount_detail_destination["$source"]}"
    else
      print_path "$source" "$destination" "${mount_cache["$source"]}" mount
    fi
  done <<< "${container_mounts["$name"]:-}"
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
printf 'Scanned persistent sources: %d/%d\n' "$scanned_mounts" "${#scan_roots[@]}"
printf 'Persistent mount failures:  %d\n' "$failed_mounts"
printf 'Shared persistent sources:  %d\n' "$shared_sources"

section "Commands for manual inspection"
echo "Container directories over 1 GiB, depth 4:"
echo "  sudo docker exec <container> du -x -B1 --max-depth=4 /path/to/scan 2>/dev/null | sort -nr | awk '\$1 >= 1073741824' | numfmt --field=1 --to=iec-i --suffix=B | less"
echo
echo "Container files over 1 GiB:"
printf '%s\n' "  sudo docker exec <container> find /path/to/scan -xdev -type f -printf '%s\\t%p\\n' 2>/dev/null | awk '\$1 >= 1073741824' | sort -nr | numfmt --field=1 --to=iec-i --suffix=B | less"

echo
if (( failed_containers > 0 || failed_mounts > 0 )); then
  echo "Audit incomplete: one or more container layers or persistent mounts could not be scanned." >&2
  exit 1
fi
echo "Audit complete. No Docker data was modified."
