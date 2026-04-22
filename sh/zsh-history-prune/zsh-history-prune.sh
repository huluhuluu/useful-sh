#!/bin/sh
set -eu

usage() {
  cat <<'EOF'
Usage:
  ./zsh-history-prune.sh [options]

Default behavior:
  Preview which full command lines are considered common and how many history lines would be kept.
  Use --apply to rewrite the history file.

Options:
  --histfile FILE     zsh history file to process (default: $HISTFILE or ~/.zsh_history)
  --min-count N       keep full command lines used at least N times (default: 5)
  --top N             also keep the top N most-used full command lines (default: 0)
  --keep-recent N     always keep the most recent N history lines (default: 500)
  --backup-dir DIR    backup directory for --apply (default: ~/.zsh_history.backups)
  --apply             rewrite the history file after creating a backup
  -h, --help          show this help

Examples:
  ./zsh-history-prune.sh
  ./zsh-history-prune.sh --min-count 5
  ./zsh-history-prune.sh --min-count 8 --top 20 --keep-recent 800
  ./zsh-history-prune.sh --apply
  ./zsh-history-prune.sh --histfile ~/.zsh_history --apply
EOF
}

HISTFILE_PATH="${HISTFILE:-$HOME/.zsh_history}"
MIN_COUNT=5
TOP_N=0
KEEP_RECENT=500
BACKUP_DIR="$HOME/.zsh_history.backups"
APPLY=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --histfile)
      [ "$#" -ge 2 ] || { echo "missing value for --histfile" >&2; exit 1; }
      HISTFILE_PATH=$2
      shift 2
      ;;
    --min-count)
      [ "$#" -ge 2 ] || { echo "missing value for --min-count" >&2; exit 1; }
      MIN_COUNT=$2
      shift 2
      ;;
    --top)
      [ "$#" -ge 2 ] || { echo "missing value for --top" >&2; exit 1; }
      TOP_N=$2
      shift 2
      ;;
    --keep-recent)
      [ "$#" -ge 2 ] || { echo "missing value for --keep-recent" >&2; exit 1; }
      KEEP_RECENT=$2
      shift 2
      ;;
    --backup-dir)
      [ "$#" -ge 2 ] || { echo "missing value for --backup-dir" >&2; exit 1; }
      BACKUP_DIR=$2
      shift 2
      ;;
    --apply)
      APPLY=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

is_non_negative_int() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

for value in "$MIN_COUNT" "$TOP_N" "$KEEP_RECENT"; do
  is_non_negative_int "$value" || {
    echo "numeric options must be non-negative integers" >&2
    exit 1
  }
done

[ -f "$HISTFILE_PATH" ] || {
  echo "history file not found: $HISTFILE_PATH" >&2
  exit 1
}

[ -s "$HISTFILE_PATH" ] || {
  echo "history file is empty: $HISTFILE_PATH" >&2
  exit 1
}

TMPDIR_PATH="$(mktemp -d)"
cleanup() {
  rm -rf "$TMPDIR_PATH"
}
trap cleanup EXIT INT TERM

COUNTS_FILE="$TMPDIR_PATH/counts.tsv"
KEEP_CMDS_FILE="$TMPDIR_PATH/keep_cmds.txt"
FILTERED_FILE="$TMPDIR_PATH/filtered_history"
SUMMARY_FILE="$TMPDIR_PATH/summary.env"

awk '
function trim(s) {
  sub(/^[[:space:]]+/, "", s)
  sub(/[[:space:]]+$/, "", s)
  return s
}

function normalize_line(raw, line) {
  line = raw
  if (line ~ /^: [0-9]+:[0-9]+;/) {
    sub(/^: [0-9]+:[0-9]+;/, "", line)
  }
  line = trim(line)
  return line
}

{
  line = normalize_line($0)
  if (line != "") {
    counts[line]++
  }
}

END {
  for (line in counts) {
    printf "%d\t%s\n", counts[line], line
  }
}
' "$HISTFILE_PATH" | sort -t '	' -k1,1nr -k2,2 > "$COUNTS_FILE"

: > "$KEEP_CMDS_FILE"

if [ "$TOP_N" -gt 0 ]; then
  awk -F '	' -v top="$TOP_N" 'NR <= top { print $2 }' "$COUNTS_FILE" >> "$KEEP_CMDS_FILE"
fi

if [ "$MIN_COUNT" -gt 0 ]; then
  awk -F '	' -v min="$MIN_COUNT" '$1 >= min { print $2 }' "$COUNTS_FILE" >> "$KEEP_CMDS_FILE"
fi

sort -u "$KEEP_CMDS_FILE" -o "$KEEP_CMDS_FILE"

awk -v keep_recent="$KEEP_RECENT" -v keep_cmds="$KEEP_CMDS_FILE" -v filtered="$FILTERED_FILE" -v summary="$SUMMARY_FILE" '
function trim(s) {
  sub(/^[[:space:]]+/, "", s)
  sub(/[[:space:]]+$/, "", s)
  return s
}

function normalize_line(raw, line) {
  line = raw
  if (line ~ /^: [0-9]+:[0-9]+;/) {
    sub(/^: [0-9]+:[0-9]+;/, "", line)
  }
  line = trim(line)
  return line
}

BEGIN {
  while ((getline line < keep_cmds) > 0) {
    keep_map[line] = 1
  }
  close(keep_cmds)
}

{
  total++
  lines[total] = $0
  normalized[total] = normalize_line($0)
}

END {
  start_recent = total - keep_recent + 1
  if (start_recent < 1) {
    start_recent = 1
  }

  for (i = 1; i <= total; i++) {
    keep = 0
    if (i >= start_recent) {
      keep = 1
    } else if (normalized[i] != "" && (normalized[i] in keep_map)) {
      keep = 1
    }

    if (keep) {
      print lines[i] >> filtered
      kept++
    }
  }

  print "TOTAL_LINES=" total > summary
  print "KEPT_LINES=" kept >> summary
  print "REMOVED_LINES=" (total - kept) >> summary
}
' "$HISTFILE_PATH"

. "$SUMMARY_FILE"

echo "history file:  $HISTFILE_PATH"
echo "min count:     $MIN_COUNT"
echo "top lines:     $TOP_N"
echo "keep recent:   $KEEP_RECENT"
echo
echo "top full command lines that will be kept:"
if [ -s "$COUNTS_FILE" ]; then
  awk -F '	' 'NR <= 20 { printf "  [%s] %s\n", $1, $2 }' "$COUNTS_FILE"
else
  echo "  no command lines found"
fi
echo
echo "line summary:"
echo "  total:       $TOTAL_LINES"
echo "  kept:        $KEPT_LINES"
echo "  removed:     $REMOVED_LINES"

if [ "$APPLY" -eq 0 ]; then
  echo
  echo "preview only. add --apply to rewrite the history file."
  exit 0
fi

if cmp -s "$HISTFILE_PATH" "$FILTERED_FILE"; then
  echo
  echo "history already matches the filtered result. nothing to do."
  exit 0
fi

mkdir -p "$BACKUP_DIR"
TIMESTAMP="$(date -u +"%Y%m%dT%H%M%SZ")"
BACKUP_FILE="$BACKUP_DIR/$(basename "$HISTFILE_PATH").$TIMESTAMP.bak"
cp "$HISTFILE_PATH" "$BACKUP_FILE"
cp "$FILTERED_FILE" "$HISTFILE_PATH"

echo
echo "backup written to: $BACKUP_FILE"
echo "history rewritten: $HISTFILE_PATH"
