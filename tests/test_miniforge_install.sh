#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local message="$3"

  [ "$expected" = "$actual" ] || fail "$message: expected '$expected', got '$actual'"
}

assert_contains() {
  local value="$1"
  local expected="$2"
  local message="$3"

  case "$value" in
    *"$expected"*) ;;
    *) fail "$message: expected '$value' to contain '$expected'" ;;
  esac
}

assert_temp_targets_removed() {
  local target

  while IFS= read -r target; do
    [ -n "$target" ] || continue
    [ ! -e "$(dirname "$target")" ] || fail "temporary download directory was not removed: $(dirname "$target")"
  done <"$FETCH_TARGET_LOG"
}

read_fetch_urls() {
  FETCH_URLS=()
  mapfile -t FETCH_URLS <"$FETCH_URL_LOG"
}

read_fetch_targets() {
  FETCH_TARGETS=()
  mapfile -t FETCH_TARGETS <"$FETCH_TARGET_LOG"
}

read_installer_args() {
  INSTALL_ARGS=()
  mapfile -d '' -t INSTALL_ARGS <"$INSTALL_ARGS_LOG"
}

# shellcheck source=bootstrap/common.sh
source "$REPO_ROOT/bootstrap/common.sh"
# shellcheck source=bootstrap/server/miniforge.sh
source "$REPO_ROOT/bootstrap/server/miniforge.sh"

tmp_root="$(mktemp -d)"
trap 'rm -rf "$tmp_root"' EXIT

ARCH=x86_64
DISCOVERED_CONDA=''
CHECKSUM_CONTENT=''
PAYLOAD_CONTENT='miniforge installer fixture'
INSTALL_MODE=success
FUNCTION_CONDA_VERSION_STATUS=0

linux_arch() {
  printf '%s\n' "$ARCH"
}

conda_discovery() {
  [ -n "$DISCOVERED_CONDA" ] && printf '%s\n' "$DISCOVERED_CONDA"
}

fetch_url() {
  local url="$1"
  local output="$2"

  printf '%s\n' "$url" >>"$FETCH_URL_LOG"
  printf '%s\n' "$output" >>"$FETCH_TARGET_LOG"
  case "$url" in
    *.sha256) printf '%s\n' "$CHECKSUM_CONTENT" >"$output" ;;
    *) printf '%s\n' "$PAYLOAD_CONTENT" >"$output" ;;
  esac
}

make_conda() {
  local path="$1"
  local version_status="$2"
  local label="$3"

  mkdir -p "$(dirname "$path")"
  printf '%s\n' '#!/usr/bin/env bash' >"$path"
  printf 'if [ "$1" = "--version" ]; then exit %s; fi\n' "$version_status" >>"$path"
  printf 'if [ "$1" = "config" ]; then printf "%s:%%s\\n" "$*" >>"$CONDA_LOG"; exit 0; fi\n' "$label" >>"$path"
  printf '%s\n' 'exit 1' >>"$path"
  chmod +x "$path"
}

define_conda_function() {
  conda() {
    case "${1:-}" in
      --version) return "$FUNCTION_CONDA_VERSION_STATUS" ;;
      config) printf 'function:%s\n' "$*" >>"$CONDA_LOG" ;;
      *) return 1 ;;
    esac
  }
}

run_miniforge_installer() {
  printf '%s\0' "$@" >>"$INSTALL_ARGS_LOG"
  case "$INSTALL_MODE" in
    success) make_conda "$HOME/miniforge3/bin/conda" 0 installed ;;
    post_install_broken) make_conda "$HOME/miniforge3/bin/conda" 1 installed ;;
    failure) return 1 ;;
    *) fail "unexpected INSTALL_MODE: $INSTALL_MODE" ;;
  esac
}

