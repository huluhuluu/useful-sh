#!/bin/sh
set -eu

usage() {
  cat <<'EOF'
Usage:
  ./android-clangd-setup.sh [options]

What it does:
  1. Detects Android NDK from common environment variables
  2. Creates or updates .vscode/settings.json in the target project
  3. Creates or updates .clangd in the target project

Options:
  --path DIR         Target project directory (default: current directory)
  --ndk-path DIR     Override Android NDK directory instead of auto-detect
  -h, --help         Show this help

Examples:
  ./android-clangd-setup.sh
  ./android-clangd-setup.sh --path /workspace/zjh/code/my-project
  ./android-clangd-setup.sh --ndk-path /opt/android-ndk-r29
EOF
}

TARGET_DIR="."
NDK_ROOT_OVERRIDE=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --path)
      [ "$#" -ge 2 ] || { echo "missing value for --path" >&2; exit 1; }
      TARGET_DIR=$2
      shift 2
      ;;
    --ndk-path)
      [ "$#" -ge 2 ] || { echo "missing value for --ndk-path" >&2; exit 1; }
      NDK_ROOT_OVERRIDE=$2
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

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required" >&2
  exit 1
fi

if [ ! -d "$TARGET_DIR" ]; then
  echo "target directory not found: $TARGET_DIR" >&2
  exit 1
fi

TARGET_DIR="$(cd "$TARGET_DIR" && pwd)"

if [ ! -w "$TARGET_DIR" ]; then
  echo "target directory is not writable: $TARGET_DIR" >&2
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
  echo "unable to detect Android NDK path from environment variables" >&2
  echo "checked: ANDROID_NDK, ANDROID_NDK_ROOT, ANDROID_NDK_HOME, NDK_ROOT, NDK_HOME, ANDROID_SDK_ROOT, ANDROID_HOME" >&2
  echo "you can also pass --ndk-path /path/to/android-ndk" >&2
  exit 1
}

[ -d "$NDK_ROOT" ] || {
  echo "android NDK directory not found: $NDK_ROOT" >&2
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
  echo "expected a file matching: $PREBUILT_ROOT/*/bin/clangd" >&2
  exit 1
}

PREBUILT_BIN_DIR="$(dirname "$CLANGD_BIN_FILE")"
CLANGD_PATH="$PREBUILT_BIN_DIR/clangd"
QUERY_DRIVER="$PREBUILT_BIN_DIR/clang*"
CLANG_BIN="$PREBUILT_BIN_DIR/clang"
VSCODE_DIR="$TARGET_DIR/.vscode"
SETTINGS_FILE="$VSCODE_DIR/settings.json"
CLANGD_FILE="$TARGET_DIR/.clangd"
COMPILE_COMMANDS_FILE="$TARGET_DIR/build/compile_commands.json"

[ -x "$CLANGD_PATH" ] || {
  echo "clangd is not executable: $CLANGD_PATH" >&2
  exit 1
}

[ -x "$CLANG_BIN" ] || {
  echo "clang is not executable: $CLANG_BIN" >&2
  exit 1
}

mkdir -p "$VSCODE_DIR"

[ -w "$VSCODE_DIR" ] || {
  echo "directory is not writable: $VSCODE_DIR" >&2
  exit 1
}

if [ -e "$SETTINGS_FILE" ] && [ ! -w "$SETTINGS_FILE" ]; then
  echo "settings file is not writable: $SETTINGS_FILE" >&2
  exit 1
fi

if [ -e "$CLANGD_FILE" ] && [ ! -w "$CLANGD_FILE" ]; then
  echo "clangd file is not writable: $CLANGD_FILE" >&2
  exit 1
fi

python3 - "$SETTINGS_FILE" "$CLANGD_FILE" "$CLANGD_PATH" "$QUERY_DRIVER" <<'PY'
import json
import sys
from pathlib import Path

