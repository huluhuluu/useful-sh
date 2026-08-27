#!/bin/sh
set -eu

usage() {
  cat <<'EOF'
Usage:
  ./adb-server-relay.sh [options]

Purpose:
  Expose this host's local ADB *server* socket (protocol 1) to a remote host
  over an SSH reverse tunnel, so remote clients can run:

      adb -H <relay-ip> -P <relay-port> push -z zstd ...

  This is complementary to adb-relay-guard.sh, which forwards device *adbd*
  ports (protocol 2). Protocol 2 is stop-and-wait and collapses over a WAN;
  protocol 1 is a plain byte stream and runs at link speed. Keeping the adb
  server next to the USB device is what makes remote push fast.

  Use this relay for `push`. Keep adb-relay-guard.sh + `adb connect` for
  `pull`, `shell`, and `adb forward`, which are faster or only work there.

Options:
  --ssh-host HOST      SSH host for the reverse tunnel. Required unless --no-ssh
  --remote-port PORT   Remote port to bind the tunnel to (default: 47964)
  --server-port PORT   Local adb server port (default: 5037)
  --ssh-bind ADDR      Remote bind address for ssh -R (default: 127.0.0.1)
  --device SERIAL      USB adb serial to health check. Auto-detects by default
  --guard-config FILE  Refuse to start if FILE reserves --remote-port
  --interval SEC       Health check interval in seconds (default: 5)
  --once               Check once, start the tunnel, then wait on it
  --no-ssh             Do not start the SSH reverse tunnel
  -v, --verbose        Print healthy polling details
  -h, --help           Show this help

Examples:
  ./adb-server-relay.sh --ssh-host cpu
  ./adb-server-relay.sh --ssh-host cpu --remote-port 47964 \
      --guard-config ../adb-relay-guard/devices.conf
  ./adb-server-relay.sh --no-ssh --once
EOF
}

REMOTE_PORT=47964
SERVER_PORT=5037
SSH_HOST=""
SSH_BIND=127.0.0.1
USB_SERIAL=""
GUARD_CONFIG=""
INTERVAL=5
ONCE=0
NO_SSH=0
VERBOSE=0
SSH_PID=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --ssh-host)
      [ "$#" -ge 2 ] || { echo "missing value for --ssh-host" >&2; exit 1; }
      SSH_HOST=$2
      shift 2
      ;;
    --remote-port)
      [ "$#" -ge 2 ] || { echo "missing value for --remote-port" >&2; exit 1; }
      REMOTE_PORT=$2
      shift 2
      ;;
    --server-port)
      [ "$#" -ge 2 ] || { echo "missing value for --server-port" >&2; exit 1; }
      SERVER_PORT=$2
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
    --guard-config)
      [ "$#" -ge 2 ] || { echo "missing value for --guard-config" >&2; exit 1; }
      GUARD_CONFIG=$2
      shift 2
      ;;
    --interval)
      [ "$#" -ge 2 ] || { echo "missing value for --interval" >&2; exit 1; }
      INTERVAL=$2
      shift 2
      ;;
    --once) ONCE=1; shift ;;
    --no-ssh) NO_SSH=1; shift ;;
    -v|--verbose) VERBOSE=1; shift ;;
    -h|--help) usage; exit 0 ;;
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

is_port "$REMOTE_PORT" || { echo "invalid --remote-port: $REMOTE_PORT" >&2; exit 1; }
is_port "$SERVER_PORT" || { echo "invalid --server-port: $SERVER_PORT" >&2; exit 1; }
is_positive_int "$INTERVAL" || { echo "invalid --interval: $INTERVAL" >&2; exit 1; }

require_command adb

if [ "$NO_SSH" -eq 0 ]; then
  [ -n "$SSH_HOST" ] || {
    echo "--ssh-host is required unless --no-ssh is set" >&2
    exit 1
  }
  require_command ssh
fi

