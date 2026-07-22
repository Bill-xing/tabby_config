#!/usr/bin/env bash

# Host-sensitive operations are kept behind small functions so this installer can
# be tested without consulting or changing the machine running the test suite.

if ! declare -F docker_command_discovery >/dev/null 2>&1; then
  docker_command_discovery() {
    command -v "$1"
  }
fi

if ! declare -F docker_execute >/dev/null 2>&1; then
  docker_execute() {
    "$@"
  }
fi

if ! declare -F run_docker_sudo >/dev/null 2>&1; then
  run_docker_sudo() {
    sudo "$@"
  }
fi

if ! declare -F docker_systemctl >/dev/null 2>&1; then
  docker_systemctl() {
    local scope="$1"
    shift
    case "$scope" in
      system) run_docker_sudo systemctl "$@" ;;
      user) systemctl --user "$@" ;;
      *) return 2 ;;
    esac
  }
fi

if ! declare -F docker_current_uid >/dev/null 2>&1; then
  docker_current_uid() {
    id -u
  }
fi

if ! declare -F docker_current_user >/dev/null 2>&1; then
  docker_current_user() {
    id -un
  }
fi

if ! declare -F docker_dpkg_architecture >/dev/null 2>&1; then
  docker_dpkg_architecture() {
    dpkg --print-architecture
  }
fi

if ! declare -F docker_package_installed >/dev/null 2>&1; then
  docker_package_installed() {
    [ "$(dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null || true)" = installed ]
  }
fi

if ! declare -F docker_fetch_url >/dev/null 2>&1; then
  docker_fetch_url() {
    fetch_url "$@"
  }
fi

if ! declare -F docker_github_latest_asset_url >/dev/null 2>&1; then
  docker_github_latest_asset_url() {
    github_latest_asset_url "$@"
  }
fi

if ! declare -F run_rootless_docker_installer >/dev/null 2>&1; then
  run_rootless_docker_installer() {
    sh "$1"
  }
fi

if ! declare -F docker_os_release_value >/dev/null 2>&1; then
  docker_os_release_value() {
    local key="$1"
    awk -F= -v key="$key" '
      $1 == key {
        value=substr($0, index($0, "=") + 1)
        gsub(/^\047|\047$/, "", value)
        gsub(/^"|"$/, "", value)
        print value
        exit
      }
    ' /etc/os-release
  }
fi

if ! declare -F docker_subordinate_id_total >/dev/null 2>&1; then
  docker_subordinate_id_total() {
    local kind="$1" user="$2" uid="$3"
    awk -F: -v user="$user" -v uid="$uid" '
      ($1 == user || $1 == uid) && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ { total += $3 }
      END { print total + 0 }
    ' "/etc/$kind" 2>/dev/null
  }
fi

_docker_find_command() {
  local candidate

  candidate="$(docker_command_discovery docker 2>/dev/null || true)"
  [ -n "$candidate" ] || return 1
  printf '%s\n' "$candidate"
}

_docker_client_works() {
  docker_execute "$1" --version >/dev/null 2>&1
}

_docker_probe_existing() {
  local docker="$1" version warnings=false

  version="$(docker_execute "$docker" --version 2>/dev/null)" || return 1
  log "Reusing existing Docker client: $version"

  if ! docker_execute "$docker" compose version >/dev/null 2>&1; then
    warn 'Docker Compose is unavailable; keeping the existing Docker installation unchanged'
    warnings=true
  fi
  if ! docker_execute "$docker" buildx version >/dev/null 2>&1; then
    warn 'Docker Buildx is unavailable; keeping the existing Docker installation unchanged'
    warnings=true
  fi
  if ! docker_execute "$docker" info >/dev/null 2>&1; then
    warn 'the Docker daemon is unavailable to this user; keeping the existing Docker installation unchanged'
    warnings=true
  fi

  SERVER_DOCKER_REUSED_WITH_WARNINGS="$warnings"
  export SERVER_DOCKER_REUSED_WITH_WARNINGS
}

_docker_validate_ubuntu() {
  local os_id codename architecture

  os_id="$(docker_os_release_value ID 2>/dev/null || true)"
  if [ "$os_id" != ubuntu ]; then
    warn "official Docker Engine system installation requires Ubuntu (detected: ${os_id:-unknown})"
    return 1
  fi
  codename="$(docker_os_release_value UBUNTU_CODENAME 2>/dev/null || true)"
  if [ -z "$codename" ]; then
    codename="$(docker_os_release_value VERSION_CODENAME 2>/dev/null || true)"
  fi
  if [ -z "$codename" ]; then
    warn 'cannot determine the Ubuntu codename from /etc/os-release'
    return 1
  fi
  architecture="$(docker_dpkg_architecture 2>/dev/null || true)"
  if [ -z "$architecture" ]; then
    warn 'cannot determine the dpkg architecture for Docker installation'
    return 1
  fi
  printf '%s\t%s\n' "$codename" "$architecture"
}

