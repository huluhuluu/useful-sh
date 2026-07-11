#!/bin/sh
set -eu

usage() {
  cat <<'EOF'
Usage:
  ./adb-relay-guard.sh [options]

Default behavior:
  Keep USB ADB, adb forward, and SSH reverse tunnel ready for remote ADB access.

Options:
  --config FILE       Multi-device config file. Cannot be combined with --device/--adb-port/--relay-port
  --adb-port PORT      Device adbd TCP port and forwarded local port (default: 47954)
  --relay-port PORT    Extra forwarded relay port. Can be repeated (default: 45058)
  --relay-ports PORTS  Comma-separated extra forwarded relay ports
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
  ./adb-relay-guard.sh --ssh-host <ssh-host> --device ABC123 --adb-port 47954 --relay-ports 45058,45059
  ./adb-relay-guard.sh --ssh-host <ssh-host> --config devices.conf
EOF
}

CONFIG_FILE=""
ADB_PORT=47954
RELAY_PORTS=45058
RELAY_PORTS_SET=0
SINGLE_TARGET_ARG_SET=0
SSH_HOST=""
SSH_BIND=0.0.0.0
USB_SERIAL=""
INTERVAL=5
ONCE=0
NO_SSH=0
VERBOSE=0
SSH_PID=""
CONFIG_RECORDS=""
SSH_PORTS=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --config)
      [ "$#" -ge 2 ] || { echo "missing value for --config" >&2; exit 1; }
      CONFIG_FILE=$2
      shift 2
      ;;
    --adb-port)
      [ "$#" -ge 2 ] || { echo "missing value for --adb-port" >&2; exit 1; }
      ADB_PORT=$2
      SINGLE_TARGET_ARG_SET=1
      shift 2
      ;;
    --relay-port)
      [ "$#" -ge 2 ] || { echo "missing value for --relay-port" >&2; exit 1; }
      if [ "$RELAY_PORTS_SET" -eq 0 ]; then
        RELAY_PORTS=$2
        RELAY_PORTS_SET=1
      else
        RELAY_PORTS=$RELAY_PORTS,$2
      fi
      SINGLE_TARGET_ARG_SET=1
      shift 2
      ;;
    --relay-ports)
      [ "$#" -ge 2 ] || { echo "missing value for --relay-ports" >&2; exit 1; }
      if [ "$RELAY_PORTS_SET" -eq 0 ]; then
        RELAY_PORTS=$2
        RELAY_PORTS_SET=1
      else
        RELAY_PORTS=$RELAY_PORTS,$2
      fi
      SINGLE_TARGET_ARG_SET=1
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
      SINGLE_TARGET_ARG_SET=1
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

port_list_to_words() {
  printf '%s\n' "$1" | tr ',' '\n' | awk '
    {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "")
      if ($0 != "") {
        print
      }
    }
  '
}

validate_port_list() {
  list=$1

  [ -n "$list" ] || return 1

  for port in $(port_list_to_words "$list"); do
    is_port "$port" || return 1
  done
}

parse_config_file() {
  file=$1

  [ -r "$file" ] || {
    echo "config file is not readable: $file" >&2
    return 1
  }

  awk '
    function trim(s) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
      return s
    }

    function flush() {
      if (!in_block) {
        return
      }
      if (serial == "" || adb == "" || relay == "") {
        printf("invalid config block %s: serial, adb, and relay are required\n", label) > "/dev/stderr"
        err = 1
      } else {
        print serial "|" adb "|" relay
      }
      serial = ""
      adb = ""
      relay = ""
      label = ""
      in_block = 0
    }

    {
      line = $0
      sub(/\r$/, "", line)
      sub(/[[:space:]]*#.*/, "", line)
      block_line = line
      line = trim(line)
      if (line == "") {
        next
      }

      if (block_line ~ /^[^[:space:]][^:]*:[[:space:]]*$/) {
        flush()
        label = line
        in_block = 1
        next
      }

      if (!in_block) {
        printf("config line outside device block: %s\n", line) > "/dev/stderr"
        err = 1
        next
      }

      if (index(line, ":") == 0) {
        printf("invalid config line: %s\n", line) > "/dev/stderr"
        err = 1
        next
      }

      key = trim(substr(line, 1, index(line, ":") - 1))
      value = trim(substr(line, index(line, ":") + 1))

      if (key == "serial") {
        serial = value
      } else if (key == "adb") {
        adb = value
      } else if (key == "relay" || key == "relays") {
        relay = value
      } else {
        printf("unknown config key in %s: %s\n", label, key) > "/dev/stderr"
        err = 1
      }
    }

    END {
      flush()
      exit(err ? 1 : 0)
    }
  ' "$file"
}

