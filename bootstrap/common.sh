#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=bootstrap/plugins.lock.sh
source "$REPO_ROOT/bootstrap/plugins.lock.sh"

log() {
  printf '==> %s\n' "$*"
}

warn() {
  printf 'WARN: %s\n' "$*" >&2
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

have() {
  command -v "$1" >/dev/null 2>&1
}

need_cmd() {
  have "$1" || die "missing required command: $1"
}

platform_name() {
  case "$(uname -s)" in
    Darwin) echo "macos" ;;
    Linux) echo "linux" ;;
    CYGWIN*|MINGW*|MSYS*) echo "windows" ;;
    *) echo "other" ;;
  esac
}

is_windows() {
  [ "$(platform_name)" = "windows" ]
}

is_macos() {
  [ "$(platform_name)" = "macos" ]
}

is_linux() {
  [ "$(platform_name)" = "linux" ]
}

flag_enabled() {
  case "${1:-0}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

skip_tabby() {
  flag_enabled "${DOTFILES_SKIP_TABBY:-0}"
}

force_install() {
  flag_enabled "${DOTFILES_FORCE_INSTALL:-0}"
}

run_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
}

backup_existing() {
  local target="$1"
  local stamp backup suffix

  if [ ! -e "$target" ] && [ ! -L "$target" ]; then
    return 0
  fi

  stamp="$(date +%Y%m%d%H%M%S)"
  backup="${target}.bak.${stamp}"
  suffix=1
  while [ -e "$backup" ] || [ -L "$backup" ]; do
    backup="${target}.bak.${stamp}.${suffix}"
    suffix=$((suffix + 1))
  done
  log "Backing up $target -> $backup"
  mv "$target" "$backup"
}

link_or_copy() {
  local src="$1"
  local dst="$2"
  local mode="${DOTFILES_LINK_MODE:-auto}"

  mkdir -p "$(dirname "$dst")"

  if [ -L "$dst" ] && [ "$(readlink "$dst")" = "$src" ]; then
    return 0
  fi

  if [ "$mode" = "auto" ]; then
    if is_windows; then
      mode="copy"
    else
      mode="symlink"
    fi
  fi

  if [ -e "$dst" ] || [ -L "$dst" ]; then
    backup_existing "$dst"
  fi

  case "$mode" in
    symlink)
      ln -s "$src" "$dst"
      ;;
    copy)
      if [ -d "$src" ]; then
        cp -R "$src" "$dst"
      else
        cp "$src" "$dst"
      fi
      ;;
    *)
      die "unsupported DOTFILES_LINK_MODE: $mode"
      ;;
  esac
}

windows_to_unix_path() {
  local raw="$1"

  if [ -z "$raw" ]; then
    return 0
  fi

  if have cygpath; then
    cygpath -u "$raw"
  else
    printf '%s\n' "$raw"
  fi
}

config_home() {
  printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}"
}

data_home() {
  printf '%s\n' "${XDG_DATA_HOME:-$HOME/.local/share}"
}

state_home() {
  printf '%s\n' "${XDG_STATE_HOME:-$HOME/.local/state}"
}

cache_home() {
  printf '%s\n' "${XDG_CACHE_HOME:-$HOME/.cache}"
}

ensure_base_dirs() {
  mkdir -p "$(config_home)" "$(data_home)" "$(state_home)" "$(cache_home)" "$HOME/.local/bin" "$HOME/.local/opt"
}

tabby_config_path() {
  local platform="${1:-$(platform_name)}"
  local appdata_unix

  case "$platform" in
    linux)
      printf '%s\n' "$(config_home)/tabby/config.yaml"
      ;;
    macos)
      printf '%s\n' "$HOME/Library/Application Support/tabby/config.yaml"
      ;;
    windows)
      appdata_unix="$(windows_to_unix_path "${APPDATA:-}")"
      [ -n "$appdata_unix" ] || die "APPDATA is required to install the Windows Tabby config"
      printf '%s\n' "$appdata_unix/Tabby/config.yaml"
      ;;
    *)
      die "unsupported platform for Tabby config: $platform"
      ;;
  esac
}