# adb-relay-guard.sh reserves ports per device. If a device block in its config
# claims REMOTE_PORT, that device coming online would collide with this tunnel.
check_guard_conflict() {
  file=$1
  port=$2

  [ -r "$file" ] || {
    echo "guard config is not readable: $file" >&2
    return 1
  }

  owner=$(awk -v want="$port" '
    function trim(s) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
      return s
    }

    {
      line = $0
      sub(/\r$/, "", line)
      block_line = line
      sub(/[[:space:]]*#.*/, "", line)
      line = trim(line)
      if (line == "") {
        next
      }

      if (block_line ~ /^[^[:space:]][^:]*:[[:space:]]*$/) {
        label = line
        sub(/:$/, "", label)
        next
      }

      if (index(line, ":") == 0) {
        next
      }

      key = trim(substr(line, 1, index(line, ":") - 1))
      value = trim(substr(line, index(line, ":") + 1))

      if (key != "adb" && key != "relay" && key != "relays") {
        next
      }

      n = split(value, ports, ",")
      for (i = 1; i <= n; i++) {
        if (trim(ports[i]) == want) {
          print label
          exit
        }
      }
    }
  ' "$file")

  if [ -n "$owner" ]; then
    echo "port $port is reserved by device block '$owner' in $file" >&2
    echo "pick a different --remote-port, or remove that device from the guard config" >&2
    return 1
  fi
}

if [ -n "$GUARD_CONFIG" ]; then
  check_guard_conflict "$GUARD_CONFIG" "$REMOTE_PORT" || exit 1
fi

log "adb server relay started: server_port=$SERVER_PORT remote=$SSH_BIND:$REMOTE_PORT ssh_host=${SSH_HOST:-none} device=${USB_SERIAL:-auto} interval=${INTERVAL}s once=$ONCE no_ssh=$NO_SSH verbose=$VERBOSE"

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
  adb devices -l | awk '
    NR > 1 && $2 == "device" && $0 ~ /usb:/ {
      print $1
      exit
    }
  '
}

# Deliberately never calls kill-server: adb-relay-guard.sh shares this server,
# and killing it would tear down the device forward rules behind the production
# relay. Only start it if nothing is listening yet.
ensure_server() {
  if adb -P "$SERVER_PORT" host-features >/dev/null 2>&1; then
    debug "adb server is up on port $SERVER_PORT"
    return 0
  fi

  log "adb server not responding on $SERVER_PORT; starting it"
  adb -P "$SERVER_PORT" start-server >/dev/null 2>&1 || {
    echo "failed to start adb server on port $SERVER_PORT" >&2
    return 1
  }
}

device_present() {
  if [ -n "$USB_SERIAL" ]; then
    adb -P "$SERVER_PORT" -s "$USB_SERIAL" get-state >/dev/null 2>&1
    return $?
  fi

  [ -n "$(detect_usb_serial)" ]
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

  log "starting ssh reverse tunnel to $SSH_HOST ($SSH_BIND:$REMOTE_PORT -> 127.0.0.1:$SERVER_PORT)"
  ssh -NT \
    -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval=15 \
    -o ServerAliveCountMax=2 \
    -R "$SSH_BIND:$REMOTE_PORT:127.0.0.1:$SERVER_PORT" \
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
    log "stopping ssh tunnel because health check failed"
    kill "$SSH_PID" 2>/dev/null || true
    wait "$SSH_PID" 2>/dev/null || true
  fi
  SSH_PID=""
}

relay_is_healthy() {
  ensure_server || return 1

  if ! device_present; then
    log "no usb adb device available"
    return 1
  fi

  debug "relay healthy: server=$SERVER_PORT device=${USB_SERIAL:-$(detect_usb_serial)}"
}

if [ "$ONCE" -eq 1 ]; then
  relay_is_healthy || exit 1
  if [ "$NO_SSH" -eq 0 ]; then
    start_ssh_tunnel || { echo "ssh tunnel start failed" >&2; exit 1; }
    wait "$SSH_PID"
  fi
  exit 0
fi

while :; do
  if relay_is_healthy; then
    if [ "$NO_SSH" -eq 0 ]; then
      start_ssh_tunnel || log "ssh tunnel start failed"
    fi
  else
    log "relay health check failed"
    stop_ssh_tunnel
  fi

  sleep "$INTERVAL"
  reap_ssh_if_dead
done
