#!/bin/sh
set -eu

usage() {
  cat <<'EOF'
Usage:
  ./nvim-clangd-setup.sh [options]

Creates or updates the clangd project configuration at DIR/.clangd.

Options:
  --path DIR         Target project directory (default: current directory)
  --ndk-path DIR     Override Android NDK directory instead of auto-detect
  --compdb-dir DIR   Compilation database directory, relative to the project
                     root or absolute (default: build)
  --compile-commands-dir DIR
                     Alias for --compdb-dir
  -h, --help         Show this help
EOF
}

PROJECT_DIR="."
NDK_ROOT_OVERRIDE=""
COMPILE_COMMANDS_DIR="build"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --path)
      [ "$#" -ge 2 ] || { echo "missing value for $1" >&2; exit 1; }
      PROJECT_DIR=$2
      shift 2
      ;;
    --ndk-path)
      [ "$#" -ge 2 ] || { echo "missing value for --ndk-path" >&2; exit 1; }
      NDK_ROOT_OVERRIDE=$2
      shift 2
      ;;
    --compdb-dir|--compile-commands-dir)
      [ "$#" -ge 2 ] || { echo "missing value for $1" >&2; exit 1; }
      COMPILE_COMMANDS_DIR=$2
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

[ -n "$COMPILE_COMMANDS_DIR" ] || {
  echo "compile commands directory must not be empty" >&2
  exit 1
}

[ -d "$PROJECT_DIR" ] || {
  echo "target project directory not found: $PROJECT_DIR" >&2
  exit 1
}

PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"
[ -w "$PROJECT_DIR" ] || {
  echo "target project directory is not writable: $PROJECT_DIR" >&2
  exit 1
}

print_install_hint() {
  case "$1" in
    python3) package="python3" ;;
    find) package="findutils" ;;
    sort) package="coreutils" ;;
    *) return ;;
  esac
  printf 'install on Ubuntu/Debian: sudo apt install %s\n' "$package" >&2
  [ "$1" != "python3" ] || echo "install on macOS: brew install python" >&2
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "required command not found: $1" >&2
    print_install_hint "$1"
    exit 1
  }
}

for command_name in python3 find sort; do
  require_command "$command_name"
done

if ! python3 -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 9) else 1)'; then
  echo "Python 3.9 or newer is required" >&2
  print_install_hint python3
  exit 1
fi

detect_ndk_root() {
  for var_name in ANDROID_NDK ANDROID_NDK_ROOT ANDROID_NDK_HOME NDK_ROOT NDK_HOME; do
    eval "value=\${$var_name-}"
    if [ -n "${value}" ] && [ -d "$value" ]; then
      printf '%s\n' "$value"
      return 0
    fi
  done

  for sdk_var in ANDROID_SDK_ROOT ANDROID_HOME; do
    eval "sdk_root=\${$sdk_var-}"
    if [ -n "${sdk_root}" ] && [ -d "$sdk_root/ndk" ]; then
      candidate="$(find "$sdk_root/ndk" -mindepth 1 -maxdepth 1 -type d | sort | tail -n 1)"
      if [ -n "${candidate}" ] && [ -d "$candidate" ]; then
        printf '%s\n' "$candidate"
        return 0
      fi
    fi
    if [ -n "${sdk_root}" ] && [ -d "$sdk_root/ndk-bundle" ]; then
      printf '%s\n' "$sdk_root/ndk-bundle"
      return 0
    fi
  done

  return 1
}

if [ -n "$NDK_ROOT_OVERRIDE" ]; then
  NDK_ROOT=$NDK_ROOT_OVERRIDE
else
  NDK_ROOT="$(detect_ndk_root || true)"
fi

[ -n "$NDK_ROOT" ] || {
  echo "unable to detect Android NDK path; pass --ndk-path DIR" >&2
  exit 1
}

PREBUILT_ROOT="$NDK_ROOT/toolchains/llvm/prebuilt"
[ -d "$PREBUILT_ROOT" ] || {
  echo "invalid Android NDK layout: missing directory $PREBUILT_ROOT" >&2
  exit 1
}

CLANGD_BIN_FILE="$(find "$PREBUILT_ROOT" -type f -path '*/bin/clangd' 2>/dev/null | sort | head -n 1)"
[ -n "$CLANGD_BIN_FILE" ] || {
  echo "clangd not found under NDK: $NDK_ROOT" >&2
  exit 1
}

PREBUILT_BIN_DIR="$(dirname "$CLANGD_BIN_FILE")"
CLANGD_PATH="$PREBUILT_BIN_DIR/clangd"
QUERY_DRIVER="$PREBUILT_BIN_DIR/clang*"
PROJECT_CONFIG_FILE="$PROJECT_DIR/.clangd"

[ -x "$CLANGD_PATH" ] || {
  echo "clangd is not executable: $CLANGD_PATH" >&2
  exit 1
}

if [ -e "$PROJECT_CONFIG_FILE" ] && [ ! -w "$PROJECT_CONFIG_FILE" ]; then
  echo "project clangd file is not writable: $PROJECT_CONFIG_FILE" >&2
  exit 1
fi

case "$COMPILE_COMMANDS_DIR" in
  /*) COMPILE_COMMANDS_FILE="$COMPILE_COMMANDS_DIR/compile_commands.json" ;;
  *) COMPILE_COMMANDS_FILE="$PROJECT_DIR/$COMPILE_COMMANDS_DIR/compile_commands.json" ;;
esac

python3 - "$PROJECT_CONFIG_FILE" "$COMPILE_COMMANDS_DIR" <<'PY'
import sys
from pathlib import Path

project_path = Path(sys.argv[1])
compile_commands_dir = sys.argv[2]


def replace_top_level_section(lines: list[str], section_name: str, new_block: list[str]) -> list[str]:
    start = None
    end = None
    for index, line in enumerate(lines):
        if line.startswith(f"{section_name}:"):
            start = index
            break

    if start is not None:
        end = len(lines)
        for index in range(start + 1, len(lines)):
            line = lines[index]
            if line and not line.startswith((" ", "\t", "#")):
                end = index
                break
        del lines[start:end]

    while lines and lines[-1] == "":
        lines.pop()
    if lines:
        lines.append("")
    lines.extend(new_block)
    return lines


if project_path.exists():
    lines = project_path.read_text(encoding="utf-8").splitlines()
else:
    lines = []

lines = replace_top_level_section(
    lines,
    "CompileFlags",
    ["CompileFlags:", f"  CompilationDatabase: {compile_commands_dir}"],
)
project_path.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")
PY

echo "ndk root:       $NDK_ROOT"
echo "clangd path:    $CLANGD_PATH"
echo "clangd config:  $PROJECT_CONFIG_FILE"
echo "compile db dir: $COMPILE_COMMANDS_DIR"

if [ -f "$COMPILE_COMMANDS_FILE" ]; then
  echo "compile db:     $COMPILE_COMMANDS_FILE"
else
  echo "warning: compile_commands.json not found: $COMPILE_COMMANDS_FILE" >&2
  echo "warning: generate it with CMake option -DCMAKE_EXPORT_COMPILE_COMMANDS=ON" >&2
fi