settings_path = Path(sys.argv[1])
clangd_path = Path(sys.argv[2])
clangd_bin = sys.argv[3]
query_driver = sys.argv[4]


def strip_jsonc(text: str) -> str:
    result = []
    index = 0
    in_string = False
    in_line_comment = False
    in_block_comment = False
    escape = False

    while index < len(text):
        char = text[index]
        nxt = text[index + 1] if index + 1 < len(text) else ""

        if in_line_comment:
            if char == "\n":
                in_line_comment = False
                result.append(char)
            index += 1
            continue

        if in_block_comment:
            if char == "*" and nxt == "/":
                in_block_comment = False
                index += 2
            else:
                index += 1
            continue

        if in_string:
            result.append(char)
            if escape:
                escape = False
            elif char == "\\":
                escape = True
            elif char == '"':
                in_string = False
            index += 1
            continue

        if char == "/" and nxt == "/":
            in_line_comment = True
            index += 2
            continue

        if char == "/" and nxt == "*":
            in_block_comment = True
            index += 2
            continue

        result.append(char)
        if char == '"':
            in_string = True
        index += 1

    return "".join(result)


def load_settings(path: Path) -> dict:
    if not path.exists():
        return {}
    raw = path.read_text(encoding="utf-8")
    stripped = strip_jsonc(raw).strip()
    if not stripped:
        return {}
    data = json.loads(stripped)
    if not isinstance(data, dict):
        raise SystemExit(f"expected JSON object in {path}")
    return data


def dump_settings(path: Path, data: dict) -> None:
    path.write_text(
        json.dumps(data, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )


def replace_top_level_section(lines: list[str], section_name: str, new_block: list[str]) -> list[str]:
    start = None
    end = None

    for idx, line in enumerate(lines):
        if line.startswith(f"{section_name}:"):
            start = idx
            break

    if start is not None:
        end = len(lines)
        for idx in range(start + 1, len(lines)):
            line = lines[idx]
            if line and not line.startswith((" ", "\t", "#")):
                end = idx
                break
        del lines[start:end]

    while lines and lines[-1] == "":
        lines.pop()

    if lines:
        lines.append("")
    lines.extend(new_block)
    return lines


settings = load_settings(settings_path)
settings["clangd.arguments"] = [
    "-j=16",
    "--header-insertion=never",
    "--compile-commands-dir=${workspaceFolder}/build",
    f"--query-driver={query_driver}",
    "--clang-tidy",
]
settings["clangd.path"] = clangd_bin
dump_settings(settings_path, settings)

compile_flags_block = [
    "CompileFlags:",
    "  CompilationDatabase: build",
]

diagnostics_block = [
    "Diagnostics:",
    "  UnusedIncludes: None",
    "  Suppress:",
    '    - "macro_is_not_used"',
    '    - "pp_including_mainfile_in_preamble"',
    '    - "misleading-indentation"',
]

clangd_lines: list[str]
if clangd_path.exists():
    clangd_lines = clangd_path.read_text(encoding="utf-8").splitlines()
else:
    clangd_lines = []

clangd_lines = replace_top_level_section(clangd_lines, "CompileFlags", compile_flags_block)
clangd_lines = replace_top_level_section(clangd_lines, "Diagnostics", diagnostics_block)

content = "\n".join(clangd_lines).rstrip() + "\n"
clangd_path.write_text(content, encoding="utf-8")
PY

echo "target project: $TARGET_DIR"
echo "ndk root:       $NDK_ROOT"
echo "clangd path:    $CLANGD_PATH"
echo "settings:       $SETTINGS_FILE"
echo "clangd file:    $CLANGD_FILE"

if [ -f "$COMPILE_COMMANDS_FILE" ]; then
  echo "compile db:     $COMPILE_COMMANDS_FILE"
else
  echo "warning: compile_commands.json not found: $COMPILE_COMMANDS_FILE" >&2
  echo "warning: generate it with CMake option -DCMAKE_EXPORT_COMPILE_COMMANDS=ON" >&2
fi