reset_case() {
  local name="$1"
  local payload_path

  unset -f conda 2>/dev/null || true
  HOME="$tmp_root/$name/home"
  export HOME
  mkdir -p "$HOME"
  PATH="$tmp_root/$name/path-bin:/usr/bin:/bin"
  export PATH
  mkdir -p "${PATH%%:*}"
  CONDA_LOG="$tmp_root/$name/conda.log"
  FETCH_URL_LOG="$tmp_root/$name/fetch-urls.log"
  FETCH_TARGET_LOG="$tmp_root/$name/fetch-targets.log"
  INSTALL_ARGS_LOG="$tmp_root/$name/installer-args.bin"
  export CONDA_LOG
  : >"$CONDA_LOG"
  : >"$FETCH_URL_LOG"
  : >"$FETCH_TARGET_LOG"
  : >"$INSTALL_ARGS_LOG"

  DISCOVERED_CONDA=''
  INSTALL_MODE=success
  FUNCTION_CONDA_VERSION_STATUS=0
  PAYLOAD_CONTENT="miniforge installer fixture for $name"
  payload_path="$tmp_root/$name/payload"
  printf '%s\n' "$PAYLOAD_CONTENT" >"$payload_path"
  CHECKSUM_CONTENT="$(sha256_file "$payload_path")  Miniforge3-Linux-fixture.sh"
  ARCH=x86_64
}

reset_case existing-external-conda
make_conda "${PATH%%:*}/conda" 0 current
DISCOVERED_CONDA="${PATH%%:*}/conda"
assert_eq "$DISCOVERED_CONDA" "$(conda_bin)" 'conda_bin returns the discovered executable path'
install_miniforge
assert_eq 0 "$(wc -l <"$FETCH_URL_LOG")" 'usable current conda skips downloads'
assert_eq 0 "$(wc -c <"$INSTALL_ARGS_LOG")" 'usable current conda skips installer'
assert_contains "$(<"$CONDA_LOG")" 'current:config --set auto_activate_base false' 'usable current conda is configured'

reset_case existing-function-conda
define_conda_function
DISCOVERED_CONDA=conda
assert_eq conda "$(conda_bin)" 'conda_bin returns a usable conda shell function'
install_miniforge
assert_eq 0 "$(wc -l <"$FETCH_URL_LOG")" 'usable conda function skips downloads'
assert_eq 0 "$(wc -c <"$INSTALL_ARGS_LOG")" 'usable conda function skips installer'
assert_contains "$(<"$CONDA_LOG")" 'function:config --set auto_activate_base false' 'usable conda function is configured'

reset_case broken-function-home-fallback
define_conda_function
FUNCTION_CONDA_VERSION_STATUS=1
DISCOVERED_CONDA=conda
make_conda "$HOME/miniforge3/bin/conda" 0 home
install_miniforge
assert_eq 0 "$(wc -l <"$FETCH_URL_LOG")" 'valid home Miniforge conda skips downloads after function verification fails'
assert_eq 0 "$(wc -c <"$INSTALL_ARGS_LOG")" 'valid home Miniforge conda skips installer after function verification fails'
assert_contains "$(<"$CONDA_LOG")" 'home:config --set auto_activate_base false' 'home Miniforge conda is configured'

reset_case 'x86 install with spaces'
define_conda_function
FUNCTION_CONDA_VERSION_STATUS=1
DISCOVERED_CONDA=conda
set -T
install_miniforge
set +T
read_fetch_urls
read_fetch_targets
read_installer_args
assert_eq 2 "${#FETCH_URLS[@]}" 'x86_64 install downloads installer and checksum'
assert_eq 'https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-x86_64.sh' "${FETCH_URLS[0]}" 'x86_64 installer URL'
assert_eq 'https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-x86_64.sh.sha256' "${FETCH_URLS[1]}" 'x86_64 checksum URL'
assert_eq 4 "${#INSTALL_ARGS[@]}" 'installer receives four distinct arguments'
assert_eq "${FETCH_TARGETS[0]}" "${INSTALL_ARGS[0]}" 'installer path is one argument'
assert_eq -b "${INSTALL_ARGS[1]}" 'installer batch flag is one argument'
assert_eq -p "${INSTALL_ARGS[2]}" 'installer prefix flag is one argument'
assert_eq "$HOME/miniforge3" "${INSTALL_ARGS[3]}" 'installer prefix with spaces is one argument'
assert_contains "$(<"$CONDA_LOG")" 'installed:config --set auto_activate_base false' 'installed conda is configured'
assert_temp_targets_removed

