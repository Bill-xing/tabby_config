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