tabby_plugins_path() {
  local platform="${1:-$(platform_name)}"
  printf '%s\n' "$(dirname "$(tabby_config_path "$platform")")/plugins"
}

package_json_string_field() {
  local field="$1"
  local path="$2"

  sed -n \
    "s/^[[:space:]]*\"${field}\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" \
    "$path" | sed -n '1p'
}

tabby_osc_notify_package_is_valid() {
  local target="$1"

  [ -d "$target" ] &&
    [ ! -L "$target" ] &&
    [ -f "$target/package.json" ] &&
    [ -f "$target/dist/index.js" ] &&
    [ "$(package_json_string_field name "$target/package.json")" = "$TABBY_OSC_NOTIFY_NAME" ] &&
    [ "$(package_json_string_field version "$target/package.json")" = "$TABBY_OSC_NOTIFY_VERSION" ]
}

sha256_file() {
  local path="$1"

  if have sha256sum; then
    sha256sum "$path" | awk '{ print $1 }'
  elif have shasum; then
    shasum -a 256 "$path" | awk '{ print $1 }'
  else
    warn "Cannot verify SHA-256 (sha256sum or shasum is required)"
    return 1
  fi
}

tabby_plugin_archive_list_is_safe() {
  local list_file="$1"
  local entry saw_member=0

  while IFS= read -r entry || [ -n "$entry" ]; do
    [ -n "$entry" ] || return 1
    case "$entry" in
      /*|../*|*/../*|*/..|.|./*|*/./*|*/.) return 1 ;;
    esac
    case "$entry" in
      package|package/*) saw_member=1 ;;
      *) return 1 ;;
    esac
  done <"$list_file"

  [ "$saw_member" -eq 1 ]
}

tabby_plugin_archive_types_are_safe() {
  local list_file="$1"
  local entry saw_member=0

  while IFS= read -r entry || [ -n "$entry" ]; do
    [ -n "$entry" ] || continue
    case "$entry" in
      -*|d*) saw_member=1 ;;
      *) return 1 ;;
    esac
  done <"$list_file"

  [ "$saw_member" -eq 1 ]
}

next_tabby_plugin_backup_path() {
  local plugin_root="$1"
  local package_name="$2"
  local stamp backup suffix

  stamp="$(date +%Y%m%d%H%M%S)"
  backup="$plugin_root/backups/${package_name}.bak.${stamp}"
  suffix=1
  while [ -e "$backup" ] || [ -L "$backup" ]; do
    backup="$plugin_root/backups/${package_name}.bak.${stamp}.${suffix}"
    suffix=$((suffix + 1))
  done
  printf '%s\n' "$backup"
}

install_tabby_config() {
  local platform="${1:-$(platform_name)}"
  local source_file="$REPO_ROOT/config/tabby/config.yaml"
  local target

  [ -f "$source_file" ] || die "missing Tabby config: $source_file"
  target="$(tabby_config_path "$platform")"

  warn "Close Tabby before installing config; a running app may overwrite this file on exit"
  mkdir -p "$(dirname "$target")"

  if [ -e "$target" ] || [ -L "$target" ]; then
    backup_existing "$target"
  fi

  cp "$source_file" "$target"
}

install_codex_notifications() {
  local source_file="$REPO_ROOT/config/codex/tabby-notifications.toml"
  local merger="$REPO_ROOT/bootstrap/merge_codex_tui_config.py"
  local codex_home target temp_file

  if ! have codex; then
    log "Skipping Codex notifications (codex is not installed)"
    return 0
  fi
  if ! have python3; then
    warn "Skipping Codex notifications (python3 is required to merge config.toml safely)"
    return 0
  fi

  [ -f "$source_file" ] || die "missing Codex notification config: $source_file"
  [ -f "$merger" ] || die "missing Codex TUI config merger: $merger"

  codex_home="${CODEX_HOME:-$HOME/.codex}"
  target="$codex_home/config.toml"
  mkdir -p "$codex_home"
  temp_file="$(mktemp "${target}.tmp.XXXXXX")"

  if [ -e "$target" ] || [ -L "$target" ]; then
    if ! python3 "$merger" "$source_file" "$target" >"$temp_file"; then
      rm -f "$temp_file"
      die "failed to merge Codex notification config into $target"
    fi
    if cmp -s "$temp_file" "$target"; then
      rm -f "$temp_file"
      return 0
    fi
    backup_existing "$target"
  elif ! python3 "$merger" "$source_file" >"$temp_file"; then
    rm -f "$temp_file"
    die "failed to create Codex notification config"
  fi

  mv "$temp_file" "$target"
  log "Installed Codex OSC 9 notifications in $target"
}

install_tabby_osc_notify() {
  local platform="${1:-$(platform_name)}"
  local plugin_root node_modules target tmp_dir archive archive_list archive_types
  local unpacked staged actual_sha backup=""

  plugin_root="$(tabby_plugins_path "$platform")"
  node_modules="$plugin_root/node_modules"
  target="$node_modules/$TABBY_OSC_NOTIFY_NAME"

  if tabby_osc_notify_package_is_valid "$target"; then
    log "Reusing $TABBY_OSC_NOTIFY_NAME@$TABBY_OSC_NOTIFY_VERSION"
    return 0
  fi

  mkdir -p "$node_modules"
  tmp_dir="$(mktemp -d "$plugin_root/.${TABBY_OSC_NOTIFY_NAME}.install.XXXXXX")"
  trap 'rm -rf "$tmp_dir"; trap - RETURN' RETURN
  archive="$tmp_dir/plugin.tgz"
  archive_list="$tmp_dir/archive.list"
  archive_types="$tmp_dir/archive.types"
  unpacked="$tmp_dir/unpacked"

  log "Installing $TABBY_OSC_NOTIFY_NAME@$TABBY_OSC_NOTIFY_VERSION"
  if ! fetch_url "$TABBY_OSC_NOTIFY_TARBALL_URL" "$archive"; then
    warn "Failed to download $TABBY_OSC_NOTIFY_TARBALL_URL"
    return 1
  fi
  if ! actual_sha="$(sha256_file "$archive")"; then
    return 1
  fi
  if [ "$actual_sha" != "$TABBY_OSC_NOTIFY_SHA256" ]; then
    warn "SHA-256 mismatch for $TABBY_OSC_NOTIFY_NAME: $actual_sha"
    return 1
  fi
  if ! tar -tzf "$archive" >"$archive_list"; then
    warn "Cannot list $TABBY_OSC_NOTIFY_NAME archive"
    return 1
  fi
  if ! tabby_plugin_archive_list_is_safe "$archive_list"; then
    warn "Unsafe paths in $TABBY_OSC_NOTIFY_NAME archive"
    return 1
  fi
  if ! LC_ALL=C tar -tvzf "$archive" >"$archive_types"; then
    warn "Cannot inspect $TABBY_OSC_NOTIFY_NAME archive member types"
    return 1
  fi
  if ! tabby_plugin_archive_types_are_safe "$archive_types"; then
    warn "Unsafe member types in $TABBY_OSC_NOTIFY_NAME archive"
    return 1
  fi

  mkdir -p "$unpacked"
  if ! tar -xzf "$archive" -C "$unpacked"; then
    warn "Cannot extract $TABBY_OSC_NOTIFY_NAME archive"
    return 1
  fi
  staged="$unpacked/package"
  if ! chmod -R u+rwX "$staged"; then
    warn "Cannot repair permissions for $TABBY_OSC_NOTIFY_NAME"
    return 1
  fi
  if ! tabby_osc_notify_package_is_valid "$staged"; then
    warn "Unexpected package metadata for $TABBY_OSC_NOTIFY_NAME"
    return 1
  fi

  if [ -e "$target" ] || [ -L "$target" ]; then
    mkdir -p "$plugin_root/backups"
    backup="$(next_tabby_plugin_backup_path "$plugin_root" "$TABBY_OSC_NOTIFY_NAME")"
    log "Backing up $target -> $backup"
    if ! mv "$target" "$backup"; then
      warn "Cannot back up existing $TABBY_OSC_NOTIFY_NAME"
      return 1
    fi
  fi

  if ! mv "$staged" "$target"; then
    if [ -n "$backup" ]; then
      mv "$backup" "$target" || warn "Cannot restore $backup"
    fi
    warn "Cannot install $TABBY_OSC_NOTIFY_NAME into $target"
    return 1
  fi

  log "Installed $TABBY_OSC_NOTIFY_NAME@$TABBY_OSC_NOTIFY_VERSION; restart Tabby to load it"
}

install_tabby_payload() {
  if skip_tabby; then
    log "Skipping Tabby config and plugins (DOTFILES_SKIP_TABBY is enabled)"
  else
    install_tabby_config
    install_tabby_osc_notify
  fi
}

install_config_payload() {
  local cfg
  cfg="$(config_home)"

  ensure_base_dirs
  install_codex_notifications
  link_or_copy "$REPO_ROOT/config/zsh/.zshrc" "$HOME/.zshrc"
  link_or_copy "$REPO_ROOT/config/zsh/.p10k.zsh" "$HOME/.p10k.zsh"
  link_or_copy "$REPO_ROOT/config/tmux/.tmux.conf" "$HOME/.tmux.conf"
  link_or_copy "$REPO_ROOT/config/tmux-powerline" "$cfg/tmux-powerline"
  install_tabby_payload
  link_or_copy "$REPO_ROOT/config/nvim" "$cfg/nvim"
  link_or_copy "$REPO_ROOT/config/yazi" "$cfg/yazi"

  if [ -f "$REPO_ROOT/config/lazygit/config.yml" ]; then
    link_or_copy "$REPO_ROOT/config/lazygit" "$cfg/lazygit"
  fi

  if is_windows; then
    install_windows_mirrors
  fi
}

install_windows_mirrors() {
  local appdata localappdata appdata_unix localappdata_unix

  appdata_unix="$(windows_to_unix_path "${APPDATA:-}")"
  localappdata_unix="$(windows_to_unix_path "${LOCALAPPDATA:-}")"

  if [ -n "$localappdata_unix" ]; then
    link_or_copy "$REPO_ROOT/config/nvim" "$localappdata_unix/nvim"
  fi

  if [ -n "$appdata_unix" ]; then
    mkdir -p "$appdata_unix/yazi"
    link_or_copy "$REPO_ROOT/config/yazi" "$appdata_unix/yazi/config"

    if [ -f "$REPO_ROOT/config/lazygit/config.yml" ]; then
      link_or_copy "$REPO_ROOT/config/lazygit" "$appdata_unix/lazygit"
    fi
  fi
}

clone_repo_at_ref() {
  local repo_url="$1"
  local ref="$2"
  local target_dir="$3"
  local current_ref

  if [ -d "$target_dir/.git" ]; then
    current_ref="$(git -C "$target_dir" rev-parse HEAD 2>/dev/null || true)"
    if ! force_install && [ "$current_ref" = "$ref" ]; then
      log "Reusing pinned checkout: $target_dir"
      return 0
    fi
    git -C "$target_dir" remote set-url origin "$repo_url"
  else
    if [ -e "$target_dir" ]; then
      die "plugin target exists but is not a git repository: $target_dir"
    fi
    mkdir -p "$(dirname "$target_dir")"
    git init -q "$target_dir"
    git -C "$target_dir" remote add origin "$repo_url"
  fi

  log "Fetching pinned checkout: $target_dir"
  if ! git -C "$target_dir" fetch --depth 1 origin "$ref"; then
    warn "Shallow fetch failed for $repo_url; retrying with tags"
    git -C "$target_dir" fetch --tags --force origin
  fi
  git -C "$target_dir" checkout --force --detach "$ref"
}

install_oh_my_zsh_stack() {
  log "Installing pinned oh-my-zsh stack"
  clone_repo_at_ref "$OH_MY_ZSH_REPO" "$OH_MY_ZSH_REF" "$HOME/.oh-my-zsh"
  clone_repo_at_ref "$POWERLEVEL10K_REPO" "$POWERLEVEL10K_REF" "$HOME/.oh-my-zsh/custom/themes/powerlevel10k"
  clone_repo_at_ref "$ZSH_AUTOSUGGESTIONS_REPO" "$ZSH_AUTOSUGGESTIONS_REF" "$HOME/.oh-my-zsh/custom/plugins/zsh-autosuggestions"
  clone_repo_at_ref "$ZSH_SYNTAX_HIGHLIGHTING_REPO" "$ZSH_SYNTAX_HIGHLIGHTING_REF" "$HOME/.oh-my-zsh/custom/plugins/zsh-syntax-highlighting"
}

install_tmux_plugins() {
  log "Installing pinned tmux plugins"
  clone_repo_at_ref "$TPM_REPO" "$TPM_REF" "$HOME/.tmux/plugins/tpm"
  clone_repo_at_ref "$TMUX_SENSIBLE_REPO" "$TMUX_SENSIBLE_REF" "$HOME/.tmux/plugins/tmux-sensible"
  clone_repo_at_ref "$TMUX_YANK_REPO" "$TMUX_YANK_REF" "$HOME/.tmux/plugins/tmux-yank"
  clone_repo_at_ref "$TMUX_RESURRECT_REPO" "$TMUX_RESURRECT_REF" "$HOME/.tmux/plugins/tmux-resurrect"
  clone_repo_at_ref "$TMUX_CONTINUUM_REPO" "$TMUX_CONTINUUM_REF" "$HOME/.tmux/plugins/tmux-continuum"
  clone_repo_at_ref "$TMUX_POWERLINE_REPO" "$TMUX_POWERLINE_REF" "$HOME/.tmux/plugins/tmux-powerline"
}

fetch_url() {
  local url="$1"
  local output="$2"

  if have curl; then
    curl -fsSL \
      --retry 3 \
      --retry-delay 1 \
      --connect-timeout 15 \
      "$url" -o "$output"
  elif have wget; then
    wget --tries=3 --timeout=15 -qO "$output" "$url"
  else
    die "need curl or wget to download $url"
  fi
}

github_latest_asset_url() {
  local repo="$1"
  local pattern="$2"

  need_cmd python3
  python3 "$REPO_ROOT/bootstrap/github_release_asset.py" "$repo" "$pattern"
}

linux_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo "x86_64" ;;
    arm64|aarch64) echo "arm64" ;;
    *) die "unsupported architecture: $(uname -m)" ;;
  esac
}

install_neovim_linux() {
  local arch asset url tmp_dir extracted

  arch="$(linux_arch)"
  case "$arch" in
    x86_64) asset="nvim-linux-x86_64.tar.gz" ;;
    arm64) asset="nvim-linux-arm64.tar.gz" ;;
  esac

  url="https://github.com/neovim/neovim/releases/latest/download/${asset}"
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' RETURN

  log "Installing Neovim from $url"
  fetch_url "$url" "$tmp_dir/$asset"
  tar -xzf "$tmp_dir/$asset" -C "$tmp_dir"
  extracted="$(find "$tmp_dir" -maxdepth 1 -type d -name 'nvim-*' | head -n 1)"
  [ -n "$extracted" ] || die "failed to unpack Neovim archive"

  rm -rf "$HOME/.local/opt/nvim"
  mv "$extracted" "$HOME/.local/opt/nvim"
  ln -sf "$HOME/.local/opt/nvim/bin/nvim" "$HOME/.local/bin/nvim"
}

install_lazygit_linux() {
  local arch pattern url tmp_dir asset_name

  arch="$(linux_arch)"
  case "$arch" in
    x86_64) pattern='[Ll]inux_x86_64\.tar\.gz$' ;;
    arm64) pattern='[Ll]inux_arm64\.tar\.gz$' ;;
  esac

  url="$(github_latest_asset_url 'jesseduffield/lazygit' "$pattern")"
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' RETURN
  asset_name="$(basename "$url")"

  log "Installing Lazygit from $url"
  fetch_url "$url" "$tmp_dir/$asset_name"
  tar -xzf "$tmp_dir/$asset_name" -C "$tmp_dir"
  install -m 0755 "$tmp_dir/lazygit" "$HOME/.local/bin/lazygit"
}

install_yazi_linux() {
  local arch pattern url tmp_dir asset_name unpacked

  arch="$(linux_arch)"
  case "$arch" in
    x86_64) pattern='x86_64-unknown-linux-musl\.zip$' ;;
    arm64) pattern='aarch64-unknown-linux-musl\.zip$' ;;
  esac

  url="$(github_latest_asset_url 'sxyazi/yazi' "$pattern")"
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' RETURN
  asset_name="$(basename "$url")"

  log "Installing Yazi from $url"
  fetch_url "$url" "$tmp_dir/$asset_name"
  unzip -q "$tmp_dir/$asset_name" -d "$tmp_dir"
  unpacked="$(find "$tmp_dir" -maxdepth 1 -type d -name 'yazi-*' | head -n 1)"
  [ -n "$unpacked" ] || die "failed to unpack Yazi archive"

  install -m 0755 "$unpacked/yazi" "$HOME/.local/bin/yazi"
  install -m 0755 "$unpacked/ya" "$HOME/.local/bin/ya"
}

install_tabby_linux() {
  local arch pattern url tmp_dir asset_name

  arch="$(linux_arch)"
  case "$arch" in
    x86_64) pattern='tabby-[0-9.]+-linux-x64\.deb$' ;;
    arm64) pattern='tabby-[0-9.]+-linux-arm64\.deb$' ;;
  esac

  url="$(github_latest_asset_url 'Eugeny/tabby' "$pattern")"
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' RETURN
  asset_name="$(basename "$url")"

  log "Installing Tabby from $url"
  fetch_url "$url" "$tmp_dir/$asset_name"
  run_root apt-get install -y "$tmp_dir/$asset_name"
}

msys2_mingw_prefix() {
  case "${MSYSTEM:-UCRT64}" in
    UCRT64) echo "mingw-w64-ucrt-x86_64" ;;
    CLANG64) echo "mingw-w64-clang-x86_64" ;;
    CLANGARM64) echo "mingw-w64-clang-aarch64" ;;
    MINGW64) echo "mingw-w64-x86_64" ;;
    *) die "unsupported MSYSTEM: ${MSYSTEM:-unset}" ;;
  esac
}

msys2_install_packages() {
  local prefix required optional pkg
  prefix="$(msys2_mingw_prefix)"
  required=(
    git
    zsh
    tmux
    curl
    tar
    unzip
    file
    ${prefix}-neovim
    ${prefix}-ripgrep
    ${prefix}-fd
    ${prefix}-fzf
    ${prefix}-yazi
  )
  optional=(
    ${prefix}-bat
    ${prefix}-eza
    ${prefix}-direnv
    ${prefix}-jq
    ${prefix}-python
  )

  log "Updating MSYS2 package database"
  pacman -Sy --noconfirm
  log "Installing required MSYS2 packages"
  pacman -S --needed --noconfirm "${required[@]}"

  for pkg in "${optional[@]}"; do
    if pacman -Si "$pkg" >/dev/null 2>&1; then
      pacman -S --needed --noconfirm "$pkg"
    else
      warn "MSYS2 package not available, skipping: $pkg"
    fi
  done
}
