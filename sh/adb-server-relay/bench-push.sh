#!/bin/sh
# Benchmark adb push across the two relay paths.
#
# Two measurement traps this works around:
#   1. -Z / -z are `push` subcommand flags, not global adb flags. Placed before
#      the subcommand adb exits with "unknown command" in 0.01s, which looks
#      like an impossibly fast transfer.
#   2. push returns once data is handed to the kernel/ssh/socat buffers, so it
#      can report hundreds of MB/s over a slow link. Only the push+verify total
#      is trustworthy: md5sum cannot read the right hash until bytes land.
set -u

FAILED=0

A=${ADB_BIN:-/data/tools/platform-tools/adb}
F=${1:?usage: bench-push.sh <file> [connect-serial] [relay-host:port] [usb-serial]}
CONNECT_SERIAL=${2:-192.168.124.101:47954}
RELAY=${3:-192.168.124.101:47964}
USB_SERIAL=${4:-3B1F4CE65NHWP2E5}

RELAY_HOST=$(printf '%s' "$RELAY" | cut -d: -f1)
RELAY_PORT=$(printf '%s' "$RELAY" | cut -d: -f2)

[ -r "$F" ] || { echo "cannot read $F" >&2; exit 1; }

SZ=$(stat -c %s "$F")
REF=$(md5sum "$F" | awk '{print $1}')
printf 'file  %s\nsize  %s bytes (%.1f MB)\nmd5   %s\n\n' \
  "$F" "$SZ" "$(awk -v s="$SZ" 'BEGIN{print s/1048576}')" "$REF"
printf '%-22s %9s %9s %9s %11s  %s\n' MODE PUSH VERIFY TOTAL 'EFFECTIVE' RESULT

bench() {
  label=$1
  shift
  dst=bench_$$

  $A -s "$CONNECT_SERIAL" shell rm -f "/data/local/tmp/$dst" >/dev/null 2>&1

  t0=$(date +%s.%N)
  if ! "$@" "$F" "/data/local/tmp/$dst" >/dev/null 2>&1; then
    printf '%-22s %9s %9s %9s %11s  PUSH-FAILED\n' "$label" - - - -
    return 1
  fi
  t1=$(date +%s.%N)
  got=$($A -s "$CONNECT_SERIAL" shell md5sum "/data/local/tmp/$dst" 2>/dev/null | awk '{print $1}')
  t2=$(date +%s.%N)

  if [ "$got" = "$REF" ]; then
    verdict=MD5-OK
  else
    verdict="MD5-BAD(${got:-empty})"
    return_code=1
  fi

  awk -v a="$t0" -v b="$t1" -v c="$t2" -v sz="$SZ" -v l="$label" -v v="$verdict" 'BEGIN {
    push = b - a; verify = c - b; total = c - a
    printf "%-22s %8.2fs %8.2fs %8.2fs %8.2f MB/s  %s\n", l, push, verify, total, sz/1048576/total, v
  }'

  $A -s "$CONNECT_SERIAL" shell rm -f "/data/local/tmp/$dst" >/dev/null 2>&1

  if [ "${return_code:-0}" -ne 0 ]; then
    unset return_code
    return 1
  fi
}

bench 'connect -Z' \
  $A -s "$CONNECT_SERIAL" push -Z || FAILED=1
bench 'connect -z zstd' \
  $A -s "$CONNECT_SERIAL" push -z zstd || FAILED=1
bench '-H -Z' \
  $A -H "$RELAY_HOST" -P "$RELAY_PORT" -s "$USB_SERIAL" push -Z || FAILED=1
bench '-H -z zstd' \
  $A -H "$RELAY_HOST" -P "$RELAY_PORT" -s "$USB_SERIAL" push -z zstd || FAILED=1

printf '\ndevice /data:\n'
$A -s "$CONNECT_SERIAL" shell df -h /data/local/tmp | tail -1

exit "$FAILED"