_docker_refuse_conflicting_packages() {
  local package
  local -a conflicts=()
  local -a candidates=(
    docker.io docker-compose docker-compose-v2 docker-doc podman-docker containerd runc
  )

  for package in "${candidates[@]}"; do
    if docker_package_installed "$package"; then
      conflicts+=("$package")
    fi
  done
  if [ "${#conflicts[@]}" -gt 0 ]; then
    warn "Docker CLI is unusable and conflicting packages are installed: ${conflicts[*]}"
    warn "review the impact, then remove them with: sudo apt-get remove ${conflicts[*]}"
    return 1
  fi
}

_docker_configure_apt_and_install() {
  local codename="$1" architecture="$2" tmp_dir key source

  (
    tmp_dir="$(mktemp -d)" || {
      warn 'failed to create a temporary directory for Docker repository setup'
      exit 1
    }
    trap 'rm -rf "$tmp_dir"' EXIT
    key="$tmp_dir/docker.asc"
    source="$tmp_dir/docker.sources"

    if ! docker_fetch_url 'https://download.docker.com/linux/ubuntu/gpg' "$key"; then
      warn 'failed to download the official Docker apt signing key'
      exit 1
    fi
    if [ ! -s "$key" ]; then
      warn 'the downloaded Docker apt signing key is empty'
      exit 1
    fi
    if ! cat >"$source" <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $codename
Components: stable
Architectures: $architecture
Signed-By: /etc/apt/keyrings/docker.asc
EOF
    then
      warn 'failed to generate the Docker apt source'
      exit 1
    fi

    run_docker_sudo install -m 0755 -d /etc/apt/keyrings || {
      warn 'failed to create /etc/apt/keyrings for Docker'
      exit 1
    }
    run_docker_sudo install -m 0644 "$key" /etc/apt/keyrings/docker.asc || {
      warn 'failed to install the Docker apt signing key'
      exit 1
    }
    run_docker_sudo install -m 0644 "$source" /etc/apt/sources.list.d/docker.sources || {
      warn 'failed to install the Docker apt source'
      exit 1
    }
    run_docker_sudo apt-get update || {
      warn 'apt-get update failed for the Docker repository'
      exit 1
    }
    run_docker_sudo apt-get install -y \
      docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || {
      warn 'apt-get install failed for the official Docker packages'
      exit 1
    }
  )
}

_docker_install_system() {
  local platform codename architecture docker user

  platform="$(_docker_validate_ubuntu)" || return 1
  IFS=$'\t' read -r codename architecture <<<"$platform"
  _docker_refuse_conflicting_packages || return 1
  _docker_configure_apt_and_install "$codename" "$architecture" || return 1

  if ! docker_systemctl system enable --now docker; then
    warn 'failed to enable and start the system Docker service'
    return 1
  fi
  user="$(docker_current_user 2>/dev/null || true)"
  if [ -z "$user" ]; then
    warn 'cannot determine the current user for Docker group membership'
    return 1
  fi
  if ! run_docker_sudo usermod -aG docker "$user"; then
    warn "failed to add $user to the docker group"
    return 1
  fi
  SERVER_DOCKER_NEEDS_RELOGIN=true
  export SERVER_DOCKER_NEEDS_RELOGIN

  docker="$(_docker_find_command)" || {
    warn 'Docker package installation did not provide a discoverable docker command'
    return 1
  }
  _docker_client_works "$docker" || {
    warn 'installed Docker client verification failed: docker --version'
    return 1
  }
  docker_execute "$docker" buildx version >/dev/null 2>&1 || {
    warn 'installed Docker Buildx verification failed'
    return 1
  }
  docker_execute "$docker" compose version >/dev/null 2>&1 || {
    warn 'installed Docker Compose verification failed'
    return 1
  }
  run_docker_sudo "$docker" info >/dev/null 2>&1 || {
    warn 'installed Docker daemon verification failed through sudo docker info'
    return 1
  }
  log 'Installed the official Docker Engine packages; log out and back in to activate docker group membership'
}

