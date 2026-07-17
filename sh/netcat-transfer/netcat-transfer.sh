#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./netcat-transfer.sh send [options]
  ./netcat-transfer.sh recv [options]
  ./netcat-transfer.sh test --listen --port PORT
  ./netcat-transfer.sh test --host HOST --port PORT [--timeout SECONDS]

Order:
  1. Start recv on the destination machine.
  2. Start send on the source machine after recv is listening.

Modes:
  send                 Archive one or more paths and stream them with netcat
  recv                 Listen with netcat and extract the received archive
  test                 Test whether the receiver TCP port is reachable

Common options:
  --port PORT          Transfer port. It must match on both sides
  --compression MODE   Backward-compatible alias for --compress (send) or
                       --decompress (recv)
  -h, --help           Show this help

Test options:
  --host HOST          Receiver host
  --listen             Listen for one connectivity test, then exit
  --timeout SECONDS    Connection timeout (default: 5)

Send options:
  --host HOST          Receiver host
  --path PATH...       One or more files/directories. Repeatable; shell globs
                       expanded to multiple arguments are supported
  --compress MODE      Compression: auto, zstd, gzip, none (default: auto)
  --no-compress        Send an uncompressed tar stream

Receive options:
  --path DIR           Destination directory for extraction
  --decompress MODE    Expected compression: auto, zstd, gzip, none
                       (default: none; auto trusts the sender stream header)
  --no-decompress      Expect an uncompressed tar stream (the default)

Examples:
  # Destination first
  ./netcat-transfer.sh recv --port 9000 --path /tmp/recv --decompress zstd

  # Source second
  ./netcat-transfer.sh send --host 192.168.1.10 --port 9000 \
    --path ./model-a.pkl ./model-b.pkl --compress zstd

  # Optional standalone connectivity test: destination first, source second
  ./netcat-transfer.sh test --listen --port 9000
  ./netcat-transfer.sh test --host 192.168.1.10 --port 9000

  # zsh expands this glob into multiple paths before invoking the script
  ./netcat-transfer.sh send --host 192.168.1.10 --port 9000 \
    --path ~/**/*.pkl --compress gzip

  # No compression: both sides must disable it
  ./netcat-transfer.sh recv --port 9000 --path /tmp/recv --no-decompress
  ./netcat-transfer.sh send --host 192.168.1.10 --port 9000 \
    --path ./large.bin --no-compress

The sender writes its actual compression mode into a stream header. A mismatch
is rejected before extraction. Both machines must use this script version.
EOF
}

MODE=""
HOST=""
PORT=""
TARGET_PATH=""
SEND_COMPRESSION="auto"
RECV_DECOMPRESSION="none"
CONNECT_TIMEOUT=5
TEST_LISTEN=0
SOURCE_PATHS=()

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "required command not found: $1" >&2
    exit 1
  }
}

is_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( 1 <= 10#$1 && 10#$1 <= 65535 ))
}

pick_codec() {
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
      echo "unsupported compression mode: $1" >&2
      exit 1
      ;;
  esac
}

compress_stream() {
  case "$1" in
    zstd)
      zstd -T0 -q -c
      ;;
    gzip)
      gzip -c
      ;;
    none)
      cat
      ;;
  esac
}

decompress_stream() {
  case "$1" in
    zstd)
      zstd -q -d -c
      ;;
    gzip)
      gzip -d -c
      ;;
    none)
      cat
      ;;
  esac
}

is_openbsd_nc() {
  nc -h 2>&1 | grep -qi 'openbsd'
}

nc_send() {
  if is_openbsd_nc; then
    nc -N "$HOST" "$PORT"
  else
    nc "$HOST" "$PORT"
  fi
}

nc_listen() {
  if is_openbsd_nc; then
    nc -l "$PORT"
  else
    nc -l -p "$PORT"
  fi
}

nc_test_send() {
  if is_openbsd_nc; then
    printf 'NETCAT_TRANSFER_CONNECTIVITY_TEST_V1\n' |
      nc -N -w "$CONNECT_TIMEOUT" "$HOST" "$PORT"
  else
    printf 'NETCAT_TRANSFER_CONNECTIVITY_TEST_V1\n' |
      nc -q 1 -w "$CONNECT_TIMEOUT" "$HOST" "$PORT"
  fi
}

send_stream() {
  printf 'NETCAT_TRANSFER_V1 compression=%s\n' "$SELECTED_COMPRESSION"
  (
    cd "$COMMON_PARENT"
    tar -cf - -- "${SOURCE_REL[@]}"
  ) | compress_stream "$SELECTED_COMPRESSION"
}

