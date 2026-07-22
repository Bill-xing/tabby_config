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

if ! declare -F docker_system_cli_path >/dev/null 2>&1; then
  docker_system_cli_path() {
    printf '%s\n' /usr/bin/docker
  }
fi

if ! declare -F docker_rootless_cli_path >/dev/null 2>&1; then
  docker_rootless_cli_path() {
    printf '%s\n' "$HOME/bin/docker"
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

if ! declare -F docker_stage_plugin_file >/dev/null 2>&1; then
  docker_stage_plugin_file() {
    install -m 0755 "$1" "$2"
  }
fi

if ! declare -F docker_plugin_atomic_move >/dev/null 2>&1; then
  docker_plugin_atomic_move() {
    mv "$1" "$2"
  }
fi

if ! declare -F docker_system_file_status >/dev/null 2>&1; then
  docker_system_file_status() {
    run_docker_sudo sh -c '
      path=$1
      if [ -L "$path" ]; then
        printf "%s\n" symlink
      elif [ -f "$path" ]; then
        printf "%s\n" regular
      elif [ ! -e "$path" ]; then
        printf "%s\n" absent
      else
        printf "%s\n" unsupported
      fi
    ' sh "$1"
  }
fi

if ! declare -F docker_system_copy_file >/dev/null 2>&1; then
  docker_system_copy_file() {
    run_docker_sudo cp -a -- "$1" "$2"
  }
fi

if ! declare -F docker_system_restore_file >/dev/null 2>&1; then
  docker_system_restore_file() {
    run_docker_sudo cp -a -- "$1" "$2"
  }
fi

if ! declare -F docker_system_install_file >/dev/null 2>&1; then
  docker_system_install_file() {
    run_docker_sudo install -m 0644 "$1" "$2"
  }
fi

if ! declare -F docker_system_move_file >/dev/null 2>&1; then
  docker_system_move_file() {
    run_docker_sudo mv -fT -- "$1" "$2"
  }
fi

if ! declare -F docker_system_remove_file >/dev/null 2>&1; then
  docker_system_remove_file() {
    run_docker_sudo rm -f -- "$1"
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

_docker_incomplete_marker_path() {
  printf '%s\n' "${XDG_STATE_HOME:-$HOME/.local/state}/tabby-config/docker-install-incomplete"
}

_docker_mark_incomplete() {
  local branch="$1" marker directory temporary

  marker="$(_docker_incomplete_marker_path)"
  directory="$(dirname "$marker")"
  mkdir -p "$directory" || {
    warn "failed to create Docker installer state directory: $directory"
    return 1
  }
  temporary="$(mktemp "$directory/.docker-install-incomplete.XXXXXX")" || {
    warn 'failed to create a temporary Docker installer state marker'
    return 1
  }
  if ! printf '%s\n' "$branch" >"$temporary" || ! mv "$temporary" "$marker"; then
    rm -f "$temporary"
    warn "failed to record incomplete Docker $branch installation at $marker"
    return 1
  fi
}

_docker_clear_incomplete() {
  local marker
  marker="$(_docker_incomplete_marker_path)"
  rm -f "$marker" || {
    warn "Docker installation succeeded but its incomplete marker could not be cleared: $marker"
    return 1
  }
}

_docker_rootless_socket() {
  local uid

  uid="$(docker_current_uid 2>/dev/null || true)"
  [ -n "$uid" ] || return 1
  printf 'unix:///run/user/%s/docker.sock\n' "$uid"
}

_docker_existing_is_rootless() {
  local docker="$1" context_host rootless_socket selected_endpoint

  # SecurityOptions describes the daemon, not how this client reaches it. Probe
  # it for diagnostics, but never use it alone to publish a local DOCKER_HOST.
  docker_execute "$docker" info --format '{{json .SecurityOptions}}' >/dev/null 2>&1 || true
  context_host="$(
    docker_execute "$docker" context inspect --format '{{.Endpoints.docker.Host}}' 2>/dev/null || true
  )"
  rootless_socket="$(_docker_rootless_socket 2>/dev/null || true)"

  [ -n "$rootless_socket" ] || return 1
  if [ -n "${DOCKER_HOST:-}" ]; then
    selected_endpoint="$DOCKER_HOST"
  else
    selected_endpoint="$context_host"
  fi
  [ "$selected_endpoint" = "$rootless_socket" ]
}

_docker_probe_existing() {
  local docker="$1" version warnings=false rootless_socket

  version="$(docker_execute "$docker" --version 2>/dev/null)" || return 1
  log "Reusing existing Docker client: $version"
  SERVER_DOCKER_BIN="$docker"
  export SERVER_DOCKER_BIN

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
  if _docker_existing_is_rootless "$docker"; then
    SERVER_ROOTLESS_DOCKER=true
    rootless_socket="$(_docker_rootless_socket 2>/dev/null || true)"
    if [ -n "$rootless_socket" ]; then
      DOCKER_HOST="$rootless_socket"
      export DOCKER_HOST
    fi
    export SERVER_ROOTLESS_DOCKER
  fi
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

_docker_ascii_public_key_valid() {
  local -a pipeline_status

  awk '
    state == 0 {
      if ($0 == "-----BEGIN PGP PUBLIC KEY BLOCK-----") { state=1; next }
      if ($0 != "") invalid=1
      next
    }
    state == 1 {
      if ($0 == "-----END PGP PUBLIC KEY BLOCK-----") {
        if (!body) invalid=1
        state=2
        next
      }
      if (!body && ($0 == "" || $0 ~ /^[A-Za-z0-9-]+: /)) next
      if (body && $0 ~ /^=[A-Za-z0-9+\/]{4}$/) next
      if ($0 ~ /^[A-Za-z0-9+\/]+={0,2}$/ && length($0) % 4 == 0) {
        print
        body=1
        next
      }
      invalid=1
      next
    }
    state == 2 && $0 != "" { invalid=1 }
    END { exit invalid || state != 2 || !body }
  ' "$1" | base64 --decode >/dev/null 2>&1
  pipeline_status=("${PIPESTATUS[@]}")
  [ "${pipeline_status[0]}" -eq 0 ] && [ "${pipeline_status[1]}" -eq 0 ]
}

_docker_install_system_transaction() {
  local codename="$1" architecture="$2" user="$3" docker="$4" discovered
  local tmp_dir key source key_path source_path key_stage source_stage key_backup source_backup
  local key_existed=false source_existed=false staging_started=false rollback_needed=false transaction_succeeded=false
  local rollback_failed=false key_status source_status

  (
    tmp_dir="$(mktemp -d)" || {
      warn 'failed to create a temporary directory for Docker repository setup'
      exit 1
    }
    key="$tmp_dir/docker.asc"
    source="$tmp_dir/docker.sources"
    key_backup="$tmp_dir/docker.asc.previous"
    source_backup="$tmp_dir/docker.sources.previous"
    key_path=/etc/apt/keyrings/docker.asc
    source_path=/etc/apt/sources.list.d/docker.sources
    key_stage="${key_path}.tabby-config.stage.$$"
    source_stage="${source_path}.tabby-config.stage.$$"

    _docker_system_transaction_cleanup() {
      local status=$?
      trap - EXIT
      if [ "$transaction_succeeded" != true ] && [ "$rollback_needed" = true ]; then
        if [ "$source_existed" = true ]; then
          if ! docker_system_remove_file "$source_stage" ||
            ! docker_system_restore_file "$source_backup" "$source_stage" ||
            ! docker_system_move_file "$source_stage" "$source_path"; then
            warn "failed to restore previous Docker apt source: $source_path"
            rollback_failed=true
          fi
        elif ! docker_system_remove_file "$source_path"; then
          warn "failed to remove installer-created Docker apt source: $source_path"
          rollback_failed=true
        fi
        if [ "$key_existed" = true ]; then
          if ! docker_system_remove_file "$key_stage" ||
            ! docker_system_restore_file "$key_backup" "$key_stage" ||
            ! docker_system_move_file "$key_stage" "$key_path"; then
            warn "failed to restore previous Docker apt key: $key_path"
            rollback_failed=true
          fi
        elif ! docker_system_remove_file "$key_path"; then
          warn "failed to remove installer-created Docker apt key: $key_path"
          rollback_failed=true
        fi
      fi
      if [ "$staging_started" = true ]; then
        docker_system_remove_file "$source_stage" >/dev/null 2>&1 || true
        docker_system_remove_file "$key_stage" >/dev/null 2>&1 || true
      fi
      if [ "$rollback_failed" = true ]; then
        warn "Docker repository rollback was incomplete; recovery snapshots retained at: $tmp_dir"
      else
        rm -rf "$tmp_dir"
      fi
      exit "$status"
    }
    trap _docker_system_transaction_cleanup EXIT

    if ! docker_fetch_url 'https://download.docker.com/linux/ubuntu/gpg' "$key"; then
      warn 'failed to download the official Docker apt signing key'
      exit 1
    fi
    if [ ! -s "$key" ]; then
      warn 'the downloaded Docker apt signing key is empty'
      exit 1
    fi
    if ! _docker_ascii_public_key_valid "$key"; then
      warn 'the downloaded Docker signing key is not an ASCII-armored PGP PUBLIC KEY BLOCK; refusing publication'
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
    if ! key_status="$(docker_system_file_status "$key_path")"; then
      warn "failed to probe existing Docker apt key path; refusing publication: $key_path"
      exit 1
    fi
    case "$key_status" in
      regular|symlink)
        key_existed=true
        if ! docker_system_copy_file "$key_path" "$key_backup"; then
          warn "failed to snapshot existing Docker apt key: $key_path"
          exit 1
        fi
        ;;
      absent) ;;
      *) warn "unexpected Docker apt key path status '$key_status'; refusing publication: $key_path"; exit 1 ;;
    esac
    if ! source_status="$(docker_system_file_status "$source_path")"; then
      warn "failed to probe existing Docker apt source path; refusing publication: $source_path"
      exit 1
    fi
    case "$source_status" in
      regular|symlink)
        source_existed=true
        if ! docker_system_copy_file "$source_path" "$source_backup"; then
          warn "failed to snapshot existing Docker apt source: $source_path"
          exit 1
        fi
        ;;
      absent) ;;
      *) warn "unexpected Docker apt source path status '$source_status'; refusing publication: $source_path"; exit 1 ;;
    esac

    staging_started=true
    rollback_needed=true
    if ! docker_system_install_file "$key" "$key_stage" ||
      ! docker_system_move_file "$key_stage" "$key_path"; then
      warn 'failed to atomically publish the Docker apt signing key'
      exit 1
    fi
    if ! docker_system_install_file "$source" "$source_stage" ||
      ! docker_system_move_file "$source_stage" "$source_path"; then
      warn 'failed to atomically publish the Docker apt source'
      exit 1
    fi
    run_docker_sudo apt-get update || {
      warn 'apt-get update failed for the Docker repository'
      exit 1
    }
    run_docker_sudo apt-get install -y \
      docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || {
      warn 'apt-get install failed for the official Docker packages'
      exit 1
    }

    if ! docker_systemctl system enable --now docker; then
      warn 'failed to enable and start the system Docker service'
      exit 1
    fi
    if ! run_docker_sudo usermod -aG docker "$user"; then
      warn "failed to add $user to the docker group"
      exit 1
    fi
    discovered="$(_docker_find_command 2>/dev/null || true)"
    if [ "$discovered" != "$docker" ]; then
      warn "PATH resolves docker to ${discovered:-nothing}, not the official package CLI $docker; adjust PATH or remove the shadowing command. Verification will use $docker"
    fi
    _docker_client_works "$docker" || {
      warn "installed Docker client verification failed: $docker --version"
      exit 1
    }
    docker_execute "$docker" buildx version >/dev/null 2>&1 || {
      warn 'installed Docker Buildx verification failed'
      exit 1
    }
    docker_execute "$docker" compose version >/dev/null 2>&1 || {
      warn 'installed Docker Compose verification failed'
      exit 1
    }
    run_docker_sudo "$docker" info >/dev/null 2>&1 || {
      warn 'installed Docker daemon verification failed through sudo docker info'
      exit 1
    }
    transaction_succeeded=true
  )
}

