#!/bin/sh
set -eu

usage() {
  cat <<'EOF'
Usage:
  ./netcat-transfer.sh send [options]
  ./netcat-transfer.sh recv [options]

Modes:
  send               Archive a file or directory, compress it, and stream it with netcat
  recv               Listen with netcat, receive the stream, decompress, and extract it

Common options:
  --compression MODE Compression mode: auto, zstd, gzip, none (default: auto)
  -h, --help         Show this help

Send options:
  --host HOST        Receiver host
  --port PORT        Receiver port
  --path PATH        File or directory to send

Receive options:
  --port PORT        Listen port
  --path DIR         Destination directory for extraction

Examples:
  ./netcat-transfer.sh recv --port 9000 --path /tmp/recv
  ./netcat-transfer.sh send --host 192.168.1.10 --port 9000 --path ./demo
  ./netcat-transfer.sh send --host 192.168.1.10 --port 9000 --path ./demo --compression gzip
EOF
}

MODE=""
HOST=""
PORT=""
SOURCE_PATH=""
TARGET_PATH=""
COMPRESSION="auto"

[ "$#" -gt 0 ] || {
  usage >&2
  exit 1
}

case "$1" in
  -h|--help)
    usage
    exit 0
    ;;
esac

MODE=$1
shift

while [ "$#" -gt 0 ]; do
  case "$1" in
    --host)
      [ "$#" -ge 2 ] || { echo "missing value for --host" >&2; exit 1; }
      HOST=$2
      shift 2
      ;;
    --port)
      [ "$#" -ge 2 ] || { echo "missing value for --port" >&2; exit 1; }
      PORT=$2
      shift 2
      ;;
    --path)
      [ "$#" -ge 2 ] || { echo "missing value for --path" >&2; exit 1; }
      TARGET_PATH=$2
      shift 2
      ;;
    --compression)
      [ "$#" -ge 2 ] || { echo "missing value for --compression" >&2; exit 1; }
      COMPRESSION=$2
      shift 2
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

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "required command not found: $1" >&2
    exit 1
  }
}

is_port() {
  case "$1" in
    ''|*[!0-9]*)
      return 1
      ;;
    *)
      [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
      ;;
  esac
}

pick_compression() {
  case "$1" in
    auto)
      if command -v zstd >/dev/null 2>&1; then
        printf '%s\n' "zstd"
      else
        printf '%s\n' "gzip"
      fi
      ;;
    zstd|gzip|none)
      printf '%s\n' "$1"
      ;;
    *)
      echo "unsupported compression: $1" >&2
      exit 1
      ;;
  esac
}

compress_cmd() {
  case "$1" in
    zstd)
      require_command zstd
      printf '%s\n' "zstd -T0 -q -c"
      ;;
    gzip)
      require_command gzip
      printf '%s\n' "gzip -c"
      ;;
    none)
      printf '%s\n' "cat"
      ;;
  esac
}

decompress_cmd() {
  case "$1" in
    zstd)
      require_command zstd
      printf '%s\n' "zstd -q -d -c"
      ;;
    gzip)
      require_command gzip
      printf '%s\n' "gzip -d -c"
      ;;
    none)
      printf '%s\n' "cat"
      ;;
  esac
}

nc_listen_args() {
  if nc -h 2>&1 | grep -qi 'openbsd'; then
    printf '%s\n' "-l $1"
  else
    printf '%s\n' "-l -p $1"
  fi
}

nc_send_args() {
  if nc -h 2>&1 | grep -qi 'openbsd'; then
    printf '%s\n' "-N"
  else
    printf '%s\n' ""
  fi
}

require_command tar
require_command nc

SELECTED_COMPRESSION="$(pick_compression "$COMPRESSION")"
COMPRESS_CMD="$(compress_cmd "$SELECTED_COMPRESSION")"
DECOMPRESS_CMD="$(decompress_cmd "$SELECTED_COMPRESSION")"

case "$MODE" in
  send)
    [ -n "$PORT" ] || {
      echo "--port is required for send mode" >&2
      exit 1
    }
    is_port "$PORT" || {
      echo "invalid port: $PORT" >&2
      exit 1
    }
    [ -n "$HOST" ] || {
      echo "--host is required for send mode" >&2
      exit 1
    }
    [ -n "$TARGET_PATH" ] || {
      echo "--path is required for send mode" >&2
      exit 1
    }
    SOURCE_PATH=$TARGET_PATH
    [ -e "$SOURCE_PATH" ] || {
      echo "source path not found: $SOURCE_PATH" >&2
      exit 1
    }

    SOURCE_ABS="$(cd "$(dirname "$SOURCE_PATH")" && pwd)/$(basename "$SOURCE_PATH")"
    SOURCE_PARENT="$(dirname "$SOURCE_ABS")"
    SOURCE_NAME="$(basename "$SOURCE_ABS")"
    SEND_ARGS="$(nc_send_args)"

    echo "mode:            send"
    echo "source:          $SOURCE_ABS"
    echo "host:            $HOST"
    echo "port:            $PORT"
    echo "compression:     $SELECTED_COMPRESSION"

    (
      cd "$SOURCE_PARENT"
      if [ -n "$SEND_ARGS" ]; then
        tar -cf - "$SOURCE_NAME" | eval "$COMPRESS_CMD" | nc $SEND_ARGS "$HOST" "$PORT"
      else
        tar -cf - "$SOURCE_NAME" | eval "$COMPRESS_CMD" | nc "$HOST" "$PORT"
      fi
    )
    ;;
  recv)
    [ -n "$PORT" ] || {
      echo "--port is required for recv mode" >&2
      exit 1
    }
    is_port "$PORT" || {
      echo "invalid port: $PORT" >&2
      exit 1
    }
    [ -n "$TARGET_PATH" ] || {
      echo "--path is required for recv mode" >&2
      exit 1
    }

    DEST_DIR=$TARGET_PATH

    mkdir -p "$DEST_DIR"
    [ -w "$DEST_DIR" ] || {
      echo "destination directory is not writable: $DEST_DIR" >&2
      exit 1
    }

    LISTEN_ARGS="$(nc_listen_args "$PORT")"

    echo "mode:            recv"
    echo "destination:     $DEST_DIR"
    echo "port:            $PORT"
    echo "compression:     $SELECTED_COMPRESSION"

    eval "nc $LISTEN_ARGS" | eval "$DECOMPRESS_CMD" | tar -xf - -C "$DEST_DIR"
    ;;
  *)
    echo "unknown mode: $MODE" >&2
    usage >&2
    exit 1
    ;;
esac
