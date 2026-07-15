# shellcheck shell=bash

# Inherit window formatting, separators, and the colour235 status background
# from the default theme bundled with the pinned tmux-powerline checkout.
# shellcheck disable=SC1090
source "${TMUX_POWERLINE_DIR_THEMES}/default.sh"

TMUX_POWERLINE_LEFT_STATUS_SEGMENTS=(
  "tmux_session_info 148 234"
)
TMUX_POWERLINE_RIGHT_STATUS_SEGMENTS=()
