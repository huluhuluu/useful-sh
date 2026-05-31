#!/bin/sh
set -eu

usage() {
  cat <<'EOF'
Usage:
  ./adb-relay-guard.sh [options]

Default behavior:
  Keep USB ADB, adb forward, and SSH reverse tunnel ready for remote ADB access.

Options:
  --adb-port PORT      Device adbd TCP port and forwarded local port (default: 47954)
  --relay-port PORT    Extra forwarded relay port (default: 45058)
  --ssh-host HOST      SSH host used by reverse tunnel. Required unless --no-ssh is set
  --ssh-bind ADDR      Remote bind address for ssh -R (default: 0.0.0.0)
  --device SERIAL      USB adb serial to use. Auto-detects the first usb: device by default
  --interval SEC       Health check interval in seconds (default: 5)
  --once               Repair adb tcpip and adb forward once, then exit unless SSH is enabled
  --no-ssh             Do not start SSH reverse tunnel
  -v, --verbose        Print healthy polling details
  -h, --help           Show this help

Examples:
  ./adb-relay-guard.sh --once --no-ssh
  ./adb-relay-guard.sh --ssh-host <ssh-host>
  ./adb-relay-guard.sh --ssh-host <ssh-host> --adb-port 47954 --relay-port 45058
EOF
}

ADB_PORT=47954
RELAY_PORT=45058
SSH_HOST=""
SSH_BIND=0.0.0.0
USB_SERIAL=""
INTERVAL=5
ONCE=0
NO_SSH=0
VERBOSE=0
SSH_PID=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --adb-port)
      [ "$#" -ge 2 ] || { echo "missing value for --adb-port" >&2; exit 1; }
      ADB_PORT=$2
      shift 2
      ;;
    --relay-port)
      [ "$#" -ge 2 ] || { echo "missing value for --relay-port" >&2; exit 1; }
      RELAY_PORT=$2
      shift 2
      ;;
    --ssh-host)
      [ "$#" -ge 2 ] || { echo "missing value for --ssh-host" >&2; exit 1; }
      SSH_HOST=$2
      shift 2
      ;;
    --ssh-bind)
      [ "$#" -ge 2 ] || { echo "missing value for --ssh-bind" >&2; exit 1; }
      SSH_BIND=$2
      shift 2
      ;;
    --device)
      [ "$#" -ge 2 ] || { echo "missing value for --device" >&2; exit 1; }
      USB_SERIAL=$2
      shift 2
      ;;
    --interval)
      [ "$#" -ge 2 ] || { echo "missing value for --interval" >&2; exit 1; }
      INTERVAL=$2
      shift 2
      ;;
    --once)
      ONCE=1
      shift
      ;;
    --no-ssh)
      NO_SSH=1
      shift
      ;;
    -v|--verbose)
      VERBOSE=1
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

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

debug() {
  if [ "$VERBOSE" -eq 1 ]; then
    log "$@"
  fi
}

is_positive_int() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    *) [ "$1" -ge 1 ] ;;
  esac
}

is_port() {
  is_positive_int "$1" && [ "$1" -le 65535 ]
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "required command not found: $1" >&2
    exit 1
  }
}

is_port "$ADB_PORT" || {
  echo "invalid --adb-port: $ADB_PORT" >&2
  exit 1
}

is_port "$RELAY_PORT" || {
  echo "invalid --relay-port: $RELAY_PORT" >&2
  exit 1
}

is_positive_int "$INTERVAL" || {
  echo "invalid --interval: $INTERVAL" >&2
  exit 1
}

require_command adb

if [ "$NO_SSH" -eq 0 ]; then
  [ -n "$SSH_HOST" ] || {
    echo "--ssh-host is required unless --no-ssh is set" >&2
    exit 1
  }
  require_command ssh
fi

log "adb relay guard started: adb_port=$ADB_PORT relay_port=$RELAY_PORT ssh_host=${SSH_HOST:-none} ssh_bind=$SSH_BIND interval=${INTERVAL}s once=$ONCE no_ssh=$NO_SSH verbose=$VERBOSE"

cleanup() {
  if [ -n "$SSH_PID" ] && kill -0 "$SSH_PID" 2>/dev/null; then
    log "stopping ssh tunnel pid=$SSH_PID"
    kill "$SSH_PID" 2>/dev/null || true
    wait "$SSH_PID" 2>/dev/null || true
  fi
}

trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM

detect_usb_serial() {
  if [ -n "$USB_SERIAL" ]; then
    printf '%s\n' "$USB_SERIAL"
    return 0
  fi

  adb devices -l | awk '
    NR > 1 && $2 == "device" && $0 ~ /usb:/ {
      print $1
      exit
    }
  '
}

restart_adb_server() {
  log "restarting adb server"
  adb kill-server >/dev/null 2>&1 || true
  adb start-server >/dev/null
}

show_port_listener() {
  port=$1
  if command -v ss >/dev/null 2>&1; then
    ss -ltnp "sport = :$port" 2>/dev/null || true
  fi
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null || true
  fi
}

port_is_listened_by_adb() {
  port=$1

  if command -v ss >/dev/null 2>&1; then
    if ss -ltnp "sport = :$port" 2>/dev/null | grep -q '("adb",'; then
      return 0
    fi
  fi

  if command -v lsof >/dev/null 2>&1; then
    if lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | awk 'NR > 1 { print $1 }' | grep -qx adb; then
      return 0
    fi
  fi

  return 1
}

