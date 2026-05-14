#!/bin/sh
set -eu

usage() {
  cat <<'EOF'
Usage:
  ./ubuntu-config.sh [options]

What it does:
  1. Checks the current system and package manager availability
  2. Runs apt-get update
  3. Installs selected Ubuntu package groups
  4. Configures tmux, zsh, oh-my-zsh, zsh plugins, zoxide, and fzf
  5. Optionally installs Miniforge and configures conda channels
  6. Optionally appends CUDA environment variables into ~/.zshrc

Options:
  --install-base         Install common base packages
  --install-dev          Install common development packages
  --install-shell        Install shell packages and configure zsh shell tools
  --install-miniforge    Install Miniforge and configure conda
  --skip-shell-config    Skip shell configuration after --install-shell
  --skip-update          Skip apt-get update
  --cuda-home DIR        Append CUDA PATH and LD_LIBRARY_PATH exports for DIR
  --miniforge-prefix DIR Override Miniforge install prefix (default: ~/miniforge3)
  --miniforge-url URL    Override Miniforge installer URL
  --all                  Enable base, dev, shell, and Miniforge setup
  --check                Print planned actions only
  -h, --help             Show this help

Examples:
  ./ubuntu-config.sh --check --all
  ./ubuntu-config.sh --install-base --install-dev --install-shell
  ./ubuntu-config.sh --install-shell --cuda-home /usr/local/cuda
  ./ubuntu-config.sh --install-miniforge
  ./ubuntu-config.sh --all --cuda-home /usr/local/cuda
EOF
}

INSTALL_BASE=0
INSTALL_DEV=0
INSTALL_SHELL=0
INSTALL_MINIFORGE=0
RUN_UPDATE=1
CHECK_ONLY=0
CONFIGURE_SHELL=1
CUDA_HOME=""
MINIFORGE_PREFIX="${HOME}/miniforge3"
MINIFORGE_URL=""

BASE_PACKAGES="ca-certificates curl wget gzip netcat-openbsd pv tmux nvtop htop lsof aria2 pigz git-lfs git vim tree unzip zip net-tools ripgrep fd-find jq"
DEV_PACKAGES="build-essential cmake ninja-build pkg-config gdb clang clangd python3-pip python3-venv"
SHELL_PACKAGES="zsh fzf bat zoxide git"

OH_MY_ZSH_REPO="https://gitee.com/mirror-hub/ohmyzsh.git"
ZSH_SYNTAX_HIGHLIGHTING_REPO="https://gitee.com/mirror-hub/zsh-syntax-highlighting.git"
ZSH_AUTOSUGGESTIONS_REPO="https://gitee.com/mirror-hub/zsh-autosuggestions.git"
FZF_REPO="https://github.com/junegunn/fzf.git"
CONDA_CHANNELS="
https://mirrors.tuna.tsinghua.edu.cn/anaconda/pkgs/free/
https://mirrors.tuna.tsinghua.edu.cn/anaconda/pkgs/main/
https://mirrors.tuna.tsinghua.edu.cn/anaconda/cloud/conda-forge/
https://mirrors.tuna.tsinghua.edu.cn/anaconda/cloud/bioconda/
"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --install-base)
      INSTALL_BASE=1
      shift
      ;;
    --install-dev)
      INSTALL_DEV=1
      shift
      ;;
    --install-shell)
      INSTALL_SHELL=1
      shift
      ;;
    --install-miniforge)
      INSTALL_MINIFORGE=1
      shift
      ;;
    --skip-shell-config)
      CONFIGURE_SHELL=0
      shift
      ;;
    --skip-update)
      RUN_UPDATE=0
      shift
      ;;
    --cuda-home)
      [ "$#" -ge 2 ] || { echo "missing value for --cuda-home" >&2; exit 1; }
      CUDA_HOME=$2
      shift 2
      ;;
    --miniforge-prefix)
      [ "$#" -ge 2 ] || { echo "missing value for --miniforge-prefix" >&2; exit 1; }
      MINIFORGE_PREFIX=$2
      shift 2
      ;;
    --miniforge-url)
      [ "$#" -ge 2 ] || { echo "missing value for --miniforge-url" >&2; exit 1; }
      MINIFORGE_URL=$2
      shift 2
      ;;
    --all)
      INSTALL_BASE=1
      INSTALL_DEV=1
      INSTALL_SHELL=1
      INSTALL_MINIFORGE=1
      shift
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

