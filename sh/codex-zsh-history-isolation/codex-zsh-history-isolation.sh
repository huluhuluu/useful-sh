#!/bin/sh
set -eu

usage() {
  cat <<'EOF'
Usage:
  ./codex-zsh-history-isolation.sh [options]

What it does:
  1. Checks or updates Codex shell isolation settings in ~/.codex/config.toml
  2. Redirects shell history writes into a separate HISTFILE
  3. Creates a minimal ZDOTDIR with its own .zshenv
  4. Controls Codex's own history.jsonl persistence mode

Options:
  --codex-dir DIR                    Override Codex home directory (default: ~/.codex)
  --histfile FILE                    Override isolated shell history file path
  --codex-shell-histfile FILE        Alias of --histfile
  --zdotdir DIR                      Override isolated zsh config directory
  --codex-history-persistence MODE   Set [history].persistence (default: none)
                                     Allowed: none, save-all
  --check                            Only detect and print current state, do not write files
  -h, --help                         Show this help

Examples:
  ./codex-zsh-history-isolation.sh
  ./codex-zsh-history-isolation.sh --check
  ./codex-zsh-history-isolation.sh --codex-history-persistence save-all
  ./codex-zsh-history-isolation.sh --codex-dir /tmp/codex-test
EOF
}

CODEX_DIR="${HOME}/.codex"
HISTFILE_PATH=""
ZDOTDIR_PATH=""
CODEX_HISTORY_PERSISTENCE="none"
CHECK_ONLY=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --codex-dir)
      [ "$#" -ge 2 ] || { echo "missing value for --codex-dir" >&2; exit 1; }
      CODEX_DIR=$2
      shift 2
      ;;
    --histfile|--codex-shell-histfile)
      [ "$#" -ge 2 ] || { echo "missing value for $1" >&2; exit 1; }
      HISTFILE_PATH=$2
      shift 2
      ;;
    --zdotdir)
      [ "$#" -ge 2 ] || { echo "missing value for --zdotdir" >&2; exit 1; }
      ZDOTDIR_PATH=$2
      shift 2
      ;;
    --codex-history-persistence)
      [ "$#" -ge 2 ] || { echo "missing value for --codex-history-persistence" >&2; exit 1; }
      CODEX_HISTORY_PERSISTENCE=$2
      shift 2
      ;;
    --check)
      CHECK_ONLY=1
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

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required" >&2
  exit 1
fi

