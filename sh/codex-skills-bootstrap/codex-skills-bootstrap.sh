#!/bin/sh
set -u

DEFAULT_APP="codex"
DEFAULT_SKILLS="find-skills karpathy-guidelines matplotlib planning-with-files ralph-loop readme-generator ui-ux-pro-max"

usage() {
  cat <<'EOF'
Usage:
  ./codex-skills-bootstrap.sh [options]

What it does:
  1. Ensures cc-switch is available
  2. Installs skills from skills.sh sources with npx skills add
  3. Imports unmanaged skills into cc-switch
  4. Enables the skills for the selected app

Options:
  --app APP           Target app, default: codex
                      Allowed: claude, codex, gemini, open-code, open-claw
  --skill NAME        Install only the selected skill set.
                      Repeat this option or use comma-separated values.
  --repo REPO         Add or enable an extra cc-switch skill repo first.
                      Example: owner/name or owner/name@branch
  --source SOURCE     Source repository for custom --skill values not in the built-in map.
                      Example: owner/name or https://github.com/owner/name
  --no-install-cc-switch
                      Do not auto-install cc-switch when it is missing
  --dry-run           Print commands without running them
  --list-defaults     Print default skills and exit
  -h, --help          Show this help

Examples:
  ./codex-skills-bootstrap.sh
  ./codex-skills-bootstrap.sh --app claude
  ./codex-skills-bootstrap.sh --skill matplotlib --skill readme-generator
EOF
}

APP="$DEFAULT_APP"
SELECTED_SKILLS=""
EXTRA_REPOS=""
DEFAULT_SOURCE=""
INSTALL_CC_SWITCH=1
DRY_RUN=0
RUN_ENV="unknown"
OS_NAME="unknown"

normalize_values() {
  printf '%s' "$1" | tr ',' ' '
}

print_defaults() {
  for skill in $DEFAULT_SKILLS; do
    echo "$skill"
  done
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --app)
      [ "$#" -ge 2 ] || { echo "missing value for --app" >&2; exit 1; }
      APP=$2
      shift 2
      ;;
    --skill)
      [ "$#" -ge 2 ] || { echo "missing value for --skill" >&2; exit 1; }
      SELECTED_SKILLS="$SELECTED_SKILLS $(normalize_values "$2")"
      shift 2
      ;;
    --repo)
      [ "$#" -ge 2 ] || { echo "missing value for --repo" >&2; exit 1; }
      EXTRA_REPOS="$EXTRA_REPOS $(normalize_values "$2")"
      shift 2
      ;;
    --source)
      [ "$#" -ge 2 ] || { echo "missing value for --source" >&2; exit 1; }
      DEFAULT_SOURCE=$2
      shift 2
      ;;
    --no-install-cc-switch)
      INSTALL_CC_SWITCH=0
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --list-defaults)
      print_defaults
      exit 0
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

case "$APP" in
  claude|codex|gemini|open-code|open-claw) ;;
  *)
    echo "--app must be one of: claude, codex, gemini, open-code, open-claw" >&2
    exit 1
    ;;
esac

run_cmd() {
  printf '+'
  for arg in "$@"; do
    printf ' %s' "$arg"
  done
  echo

  if [ "$DRY_RUN" -eq 1 ]; then
    return 0
  fi

  "$@"
}

skill_source() {
  case "$1" in
    find-skills) echo "https://github.com/vercel-labs/skills" ;;
    karpathy-guidelines) echo "https://github.com/forrestchang/andrej-karpathy-skills" ;;
    matplotlib|planning-with-files|ui-ux-pro-max) echo "https://github.com/davila7/claude-code-templates" ;;
    ralph-loop) echo "https://github.com/andrelandgraf/fullstackrecipes" ;;
    readme-generator) echo "https://github.com/patricio0312rev/skills" ;;
    *)
      if [ -n "$DEFAULT_SOURCE" ]; then
        echo "$DEFAULT_SOURCE"
      else
        echo "no source configured for skill: $1. pass --source owner/repo or use a built-in skill" >&2
        return 1
      fi
      ;;
  esac
}

print_windows_cc_switch_install() {
  cat <<'EOF'
cc-switch is not available.

This looks like a Windows shell. Install cc-switch from PowerShell first:

  $downloadUrl = "https://github.com/SaladDay/cc-switch-cli/releases/latest/download/cc-switch-cli-windows-x64.zip"
  $zipPath = "$env:TEMP\cc-switch-cli.zip"
  $extractPath = "$env:TEMP\cc-switch-extract"
  Invoke-WebRequest -Uri $downloadUrl -OutFile $zipPath
  Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force
  $binPath = "$env:LOCALAPPDATA\Microsoft\WindowsApps"
  if (!(Test-Path $binPath)) { New-Item -ItemType Directory -Path $binPath -Force }
  Copy-Item "$extractPath\cc-switch.exe" -Destination $binPath -Force
  cc-switch --version

If GitHub cannot be reached directly, configure a proxy in PowerShell first:

  $env:HTTPS_PROXY = "http://127.0.0.1:7890"
  $env:HTTP_PROXY = "http://127.0.0.1:7890"
EOF
}

