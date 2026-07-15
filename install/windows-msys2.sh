#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bootstrap/common.sh
source "$SCRIPT_DIR/../bootstrap/common.sh"

is_windows || die "install/windows-msys2.sh must be run inside MSYS2"
need_cmd pacman
need_cmd git

DOTFILES_LINK_MODE="${DOTFILES_LINK_MODE:-copy}"
export DOTFILES_LINK_MODE

msys2_install_packages
install_oh_my_zsh_stack
install_tmux_plugins
install_config_payload

if command -v winget.exe >/dev/null 2>&1; then
  log "Installing WezTerm and Lazygit through winget"
  winget.exe install -e --id Wez.WezTerm --accept-package-agreements --accept-source-agreements || true
  winget.exe install -e --id JesseDuffield.lazygit --accept-package-agreements --accept-source-agreements || true
else
  warn "winget.exe not found; install WezTerm and Lazygit manually on Windows"
fi

log "Done. Start WezTerm and point it at MSYS2 zsh if needed"