reset_case arm-install
ARCH=arm64
install_miniforge
read_fetch_urls
assert_eq 'https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-aarch64.sh' "${FETCH_URLS[0]}" 'arm64 installer URL'
assert_eq 'https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-aarch64.sh.sha256' "${FETCH_URLS[1]}" 'arm64 checksum URL'

for checksum_case in missing-checksum malformed-checksum mismatched-checksum; do
  reset_case "$checksum_case"
  case "$checksum_case" in
    missing-checksum) CHECKSUM_CONTENT='' ;;
    malformed-checksum) CHECKSUM_CONTENT='not-a-sha256 Miniforge3-Linux-x86_64.sh' ;;
    mismatched-checksum) CHECKSUM_CONTENT='0000000000000000000000000000000000000000000000000000000000000000 Miniforge3-Linux-x86_64.sh' ;;
  esac
  if (install_miniforge); then
    fail "$checksum_case must fail"
  fi
  assert_eq 0 "$(wc -c <"$INSTALL_ARGS_LOG")" "$checksum_case aborts before installer execution"
  assert_temp_targets_removed
done

reset_case installer-failure
INSTALL_MODE=failure
if (install_miniforge); then
  fail 'installer failure must be nonzero'
fi
read_installer_args
assert_eq 4 "${#INSTALL_ARGS[@]}" 'installer failure still invokes installer once'
assert_temp_targets_removed

reset_case post-install-verification-failure
INSTALL_MODE=post_install_broken
if (install_miniforge); then
  fail 'post-install conda verification failure must be nonzero'
fi
read_installer_args
assert_eq 4 "${#INSTALL_ARGS[@]}" 'post-install verification failure invokes installer once'
assert_temp_targets_removed

reset_case recognized-prefix-repair
mkdir -p "$HOME/miniforge3/conda-meta"
printf '%s\n' broken >"$HOME/miniforge3/conda-meta/history"
make_conda "$HOME/miniforge3/bin/conda" 1 broken
install_miniforge
read_fetch_targets
read_installer_args
assert_eq 5 "${#INSTALL_ARGS[@]}" 'recognized broken prefix adds one repair argument'
assert_eq "${FETCH_TARGETS[0]}" "${INSTALL_ARGS[0]}" 'repair installer path is one argument'
assert_eq -b "${INSTALL_ARGS[1]}" 'repair keeps batch flag'
assert_eq -u "${INSTALL_ARGS[2]}" 'recognized broken prefix uses update repair flag'
assert_eq -p "${INSTALL_ARGS[3]}" 'repair keeps prefix flag'
assert_eq "$HOME/miniforge3" "${INSTALL_ARGS[4]}" 'repair keeps exact prefix'
[ -f "$HOME/miniforge3/conda-meta/history" ] || fail 'recognized prefix remains in place for repair'

reset_case partial-prefix-backup
mkdir -p "$HOME/miniforge3"
printf '%s\n' preserve-me >"$HOME/miniforge3/partial-state"
install_miniforge
read_installer_args
assert_eq 4 "${#INSTALL_ARGS[@]}" 'unrecognized partial prefix uses clean installer arguments'
assert_eq -b "${INSTALL_ARGS[1]}" 'partial prefix clean install keeps batch flag'
assert_eq -p "${INSTALL_ARGS[2]}" 'partial prefix clean install keeps prefix flag'
backup_path="$(find "$HOME" -maxdepth 1 -mindepth 1 -name 'miniforge3.bak.*' -print -quit)"
[ -n "$backup_path" ] || fail 'unrecognized partial prefix is backed up before install'
assert_eq preserve-me "$(<"$backup_path/partial-state")" 'partial prefix backup preserves original content'
install_miniforge
read_fetch_urls
read_installer_args
assert_eq 2 "${#FETCH_URLS[@]}" 'rerun after partial-prefix recovery does not redownload Miniforge'
assert_eq 4 "${#INSTALL_ARGS[@]}" 'rerun after partial-prefix recovery reuses installed Miniforge'

printf 'Miniforge installation checks passed\n'
