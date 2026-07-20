#!/bin/sh
set -eu

SCRIPT="./sh/netcat-transfer/netcat-transfer.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  haystack=$1
  needle=$2
  label=$3

  case "$haystack" in
    *"$needle"*) ;;
    *) fail "$label: expected output to contain '$needle'" ;;
  esac
}

help_output="$("$SCRIPT" --help)"
assert_contains "$help_output" "--progress MODE" "help documents progress option"
assert_contains "$help_output" "auto, on, off" "help documents progress modes"

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM

set +e
"$SCRIPT" send \
  --host 127.0.0.1 \
  --port 9000 \
  --path "$tmp_dir" \
  --progress fast \
  >"$tmp_dir/stdout" 2>"$tmp_dir/stderr"
status=$?
set -e

[ "$status" -ne 0 ] || fail "invalid progress mode should fail"
assert_contains "$(cat "$tmp_dir/stderr")" "unsupported progress mode: fast" "invalid progress mode error"

echo "netcat-transfer progress tests passed"
