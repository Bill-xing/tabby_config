#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bootstrap/common.sh
source "$SCRIPT_DIR/../bootstrap/common.sh"

is_macos || die "install/macos.sh must be run on macOS"
need_cmd brew
need_cmd git

log "Installing Homebrew packages"
brew install tmux neovim lazygit yazi wezterm direnv eza bat fzf ripgrep fd

if brew tap homebrew/cask-fonts >/dev/null 2>&1; then
  brew install --cask font-jetbrains-mono-nerd-font || true
fi

install_oh_my_zsh_stack
install_tmux_plugins
install_config_payload

log "Done. Restart the shell or run: exec zsh"
