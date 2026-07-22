#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# shellcheck source=bootstrap/common.sh
source "$REPO_ROOT/bootstrap/common.sh"

tmp_root="$(mktemp -d)"
trap 'rm -rf "$tmp_root"' EXIT
export HOME="$tmp_root/home"
mkdir -p "$HOME/.local/bin" "$HOME/.local/opt"

fixture_root="$tmp_root/fixtures"
mkdir -p \
  "$fixture_root/nvim-linux-x86_64/bin" \
  "$fixture_root/lazygit" \
  "$fixture_root/yazi-x86_64-unknown-linux-musl"
printf '#!/usr/bin/env bash\nexit 0\n' >"$fixture_root/nvim-linux-x86_64/bin/nvim"
printf '#!/usr/bin/env bash\nexit 0\n' >"$fixture_root/lazygit/lazygit"
printf '#!/usr/bin/env bash\nexit 0\n' >"$fixture_root/yazi-x86_64-unknown-linux-musl/yazi"
printf '#!/usr/bin/env bash\nexit 0\n' >"$fixture_root/yazi-x86_64-unknown-linux-musl/ya"
chmod +x \
  "$fixture_root/nvim-linux-x86_64/bin/nvim" \
  "$fixture_root/lazygit/lazygit" \
  "$fixture_root/yazi-x86_64-unknown-linux-musl/yazi" \
  "$fixture_root/yazi-x86_64-unknown-linux-musl/ya"

tar -czf "$fixture_root/nvim.tar.gz" -C "$fixture_root" nvim-linux-x86_64
tar -czf "$fixture_root/lazygit.tar.gz" -C "$fixture_root/lazygit" lazygit

github_latest_asset_url() {
  case "$1" in
    jesseduffield/lazygit) printf '%s\n' 'https://example.invalid/lazygit.tar.gz' ;;
    sxyazi/yazi) printf '%s\n' 'https://example.invalid/yazi.zip' ;;
    *) fail "unexpected release repository: $1" ;;
  esac
}

fetch_url() {
  case "$2" in
    *nvim-linux-x86_64.tar.gz) cp "$fixture_root/nvim.tar.gz" "$2" ;;
    *lazygit.tar.gz) cp "$fixture_root/lazygit.tar.gz" "$2" ;;
    *yazi.zip) : >"$2" ;;
    *) fail "unexpected download target: $2" ;;
  esac
}

unzip() {
  local destination
  destination="${4:?missing unzip destination}"
  cp -R "$fixture_root/yazi-x86_64-unknown-linux-musl" "$destination/"
}

invoke_installer() {
  "$1"
}

assert_installer_clears_return_trap() {
  local installer="$1"

  if ! (
    invoke_installer "$installer"
    after_installer_return() { :; }
    after_installer_return
  ); then
    fail "$installer leaked a RETURN trap outside its temporary-directory scope"
  fi
}

assert_installer_clears_return_trap install_neovim_linux
assert_installer_clears_return_trap install_lazygit_linux
assert_installer_clears_return_trap install_yazi_linux

assert_find_failure_without_pipefail() {
  local installer="$1"
  local expected_status="$2"
  local actual_status=0

  if (
    set +o pipefail
    find() {
      command find "$@"
      return "$expected_status"
    }
    "$installer" >/dev/null 2>&1
  ); then
    fail "$installer masked find failure with pipefail disabled"
  else
    actual_status=$?
  fi
  [ "$actual_status" -eq "$expected_status" ] ||
    fail "$installer returned $actual_status instead of find status $expected_status"
}

assert_find_failure_without_pipefail install_yazi_linux 51
assert_find_failure_without_pipefail install_neovim_linux 50

printf 'Linux release installer cleanup checks passed\n'
