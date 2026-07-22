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
  done <"$FETCH_LOG"
}

# shellcheck source=bootstrap/common.sh
source "$REPO_ROOT/bootstrap/common.sh"
# shellcheck source=bootstrap/server/miniforge.sh
source "$REPO_ROOT/bootstrap/server/miniforge.sh"

tmp_root="$(mktemp -d)"
trap 'rm -rf "$tmp_root"' EXIT

ARCH=x86_64
FETCH_URLS=()
FETCH_TARGETS=()
INSTALL_CALLS=()
CHECKSUM_CONTENT=''
PAYLOAD_CONTENT='miniforge installer fixture'
INSTALL_MODE=success

linux_arch() {
  printf '%s\n' "$ARCH"
}

fetch_url() {
  local url="$1"
  local output="$2"

  FETCH_URLS+=("$url")
  FETCH_TARGETS+=("$output")
  printf '%s\n' "$output" >>"$FETCH_LOG"
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

run_miniforge_installer() {
  INSTALL_CALLS+=("$*")
  printf '%s\n' "$*" >>"$INSTALL_LOG"
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

  HOME="$tmp_root/$name/home"
  export HOME
  mkdir -p "$HOME"
  PATH="$tmp_root/$name/path-bin:/usr/bin:/bin"
  export PATH
  mkdir -p "${PATH%%:*}"
  CONDA_LOG="$tmp_root/$name/conda.log"
  export CONDA_LOG
  : >"$CONDA_LOG"
  FETCH_LOG="$tmp_root/$name/fetch.log"
  INSTALL_LOG="$tmp_root/$name/install.log"
  : >"$FETCH_LOG"
  : >"$INSTALL_LOG"

  FETCH_URLS=()
  FETCH_TARGETS=()
  INSTALL_CALLS=()
  INSTALL_MODE=success
  PAYLOAD_CONTENT="miniforge installer fixture for $name"
  payload_path="$tmp_root/$name/payload"
  printf '%s\n' "$PAYLOAD_CONTENT" >"$payload_path"
  CHECKSUM_CONTENT="$(sha256_file "$payload_path")  Miniforge3-Linux-fixture.sh"
  ARCH=x86_64
}

reset_case existing-conda
make_conda "${PATH%%:*}/conda" 0 current
assert_eq "${PATH%%:*}/conda" "$(conda_bin)" 'conda_bin returns the current executable command path'
install_miniforge
assert_eq 0 "${#FETCH_URLS[@]}" 'usable current conda skips downloads'
assert_eq 0 "${#INSTALL_CALLS[@]}" 'usable current conda skips installer'
assert_contains "$(<"$CONDA_LOG")" 'current:config --set auto_activate_base false' 'usable current conda is configured'

reset_case fallback-home-conda
make_conda "${PATH%%:*}/conda" 1 broken-current
make_conda "$HOME/miniforge3/bin/conda" 0 home
install_miniforge
assert_eq 0 "${#FETCH_URLS[@]}" 'valid home Miniforge conda skips downloads after current conda fails verification'
assert_eq 0 "${#INSTALL_CALLS[@]}" 'valid home Miniforge conda skips installer after current conda fails verification'
assert_contains "$(<"$CONDA_LOG")" 'home:config --set auto_activate_base false' 'home Miniforge conda is configured'

reset_case x86-install
install_miniforge
assert_eq 2 "${#FETCH_URLS[@]}" 'x86_64 install downloads installer and checksum'
assert_eq 'https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-x86_64.sh' "${FETCH_URLS[0]}" 'x86_64 installer URL'
assert_eq 'https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-x86_64.sh.sha256' "${FETCH_URLS[1]}" 'x86_64 checksum URL'
assert_eq 1 "${#INSTALL_CALLS[@]}" 'x86_64 install runs installer once'
assert_eq "${FETCH_TARGETS[0]} -b -p $HOME/miniforge3" "${INSTALL_CALLS[0]}" 'installer receives exact noninteractive arguments'
assert_contains "$(<"$CONDA_LOG")" 'installed:config --set auto_activate_base false' 'installed conda is configured'
assert_temp_targets_removed

reset_case arm-install
ARCH=arm64
install_miniforge
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
  assert_eq 0 "$(wc -l <"$INSTALL_LOG")" "$checksum_case aborts before installer execution"
  assert_temp_targets_removed
done

reset_case installer-failure
INSTALL_MODE=failure
if (install_miniforge); then
  fail 'installer failure must be nonzero'
fi
assert_eq 1 "$(wc -l <"$INSTALL_LOG")" 'installer failure still invokes installer once'
assert_temp_targets_removed

reset_case post-install-verification-failure
INSTALL_MODE=post_install_broken
if (install_miniforge); then
  fail 'post-install conda verification failure must be nonzero'
fi
assert_eq 1 "$(wc -l <"$INSTALL_LOG")" 'post-install verification failure invokes installer once'
assert_temp_targets_removed

reset_case rerun
install_miniforge
install_miniforge
assert_eq 1 "${#INSTALL_CALLS[@]}" 'rerun reuses the verified Miniforge installation'
assert_eq 2 "${#FETCH_URLS[@]}" 'rerun does not redownload Miniforge'

printf 'Miniforge installation checks passed\n'