_docker_install_system() {
  local platform codename architecture docker user

  platform="$(_docker_validate_ubuntu)" || return 1
  IFS=$'\t' read -r codename architecture <<<"$platform"
  _docker_refuse_conflicting_packages || return 1
  user="$(docker_current_user 2>/dev/null || true)"
  if [ -z "$user" ]; then
    warn 'cannot determine the current user for Docker group membership'
    return 1
  fi
  docker="$(docker_system_cli_path 2>/dev/null || true)"
  if [ -z "$docker" ]; then
    warn 'cannot determine the official package-owned Docker CLI path'
    return 1
  fi
  _docker_mark_incomplete system || return 1
  _docker_install_system_transaction "$codename" "$architecture" "$user" "$docker" || return 1
  SERVER_DOCKER_NEEDS_RELOGIN=true
  export SERVER_DOCKER_NEEDS_RELOGIN
  SERVER_DOCKER_BIN="$docker"
  export SERVER_DOCKER_BIN
  _docker_clear_incomplete || return 1
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
    warn "/etc/subuid provides $subuid_total subordinate UIDs for $user; rootless Docker requires >=65536 total. Administrator template (choose a non-overlapping range): sudo usermod --add-subuids <START>-<END> $user"
    return 1
  fi
  subgid_total="$(docker_subordinate_id_total subgid "$user" "$uid" 2>/dev/null || true)"
  case "$subgid_total" in ''|*[!0-9]*) subgid_total=0 ;; esac
  if [ "$subgid_total" -lt 65536 ]; then
    warn "/etc/subgid provides $subgid_total subordinate GIDs for $user; rootless Docker requires >=65536 total. Administrator template (choose a non-overlapping range): sudo usermod --add-subgids <START>-<END> $user"
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