has_exact_forward() {
  serial=$1
  port=$2

  adb forward --list | awk -v serial="$serial" -v port="$port" '
    $1 == serial && $2 == "tcp:" port && $3 == "tcp:" port {
      found = 1
    }
    END {
      exit(found ? 0 : 1)
    }
  '
}

forward_owner() {
  port=$1

  adb forward --list | awk -v port="$port" '
    $2 == "tcp:" port {
      print $1
      exit
    }
  '
}

remove_stale_forward() {
  port=$1
  owner=$(forward_owner "$port" || true)

  if [ -n "$owner" ]; then
    log "removing stale adb forward owner=$owner tcp:$port"
    adb -s "$owner" forward --remove "tcp:$port" >/dev/null 2>&1 || true
  fi
}

ensure_tcpip() {
  serial=$1
  current_port=$(adb -s "$serial" shell getprop service.adb.tcp.port 2>/dev/null | tr -d '\r' | awk 'NR == 1 { print $1 }')

  if [ "$current_port" = "$ADB_PORT" ]; then
    debug "adb tcpip already uses port $ADB_PORT"
    return 0
  fi

  log "switching device $serial to adb tcpip $ADB_PORT"
  adb -s "$serial" tcpip "$ADB_PORT" >/dev/null
  sleep 2
}

ensure_forward_port() {
  serial=$1
  port=$2
  output_file=$(mktemp)

  if has_exact_forward "$serial" "$port"; then
    debug "adb forward exists: $serial tcp:$port tcp:$port"
    rm -f "$output_file"
    return 0
  fi

  remove_stale_forward "$port"

  log "creating adb forward: $serial tcp:$port tcp:$port"
  if adb -s "$serial" forward "tcp:$port" "tcp:$port" >"$output_file" 2>&1; then
    rm -f "$output_file"
    return 0
  fi

  if grep -q 'Address already in use' "$output_file"; then
    cat "$output_file" >&2
    rm -f "$output_file"

    if port_is_listened_by_adb "$port"; then
      log "tcp:$port is occupied by adb server; adb server needs restart"
      return 2
    fi

    echo "tcp:$port is occupied by a non-adb process" >&2
    show_port_listener "$port" >&2
    return 1
  fi

  cat "$output_file" >&2
  rm -f "$output_file"
  return 1
}

ensure_forward_ports() {
  serial=$1

  ensure_forward_port "$serial" "$ADB_PORT" || return $?
  ensure_forward_port "$serial" "$RELAY_PORT" || return $?
}

ensure_adb_ready_once() {
  serial=$(detect_usb_serial)

  if [ -z "$serial" ]; then
    echo "no usb adb device found" >&2
    return 1
  fi

  debug "using usb adb device: $serial"
  ensure_tcpip "$serial" || return 1
  ensure_forward_ports "$serial"
}

ensure_adb_ready() {
  attempt=1

  while [ "$attempt" -le 2 ]; do
    result=0
    ensure_adb_ready_once || result=$?

    case "$result" in
      0)
        return 0
        ;;
      2)
        restart_adb_server
        attempt=$((attempt + 1))
        ;;
      *)
        if [ "$attempt" -eq 1 ]; then
          restart_adb_server
          attempt=$((attempt + 1))
        else
          return "$result"
        fi
        ;;
    esac
  done

  return 1
}

ssh_is_running() {
  [ -n "$SSH_PID" ] && kill -0 "$SSH_PID" 2>/dev/null
}

reap_ssh_if_dead() {
  if [ -n "$SSH_PID" ] && ! kill -0 "$SSH_PID" 2>/dev/null; then
    wait "$SSH_PID" 2>/dev/null || true
    log "ssh tunnel exited"
    SSH_PID=""
  fi
}

start_ssh_tunnel() {
  if ssh_is_running; then
    return 0
  fi

  log "starting ssh reverse tunnel to $SSH_HOST"
  ssh -NT \
    -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval=15 \
    -o ServerAliveCountMax=2 \
    -R "$SSH_BIND:$ADB_PORT:127.0.0.1:$ADB_PORT" \
    -R "$SSH_BIND:$RELAY_PORT:127.0.0.1:$RELAY_PORT" \
    "$SSH_HOST" &
  SSH_PID=$!

  sleep 1
  if ssh_is_running; then
    log "ssh tunnel pid=$SSH_PID"
    return 0
  fi

  wait "$SSH_PID" 2>/dev/null || true
  SSH_PID=""
  return 1
}

stop_ssh_tunnel() {
  if ssh_is_running; then
    log "stopping ssh tunnel because adb repair failed"
    kill "$SSH_PID" 2>/dev/null || true
    wait "$SSH_PID" 2>/dev/null || true
  fi
  SSH_PID=""
}

if [ "$ONCE" -eq 1 ]; then
  ensure_adb_ready
  if [ "$NO_SSH" -eq 0 ]; then
    start_ssh_tunnel
    wait "$SSH_PID"
  fi
  exit 0
fi

while :; do
  if ensure_adb_ready; then
    if [ "$NO_SSH" -eq 0 ]; then
      start_ssh_tunnel || log "ssh tunnel start failed"
    fi
  else
    log "adb repair failed"
    stop_ssh_tunnel
  fi

  sleep "$INTERVAL"
  reap_ssh_if_dead
done