if [ "$INSTALL_BASE" -eq 0 ] &&
   [ "$INSTALL_DEV" -eq 0 ] &&
   [ "$INSTALL_SHELL" -eq 0 ] &&
   [ "$INSTALL_MINIFORGE" -eq 0 ] &&
   [ -z "$CUDA_HOME" ]; then
  echo "at least one install or configuration option is required" >&2
  usage >&2
  exit 1
fi

command -v apt-get >/dev/null 2>&1 || {
  echo "apt-get is required" >&2
  exit 1
}

[ -r /etc/os-release ] || {
  echo "/etc/os-release not found" >&2
  exit 1
}

. /etc/os-release

case "${ID:-}" in
  ubuntu) ;;
  *)
    echo "this script currently supports Ubuntu only" >&2
    echo "detected system id: ${ID:-unknown}" >&2
    exit 1
    ;;
esac

if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
else
  command -v sudo >/dev/null 2>&1 || {
    echo "sudo is required when not running as root" >&2
    exit 1
  }
  SUDO="sudo"
fi

if [ -n "$CUDA_HOME" ] && [ ! -d "$CUDA_HOME" ]; then
  echo "cuda directory not found: $CUDA_HOME" >&2
  exit 1
fi

case "$MINIFORGE_PREFIX" in
  /*) ;;
  *)
    echo "--miniforge-prefix must be an absolute path" >&2
    exit 1
    ;;
esac

detect_miniforge_url() {
  if [ -n "$MINIFORGE_URL" ]; then
    printf '%s\n' "$MINIFORGE_URL"
    return 0
  fi

  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64)
      suffix="x86_64"
      ;;
    aarch64|arm64)
      suffix="aarch64"
      ;;
    *)
      echo "unsupported architecture for Miniforge auto URL: $arch" >&2
      echo "use --miniforge-url to provide an explicit installer URL" >&2
      exit 1
      ;;
  esac

  printf '%s\n' "https://mirror.nju.edu.cn/github-release/conda-forge/miniforge/LatestRelease/Miniforge3-Linux-${suffix}.sh"
}

run_cmd() {
  echo "+ $*"
  "$@"
}

append_line_if_missing() {
  file=$1
  line=$2

  touch "$file"
  if ! grep -Fqx "$line" "$file" 2>/dev/null; then
    printf '%s\n' "$line" >> "$file"
  fi
}

replace_or_append_plugins_line() {
  file=$1
  tmp_file="$(mktemp)"

  awk '
  BEGIN {
    replaced = 0
  }
  /^plugins=\(/ && replaced == 0 {
    print "plugins=(git sudo zsh-syntax-highlighting zsh-autosuggestions fzf)"
    replaced = 1
    next
  }
  {
    print
  }
  END {
    if (replaced == 0) {
      print "plugins=(git sudo zsh-syntax-highlighting zsh-autosuggestions fzf)"
    }
  }
  ' "$file" > "$tmp_file"

  mv "$tmp_file" "$file"
}

clone_repo_if_missing() {
  repo_url=$1
  target_dir=$2

  if [ -d "$target_dir/.git" ] || [ -d "$target_dir" ]; then
    echo "reuse existing repo: $target_dir"
    return 0
  fi

  parent_dir="$(dirname "$target_dir")"
  mkdir -p "$parent_dir"
  run_cmd git clone "$repo_url" "$target_dir"
}

download_file() {
  url=$1
  out_file=$2

  if command -v wget >/dev/null 2>&1; then
    run_cmd wget -O "$out_file" "$url"
    return 0
  fi

  if command -v curl >/dev/null 2>&1; then
    run_cmd curl -fsSL -o "$out_file" "$url"
    return 0
  fi

  echo "wget or curl is required to download: $url" >&2
  exit 1
}

configure_tmux() {
  tmux_conf="${HOME}/.tmux.conf"
  append_line_if_missing "$tmux_conf" "set -g mouse on"
  echo "configured tmux mouse mode: $tmux_conf"
}

configure_oh_my_zsh() {
  oh_my_zsh_dir="${HOME}/.oh-my-zsh"
  zsh_custom_dir="${oh_my_zsh_dir}/custom"
  zshrc="${HOME}/.zshrc"
  bash_profile="${HOME}/.bash_profile"
  fzf_dir="${HOME}/.fzf"

  clone_repo_if_missing "$OH_MY_ZSH_REPO" "$oh_my_zsh_dir"
  clone_repo_if_missing "$ZSH_SYNTAX_HIGHLIGHTING_REPO" "${zsh_custom_dir}/plugins/zsh-syntax-highlighting"
  clone_repo_if_missing "$ZSH_AUTOSUGGESTIONS_REPO" "${zsh_custom_dir}/plugins/zsh-autosuggestions"
  clone_repo_if_missing "$FZF_REPO" "$fzf_dir"

  if [ -x "${fzf_dir}/install" ]; then
    run_cmd "${fzf_dir}/install" --all
  fi

  if [ ! -f "$zshrc" ] && [ -f "${oh_my_zsh_dir}/templates/zshrc.zsh-template" ]; then
    cp "${oh_my_zsh_dir}/templates/zshrc.zsh-template" "$zshrc"
  else
    touch "$zshrc"
  fi

  if ! grep -Fq 'oh-my-zsh.sh' "$zshrc" 2>/dev/null; then
    append_line_if_missing "$zshrc" 'export ZSH="$HOME/.oh-my-zsh"'
    append_line_if_missing "$zshrc" 'ZSH_THEME="robbyrussell"'
    append_line_if_missing "$zshrc" 'source "$ZSH/oh-my-zsh.sh"'
  fi

  replace_or_append_plugins_line "$zshrc"
  append_line_if_missing "$zshrc" 'autoload -U compinit && compinit'
  append_line_if_missing "$zshrc" 'eval "$(zoxide init zsh)"'
  append_line_if_missing "$zshrc" '[ -f "$HOME/.fzf.zsh" ] && source "$HOME/.fzf.zsh"'
  append_line_if_missing "$zshrc" '[ -f /usr/share/doc/fzf/examples/key-bindings.zsh ] && source /usr/share/doc/fzf/examples/key-bindings.zsh'
  append_line_if_missing "$zshrc" '[ -f /usr/share/doc/fzf/examples/completion.zsh ] && source /usr/share/doc/fzf/examples/completion.zsh'

  touch "$bash_profile"
  append_line_if_missing "$bash_profile" 'exec "$(command -v zsh)" -l'

  echo "configured oh-my-zsh and plugins: $zshrc"
  echo "configured login shell handoff: $bash_profile"
}

configure_cuda_env() {
  zshrc="${HOME}/.zshrc"
  touch "$zshrc"
  append_line_if_missing "$zshrc" "export PATH=\"${CUDA_HOME}/bin:\$PATH\""
  append_line_if_missing "$zshrc" "export LD_LIBRARY_PATH=\"${CUDA_HOME}/lib64:\$LD_LIBRARY_PATH\""
  echo "configured CUDA environment: $zshrc"
}

configure_shell_tools() {
  if [ "$CONFIGURE_SHELL" -eq 0 ]; then
    echo "skip shell configuration"
    return 0
  fi

  configure_tmux
  configure_oh_my_zsh

  if [ -n "$CUDA_HOME" ]; then
    configure_cuda_env
  fi
}

ensure_conda_channel() {
  conda_bin=$1
  channel=$2

  if "$conda_bin" config --show channels 2>/dev/null | grep -Fq "$channel"; then
    echo "reuse existing conda channel: $channel"
    return 0
  fi

  run_cmd "$conda_bin" config --add channels "$channel"
}

install_miniforge() {
  installer_url="$(detect_miniforge_url)"
  installer_file="$(mktemp /tmp/miniforge-installer.XXXXXX.sh)"
  conda_sh="${MINIFORGE_PREFIX}/etc/profile.d/conda.sh"
  conda_bin="${MINIFORGE_PREFIX}/bin/conda"
  zshrc="${HOME}/.zshrc"

  if [ ! -x "$conda_bin" ]; then
    download_file "$installer_url" "$installer_file"
    run_cmd bash "$installer_file" -b -p "$MINIFORGE_PREFIX"
  else
    echo "reuse existing Miniforge install: $MINIFORGE_PREFIX"
  fi

  rm -f "$installer_file"

  [ -f "$conda_sh" ] || {
    echo "conda.sh not found after Miniforge install: $conda_sh" >&2
    exit 1
  }

  chmod u+x "$conda_sh"
  touch "$zshrc"
  append_line_if_missing "$zshrc" "source ${conda_sh}"

  run_cmd "$conda_bin" init zsh

  old_ifs=$IFS
  IFS='
'
  for channel in $CONDA_CHANNELS; do
    [ -n "$channel" ] || continue
    ensure_conda_channel "$conda_bin" "$channel"
  done
  IFS=$old_ifs

  echo "configured Miniforge: $MINIFORGE_PREFIX"
}

install_group() {
  package_list=$1
  if [ -n "$SUDO" ]; then
    run_cmd $SUDO apt-get install -y $package_list
  else
    run_cmd apt-get install -y $package_list
  fi
}

print_plan() {
  echo "system:              ${PRETTY_NAME:-Ubuntu}"
  echo "apt update:          $RUN_UPDATE"
  echo "install base:        $INSTALL_BASE"
  echo "install dev:         $INSTALL_DEV"
  echo "install shell:       $INSTALL_SHELL"
  echo "shell config:        $CONFIGURE_SHELL"
  echo "install miniforge:   $INSTALL_MINIFORGE"
  echo "cuda home:           ${CUDA_HOME:-<disabled>}"
  echo "miniforge prefix:    $MINIFORGE_PREFIX"
  if [ "$INSTALL_BASE" -eq 1 ]; then
    echo "base packages:       $BASE_PACKAGES"
  fi
  if [ "$INSTALL_DEV" -eq 1 ]; then
    echo "dev packages:        $DEV_PACKAGES"
  fi
  if [ "$INSTALL_SHELL" -eq 1 ]; then
    echo "shell packages:      $SHELL_PACKAGES"
  fi
  if [ "$INSTALL_MINIFORGE" -eq 1 ]; then
    echo "miniforge url:       $(detect_miniforge_url)"
  fi
}

print_plan

if [ "$CHECK_ONLY" -eq 1 ]; then
  exit 0
fi

if [ "$RUN_UPDATE" -eq 1 ]; then
  if [ -n "$SUDO" ]; then
    run_cmd $SUDO apt-get update
  else
    run_cmd apt-get update
  fi
fi

if [ "$INSTALL_BASE" -eq 1 ]; then
  install_group "$BASE_PACKAGES"
fi

if [ "$INSTALL_DEV" -eq 1 ]; then
  install_group "$DEV_PACKAGES"
fi

if [ "$INSTALL_SHELL" -eq 1 ]; then
  install_group "$SHELL_PACKAGES"
  configure_shell_tools
elif [ -n "$CUDA_HOME" ]; then
  configure_cuda_env
fi

if [ "$INSTALL_MINIFORGE" -eq 1 ]; then
  install_miniforge
fi