_docker_plugin_backup_path() {
  local target="$1" stamp backup suffix=1

  stamp="$(date +%Y%m%d%H%M%S)"
  backup="${target}.bak.${stamp}"
  while [ -e "$backup" ] || [ -L "$backup" ]; do
    backup="${target}.bak.${stamp}.${suffix}"
    suffix=$((suffix + 1))
  done
  printf '%s\n' "$backup"
}

_docker_install_user_plugin() {
  local docker="$1" plugin="$2" arch="$3" repo asset_pattern checksum_pattern
  local tmp_dir url checksum_url binary manifest target plugin_dir staged backup=''
  local rollback_needed=false publication_succeeded=false

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
    _docker_plugin_publication_cleanup() {
      local status=$?
      trap - EXIT
      rm -f "${staged:-}"
      if [ "$publication_succeeded" != true ] && [ "$rollback_needed" = true ]; then
        rm -f "$target"
        if [ -n "$backup" ] && { [ -e "$backup" ] || [ -L "$backup" ]; }; then
          docker_plugin_atomic_move "$backup" "$target" || warn "failed to restore original Docker $plugin plugin from $backup"
        fi
      fi
      rm -rf "$tmp_dir"
      exit "$status"
    }
    trap _docker_plugin_publication_cleanup EXIT
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
    target="$HOME/.docker/cli-plugins/docker-$plugin"
    plugin_dir="$(dirname "$target")"
    mkdir -p "$plugin_dir" || exit 1
    staged="$(mktemp "$plugin_dir/.docker-$plugin.stage.XXXXXX")" || {
      warn "failed to create destination-adjacent staging for Docker $plugin"
      exit 1
    }
    if ! docker_stage_plugin_file "$binary" "$staged"; then
      warn "failed to stage Docker $plugin beside $target"
      exit 1
    fi
    if ! docker_execute "$staged" version >/dev/null 2>&1; then
      warn "staged Docker $plugin failed its own version check; refusing publication"
      exit 1
    fi

    if [ -e "$target" ] || [ -L "$target" ]; then
      backup="$(_docker_plugin_backup_path "$target")"
      log "Backing up $target -> $backup"
      if ! docker_plugin_atomic_move "$target" "$backup"; then
        warn "failed to preserve existing Docker $plugin plugin"
        exit 1
      fi
    fi
    rollback_needed=true
    if ! docker_plugin_atomic_move "$staged" "$target"; then
      warn "failed to atomically publish Docker $plugin at $target"
      exit 1
    fi
    staged=''
    if ! docker_execute "$docker" "$plugin" version >/dev/null 2>&1; then
      warn "published Docker $plugin failed Docker CLI verification; restoring the previous plugin"
      exit 1
    fi
    publication_succeeded=true
  )
}

