#!/bin/sh
set -eu

script_dir=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
repo_root=$(CDPATH='' cd -- "$script_dir/.." && pwd)
review_dir=$(mktemp -d "${TMPDIR:-/tmp}/useful-sh-regressions.XXXXXX")

cleanup() {
  rm -rf "$review_dir"
}
trap cleanup EXIT INT TERM

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  needle=$1
  file=$2
  grep -Fq -- "$needle" "$file" || fail "missing '$needle' in $file"
}

adb_script="$repo_root/sh/adb-relay-guard/adb-relay-guard.sh"
bootstrap_script="$repo_root/sh/codex-skills-bootstrap/codex-skills-bootstrap.sh"
[ -x "$adb_script" ] || fail "adb-relay-guard.sh is not executable"
[ -x "$bootstrap_script" ] || fail "codex-skills-bootstrap.sh is not executable"

mkdir -p "$review_dir/integrity"
touch "$review_dir/integrity/--payload"
(
  cd "$review_dir/integrity"
  "$repo_root/sh/file-integrity/file-integrity.sh" -- --payload
) > "$review_dir/integrity.out"
assert_contains "sha256" "$review_dir/integrity.out"

mkdir -p "$review_dir/project"
"$repo_root/sh/nvim-clangd-setup/nvim-clangd-setup.sh" \
  --path "$review_dir/project" --compdb-dir out > "$review_dir/nvim.out" 2>&1
assert_contains "CompilationDatabase: out" "$review_dir/project/.clangd"

mkdir -p "$review_dir/bin" "$review_dir/adb-tmp"
ln -s /bin/true "$review_dir/bin/adb"
if PATH="$review_dir/bin:$PATH" "$adb_script" --relay-ports , --no-ssh \
  > "$review_dir/adb-port.out" 2>&1; then
  fail "comma-only relay list was accepted"
fi
assert_contains "invalid relay ports" "$review_dir/adb-port.out"

if PATH="$review_dir/bin:$PATH" TMPDIR="$review_dir/adb-tmp" \
  "$adb_script" --config /dev/null --no-ssh > "$review_dir/adb-config.out" 2>&1; then
  fail "empty ADB config was accepted"
fi
if find "$review_dir/adb-tmp" -mindepth 1 -print -quit | grep -q .; then
  fail "ADB validation leaked temporary files"
fi

rm -f "$review_dir/bin/adb"
ln -s /bin/false "$review_dir/bin/npx"
ln -s /bin/true "$review_dir/bin/cc-switch"
if PATH="$review_dir/bin:$PATH" HOME="$review_dir/bootstrap-home" \
  "$bootstrap_script" --skill find-skills > "$review_dir/bootstrap.out" 2>&1; then
  fail "bootstrap masked a failed npx command"
fi
assert_contains "failed skills: find-skills" "$review_dir/bootstrap.out"

if command -v zsh >/dev/null 2>&1 && \
  python3 -c 'import sys, tomllib; raise SystemExit(0 if sys.version_info >= (3, 11) else 1)' 2>/dev/null; then
  histfile="$review_dir/history with spaces"
  zdotdir="$review_dir/zsh config"
  HOME="$review_dir/history-home" \
    "$repo_root/sh/codex-zsh-history-isolation/codex-zsh-history-isolation.sh" \
    --codex-dir "$review_dir/codex home" --histfile "$histfile" --zdotdir "$zdotdir" \
    > "$review_dir/history-isolation.out"
  actual_histfile=$(HOME="$review_dir/history-home" ZDOTDIR="$zdotdir" \
    zsh -c 'print -r -- "$HISTFILE"')
  [ "$actual_histfile" = "$histfile" ] || fail "zsh loaded the wrong HISTFILE"

  prefix="$review_dir/miniforge prefix"
  mkdir -p "$review_dir/ubuntu-home" "$prefix/bin" "$prefix/etc/profile.d"
  cp /bin/true "$prefix/bin/conda"
  : > "$prefix/etc/profile.d/conda.sh"
  HOME="$review_dir/ubuntu-home" \
    "$repo_root/sh/ubuntu-config/ubuntu-config.sh" --skip-update --install-miniforge \
    --miniforge-prefix "$prefix" > "$review_dir/ubuntu.out"
  HOME="$review_dir/ubuntu-home" ZDOTDIR="$review_dir/ubuntu-home" zsh -i -c exit
fi

printf '%s\n' 'echo secret-value' 'echo another-command' > "$review_dir/history"
"$repo_root/sh/zsh-history-prune/zsh-history-prune.sh" \
  --histfile "$review_dir/history" --min-count 1 --keep-recent 0 \
  > "$review_dir/prune-preview.out"
assert_contains "command text:    hidden" "$review_dir/prune-preview.out"
if grep -Fq 'secret-value' "$review_dir/prune-preview.out"; then
  fail "history preview disclosed command text"
fi

printf '%s\n' ': 1:0;echo first line' 'continued line' > "$review_dir/multiline-history"
if "$repo_root/sh/zsh-history-prune/zsh-history-prune.sh" \
  --histfile "$review_dir/multiline-history" --apply > "$review_dir/multiline.out" 2>&1; then
  fail "multiline zsh history was modified"
fi
assert_contains "multiline zsh history records are not supported" "$review_dir/multiline.out"

sh "$repo_root/tests/netcat-transfer-progress.sh" >/dev/null
echo "remediation regressions passed"
