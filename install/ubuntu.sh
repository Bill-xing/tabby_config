#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bootstrap/common.sh
source "$SCRIPT_DIR/../bootstrap/common.sh"

is_linux || die "install/ubuntu.sh must be run on Linux"
need_cmd git
need_cmd curl
need_cmd python3

log "Installing base Ubuntu packages"
run_root apt-get update
run_root apt-get install -y \
  build-essential \
  ca-certificates \
  curl \
  file \
  fzf \
  fd-find \
  git \
  gnupg \
  jq \
  ripgrep \
  tmux \
  unzip \
  wget \
  zsh

if run_root apt-cache show bat >/dev/null 2>&1; then
  run_root apt-get install -y bat
fi

if run_root apt-cache show eza >/dev/null 2>&1; then
  run_root apt-get install -y eza
fi

if run_root apt-cache show direnv >/dev/null 2>&1; then
  run_root apt-get install -y direnv
fi

install_neovim_linux
install_lazygit_linux
install_yazi_linux

mkdir -p "$HOME/.local/bin"
if command -v batcat >/dev/null 2>&1 && ! command -v bat >/dev/null 2>&1; then
  ln -sf "$(command -v batcat)" "$HOME/.local/bin/bat"
fi
if command -v fdfind >/dev/null 2>&1 && ! command -v fd >/dev/null 2>&1; then
  ln -sf "$(command -v fdfind)" "$HOME/.local/bin/fd"
fi

ensure_wezterm_apt_repo
run_root apt-get update
run_root apt-get install -y wezterm

install_oh_my_zsh_stack
install_tmux_plugins
install_config_payload

log "Done. Make zsh your default shell with: chsh -s $(command -v zsh)"