detect_environment() {
  OS_NAME="$(uname -s 2>/dev/null || echo unknown)"

  case "$OS_NAME" in
    Linux*) RUN_ENV="linux" ;;
    Darwin*) RUN_ENV="unsupported-macos" ;;
    MINGW*|MSYS*|CYGWIN*) RUN_ENV="windows-shell" ;;
    *) RUN_ENV="unknown" ;;
  esac
}

install_cc_switch() {
  case "$RUN_ENV" in
    windows-shell)
      print_windows_cc_switch_install >&2
      exit 1
      ;;
    unsupported-macos)
      echo "macOS is not supported by this installer yet" >&2
      exit 1
      ;;
    linux|unknown)
      ;;
  esac

  command -v curl >/dev/null 2>&1 || {
    echo "curl is required to install cc-switch automatically" >&2
    exit 1
  }

  command -v bash >/dev/null 2>&1 || {
    echo "bash is required to run the cc-switch installer" >&2
    exit 1
  }

  echo "cc-switch is not found. installing with official release installer..."
  echo "if GitHub is not reachable, set HTTPS_PROXY/HTTP_PROXY and rerun this script."
  run_cmd sh -c 'curl -fsSL https://github.com/SaladDay/cc-switch-cli/releases/latest/download/install.sh | bash'

  PATH="$HOME/.local/bin:$HOME/bin:/usr/local/bin:$PATH"
  export PATH
  hash -r 2>/dev/null || true
}

ensure_cc_switch() {
  echo "detected environment: $RUN_ENV ($OS_NAME)"

  if command -v cc-switch >/dev/null 2>&1; then
    echo "cc-switch: found"
    return 0
  fi

  echo "cc-switch: not found"

  if [ "$INSTALL_CC_SWITCH" -eq 0 ]; then
    echo "cc-switch is required but not found" >&2
    exit 1
  fi

  install_cc_switch

  if [ "$DRY_RUN" -eq 1 ]; then
    echo "dry-run: assuming cc-switch would be available after installation"
    return 0
  fi

  if ! command -v cc-switch >/dev/null 2>&1; then
    echo "cc-switch is still not available after installer finished" >&2
    echo "open a new shell or add the cc-switch install directory to PATH, then rerun this script" >&2
    exit 1
  fi
}

ensure_npx() {
  if command -v npx >/dev/null 2>&1; then
    echo "npx: found"
    return 0
  fi

  echo "npx is required to install skills from skills.sh sources" >&2
  echo "install Node.js first, then rerun this script" >&2
  exit 1
}

install_repo() {
  repo=$1

  if run_cmd cc-switch skills repos add "$repo"; then
    return 0
  fi

  echo "repo add failed, trying to enable existing repo: $repo" >&2
  run_cmd cc-switch skills repos enable "$repo"
}

install_and_enable_skill() {
  skill=$1

  if [ "$skill" = "huluhuluu-blog-style" ]; then
    echo "skip local style skill: $skill"
    return 0
  fi

  echo
  echo "skill: $skill"
  source=$(skill_source "$skill") || return 1

  run_cmd npx skills add "$source" --global --copy --agent "$APP" --skill "$skill" -y
  run_cmd cc-switch skills scan-unmanaged --app "$APP"
  run_cmd cc-switch skills import-from-apps "$skill"
  run_cmd cc-switch skills enable --app "$APP" "$skill"
}

detect_environment
ensure_cc_switch
ensure_npx

if [ -n "$SELECTED_SKILLS" ]; then
  REQUESTED_SKILLS="$SELECTED_SKILLS"
else
  REQUESTED_SKILLS="$DEFAULT_SKILLS"
fi

if [ -z "$REQUESTED_SKILLS" ]; then
  echo "no skills selected" >&2
  exit 1
fi

echo "target app: $APP"
echo

FAILED_REPOS=""

for repo in $EXTRA_REPOS; do
  if ! install_repo "$repo"; then
    FAILED_REPOS="$FAILED_REPOS $repo"
  fi
done

FAILED_SKILLS=""
SEEN_SKILLS=""

for skill in $REQUESTED_SKILLS; do
  [ -n "$skill" ] || continue

  case " $SEEN_SKILLS " in
    *" $skill "*) continue ;;
  esac
  SEEN_SKILLS="$SEEN_SKILLS $skill"

  if ! install_and_enable_skill "$skill"; then
    FAILED_SKILLS="$FAILED_SKILLS $skill"
  fi
done

echo
run_cmd cc-switch skills sync --app "$APP"

echo
echo "current skills:"
run_cmd cc-switch skills list

if [ -n "$FAILED_SKILLS" ]; then
  echo
  if [ -n "$FAILED_REPOS" ]; then
    echo "failed repos:$FAILED_REPOS" >&2
  fi
  echo "failed skills:$FAILED_SKILLS" >&2
  echo "check network/proxy and enabled skill repositories, then rerun this script" >&2
  exit 1
fi

if [ -n "$FAILED_REPOS" ]; then
  echo
  echo "failed repos:$FAILED_REPOS" >&2
  echo "check network/proxy and repository names, then rerun this script" >&2
  exit 1
fi

echo
echo "done"