receive_stream() {
  local protocol compression_field extra sender_compression selected_decompression

  if ! IFS=' ' read -r protocol compression_field extra; then
    echo "connection probe received; resuming transfer listener"
    return 10
  fi

  if [[ "$protocol" == "NETCAT_TRANSFER_CONNECTIVITY_TEST_V1" && -z "$compression_field" && -z "$extra" ]]; then
    echo "connectivity test marker received; resuming transfer listener"
    return 10
  fi

  if [[ "$protocol" != "NETCAT_TRANSFER_V1" || "$compression_field" != compression=* || -n "$extra" ]]; then
    echo "transfer error: invalid or legacy stream header; nothing was extracted" >&2
    echo "both machines must use the current netcat-transfer.sh version" >&2
    return 2
  fi

  sender_compression="${compression_field#compression=}"
  case "$sender_compression" in
    zstd|gzip|none) ;;
    *)
      printf 'transfer error: sender reported unsupported compression: %s\n' \
        "$sender_compression" >&2
      return 2
      ;;
  esac

  if [[ "$RECV_DECOMPRESSION" != "auto" && "$RECV_DECOMPRESSION" != "$sender_compression" ]]; then
    printf 'compression mismatch: sender=%s, receiver=%s\n' \
      "$sender_compression" "$RECV_DECOMPRESSION" >&2
    printf 'nothing was extracted; rerun recv with --decompress %s or --decompress auto\n' \
      "$sender_compression" >&2
    return 2
  fi

  selected_decompression="$sender_compression"
  case "$selected_decompression" in
    zstd) require_command zstd ;;
    gzip) require_command gzip ;;
  esac

  echo "stream compression: $sender_compression"
  decompress_stream "$selected_decompression" | tar -xf - -C "$TARGET_PATH"
}

if (( $# == 0 )); then
  usage >&2
  exit 1
fi

case "$1" in
  -h|--help)
    usage
    exit 0
    ;;
  send|recv|test)
    MODE="$1"
    shift
    ;;
  *)
    echo "unknown mode: $1" >&2
    usage >&2
    exit 1
    ;;
esac

