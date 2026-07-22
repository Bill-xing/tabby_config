#!/usr/bin/env bash

_TABBY_UBUNTU_USER_SOURCED=false
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  _TABBY_UBUNTU_USER_SOURCED=true
  case "$-" in *e*) _TABBY_UBUNTU_USER_ERREXIT=true ;; *) _TABBY_UBUNTU_USER_ERREXIT=false ;; esac
  case "$-" in *u*) _TABBY_UBUNTU_USER_NOUNSET=true ;; *) _TABBY_UBUNTU_USER_NOUNSET=false ;; esac
  if shopt -qo pipefail; then
    _TABBY_UBUNTU_USER_PIPEFAIL=true
  else
    _TABBY_UBUNTU_USER_PIPEFAIL=false
  fi
fi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bootstrap/common.sh
source "$SCRIPT_DIR/../bootstrap/common.sh"
# shellcheck source=bootstrap/server/environment.sh
source "$SCRIPT_DIR/../bootstrap/server/environment.sh"
# shellcheck source=bootstrap/server/miniforge.sh
source "$SCRIPT_DIR/../bootstrap/server/miniforge.sh"
# shellcheck source=bootstrap/server/monitoring.sh
source "$SCRIPT_DIR/../bootstrap/server/monitoring.sh"
# shellcheck source=bootstrap/server/docker.sh
source "$SCRIPT_DIR/../bootstrap/server/docker.sh"
# shellcheck source=bootstrap/server/codex.sh
source "$SCRIPT_DIR/../bootstrap/server/codex.sh"

if [ "$_TABBY_UBUNTU_USER_SOURCED" = true ]; then
  [ "$_TABBY_UBUNTU_USER_ERREXIT" = true ] || set +e
  [ "$_TABBY_UBUNTU_USER_NOUNSET" = true ] || set +u
  [ "$_TABBY_UBUNTU_USER_PIPEFAIL" = true ] || set +o pipefail
  unset _TABBY_UBUNTU_USER_ERREXIT _TABBY_UBUNTU_USER_NOUNSET
  unset _TABBY_UBUNTU_USER_PIPEFAIL _TABBY_UBUNTU_USER_SOURCED
fi

local_user_tool_usable() {
  local binary="$1"
  local path="$HOME/.local/bin/$binary"

  [ -x "$path" ] && "$path" --version >/dev/null 2>&1
}