_docker_install_rootless() {
  local docker='' rootless_docker arch uid

  _docker_require_rootless_prerequisites || return 1
  arch="$(linux_arch 2>/dev/null || true)"
  case "$arch" in
    x86_64|arm64) ;;
    *)
      warn "unsupported architecture for rootless Docker plugins: ${arch:-unknown}"
      return 1
      ;;
  esac
  _docker_mark_incomplete rootless || return 1
  _docker_add_home_bin_to_path
  rootless_docker="$(docker_rootless_cli_path 2>/dev/null || true)"
  if [ -n "$rootless_docker" ] && [ -x "$rootless_docker" ] && _docker_client_works "$rootless_docker"; then
    docker="$rootless_docker"
    log "Resuming with existing rootless Docker client: $docker"
  else
    _docker_download_rootless_installer || return 1
    if [ -n "$rootless_docker" ] && [ -x "$rootless_docker" ] && _docker_client_works "$rootless_docker"; then
      docker="$rootless_docker"
    else
      docker="$(_docker_find_command)" || {
        warn "rootless Docker installation did not provide $HOME/bin/docker or another discoverable docker command"
        return 1
      }
    fi
  fi
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
  SERVER_DOCKER_BIN="$docker"
  export SERVER_DOCKER_BIN
  _docker_clear_incomplete || return 1
  log 'Installed rootless Docker with Buildx and Compose'
}