_docker_require_rootless_prerequisites() {
  local uid user subuid_total subgid_total

  uid="$(docker_current_uid 2>/dev/null || true)"
  if [ -z "$uid" ] || [ "$uid" = 0 ]; then
    warn 'rootless Docker requires a non-root user; sign in as the intended user and rerun the installer'
    return 1
  fi
  user="$(docker_current_user 2>/dev/null || true)"
  if [ -z "$user" ]; then
    warn 'cannot determine the non-root user for rootless Docker'
    return 1
  fi
  if ! docker_command_discovery newuidmap >/dev/null 2>&1; then
    warn 'newuidmap is required for rootless Docker; ask an administrator to run: sudo apt-get install uidmap'
    return 1
  fi
  if ! docker_command_discovery newgidmap >/dev/null 2>&1; then
    warn 'newgidmap is required for rootless Docker; ask an administrator to run: sudo apt-get install uidmap'
    return 1
  fi
  subuid_total="$(docker_subordinate_id_total subuid "$user" "$uid" 2>/dev/null || true)"
  case "$subuid_total" in ''|*[!0-9]*) subuid_total=0 ;; esac
  if [ "$subuid_total" -lt 65536 ]; then
    warn "rootless Docker needs at least 65536 subordinate UIDs for $user; ask an administrator to run: sudo usermod --add-subuids 100000-165535 $user"
    return 1
  fi
  subgid_total="$(docker_subordinate_id_total subgid "$user" "$uid" 2>/dev/null || true)"
  case "$subgid_total" in ''|*[!0-9]*) subgid_total=0 ;; esac
  if [ "$subgid_total" -lt 65536 ]; then
    warn "rootless Docker needs at least 65536 subordinate GIDs for $user; ask an administrator to run: sudo usermod --add-subgids 100000-165535 $user"
    return 1
  fi
  if ! docker_systemctl user show-environment >/dev/null 2>&1; then
    warn 'rootless Docker requires a usable systemctl --user session; enable user systemd and rerun the installer'
    return 1
  fi
}

_docker_download_rootless_installer() {
  local tmp_dir installer

  (
    umask 077
    tmp_dir="$(mktemp -d)" || {
      warn 'failed to create a private temporary directory for rootless Docker'
      exit 1
    }
    trap 'rm -rf "$tmp_dir"' EXIT
    installer="$tmp_dir/rootless.sh"
    if ! docker_fetch_url 'https://get.docker.com/rootless' "$installer"; then
      warn 'failed to download the rootless Docker installer'
      exit 1
    fi
    if [ ! -s "$installer" ]; then
      warn 'the downloaded rootless Docker installer is empty; refusing to execute it'
      exit 1
    fi
    if ! run_rootless_docker_installer "$installer"; then
      warn 'rootless Docker installer failed'
      exit 1
    fi
  )
}

_docker_add_home_bin_to_path() {
  local home_bin="$HOME/bin"
  case ":$PATH:" in
    *":$home_bin:"*) ;;
    *) PATH="$home_bin:$PATH" ;;
  esac
  export PATH
}

_docker_verify_checksum_manifest() {
  local binary="$1" manifest="$2" asset expected actual

  asset="$(basename "$binary")"
  expected="$(awk -v asset="$asset" '
    $2 == asset || $2 == "*" asset { print $1; exit }
  ' "$manifest")"
  if ! [[ "$expected" =~ ^[[:xdigit:]]{64}$ ]]; then
    warn "checksum manifest has no valid entry for $asset"
    return 1
  fi
  actual="$(sha256_file "$binary")" || {
    warn "failed to calculate the checksum for $asset"
    return 1
  }
  if [ "${actual,,}" != "${expected,,}" ]; then
    warn "checksum mismatch for $asset; refusing to install it"
    return 1
  fi
}