case "$CODEX_DIR" in
  /*) ;;
  *)
    echo "--codex-dir must be an absolute path" >&2
    exit 1
    ;;
esac

if [ -z "$HISTFILE_PATH" ]; then
  HISTFILE_PATH="${CODEX_DIR}/shell_history"
fi

if [ -z "$ZDOTDIR_PATH" ]; then
  ZDOTDIR_PATH="${CODEX_DIR}/zsh"
fi

case "$HISTFILE_PATH" in
  /*) ;;
  *)
    echo "--histfile must be an absolute path" >&2
    exit 1
    ;;
esac

case "$ZDOTDIR_PATH" in
  /*) ;;
  *)
    echo "--zdotdir must be an absolute path" >&2
    exit 1
    ;;
esac

case "$CODEX_HISTORY_PERSISTENCE" in
  none|save-all) ;;
  *)
    echo "--codex-history-persistence must be one of: none, save-all" >&2
    exit 1
    ;;
esac

CONFIG_FILE="${CODEX_DIR}/config.toml"
BACKUP_DIR="${CODEX_DIR}/backups"
TIMESTAMP="$(date -u +"%Y%m%dT%H%M%SZ")"
ZSHENV_FILE="${ZDOTDIR_PATH}/.zshenv"
CODEX_HISTORY_FILE="${CODEX_DIR}/history.jsonl"

CHECK_OUTPUT="$(python3 - "$CONFIG_FILE" "$HISTFILE_PATH" "$ZDOTDIR_PATH" "$ZSHENV_FILE" "$CODEX_HISTORY_PERSISTENCE" <<'PY'
import sys
from pathlib import Path

config_path = Path(sys.argv[1])
histfile = sys.argv[2]
zdotdir = sys.argv[3]
zshenv_path = Path(sys.argv[4])
history_persistence = sys.argv[5]

try:
    import tomllib
except ModuleNotFoundError as exc:
    raise SystemExit("python3 with tomllib support is required") from exc


def print_line(key, value):
    print(f"{key}={value}")


data = {}
if config_path.exists():
    with config_path.open("rb") as handle:
        data = tomllib.load(handle)

history_table = data.get("history")
shell_env = data.get("shell_environment_policy")
shell_env_set = shell_env.get("set") if isinstance(shell_env, dict) else None
zshenv_expected = f"HISTFILE={histfile}\n"
zshenv_ok = zshenv_path.exists() and zshenv_path.read_text(encoding="utf-8") == zshenv_expected

print_line("CONFIG_EXISTS", "1" if config_path.exists() else "0")
print_line("ALLOW_LOGIN_OK", "1" if data.get("allow_login_shell") is False else "0")
print_line("HISTORY_OK", "1" if isinstance(history_table, dict) and history_table.get("persistence") == history_persistence else "0")
print_line("SHELL_ENV_OK", "1" if isinstance(shell_env, dict) and shell_env.get("experimental_use_profile") is False else "0")
print_line("SET_OK", "1" if isinstance(shell_env_set, dict) and shell_env_set.get("HISTFILE") == histfile and shell_env_set.get("ZDOTDIR") == zdotdir else "0")
print_line("ZSHENV_OK", "1" if zshenv_ok else "0")
print_line("CURRENT_HISTORY_PERSISTENCE", history_table.get("persistence", "") if isinstance(history_table, dict) else "")
PY
)"

CONFIG_EXISTS=0
ALLOW_LOGIN_OK=0
HISTORY_OK=0
SHELL_ENV_OK=0
SET_OK=0
ZSHENV_OK=0
CURRENT_HISTORY_PERSISTENCE=""

OLD_IFS=$IFS
IFS='
'
for line in $CHECK_OUTPUT; do
  case "$line" in
    CONFIG_EXISTS=*) CONFIG_EXISTS=${line#*=} ;;
    ALLOW_LOGIN_OK=*) ALLOW_LOGIN_OK=${line#*=} ;;
    HISTORY_OK=*) HISTORY_OK=${line#*=} ;;
    SHELL_ENV_OK=*) SHELL_ENV_OK=${line#*=} ;;
    SET_OK=*) SET_OK=${line#*=} ;;
    ZSHENV_OK=*) ZSHENV_OK=${line#*=} ;;
    CURRENT_HISTORY_PERSISTENCE=*) CURRENT_HISTORY_PERSISTENCE=${line#*=} ;;
  esac
done
IFS=$OLD_IFS

print_status() {
  echo "codex files:"
  echo "  config:             $CONFIG_FILE"
  echo "  codex history:      $CODEX_HISTORY_FILE"
  echo "  shell history:      $HISTFILE_PATH"
  echo "  isolated ZDOTDIR:   $ZDOTDIR_PATH"
  echo "  isolated .zshenv:   $ZSHENV_FILE"
  echo
  echo "requested state:"
  echo "  allow_login_shell:                           false"
  echo "  history.persistence:                         $CODEX_HISTORY_PERSISTENCE"
  echo "  shell_environment_policy.experimental_use_profile: false"
  echo "  shell_environment_policy.set.HISTFILE:      $HISTFILE_PATH"
  echo "  shell_environment_policy.set.ZDOTDIR:       $ZDOTDIR_PATH"
  echo
  echo "check result:"
  echo "  allow_login_shell ok:                       $ALLOW_LOGIN_OK"
  echo "  history.persistence ok:                     $HISTORY_OK"
  echo "  shell_environment_policy ok:                $SHELL_ENV_OK"
  echo "  shell_environment_policy.set ok:            $SET_OK"
  echo "  isolated .zshenv ok:                        $ZSHENV_OK"
  if [ -n "$CURRENT_HISTORY_PERSISTENCE" ]; then
    echo "  current history.persistence:                $CURRENT_HISTORY_PERSISTENCE"
  fi
}

if [ "$ALLOW_LOGIN_OK" -eq 1 ] &&
   [ "$HISTORY_OK" -eq 1 ] &&
   [ "$SHELL_ENV_OK" -eq 1 ] &&
   [ "$SET_OK" -eq 1 ] &&
   [ "$ZSHENV_OK" -eq 1 ]; then
  echo "configuration already matches the requested setup."
  print_status
  exit 0
fi

if [ "$CHECK_ONLY" -eq 1 ]; then
  echo "configuration does not fully match the requested setup."
  print_status
  exit 1
fi

mkdir -p "$CODEX_DIR" "$BACKUP_DIR" "$ZDOTDIR_PATH"

if [ "$CONFIG_EXISTS" -eq 1 ]; then
  BACKUP_FILE="${BACKUP_DIR}/config.toml.${TIMESTAMP}.bak"
  cp "$CONFIG_FILE" "$BACKUP_FILE"
  echo "backed up existing config to $BACKUP_FILE"
fi

cat >"$ZSHENV_FILE" <<EOF
HISTFILE=${HISTFILE_PATH}
EOF

python3 - "$CONFIG_FILE" "$HISTFILE_PATH" "$ZDOTDIR_PATH" "$CODEX_HISTORY_PERSISTENCE" <<'PY'
import json
import re
import sys
from pathlib import Path

config_path = Path(sys.argv[1])
histfile = sys.argv[2]
zdotdir = sys.argv[3]
history_persistence = sys.argv[4]

try:
    import tomllib
except ModuleNotFoundError as exc:
    raise SystemExit("python3 with tomllib support is required") from exc


def format_scalar(value):
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, str):
        return json.dumps(value)
    if isinstance(value, int):
        return str(value)
    if isinstance(value, float):
        return repr(value)
    raise TypeError(f"unsupported scalar type: {type(value).__name__}")


def find_section_bounds(lines, section_name):
    header = f"[{section_name}]"
    for index, line in enumerate(lines):
        if line.strip() == header:
            end = len(lines)
            for cursor in range(index + 1, len(lines)):
                stripped = lines[cursor].strip()
                if stripped.startswith("[") and stripped.endswith("]"):
                    end = cursor
                    break
            return index, end
    return None


def set_root_key(lines, key, value):
    rendered = f"{key} = {format_scalar(value)}"
    key_pattern = re.compile(rf"^\s*{re.escape(key)}\s*=")

    root_end = len(lines)
    for index, line in enumerate(lines):
        stripped = line.strip()
        if stripped.startswith("[") and stripped.endswith("]"):
            root_end = index
            break

    for index in range(root_end):
        line = lines[index]
        if line.lstrip().startswith("#"):
            continue
        if key_pattern.match(line):
            lines[index] = rendered
            return

    insert_at = root_end
    if insert_at > 0 and lines[insert_at - 1].strip() != "":
      lines.insert(insert_at, "")
      insert_at += 1
    lines.insert(insert_at, rendered)


def set_table_key(lines, section_name, key, value):
    rendered = f"{key} = {format_scalar(value)}"
    key_pattern = re.compile(rf"^\s*{re.escape(key)}\s*=")
    bounds = find_section_bounds(lines, section_name)

    if bounds is None:
        if lines and lines[-1].strip() != "":
            lines.append("")
        lines.append(f"[{section_name}]")
        lines.append(rendered)
        return

    start, end = bounds
    for index in range(start + 1, end):
        line = lines[index]
        if line.lstrip().startswith("#"):
            continue
        if key_pattern.match(line):
            lines[index] = rendered
            return

    insert_at = end
    while insert_at > start + 1 and lines[insert_at - 1].strip() == "":
        insert_at -= 1
    lines.insert(insert_at, rendered)


raw_text = ""
if config_path.exists():
    raw_text = config_path.read_text(encoding="utf-8")
    with config_path.open("rb") as handle:
        tomllib.load(handle)

lines = raw_text.splitlines()
set_root_key(lines, "allow_login_shell", False)
set_table_key(lines, "history", "persistence", history_persistence)
set_table_key(lines, "shell_environment_policy", "experimental_use_profile", False)
set_table_key(lines, "shell_environment_policy.set", "HISTFILE", histfile)
set_table_key(lines, "shell_environment_policy.set", "ZDOTDIR", zdotdir)

content = "\n".join(lines).rstrip() + "\n"
tomllib.loads(content)
config_path.write_text(content, encoding="utf-8")
PY

echo
echo "configuration written to $CONFIG_FILE"
print_status
echo
echo "how this works:"
echo "  Codex is configured to avoid login/profile shell behavior where possible."
echo "  If a shell subprocess still writes history, it writes into the isolated HISTFILE instead of your main zsh history."
echo "  ZDOTDIR points zsh at a minimal config directory so it does not inherit your normal interactive setup."
echo "  Codex's own history.jsonl retention is controlled by [history].persistence."
echo
echo "next steps:"
echo "  1. fully exit Codex"
echo "  2. start Codex again"
echo "  3. run this through Codex:"
echo "     echo \"hello this is a codex test\""
echo "  4. verify it is absent from your main zsh history:"
echo "     grep -n 'hello this is a codex test' \"/root/.zsh_history\""