install_docker() {
  local docker='' marker marker_value branch=''

  SERVER_DOCKER_REUSED_WITH_WARNINGS=false
  SERVER_DOCKER_NEEDS_RELOGIN=false
  SERVER_ROOTLESS_DOCKER=false
  SERVER_DOCKER_BIN=''
  export SERVER_DOCKER_REUSED_WITH_WARNINGS SERVER_DOCKER_NEEDS_RELOGIN
  export SERVER_ROOTLESS_DOCKER SERVER_DOCKER_BIN

  marker="$(_docker_incomplete_marker_path)"
  if [ -e "$marker" ] || [ -L "$marker" ]; then
    if [ ! -r "$marker" ]; then
      warn "Docker incomplete-install marker is not readable: $marker"
      return 1
    fi
    if ! marker_value="$(cat "$marker")"; then
      warn "failed to read Docker incomplete-install marker: $marker"
      return 1
    fi
    if [ "$(wc -l <"$marker")" -ne 1 ]; then
      warn "invalid Docker incomplete-install marker content in $marker; expected exactly one line containing system or rootless"
      return 1
    fi
    case "$marker_value" in
      system|rootless) branch="$marker_value" ;;
      *)
        warn "invalid Docker incomplete-install marker '$marker_value' in $marker; expected exactly system or rootless. Remove or correct the marker after reviewing the interrupted installation"
        return 1
        ;;
    esac
    log "Resuming incomplete Docker $branch installation"
  else
    docker="$(_docker_find_command 2>/dev/null || true)"
    if [ -n "$docker" ] && _docker_client_works "$docker"; then
      _docker_probe_existing "$docker"
      return
    fi
  fi

  if [ -z "$branch" ]; then
    if server_has_sudo; then
      branch=system
    else
      branch=rootless
    fi
  fi
  case "$branch" in
    system) _docker_install_system ;;
    rootless) _docker_install_rootless ;;
  esac
}