while (( $# > 0 )); do
  case "$1" in
    --host)
      [[ "$MODE" == "send" || "$MODE" == "test" ]] || {
        echo "--host is only valid in send or test mode" >&2
        exit 1
      }
      (( $# >= 2 )) || { echo "missing value for --host" >&2; exit 1; }
      HOST="$2"
      shift 2
      ;;
    --port)
      (( $# >= 2 )) || { echo "missing value for --port" >&2; exit 1; }
      PORT="$2"
      shift 2
      ;;
    --path)
      shift
      if [[ "$MODE" == "send" ]]; then
        paths_before=${#SOURCE_PATHS[@]}
        while (( $# > 0 )) && [[ "$1" != -* ]]; do
          SOURCE_PATHS+=("$1")
          shift
        done
        if (( ${#SOURCE_PATHS[@]} == paths_before )); then
          echo "--path requires at least one file or directory" >&2
          exit 1
        fi
      elif [[ "$MODE" == "recv" ]]; then
        (( $# >= 1 )) || { echo "missing value for --path" >&2; exit 1; }
        [[ -z "$TARGET_PATH" ]] || {
          echo "recv mode accepts only one destination path" >&2
          exit 1
        }
        TARGET_PATH="$1"
        shift
      else
        echo "--path is not valid in test mode" >&2
        exit 1
      fi
      ;;
    --timeout)
      [[ "$MODE" == "test" ]] || {
        echo "--timeout is only valid in test mode" >&2
        exit 1
      }
      (( $# >= 2 )) || { echo "missing value for --timeout" >&2; exit 1; }
      CONNECT_TIMEOUT="$2"
      shift 2
      ;;
    --listen)
      [[ "$MODE" == "test" ]] || {
        echo "--listen is only valid in test mode" >&2
        exit 1
      }
      TEST_LISTEN=1
      shift
      ;;
    --compress)
      [[ "$MODE" == "send" ]] || {
        echo "--compress is only valid in send mode" >&2
        exit 1
      }
      (( $# >= 2 )) || { echo "missing value for --compress" >&2; exit 1; }
      SEND_COMPRESSION="$2"
      shift 2
      ;;
    --no-compress)
      [[ "$MODE" == "send" ]] || {
        echo "--no-compress is only valid in send mode" >&2
        exit 1
      }
      SEND_COMPRESSION="none"
      shift
      ;;
    --decompress)
      [[ "$MODE" == "recv" ]] || {
        echo "--decompress is only valid in recv mode" >&2
        exit 1
      }
      (( $# >= 2 )) || { echo "missing value for --decompress" >&2; exit 1; }
      RECV_DECOMPRESSION="$2"
      shift 2
      ;;
    --no-decompress)
      [[ "$MODE" == "recv" ]] || {
        echo "--no-decompress is only valid in recv mode" >&2
        exit 1
      }
      RECV_DECOMPRESSION="none"
      shift
      ;;
    --compression)
      [[ "$MODE" != "test" ]] || {
        echo "--compression is not valid in test mode" >&2
        exit 1
      }
      (( $# >= 2 )) || { echo "missing value for --compression" >&2; exit 1; }
      if [[ "$MODE" == "send" ]]; then
        SEND_COMPRESSION="$2"
      else
        RECV_DECOMPRESSION="$2"
      fi
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      if [[ "$MODE" == "send" ]]; then
        SOURCE_PATHS+=("$@")
        set --
      else
        echo "unexpected positional arguments in recv mode" >&2
        exit 1
      fi
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

require_command tar
require_command nc

[[ -n "$PORT" ]] || {
  echo "--port is required for $MODE mode" >&2
  exit 1
}
is_port "$PORT" || {
  echo "invalid port: $PORT" >&2
  exit 1
}

if ! [[ "$CONNECT_TIMEOUT" =~ ^[1-9][0-9]*$ ]]; then
  echo "--timeout must be a positive integer" >&2
  exit 1
fi

case "$MODE" in
  send)
    [[ -n "$HOST" ]] || {
      echo "--host is required for send mode" >&2
      exit 1
    }
    (( ${#SOURCE_PATHS[@]} > 0 )) || {
      echo "--path is required for send mode" >&2
      exit 1
    }

    SOURCE_ABS=()
    for source_path in "${SOURCE_PATHS[@]}"; do
      [[ -e "$source_path" ]] || {
        echo "source path not found: $source_path" >&2
        exit 1
      }
      source_abs="$(cd "$(dirname "$source_path")" && pwd -P)/$(basename "$source_path")"
      SOURCE_ABS+=("$source_abs")
    done

    COMMON_PARENT="$(dirname "${SOURCE_ABS[0]}")"
    for source_abs in "${SOURCE_ABS[@]}"; do
      while [[ "$COMMON_PARENT" != "/" && "$source_abs" != "$COMMON_PARENT"/* ]]; do
        COMMON_PARENT="$(dirname "$COMMON_PARENT")"
      done
    done

    SOURCE_REL=()
    for source_abs in "${SOURCE_ABS[@]}"; do
      if [[ "$COMMON_PARENT" == "/" ]]; then
        SOURCE_REL+=("${source_abs#/}")
      else
        SOURCE_REL+=("${source_abs#"$COMMON_PARENT"/}")
      fi
    done

    SELECTED_COMPRESSION="$(pick_codec "$SEND_COMPRESSION")"
    case "$SELECTED_COMPRESSION" in
      zstd) require_command zstd ;;
      gzip) require_command gzip ;;
    esac

    echo "mode:            send"
    echo "common parent:   $COMMON_PARENT"
    echo "source count:    ${#SOURCE_REL[@]}"
    printf 'source:          %s\n' "${SOURCE_REL[@]}"
    echo "host:            $HOST"
    echo "port:            $PORT"
    echo "compression:     $SELECTED_COMPRESSION"

    if send_stream | nc_send; then
      echo "send completed: stream closed cleanly"
      echo "verify the receiver printed: receive completed successfully"
    else
      echo "send failed: connection or stream pipeline error" >&2
      exit 1
    fi
    ;;
  recv)
    [[ -n "$TARGET_PATH" ]] || {
      echo "--path is required for recv mode" >&2
      exit 1
    }

    mkdir -p "$TARGET_PATH"
    [[ -w "$TARGET_PATH" && -x "$TARGET_PATH" ]] || {
      echo "destination directory requires write and execute permissions: $TARGET_PATH" >&2
      exit 1
    }

    case "$RECV_DECOMPRESSION" in
      auto|zstd|gzip|none) ;;
      *)
        echo "unsupported decompression mode: $RECV_DECOMPRESSION" >&2
        exit 1
        ;;
    esac

    echo "mode:            recv"
    echo "destination:     $TARGET_PATH"
    echo "port:            $PORT"
    echo "expected mode:   $RECV_DECOMPRESSION"
    echo "status:          listening; start send on the source machine now"

    while true; do
      if nc_listen | receive_stream; then
        echo "receive completed successfully: $TARGET_PATH"
        break
      else
        receive_status=$?
        if (( receive_status == 10 )); then
          continue
        fi
        echo "receive failed: nothing was extracted successfully" >&2
        exit "$receive_status"
      fi
    done
    ;;
  test)
    if (( TEST_LISTEN == 1 )); then
      [[ -z "$HOST" ]] || {
        echo "--host and --listen cannot be used together" >&2
        exit 1
      }

      echo "mode:            test-listen"
      echo "port:            $PORT"
      echo "status:          waiting for connectivity test marker"

      test_message="$(nc_listen)"
      if [[ "$test_message" == "NETCAT_TRANSFER_CONNECTIVITY_TEST_V1" ]]; then
        echo "connectivity test passed: marker received on port $PORT"
      else
        echo "connectivity test failed: unexpected or empty test data" >&2
        exit 1
      fi
    else
      [[ -n "$HOST" ]] || {
        echo "--host is required unless test mode uses --listen" >&2
        exit 1
      }

      echo "mode:            test-send"
      echo "host:            $HOST"
      echo "port:            $PORT"
      echo "timeout:         ${CONNECT_TIMEOUT}s"

      if nc_test_send; then
        echo "connectivity test passed: marker sent to $HOST:$PORT"
      else
        echo "connectivity test failed: cannot send to $HOST:$PORT" >&2
        exit 1
      fi
    fi
    ;;
esac
