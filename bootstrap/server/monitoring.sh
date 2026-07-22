#!/usr/bin/env bash

# Server monitoring tools are deliberately installed outside the base conda
# environment so they remain available without changing a user's Python setup.

if ! declare -F run_server_sudo >/dev/null 2>&1; then
  run_server_sudo() {
    sudo "$@"
  }
fi

if ! declare -F monitoring_command_discovery >/dev/null 2>&1; then
  monitoring_command_discovery() {
    command -v "$1"
  }
fi

tool_usable() {
  local tool="$1"
  local executable

  case "$tool" in
    nvitop|btop|htop) ;;
    *) return 1 ;;
  esac
  executable="$(monitoring_command_discovery "$tool" 2>/dev/null)" || return 1
  [ -n "$executable" ] || return 1
  "$executable" --version >/dev/null 2>&1
}

_monitoring_add_local_bin_to_path() {
  local local_bin="$HOME/.local/bin"

  case ":$PATH:" in
    *":$local_bin:"*) ;;
    *) PATH="$local_bin:$PATH" ;;
  esac
  export PATH
}

_monitoring_install_conda_packages() {
  local conda="$1"
  local prefix="$2"
  shift 2
  local -a packages=("$@")

  [ "${#packages[@]}" -gt 0 ] || return 0
  if [ -f "$prefix/conda-meta/history" ]; then
    "$conda" install --yes --prefix "$prefix" "${packages[@]}" || return 1
  else
    if [ -e "$prefix" ] || [ -L "$prefix" ]; then
      backup_existing "$prefix" || return 1
    fi
    "$conda" create --yes --prefix "$prefix" "${packages[@]}" || return 1
  fi
}

_monitoring_link_prefix_tool() {
  local tool="$1"
  local prefix="$2"
  local target="$prefix/bin/$tool"
  local link="$HOME/.local/bin/$tool"

  [ -x "$target" ] || {
    warn "conda installation did not provide $tool at $target"
    return 1
  }
  mkdir -p "$HOME/.local/bin"
  if [ -L "$link" ] && [ "$(readlink "$link")" = "$target" ]; then
    return 0
  fi
  if [ -e "$link" ] || [ -L "$link" ]; then
    backup_existing "$link" || return 1
  fi
  ln -s "$target" "$link"
}

install_monitoring_tools() {
  local conda='' nvitop_prefix rootless_prefix tool has_sudo=false
  local -a missing=() missing_apt=() missing_conda=() linked_tools=()

  for tool in nvitop btop htop; do
    if ! tool_usable "$tool"; then
      missing+=("$tool")
    fi
  done
  [ "${#missing[@]}" -eq 0 ] && return 0

  nvitop_prefix="$HOME/.local/share/tabby-config/nvitop"
  rootless_prefix="$HOME/.local/share/tabby-config/monitoring"

  if server_has_sudo; then
    has_sudo=true
  fi

  if [ "$has_sudo" = false ] || ! tool_usable nvitop; then
    conda="$(conda_bin 2>/dev/null || true)"
    [ -n "$conda" ] && "$conda" --version >/dev/null 2>&1 ||
      die 'a usable conda installation is required to install server monitoring tools'
  fi

  if [ "$has_sudo" = true ]; then
    for tool in btop htop; do
      if ! tool_usable "$tool"; then
        missing_apt+=("$tool")
      fi
    done
    if [ "${#missing_apt[@]}" -gt 0 ]; then
      run_server_sudo apt-get update || die 'apt-get update failed while installing server monitoring tools'
      run_server_sudo apt-get install -y "${missing_apt[@]}" ||
        die 'apt-get install failed while installing server monitoring tools'
    fi
    if ! tool_usable nvitop; then
      _monitoring_install_conda_packages "$conda" "$nvitop_prefix" nvitop ||
        die "conda failed to install nvitop into $nvitop_prefix"
      linked_tools+=(nvitop)
      for tool in "${linked_tools[@]}"; do
        _monitoring_link_prefix_tool "$tool" "$nvitop_prefix" ||
          die "failed to expose $tool from $nvitop_prefix"
      done
    fi
  else
    for tool in nvitop btop htop; do
      if ! tool_usable "$tool"; then
        missing_conda+=("$tool")
      fi
    done
    _monitoring_install_conda_packages "$conda" "$rootless_prefix" "${missing_conda[@]}" ||
      die "conda failed to install monitoring tools into $rootless_prefix"
    for tool in "${missing_conda[@]}"; do
      _monitoring_link_prefix_tool "$tool" "$rootless_prefix" ||
        die "failed to expose $tool from $rootless_prefix"
    done
  fi

  _monitoring_add_local_bin_to_path
  for tool in nvitop btop htop; do
    tool_usable "$tool" || die "installed monitoring tool is not usable: $tool --version failed"
  done
}