records_to_ports() {
  records_file=$1

  while IFS='|' read -r serial adb_port relay_ports; do
    [ -n "$adb_port" ] || continue
    printf '%s\n' "$adb_port"
    for port in $(port_list_to_words "$relay_ports"); do
      printf '%s\n' "$port"
    done
  done < "$records_file"
}

validate_records() {
  records_file=$1
  count=0

  while IFS='|' read -r serial adb_port relay_ports; do
    [ -n "$adb_port" ] || continue
    count=$((count + 1))

    is_port "$adb_port" || {
      echo "invalid adb port for ${serial:-auto}: $adb_port" >&2
      return 1
    }

    validate_port_list "$relay_ports" || {
      echo "invalid relay ports for ${serial:-auto}: $relay_ports" >&2
      return 1
    }
  done < "$records_file"

  [ "$count" -gt 0 ] || {
    echo "no device records found" >&2
    return 1
  }

  duplicate_port=$(records_to_ports "$records_file" | sort | uniq -d | awk 'NR == 1 { print; exit }')
  if [ -n "$duplicate_port" ]; then
    echo "duplicate forwarded port in device records: $duplicate_port" >&2
    return 1
  fi
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "required command not found: $1" >&2
    exit 1
  }
}

if [ -n "$CONFIG_FILE" ] && [ "$SINGLE_TARGET_ARG_SET" -eq 1 ]; then
  echo "--config cannot be combined with --device, --adb-port, --relay-port, or --relay-ports" >&2
  exit 1
fi

is_port "$ADB_PORT" || {
  echo "invalid --adb-port: $ADB_PORT" >&2
  exit 1
}

