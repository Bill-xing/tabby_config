#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
POWERLINE_CONFIG="$REPO_ROOT/config/tmux-powerline/config.sh"
POWERLINE_THEME="$REPO_ROOT/config/tmux-powerline/themes/minimal.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_file_contains() {
  local path="$1"
  local expected="$2"

  grep -F -- "$expected" "$path" >/dev/null ||
    fail "expected $path to contain: $expected"
}

[ -f "$POWERLINE_CONFIG" ] || fail "missing tmux-powerline config"
[ -f "$POWERLINE_THEME" ] || fail "missing minimal tmux-powerline theme"
assert_file_contains "$POWERLINE_CONFIG" 'export TMUX_POWERLINE_THEME="minimal"'
assert_file_contains "$POWERLINE_CONFIG" 'export TMUX_POWERLINE_DIR_USER_THEMES="${XDG_CONFIG_HOME:-$HOME/.config}/tmux-powerline/themes"'
assert_file_contains "$POWERLINE_CONFIG" 'export TMUX_POWERLINE_STATUS_INTERVAL="1"'
assert_file_contains "$POWERLINE_CONFIG" 'export TMUX_POWERLINE_STATUS_JUSTIFICATION="centre"'
assert_file_contains "$POWERLINE_CONFIG" 'export TMUX_POWERLINE_SEG_TMUX_SESSION_INFO_FORMAT="#S:#I.#P"'
assert_file_contains "$POWERLINE_THEME" 'source "${TMUX_POWERLINE_DIR_THEMES}/default.sh"'
assert_file_contains "$POWERLINE_THEME" '"tmux_session_info 148 234"'
assert_file_contains "$POWERLINE_THEME" 'TMUX_POWERLINE_RIGHT_STATUS_SEGMENTS=()'

printf 'tmux-powerline content checks passed\n'

# shellcheck source=bootstrap/common.sh
source "$REPO_ROOT/bootstrap/common.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

export HOME="$tmp_dir/home"
export XDG_CONFIG_HOME="$tmp_dir/xdg-config"
export DOTFILES_LINK_MODE=copy
export DOTFILES_SKIP_TABBY=1
mkdir -p "$HOME"

install_config_payload

installed_powerline="$XDG_CONFIG_HOME/tmux-powerline"
[ -d "$installed_powerline" ] || fail "tmux-powerline directory was not installed"
[ ! -L "$installed_powerline" ] || fail "copy mode installed a symlink"
cmp -s "$POWERLINE_CONFIG" "$installed_powerline/config.sh" ||
  fail "installed tmux-powerline config differs from source"
cmp -s "$POWERLINE_THEME" "$installed_powerline/themes/minimal.sh" ||
  fail "installed minimal theme differs from source"

assert_file_contains \
  "$REPO_ROOT/bootstrap/common.sh" \
  'link_or_copy "$REPO_ROOT/config/tmux-powerline" "$cfg/tmux-powerline"'

README="$REPO_ROOT/README.md"
SERVER_GUIDE="$REPO_ROOT/docs/server-quickstart.md"

assert_file_contains "$README" 'config/tmux-powerline/config.sh'
assert_file_contains "$README" 'config/tmux-powerline/themes/minimal.sh'
assert_file_contains "$README" '${XDG_CONFIG_HOME:-$HOME/.config}/tmux-powerline'
assert_file_contains "$README" 'session/window/pane'
assert_file_contains "$README" 'powerline.sh left'
assert_file_contains "$README" 'powerline.sh right'
assert_file_contains "$SERVER_GUIDE" '"$HOME/.config/tmux-powerline"'
assert_file_contains "$SERVER_GUIDE" 'powerline.sh left'
assert_file_contains "$SERVER_GUIDE" 'powerline.sh right'

printf 'tmux-powerline deployment checks passed\n'
