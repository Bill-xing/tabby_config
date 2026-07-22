#!/usr/bin/env bash

conda_discovery() {
  command -v conda
}

conda_bin() {
  local candidate command_type

  candidate="$(conda_discovery 2>/dev/null || true)"
  command_type="$(type -t conda 2>/dev/null || true)"
  if [ "$candidate" = conda ] && [ "$command_type" = function ]; then
    printf '%s\n' conda
    return 0
  fi
  case "$candidate" in
    /*|./*|../*)
      if [ -x "$candidate" ]; then
        printf '%s\n' "$candidate"
        return 0
      fi
      ;;
  esac

  if [ -x "$HOME/miniforge3/bin/conda" ]; then
    printf '%s\n' "$HOME/miniforge3/bin/conda"
    return 0
  fi

  return 1
}

run_miniforge_installer() {
  bash "$@"
}

_miniforge_conda_works() {
  "$1" --version >/dev/null 2>&1
}

_miniforge_configure_conda() {
  local conda="$1"

  if ! "$conda" config --set auto_activate_base false; then
    warn "failed to disable Miniforge base auto-activation: $conda"
    return 1
  fi
}

install_miniforge() {
  local current_conda='' home_conda arch asset url tmp_dir installer checksum_file expected_sha actual_sha
  local -a installer_args

  home_conda="$HOME/miniforge3/bin/conda"
  if current_conda="$(conda_bin)" && _miniforge_conda_works "$current_conda"; then
    log "Reusing existing conda: $current_conda"
    _miniforge_configure_conda "$current_conda"
    return
  fi

  if [ "$current_conda" != "$home_conda" ] && [ -x "$home_conda" ] && _miniforge_conda_works "$home_conda"; then
    log "Reusing existing Miniforge conda: $home_conda"
    _miniforge_configure_conda "$home_conda"
    return
  fi

  if ! arch="$(linux_arch)"; then
    warn 'cannot determine architecture for Miniforge installation'
    return 1
  fi
  case "$arch" in
    x86_64) asset='Miniforge3-Linux-x86_64.sh' ;;
    arm64) asset='Miniforge3-Linux-aarch64.sh' ;;
    *)
      warn "unsupported architecture for Miniforge: $arch"
      return 1
      ;;
  esac

  url="https://github.com/conda-forge/miniforge/releases/latest/download/${asset}"
  (
    if ! tmp_dir="$(mktemp -d)"; then
      warn 'failed to create a temporary directory for Miniforge installation'
      exit 1
    fi
    trap 'rm -rf "$tmp_dir"' EXIT

    installer="$tmp_dir/$asset"
    checksum_file="$installer.sha256"
    log "Downloading Miniforge from $url"
    if ! fetch_url "$url" "$installer"; then
      warn "failed to download Miniforge installer: $url"
      exit 1
    fi
    if ! fetch_url "${url}.sha256" "$checksum_file"; then
      warn "failed to download Miniforge checksum: ${url}.sha256"
      exit 1
    fi

    expected_sha="$(awk 'NF { print $1; exit }' "$checksum_file")"
    if ! [[ "$expected_sha" =~ ^[[:xdigit:]]{64}$ ]]; then
      warn "malformed Miniforge SHA-256 checksum: $checksum_file"
      exit 1
    fi
    if ! actual_sha="$(sha256_file "$installer")"; then
      warn "failed to calculate Miniforge SHA-256 checksum: $installer"
      exit 1
    fi
    if [ "${actual_sha,,}" != "${expected_sha,,}" ]; then
      warn 'Miniforge installer SHA-256 checksum mismatch; refusing to execute it'
      exit 1
    fi

    installer_args=("$installer" -b)
    if [ -f "$HOME/miniforge3/conda-meta/history" ]; then
      installer_args+=(-u)
    elif [ -e "$HOME/miniforge3" ] || [ -L "$HOME/miniforge3" ]; then
      log "Backing up unrecognized Miniforge prefix: $HOME/miniforge3"
      if ! backup_existing "$HOME/miniforge3"; then
        warn "failed to back up unrecognized Miniforge prefix: $HOME/miniforge3"
        exit 1
      fi
    fi
    installer_args+=(-p "$HOME/miniforge3")

    if ! run_miniforge_installer "${installer_args[@]}"; then
      warn 'Miniforge installer failed'
      exit 1
    fi
    if [ ! -x "$home_conda" ] || ! _miniforge_conda_works "$home_conda"; then
      warn "Miniforge installation did not produce a usable conda executable: $home_conda"
      exit 1
    fi

    _miniforge_configure_conda "$home_conda"
  )
}