validate_port_list "$RELAY_PORTS" || {
  echo "invalid relay ports: $RELAY_PORTS" >&2
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

CONFIG_RECORDS=$(mktemp)
SSH_PORTS=$(mktemp)

if [ -n "$CONFIG_FILE" ]; then
  parse_config_file "$CONFIG_FILE" > "$CONFIG_RECORDS"
  MODE="config:$CONFIG_FILE"
else
  printf '%s|%s|%s\n' "$USB_SERIAL" "$ADB_PORT" "$RELAY_PORTS" > "$CONFIG_RECORDS"
  MODE="single"
fi

validate_records "$CONFIG_RECORDS"
records_to_ports "$CONFIG_RECORDS" > "$SSH_PORTS"

TARGET_COUNT=$(awk 'NF { count++ } END { print count + 0 }' "$CONFIG_RECORDS")
SSH_PORT_LIST=$(awk 'BEGIN { sep = "" } { printf "%s%s", sep, $0; sep = "," } END { print "" }' "$SSH_PORTS")

log "adb relay guard started: mode=$MODE targets=$TARGET_COUNT ports=$SSH_PORT_LIST ssh_host=${SSH_HOST:-none} ssh_bind=$SSH_BIND interval=${INTERVAL}s once=$ONCE no_ssh=$NO_SSH verbose=$VERBOSE"

cleanup() {
  if [ -n "$SSH_PID" ] && kill -0 "$SSH_PID" 2>/dev/null; then
    log "stopping ssh tunnel pid=$SSH_PID"
    kill "$SSH_PID" 2>/dev/null || true
    wait "$SSH_PID" 2>/dev/null || true
  fi
  [ -n "$CONFIG_RECORDS" ] && rm -f "$CONFIG_RECORDS"
  [ -n "$SSH_PORTS" ] && rm -f "$SSH_PORTS"
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

restart_adb_server() {
  log "restarting adb server"
  adb kill-server >/dev/null 2>&1 || true
  adb start-server >/dev/null
}

wait_for_device() {
  serial=$1
  max_wait=$2
  waited=0

  while [ "$waited" -lt "$max_wait" ]; do
    if adb -s "$serial" get-state >/dev/null 2>&1; then
      return 0
    fi

    sleep 1
    waited=$((waited + 1))
  done

  return 1
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
  adb_port=$2
  current_port=$(adb -s "$serial" shell getprop service.adb.tcp.port 2>/dev/null | tr -d '\r' | awk 'NR == 1 { print $1 }')

  if [ "$current_port" = "$adb_port" ]; then
    debug "adb tcpip already uses port $adb_port"
    return 0
  fi

  log "switching device $serial to adb tcpip $adb_port"
  adb -s "$serial" tcpip "$adb_port" >/dev/null
  wait_for_device "$serial" 15 || {
    echo "device $serial did not return after adb tcpip $adb_port" >&2
    return 1
  }
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
  adb_port=$2
  relay_ports=$3

  ensure_forward_port "$serial" "$adb_port" || return $?
  for port in $(port_list_to_words "$relay_ports"); do
    ensure_forward_port "$serial" "$port" || return $?
  done
}

ensure_device_ready_once() {
  serial_arg=$1
  adb_port=$2
  relay_ports=$3

  if [ -n "$serial_arg" ]; then
    serial=$serial_arg
  else
    serial=$(detect_usb_serial)
  fi

  if [ -z "$serial" ]; then
    echo "no usb adb device found" >&2
    return 1
  fi

  debug "using usb adb device: $serial"
  ensure_tcpip "$serial" "$adb_port" || return 1
  ensure_forward_ports "$serial" "$adb_port" "$relay_ports"
}

ensure_device_ready() {
  serial=$1
  adb_port=$2
  relay_ports=$3
  attempt=1

  while [ "$attempt" -le 2 ]; do
    result=0
    ensure_device_ready_once "$serial" "$adb_port" "$relay_ports" || result=$?

    case "$result" in
      0)
        return 0
        ;;
      2)
        restart_adb_server
        attempt=$((attempt + 1))
        ;;
      *)
        return "$result"
        ;;
    esac
  done

  return 1
}

ensure_targets_ready() {
  ok_count=0
  fail_count=0

  while IFS='|' read -r serial adb_port relay_ports <&3; do
    [ -n "$adb_port" ] || continue

    if ensure_device_ready "$serial" "$adb_port" "$relay_ports"; then
      ok_count=$((ok_count + 1))
    else
      fail_count=$((fail_count + 1))
      log "adb repair failed for ${serial:-auto} adb_port=$adb_port relay_ports=$relay_ports"
    fi
  done 3< "$CONFIG_RECORDS"

  [ "$ok_count" -gt 0 ] || return 1

  if [ "$fail_count" -gt 0 ]; then
    log "adb repair partially succeeded: ok=$ok_count failed=$fail_count"
  fi

  return 0
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
  set -- ssh -NT \
    -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval=15 \
    -o ServerAliveCountMax=2

  while read -r port; do
    [ -n "$port" ] || continue
    set -- "$@" -R "$SSH_BIND:$port:127.0.0.1:$port"
  done < "$SSH_PORTS"

  "$@" "$SSH_HOST" &
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
  ensure_targets_ready
  if [ "$NO_SSH" -eq 0 ]; then
    start_ssh_tunnel
    wait "$SSH_PID"
  fi
  exit 0
fi

while :; do
  if ensure_targets_ready; then
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