install_user_local_zsh() {
  local tmp_dir target deb status

  target="$HOME/.local/opt/zsh"
  if ! force_install \
    && [ -x "$target/root/bin/zsh" ] \
    && "$target/root/bin/zsh" --version >/dev/null 2>&1; then
    log "Reusing user-local zsh"
    mkdir -p "$target/startup" "$HOME/.local/bin"
    status=$?
    [ "$status" -eq 0 ] || return "$status"
    install -m 0755 "$REPO_ROOT/bootstrap/user-local-zsh" "$HOME/.local/bin/zsh"
    status=$?
    [ "$status" -eq 0 ] || return "$status"
    install -m 0644 "$REPO_ROOT/bootstrap/user-local-zshenv" "$target/startup/.zshenv"
    status=$?
    [ "$status" -eq 0 ] || return "$status"
    return 0
  fi

  tmp_dir="$(mktemp -d)"
  status=$?
  [ "$status" -eq 0 ] || return "$status"

  log "Downloading Ubuntu zsh packages without root privileges"
  if ! (
    cd "$tmp_dir"
    env \
      -u http_proxy -u https_proxy -u all_proxy \
      -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
      apt-get download zsh zsh-common
  ); then
    warn "Direct package download failed; retrying with the current proxy environment"
    (cd "$tmp_dir" && apt-get download zsh zsh-common)
    status=$?
    if [ "$status" -ne 0 ]; then
      rm -rf "$tmp_dir" || true
      return "$status"
    fi
  fi

  rm -rf "$target"
  status=$?
  if [ "$status" -ne 0 ]; then
    rm -rf "$tmp_dir" || true
    return "$status"
  fi
  mkdir -p "$target/root" "$target/startup" "$HOME/.local/bin"
  status=$?
  if [ "$status" -ne 0 ]; then
    rm -rf "$tmp_dir" || true
    return "$status"
  fi
  for deb in "$tmp_dir"/*.deb; do
    dpkg-deb -x "$deb" "$target/root"
    status=$?
    if [ "$status" -ne 0 ]; then
      rm -rf "$tmp_dir" || true
      return "$status"
    fi
  done

  if [ ! -x "$target/root/bin/zsh" ]; then
    rm -rf "$tmp_dir" || true
    die "failed to extract the zsh binary"
  fi
  install -m 0755 "$REPO_ROOT/bootstrap/user-local-zsh" "$HOME/.local/bin/zsh"
  status=$?
  if [ "$status" -ne 0 ]; then
    rm -rf "$tmp_dir" || true
    return "$status"
  fi
  install -m 0644 "$REPO_ROOT/bootstrap/user-local-zshenv" "$target/startup/.zshenv"
  status=$?
  if [ "$status" -ne 0 ]; then
    rm -rf "$tmp_dir" || true
    return "$status"
  fi
  rm -rf "$tmp_dir"
}

install_github_archive_binary() {
  local repo="$1"
  local pattern="$2"
  local binary="$3"
  local url tmp_dir asset_name binary_path status

  if ! force_install && local_user_tool_usable "$binary"; then
    log "Reusing user-local $binary"
    return 0
  fi

  url="$(github_latest_asset_url "$repo" "$pattern")"
  status=$?
  [ "$status" -eq 0 ] || return "$status"
  tmp_dir="$(mktemp -d)"
  status=$?
  [ "$status" -eq 0 ] || return "$status"
  asset_name="$(basename "$url")"

  log "Installing $binary from $url"
  fetch_url "$url" "$tmp_dir/$asset_name"
  status=$?
  if [ "$status" -ne 0 ]; then
    rm -rf "$tmp_dir" || true
    return "$status"
  fi
  case "$asset_name" in
    *.tar.gz) tar -xzf "$tmp_dir/$asset_name" -C "$tmp_dir" ;;
    *.zip) unzip -q "$tmp_dir/$asset_name" -d "$tmp_dir" ;;
    *) die "unsupported archive for $binary: $asset_name" ;;
  esac
  status=$?
  if [ "$status" -ne 0 ]; then
    rm -rf "$tmp_dir" || true
    return "$status"
  fi

  binary_path="$(find "$tmp_dir" -type f -name "$binary" | head -n 1)"
  status=$?
  if [ "$status" -ne 0 ] || [ -z "$binary_path" ]; then
    rm -rf "$tmp_dir" || true
    if [ "$status" -ne 0 ]; then
      return "$status"
    fi
    die "failed to find $binary in $asset_name"
  fi
  install -m 0755 "$binary_path" "$HOME/.local/bin/$binary"
  status=$?
  if [ "$status" -ne 0 ]; then
    rm -rf "$tmp_dir" || true
    return "$status"
  fi
  rm -rf "$tmp_dir"
}

install_github_binary() {
  local repo="$1"
  local pattern="$2"
  local binary="$3"
  local url tmp_dir status

  if ! force_install && local_user_tool_usable "$binary"; then
    log "Reusing user-local $binary"
    return 0
  fi

  url="$(github_latest_asset_url "$repo" "$pattern")"
  status=$?
  [ "$status" -eq 0 ] || return "$status"
  tmp_dir="$(mktemp -d)"
  status=$?
  [ "$status" -eq 0 ] || return "$status"

  log "Installing $binary from $url"
  fetch_url "$url" "$tmp_dir/$binary"
  status=$?
  if [ "$status" -ne 0 ]; then
    rm -rf "$tmp_dir" || true
    return "$status"
  fi
  install -m 0755 "$tmp_dir/$binary" "$HOME/.local/bin/$binary"
  status=$?
  if [ "$status" -ne 0 ]; then
    rm -rf "$tmp_dir" || true
    return "$status"
  fi
  rm -rf "$tmp_dir"
}

install_user_cli_stack() {
  local arch status
  local fzf_pattern fd_pattern rg_pattern bat_pattern delta_pattern eza_pattern zoxide_pattern
  local direnv_pattern jq_pattern

  arch="$(linux_arch)"
  case "$arch" in
    x86_64)
      fzf_pattern='linux_amd64\.tar\.gz$'
      fd_pattern='x86_64-unknown-linux-musl\.tar\.gz$'
      rg_pattern='x86_64-unknown-linux-musl\.tar\.gz$'
      bat_pattern='x86_64-unknown-linux-musl\.tar\.gz$'
      delta_pattern='x86_64-unknown-linux-musl\.tar\.gz$'
      eza_pattern='x86_64-unknown-linux-musl\.tar\.gz$'
      zoxide_pattern='x86_64-unknown-linux-musl\.tar\.gz$'
      direnv_pattern='direnv\.linux-amd64$'
      jq_pattern='jq-linux-amd64$'
      ;;
    arm64)
      fzf_pattern='linux_arm64\.tar\.gz$'
      fd_pattern='aarch64-unknown-linux-musl\.tar\.gz$'
      rg_pattern='aarch64-unknown-linux-musl\.tar\.gz$'
      bat_pattern='aarch64-unknown-linux-musl\.tar\.gz$'
      delta_pattern='aarch64-unknown-linux-musl\.tar\.gz$'
      eza_pattern='aarch64-unknown-linux-musl\.tar\.gz$'
      zoxide_pattern='aarch64-unknown-linux-musl\.tar\.gz$'
      direnv_pattern='direnv\.linux-arm64$'
      jq_pattern='jq-linux-arm64$'
      ;;
  esac

  install_github_archive_binary junegunn/fzf "$fzf_pattern" fzf
  status=$?
  [ "$status" -eq 0 ] || return "$status"
  install_github_archive_binary sharkdp/fd "$fd_pattern" fd
  status=$?
  [ "$status" -eq 0 ] || return "$status"
  install_github_archive_binary BurntSushi/ripgrep "$rg_pattern" rg
  status=$?
  [ "$status" -eq 0 ] || return "$status"
  install_github_archive_binary sharkdp/bat "$bat_pattern" bat
  status=$?
  [ "$status" -eq 0 ] || return "$status"
  install_github_archive_binary dandavison/delta "$delta_pattern" delta
  status=$?
  [ "$status" -eq 0 ] || return "$status"
  install_github_archive_binary eza-community/eza "$eza_pattern" eza
  status=$?
  [ "$status" -eq 0 ] || return "$status"
  install_github_archive_binary ajeetdsouza/zoxide "$zoxide_pattern" zoxide
  status=$?
  [ "$status" -eq 0 ] || return "$status"
  install_github_binary direnv/direnv "$direnv_pattern" direnv
  status=$?
  [ "$status" -eq 0 ] || return "$status"
  install_github_binary jqlang/jq "$jq_pattern" jq
}

tree_sitter_cli_usable() {
  local version

  version="$(tree-sitter --version 2>/dev/null | awk 'NR == 1 { print $2 }')" || return 1
  [ -n "$version" ] || return 1
  python3 -c \
    'import sys; parts = tuple(map(int, sys.argv[1].split(".")[:3])); raise SystemExit(parts < (0, 26, 1))' \
    "$version"
}

install_user_tree_sitter_cli() {
  local arch rust_target tmp_dir cargo_bin status
  local -a cargo_force

  if ! force_install && have tree-sitter && tree_sitter_cli_usable; then
    log "Using compatible tree-sitter CLI: $(tree-sitter --version)"
    return 0
  fi

  arch="$(linux_arch)"
  status=$?
  [ "$status" -eq 0 ] || return "$status"
  case "$arch" in
    x86_64) rust_target="x86_64-unknown-linux-gnu" ;;
    arm64) rust_target="aarch64-unknown-linux-gnu" ;;
  esac

  if have cargo; then
    cargo_bin="$(command -v cargo)"
  else
    tmp_dir="$(mktemp -d)"
    status=$?
    [ "$status" -eq 0 ] || return "$status"
    log "Installing a minimal Rust toolchain for tree-sitter CLI"
    fetch_url \
      "https://static.rust-lang.org/rustup/dist/${rust_target}/rustup-init" \
      "$tmp_dir/rustup-init"
    status=$?
    if [ "$status" -ne 0 ]; then
      rm -rf "$tmp_dir" || true
      return "$status"
    fi
    chmod 0755 "$tmp_dir/rustup-init"
    status=$?
    if [ "$status" -ne 0 ]; then
      rm -rf "$tmp_dir" || true
      return "$status"
    fi
    "$tmp_dir/rustup-init" -y --profile minimal --no-modify-path
    status=$?
    if [ "$status" -ne 0 ]; then
      rm -rf "$tmp_dir" || true
      return "$status"
    fi
    rm -rf "$tmp_dir"
    status=$?
    [ "$status" -eq 0 ] || return "$status"
    cargo_bin="$HOME/.cargo/bin/cargo"
  fi

  [ -x "$cargo_bin" ] || die "failed to install cargo for tree-sitter CLI"
  cargo_force=()
  if force_install; then
    cargo_force=(--force)
  fi
  log "Building tree-sitter CLI 0.26.11 for this server"
  "$cargo_bin" install tree-sitter-cli \
    --version 0.26.11 \
    --locked \
    --no-default-features \
    "${cargo_force[@]}" \
    --root "$HOME/.local/opt/tree-sitter-cli"
  status=$?
  [ "$status" -eq 0 ] || return "$status"
  install -m 0755 \
    "$HOME/.local/opt/tree-sitter-cli/bin/tree-sitter" \
    "$HOME/.local/bin/tree-sitter"
}

install_user_release_tool() {
  local binary="$1"
  local installer="$2"

  if ! force_install && local_user_tool_usable "$binary"; then
    log "Reusing user-local $binary"
    return 0
  fi
  "$installer"
}

install_ssh_zsh_handoff() {
  local bashrc="$HOME/.bashrc"
  local marker="# >>> tabby_config user-local zsh >>>" status

  if flag_enabled "${DOTFILES_SKIP_SSH_ZSH_HANDOFF:-0}"; then
    log "Skipping interactive SSH zsh handoff"
    return 0
  fi

  touch "$bashrc"
  status=$?
  [ "$status" -eq 0 ] || return "$status"
  if grep -Fq "$marker" "$bashrc"; then
    log "Reusing existing interactive SSH zsh handoff"
    return 0
  fi

  log "Enabling user-local zsh for interactive SSH terminals"
  cat >>"$bashrc" <<'EOF'

# >>> tabby_config user-local zsh >>>
# Keep non-interactive SSH commands (scp/rsync/remote commands) on bash.
if [ -n "${SSH_CONNECTION:-}" ] && [ -t 0 ] && [ -t 1 ] \
  && [ -x "$HOME/.local/bin/zsh" ] && [ -z "${ZSH_VERSION:-}" ]; then
  exec "$HOME/.local/bin/zsh" -l
fi
# <<< tabby_config user-local zsh <<<
EOF
  status=$?
  [ "$status" -eq 0 ] || return "$status"
}

server_git() {
  git "$@"
}

configure_server_git_identity() {
  local status

  server_git config --global user.name Bill-xing
  status=$?
  [ "$status" -eq 0 ] || return "$status"
  server_git config --global user.email bill.xjm@gmail.com
}

prepend_server_user_paths() {
  local directory

  for directory in "$HOME/.cargo/bin" "$HOME/.local/bin"; do
    case ":$PATH:" in
      *":$directory:"*) ;;
      *) PATH="$directory:$PATH" ;;
    esac
  done
  export PATH
}

server_conda_usable() {
  "$1" --version >/dev/null 2>&1
}

server_monitoring_tool_usable() {
  tool_usable "$1"
}

server_monitoring_tool_path() {
  monitoring_command_discovery "$1"
}

server_docker_version() {
  docker_execute "$1" --version
}

codex_server_config_managed() {
  local source_file="$REPO_ROOT/config/codex/server.toml"
  local merger="$REPO_ROOT/bootstrap/merge_codex_config.py"
  local target="${CODEX_HOME:-$HOME/.codex}/config.toml"

  [ -f "$source_file" ] && [ -f "$merger" ] && [ -f "$target" ] || return 1
  python3 "$merger" "$source_file" "$target" | cmp -s - "$target"
}

record_codex_npm_action() {
  local target

  target="$(pretty_mermaid_target)" || return 1
  if ! force_install &&
    pretty_mermaid_existing_reusable "$target" >/dev/null 2>&1 &&
    pretty_mermaid_dependencies_ready "$target" >/dev/null 2>&1; then
    SERVER_CODEX_NPM_ACTION=not-needed
  elif codex_npm_discovery npm >/dev/null 2>&1 &&
    codex_node_discovery node >/dev/null 2>&1; then
    SERVER_CODEX_NPM_ACTION=installed
  else
    SERVER_CODEX_NPM_ACTION=skipped-missing-node-or-npm
  fi
  export SERVER_CODEX_NPM_ACTION
}

select_server_docker_binary() {
  local docker

  if [ -n "${SERVER_DOCKER_BIN:-}" ]; then
    return 0
  fi
  docker="$(_docker_find_command 2>/dev/null || true)"
  if [ -z "$docker" ]; then
    warn 'Docker installation completed without a selected Docker binary'
    return 1
  fi
  SERVER_DOCKER_BIN="$docker"
  export SERVER_DOCKER_BIN
}

verify_server_bootstrap() {
  local actual conda docker docker_version target tool tool_path
  local monitoring_locations=''

  actual="$(server_git config --global --get user.name 2>/dev/null || true)"
  if [ "$actual" != Bill-xing ]; then
    warn 'server Git identity verification failed for user.name'
    return 1
  fi
  actual="$(server_git config --global --get user.email 2>/dev/null || true)"
  if [ "$actual" != bill.xjm@gmail.com ]; then
    warn 'server Git identity verification failed for user.email'
    return 1
  fi

  conda="$(conda_bin 2>/dev/null || true)"
  if [ -z "$conda" ] || ! server_conda_usable "$conda"; then
    warn 'server bootstrap verification failed: conda is not usable'
    return 1
  fi
  SERVER_CONDA_BIN="$conda"
  export SERVER_CONDA_BIN

  for tool in nvitop btop htop; do
    if ! server_monitoring_tool_usable "$tool"; then
      warn "server bootstrap verification failed: $tool is not usable"
      return 1
    fi
    tool_path="$(server_monitoring_tool_path "$tool" 2>/dev/null || true)"
    [ -n "$tool_path" ] || tool_path="$tool"
    monitoring_locations="${monitoring_locations}${monitoring_locations:+ }${tool}=${tool_path}"
  done
  SERVER_MONITORING_LOCATIONS="$monitoring_locations"
  export SERVER_MONITORING_LOCATIONS

  select_server_docker_binary || return 1
  docker="${SERVER_DOCKER_BIN:-}"
  if [ -z "$docker" ]; then
    warn 'server bootstrap verification failed: no Docker binary was selected'
    return 1
  fi
  docker_version="$(server_docker_version "$docker" 2>/dev/null || true)"
  if [ -z "$docker_version" ]; then
    warn "server bootstrap verification failed: $docker --version is unusable"
    return 1
  fi
  SERVER_DOCKER_VERSION="$docker_version"
  export SERVER_DOCKER_VERSION
  if flag_enabled "${SERVER_DOCKER_REUSED_WITH_WARNINGS:-false}"; then
    warn 'the existing Docker installation was kept unchanged with optional capability or daemon warnings'
  fi

  if ! codex_usable; then
    warn 'server bootstrap verification failed: Codex is not usable'
    return 1
  fi
  if ! codex_plugin_installed figma@openai-curated; then
    warn 'server bootstrap verification failed: figma@openai-curated is not installed'
    return 1
  fi
  if ! codex_plugin_installed superpowers@openai-curated; then
    warn 'server bootstrap verification failed: superpowers@openai-curated is not installed'
    return 1
  fi
  target="$(pretty_mermaid_target)" || return 1
  if ! pretty_mermaid_existing_reusable "$target"; then
    warn 'server bootstrap verification failed: pretty-mermaid pinned source is invalid'
    return 1
  fi
  if ! pretty_mermaid_dependencies_ready "$target"; then
    if codex_npm_discovery npm >/dev/null 2>&1 &&
      codex_node_discovery node >/dev/null 2>&1; then
      warn 'server bootstrap verification failed: pretty-mermaid runtime dependencies are invalid'
      return 1
    fi
    warn 'pretty-mermaid source is valid, but Node.js/npm is unavailable so rendering dependencies remain optional'
  fi
  if ! codex_server_config_managed; then
    warn 'server bootstrap verification failed: Codex config is missing or does not match the managed merge result'
    return 1
  fi
}

summarize_server_bootstrap() {
  log 'Done. Complete Ubuntu user bootstrap verified.'
  log 'Tabby was not installed or configured.'
  log "User-local CLI tools: $HOME/.local/bin"
  log "Conda: ${SERVER_CONDA_BIN:-unavailable}"
  log "Monitoring: ${SERVER_MONITORING_LOCATIONS:-unavailable}"
  log "Docker: ${SERVER_DOCKER_BIN:-unavailable} (${SERVER_DOCKER_VERSION:-version unavailable})"
  log "Shell environment: ${XDG_CONFIG_HOME:-$HOME/.config}/tabby-config/server-env.sh"
  log "Codex: ${CODEX_HOME:-$HOME/.codex}"

  if flag_enabled "${SERVER_ROOTLESS_DOCKER:-false}"; then
    log 'Docker mode: rootless; the user systemd Docker service was enabled and started.'
  elif flag_enabled "${SERVER_DOCKER_NEEDS_RELOGIN:-false}"; then
    log 'Docker mode: system; log out and back in to activate docker group membership.'
  else
    log 'Docker mode: existing installation kept unchanged.'
  fi
  if flag_enabled "${SERVER_DOCKER_REUSED_WITH_WARNINGS:-false}"; then
    warn 'Existing Docker was reused with warnings; missing Compose, Buildx, or daemon access was not reinstalled or treated as fatal.'
  fi

  case "${SERVER_CODEX_NPM_ACTION:-unknown}" in
    installed) log 'Codex pretty-mermaid npm action: installed or repaired locked runtime dependencies.' ;;
    not-needed) log 'Codex pretty-mermaid npm action: not needed; locked runtime dependencies were already ready.' ;;
    skipped-missing-node-or-npm) warn 'Codex pretty-mermaid npm action: skipped because Node.js or npm is unavailable.' ;;
    *) warn 'Codex pretty-mermaid npm action could not be determined.' ;;
  esac
  log 'Run again to repair links quickly, or set DOTFILES_FORCE_INSTALL=1 to reinstall tools.'
}

main() {
  local proxy_candidate conda_enabled=false status

  is_linux || die "install/ubuntu-user.sh must be run on Linux"
  need_cmd apt-get
  status=$?
  [ "$status" -eq 0 ] || return "$status"
  need_cmd cc
  status=$?
  [ "$status" -eq 0 ] || return "$status"
  need_cmd cmp
  status=$?
  [ "$status" -eq 0 ] || return "$status"
  need_cmd curl
  status=$?
  [ "$status" -eq 0 ] || return "$status"
  need_cmd dpkg-deb
  status=$?
  [ "$status" -eq 0 ] || return "$status"
  need_cmd file
  status=$?
  [ "$status" -eq 0 ] || return "$status"
  need_cmd git
  status=$?
  [ "$status" -eq 0 ] || return "$status"
  need_cmd python3
  status=$?
  [ "$status" -eq 0 ] || return "$status"
  need_cmd tar
  status=$?
  [ "$status" -eq 0 ] || return "$status"
  need_cmd tmux
  status=$?
  [ "$status" -eq 0 ] || return "$status"
  need_cmd unzip
  status=$?
  [ "$status" -eq 0 ] || return "$status"

  proxy_candidate="$(detect_proxy_candidate)"
  status=$?
  [ "$status" -eq 0 ] || return "$status"
  if sudo_available; then
    SERVER_HAS_SUDO=true
  else
    SERVER_HAS_SUDO=false
  fi
  export SERVER_HAS_SUDO

  prepend_server_user_paths
  ensure_base_dirs
  status=$?
  [ "$status" -eq 0 ] || return "$status"
  install_user_local_zsh
  status=$?
  [ "$status" -eq 0 ] || return "$status"
  install_user_cli_stack
  status=$?
  [ "$status" -eq 0 ] || return "$status"
  install_user_tree_sitter_cli
  status=$?
  [ "$status" -eq 0 ] || return "$status"
  install_user_release_tool nvim install_neovim_linux
  status=$?
  [ "$status" -eq 0 ] || return "$status"
  install_user_release_tool lazygit install_lazygit_linux
  status=$?
  [ "$status" -eq 0 ] || return "$status"
  install_user_release_tool yazi install_yazi_linux
  status=$?
  [ "$status" -eq 0 ] || return "$status"

  if [ -f "$HOME/.zshrc" ] && [ ! -L "$HOME/.zshrc" ] && [ ! -e "$HOME/.zshrc.local" ]; then
    log "Preserving the existing machine-specific zsh config as ~/.zshrc.local"
    cp "$HOME/.zshrc" "$HOME/.zshrc.local"
    status=$?
    [ "$status" -eq 0 ] || return "$status"
  fi

  install_oh_my_zsh_stack
  status=$?
  [ "$status" -eq 0 ] || return "$status"
  install_tmux_plugins
  status=$?
  [ "$status" -eq 0 ] || return "$status"
  DOTFILES_SKIP_TABBY=1 \
    DOTFILES_SKIP_CODEX_SERVER_CONFIG=1 \
    install_config_payload
  status=$?
  [ "$status" -eq 0 ] || return "$status"
  install_ssh_zsh_handoff
  status=$?
  [ "$status" -eq 0 ] || return "$status"

  install_miniforge
  status=$?
  [ "$status" -eq 0 ] || return "$status"
  install_monitoring_tools
  status=$?
  [ "$status" -eq 0 ] || return "$status"
  install_docker
  status=$?
  [ "$status" -eq 0 ] || return "$status"
  configure_server_git_identity
  status=$?
  [ "$status" -eq 0 ] || return "$status"
  if [ -x "$HOME/miniforge3/bin/conda" ] &&
    server_conda_usable "$HOME/miniforge3/bin/conda"; then
    conda_enabled=true
  fi
  write_server_shell_environment \
    "$proxy_candidate" \
    "$conda_enabled" \
    "${SERVER_ROOTLESS_DOCKER:-false}"
  status=$?
  [ "$status" -eq 0 ] || return "$status"
  record_codex_npm_action
  status=$?
  [ "$status" -eq 0 ] || return "$status"
  install_codex_server
  status=$?
  [ "$status" -eq 0 ] || return "$status"
  verify_server_bootstrap
  status=$?
  [ "$status" -eq 0 ] || return "$status"
  summarize_server_bootstrap
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