_docker_install_user_plugin() {
  local docker="$1" plugin="$2" arch="$3" repo asset_pattern checksum_pattern
  local tmp_dir url checksum_url binary manifest target

  if docker_execute "$docker" "$plugin" version >/dev/null 2>&1; then
    log "Reusing working Docker $plugin plugin"
    return 0
  fi

  case "$plugin:$arch" in
    buildx:x86_64) repo=docker/buildx; asset_pattern='^buildx-v[^/]*\.linux-amd64$' ;;
    buildx:arm64) repo=docker/buildx; asset_pattern='^buildx-v[^/]*\.linux-arm64$' ;;
    compose:x86_64) repo=docker/compose; asset_pattern='^docker-compose-linux-x86_64$' ;;
    compose:arm64) repo=docker/compose; asset_pattern='^docker-compose-linux-aarch64$' ;;
    *)
      warn "unsupported architecture for the Docker $plugin plugin: $arch"
      return 1
      ;;
  esac
  checksum_pattern='^checksums\.txt$'
  url="$(docker_github_latest_asset_url "$repo" "$asset_pattern")" || {
    warn "cannot resolve the official Docker $plugin release asset"
    return 1
  }
  checksum_url="$(docker_github_latest_asset_url "$repo" "$checksum_pattern")" || {
    warn "cannot resolve the official Docker $plugin checksum manifest"
    return 1
  }

  (
    umask 077
    tmp_dir="$(mktemp -d)" || {
      warn "failed to create a temporary directory for Docker $plugin"
      exit 1
    }
    trap 'rm -rf "$tmp_dir"' EXIT
    binary="$tmp_dir/$(basename "$url")"
    manifest="$tmp_dir/checksums.txt"
    if ! docker_fetch_url "$url" "$binary"; then
      warn "failed to download the official Docker $plugin plugin"
      exit 1
    fi
    if [ ! -s "$binary" ]; then
      warn "the downloaded Docker $plugin plugin is empty; refusing to install it"
      exit 1
    fi
    if ! docker_fetch_url "$checksum_url" "$manifest"; then
      warn "failed to download the Docker $plugin checksum manifest"
      exit 1
    fi
    if [ ! -s "$manifest" ]; then
      warn "the downloaded Docker $plugin checksum manifest is empty"
      exit 1
    fi
    _docker_verify_checksum_manifest "$binary" "$manifest" || exit 1
    chmod 0755 "$binary" || exit 1

    target="$HOME/.docker/cli-plugins/docker-$plugin"
    mkdir -p "$(dirname "$target")" || exit 1
    if [ -e "$target" ] || [ -L "$target" ]; then
      backup_existing "$target" || exit 1
    fi
    install -m 0755 "$binary" "$target" || {
      warn "failed to install Docker $plugin at $target"
      exit 1
    }
  )
}

_docker_install_rootless() {
  local docker arch uid

  _docker_require_rootless_prerequisites || return 1
  arch="$(linux_arch 2>/dev/null || true)"
  case "$arch" in
    x86_64|arm64) ;;
    *)
      warn "unsupported architecture for rootless Docker plugins: ${arch:-unknown}"
      return 1
      ;;
  esac
  _docker_download_rootless_installer || return 1
  _docker_add_home_bin_to_path

  docker="$(_docker_find_command)" || {
    warn "rootless Docker installation did not provide $HOME/bin/docker or another discoverable docker command"
    return 1
  }
  _docker_client_works "$docker" || {
    warn 'rootless Docker client verification failed: docker --version'
    return 1
  }
  _docker_install_user_plugin "$docker" buildx "$arch" || return 1
  _docker_install_user_plugin "$docker" compose "$arch" || return 1

  if ! docker_systemctl user enable --now docker; then
    warn 'failed to enable and start the user Docker service'
    return 1
  fi
  uid="$(docker_current_uid)" || return 1
  DOCKER_HOST="unix:///run/user/$uid/docker.sock"
  SERVER_ROOTLESS_DOCKER=true
  export DOCKER_HOST SERVER_ROOTLESS_DOCKER

  docker_execute "$docker" info >/dev/null 2>&1 || {
    warn "rootless Docker daemon is not reachable at $DOCKER_HOST"
    return 1
  }
  docker_execute "$docker" buildx version >/dev/null 2>&1 || {
    warn 'rootless Docker Buildx verification failed'
    return 1
  }
  docker_execute "$docker" compose version >/dev/null 2>&1 || {
    warn 'rootless Docker Compose verification failed'
    return 1
  }
  log 'Installed rootless Docker with Buildx and Compose'
}

install_docker() {
  local docker=''

  : "${SERVER_DOCKER_REUSED_WITH_WARNINGS:=false}"
  : "${SERVER_DOCKER_NEEDS_RELOGIN:=false}"
  : "${SERVER_ROOTLESS_DOCKER:=false}"

  docker="$(_docker_find_command 2>/dev/null || true)"
  if [ -n "$docker" ] && _docker_client_works "$docker"; then
    _docker_probe_existing "$docker"
    return
  fi

  if server_has_sudo; then
    _docker_install_system
  else
    _docker_install_rootless
  fi
}
