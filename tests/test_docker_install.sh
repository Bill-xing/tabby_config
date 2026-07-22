#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_eq() {
  local expected="$1" actual="$2" message="$3"
  [ "$expected" = "$actual" ] || fail "$message: expected '$expected', got '$actual'"
}

assert_contains() {
  local value="$1" expected="$2" message="$3"
  case "$value" in
    *"$expected"*) ;;
    *) fail "$message: expected '$value' to contain '$expected'" ;;
  esac
}

assert_not_contains() {
  local value="$1" unexpected="$2" message="$3"
  case "$value" in
    *"$unexpected"*) fail "$message: unexpectedly found '$unexpected' in '$value'" ;;
    *) ;;
  esac
}

assert_file_contains() {
  local path="$1" expected="$2" message="$3"
  grep -F -- "$expected" "$path" >/dev/null || fail "$message: missing '$expected'"
}

assert_empty() {
  local path="$1" message="$2"
  [ ! -s "$path" ] || fail "$message: unexpected contents in $path"
}

read_nul_log() {
  NUL_ARGS=()
  [ ! -s "$1" ] || mapfile -d '' -t NUL_ARGS <"$1"
}

assert_temp_targets_removed() {
  local target
  while IFS= read -r target; do
    [ -n "$target" ] || continue
    [ ! -e "$(dirname "$target")" ] || fail "temporary directory was not removed: $(dirname "$target")"
  done <"$FETCH_TARGET_LOG"
}

# shellcheck source=bootstrap/common.sh
source "$REPO_ROOT/bootstrap/common.sh"
# shellcheck source=bootstrap/server/environment.sh
source "$REPO_ROOT/bootstrap/server/environment.sh"
# shellcheck source=bootstrap/server/docker.sh
source "$REPO_ROOT/bootstrap/server/docker.sh"

tmp_root="$(mktemp -d)"
trap 'rm -rf "$tmp_root"' EXIT

default_wrapper_bin="$tmp_root/default-wrapper-bin"
mkdir -p "$default_wrapper_bin"
printf '%s\n' '#!/usr/bin/env bash' \
  'case "$*" in' \
  '  *db:Status-Status*) printf "%s\\n" installed ;;' \
  '  *) printf "%s\\n" "hi " ;;' \
  'esac' >"$default_wrapper_bin/dpkg-query"
chmod +x "$default_wrapper_bin/dpkg-query"
saved_path="$PATH"
PATH="$default_wrapper_bin:/usr/bin:/bin"
if ! docker_package_installed held-docker-package; then
  fail 'default dpkg wrapper recognizes held installed conflict packages'
fi
PATH="$saved_path"

DOCKER_AVAILABLE=false
SUDO_AVAILABLE=false
DOCKER_VERSION_STATUS=0
SHADOW_DOCKER_VERSION_STATUS=0
COMPOSE_STATUS=1
BUILDX_STATUS=1
INFO_STATUS=0
SECURITY_OPTIONS='[]'
CONTEXT_HOST='unix:///var/run/docker.sock'
SUDO_INFO_STATUS=0
ROOTLESS_INSTALL_STATUS=0
USER_SYSTEMCTL_STATUS=0
USER_SERVICE_STATUS=0
SYSTEMCTL_STATUS=0
USERMOD_STATUS=0
APT_UPDATE_STATUS=0
APT_INSTALL_STATUS=0
ARCH=x86_64
MOCK_UID=1000
MOCK_USER=tester
UIDMAP_PRESENT=true
GIDMAP_PRESENT=true
SUBUID_TOTAL=65536
SUBGID_TOTAL=65536
OS_ID=ubuntu
OS_CODENAME=noble
DPKG_ARCH=amd64
BUILDX_CHECKSUM_MODE=good
COMPOSE_CHECKSUM_MODE=good
EMPTY_KIND=''
FETCH_FAIL_KIND=''
LOOKUP_FAIL_KIND=''
APT_PROVIDES_DOCKER=true
APT_PROVIDES_BUILDX=true
APT_PROVIDES_COMPOSE=true
APT_CREATES_SHADOW=false
PLUGIN_STAGE_STATUS=0
PLUGIN_PUBLISH_STATUS=0
STAGED_PLUGIN_STATUS=0
POST_PUBLISH_BUILDX_STATUS=0
POST_PUBLISH_COMPOSE_STATUS=0
GPG_PAYLOAD=$'-----BEGIN PGP PUBLIC KEY BLOCK-----\n\nZG9ja2VyIGdwZyBmaXh0dXJl\n-----END PGP PUBLIC KEY BLOCK-----'
SYSTEM_FILE_FAIL_MATCH=''
SYSTEM_FILE_FAIL_STATUS=0
SYSTEM_FILE_PROBE_STATUS=0
SYSTEM_RESTORE_FAIL_MATCH=''
SYSTEM_RESTORE_FAIL_STATUS=0
declare -A INSTALLED_PACKAGES=()

docker_command_discovery() {
  case "$1" in
    docker)
      if [ "$DOCKER_AVAILABLE" = true ] || [ -e "$MOCK_DOCKER" ]; then
        printf '%s\n' "$MOCK_DOCKER"
      elif [ -e "$MOCK_OFFICIAL_DOCKER" ]; then
        printf '%s\n' "$MOCK_OFFICIAL_DOCKER"
      else
        return 1
      fi
      ;;
    newuidmap) [ "$UIDMAP_PRESENT" = true ] && printf '%s\n' "$MOCK_BIN/newuidmap" ;;
    newgidmap) [ "$GIDMAP_PRESENT" = true ] && printf '%s\n' "$MOCK_BIN/newgidmap" ;;
    *) return 1 ;;
  esac
}

docker_execute() {
  local executable="$1"
  printf '%s\0' "$@" >>"$DOCKER_EXEC_LOG"
  shift
  case "$executable" in
    *.stage.*) [ "$*" = version ] || fail "staged plugin self-check did not use its version command: $*"; return "$STAGED_PLUGIN_STATUS" ;;
  esac
  case "$*" in
    --version)
      printf '%s\n' 'Docker version 99.0.0, build fixture'
      [ "$executable" != "$MOCK_DOCKER" ] || return "$SHADOW_DOCKER_VERSION_STATUS"
      return "$DOCKER_VERSION_STATUS"
      ;;
    'compose version')
      if [ -x "$HOME/.docker/cli-plugins/docker-compose" ]; then return "$POST_PUBLISH_COMPOSE_STATUS"; fi
      [ -e "$MOCK_BIN/compose.ok" ] || return "$COMPOSE_STATUS"
      ;;
    'buildx version')
      if [ -x "$HOME/.docker/cli-plugins/docker-buildx" ]; then return "$POST_PUBLISH_BUILDX_STATUS"; fi
      [ -e "$MOCK_BIN/buildx.ok" ] || return "$BUILDX_STATUS"
      ;;
    info) return "$INFO_STATUS" ;;
    'info --format {{json .SecurityOptions}}')
      [ "$INFO_STATUS" -eq 0 ] || return "$INFO_STATUS"
      printf '%s\n' "$SECURITY_OPTIONS"
      ;;
    'context inspect --format {{.Endpoints.docker.Host}}')
      printf '%s\n' "$CONTEXT_HOST"
      ;;
    *) fail "unexpected docker invocation: $*" ;;
  esac
}

server_has_sudo() {
  printf 'server_has_sudo\n' >>"$DISCOVERY_LOG"
  [ "$SUDO_AVAILABLE" = true ]
}

docker_os_release_value() {
  case "$1" in
    ID) printf '%s\n' "$OS_ID" ;;
    UBUNTU_CODENAME|VERSION_CODENAME) printf '%s\n' "$OS_CODENAME" ;;
    *) return 1 ;;
  esac
}

docker_dpkg_architecture() {
  printf '%s\n' "$DPKG_ARCH"
}

docker_system_cli_path() {
  printf '%s\n' "$MOCK_OFFICIAL_DOCKER"
}

docker_rootless_cli_path() {
  printf '%s\n' "$MOCK_DOCKER"
}

docker_stage_plugin_file() {
  printf '%s\0' "$@" >>"$PLUGIN_FILE_LOG"
  [ "$PLUGIN_STAGE_STATUS" -eq 0 ] || return "$PLUGIN_STAGE_STATUS"
  install -m 0755 "$1" "$2"
}

docker_plugin_atomic_move() {
  printf '%s\0' "$@" >>"$PLUGIN_FILE_LOG"
  case "$1" in
    *.stage.*) [ "$PLUGIN_PUBLISH_STATUS" -eq 0 ] || return "$PLUGIN_PUBLISH_STATUS" ;;
  esac
  mv "$1" "$2"
}

(
  unset -f docker_system_file_status docker_system_move_file
  DEFAULT_SYSTEM_MOVE_LOG="$tmp_root/default-system-move-args.bin"
  : >"$DEFAULT_SYSTEM_MOVE_LOG"
  run_docker_sudo() {
    printf '%s\0' "$@" >>"$DEFAULT_SYSTEM_MOVE_LOG"
    "$@"
  }
  # shellcheck source=bootstrap/server/docker.sh
  source "$REPO_ROOT/bootstrap/server/docker.sh"
  unsupported_path="$tmp_root/default-system-status-directory"
  mkdir -p "$unsupported_path"
  assert_eq unsupported "$(docker_system_file_status "$unsupported_path")" 'default system path probe rejects directories'
  : >"$DEFAULT_SYSTEM_MOVE_LOG"

  exact_stage="$tmp_root/default-system-move-stage"
  exact_target="$tmp_root/default-system-move-target"
  exact_referent="$tmp_root/default-system-move-referent"
  mkdir -p "$exact_referent"
  printf '%s\n' exact-publication >"$exact_stage"
  ln -s "$exact_referent" "$exact_target"
  docker_system_move_file "$exact_stage" "$exact_target"
  [ -f "$exact_target" ] && [ ! -L "$exact_target" ] ||
    fail 'default system publication replaces a symlink-to-directory at the exact target path'
  assert_eq exact-publication "$(<"$exact_target")" 'default system publication writes the staged file at the exact target'
  [ -z "$(find "$exact_referent" -mindepth 1 -print -quit)" ] ||
    fail 'default system publication leaves no artifact inside the symlink referent'
  read_nul_log "$DEFAULT_SYSTEM_MOVE_LOG"
  expected_system_move=(mv -fT -- "$exact_stage" "$exact_target")
  assert_eq "${#expected_system_move[@]}" "${#NUL_ARGS[@]}" 'default system publication uses one exact GNU mv vector'
  for move_index in "${!expected_system_move[@]}"; do
    assert_eq "${expected_system_move[$move_index]}" "${NUL_ARGS[$move_index]}" "default system publication argument $move_index"
  done
)

mock_system_path() {
  case "$1" in
    /etc/apt/keyrings/docker.asc*) printf '%s/keyrings-docker.asc%s\n' "$MOCK_ETC" "${1#/etc/apt/keyrings/docker.asc}" ;;
    /etc/apt/sources.list.d/docker.sources*) printf '%s/docker.sources%s\n' "$MOCK_ETC" "${1#/etc/apt/sources.list.d/docker.sources}" ;;
    /etc/*) printf '%s%s\n' "$MOCK_SYSTEM_ROOT" "$1" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

mock_system_file_maybe_fail() {
  local signature="$1"
  if [ -n "$SYSTEM_FILE_FAIL_MATCH" ] && [[ "$signature" == *"$SYSTEM_FILE_FAIL_MATCH"* ]]; then
    local status="$SYSTEM_FILE_FAIL_STATUS"
    SYSTEM_FILE_FAIL_MATCH=''
    return "$status"
  fi
}

docker_system_file_status() {
  local mapped
  printf '%s\0' status "$1" >>"$SYSTEM_FILE_LOG"
  printf 'status|%s\n' "$1" >>"$SYSTEM_FILE_TEXT_LOG"
  [ "$SYSTEM_FILE_PROBE_STATUS" -eq 0 ] || return "$SYSTEM_FILE_PROBE_STATUS"
  mapped="$(mock_system_path "$1")"
  if [ -L "$mapped" ]; then
    printf '%s\n' symlink
  elif [ -f "$mapped" ]; then
    printf '%s\n' regular
  elif [ ! -e "$mapped" ]; then
    printf '%s\n' absent
  else
    printf '%s\n' unsupported
  fi
}

docker_system_copy_file() {
  local source="$1" destination="$2"
  printf '%s\0' copy "$source" "$destination" >>"$SYSTEM_FILE_LOG"
  printf 'copy|%s|%s\n' "$source" "$destination" >>"$SYSTEM_FILE_TEXT_LOG"
  mock_system_file_maybe_fail "copy:$source:$destination" || return $?
  cp -a "$(mock_system_path "$source")" "$(mock_system_path "$destination")"
}

docker_system_restore_file() {
  local source="$1" destination="$2"
  printf '%s\0' restore "$source" "$destination" >>"$SYSTEM_FILE_LOG"
  printf 'restore|%s|%s\n' "$source" "$destination" >>"$SYSTEM_FILE_TEXT_LOG"
  if [ -n "$SYSTEM_RESTORE_FAIL_MATCH" ] && [[ "$source" == *"$SYSTEM_RESTORE_FAIL_MATCH"* ]]; then
    return "$SYSTEM_RESTORE_FAIL_STATUS"
  fi
  cp -a "$(mock_system_path "$source")" "$(mock_system_path "$destination")"
}

docker_system_install_file() {
  local source="$1" destination="$2" mapped
  printf '%s\0' install "$source" "$destination" >>"$SYSTEM_FILE_LOG"
  printf 'install|%s|%s\n' "$source" "$destination" >>"$SYSTEM_FILE_TEXT_LOG"
  mock_system_file_maybe_fail "install:$source:$destination" || return $?
  mapped="$(mock_system_path "$destination")"
  mkdir -p "$(dirname "$mapped")"
  install -m 0644 "$(mock_system_path "$source")" "$mapped"
}

docker_system_move_file() {
  local source="$1" destination="$2"
  printf '%s\0' move "$source" "$destination" >>"$SYSTEM_FILE_LOG"
  printf 'move|%s|%s\n' "$source" "$destination" >>"$SYSTEM_FILE_TEXT_LOG"
  mock_system_file_maybe_fail "move:$source:$destination" || return $?
  run_docker_sudo mv -fT -- "$source" "$destination"
}

docker_system_remove_file() {
  printf '%s\0' remove "$1" >>"$SYSTEM_FILE_LOG"
  printf 'remove|%s\n' "$1" >>"$SYSTEM_FILE_TEXT_LOG"
  mock_system_file_maybe_fail "remove:$1" || return $?
  rm -f "$(mock_system_path "$1")"
}

docker_package_installed() {
  [ "${INSTALLED_PACKAGES[$1]:-false}" = true ]
}

docker_current_uid() {
  printf '%s\n' "$MOCK_UID"
}

docker_current_user() {
  printf '%s\n' "$MOCK_USER"
}

docker_subordinate_id_total() {
  case "$1" in
    subuid) printf '%s\n' "$SUBUID_TOTAL" ;;
    subgid) printf '%s\n' "$SUBGID_TOTAL" ;;
    *) return 1 ;;
  esac
}

run_docker_sudo() {
  local src target mapped_target
  printf '%s\0' "$@" >>"$SUDO_LOG"
  case "${1:-} ${2:-}" in
    'install -m')
      if [ "${3:-}" = 0755 ] && [ "${4:-}" = -d ]; then
        return 0
      fi
      src="${4:-}"
      target="${5:-}"
      case "$target" in
        /etc/apt/keyrings/docker.asc) cp "$src" "$MOCK_ETC/keyrings-docker.asc" ;;
        /etc/apt/sources.list.d/docker.sources) cp "$src" "$MOCK_ETC/docker.sources" ;;
        *) fail "unexpected sudo install target: $target" ;;
      esac
      ;;
    'mv -fT')
      [ "$#" -eq 5 ] && [ "${3:-}" = -- ] || fail "unexpected sudo mv invocation: $*"
      src="${4:-}"
      target="${5:-}"
      mapped_target="$(mock_system_path "$target")"
      mkdir -p "$(dirname "$mapped_target")"
      mv -fT -- "$(mock_system_path "$src")" "$mapped_target"
      ;;
    'apt-get update') return "$APT_UPDATE_STATUS" ;;
    'apt-get install')
      printf '%s\0' "$@" >>"$APT_INSTALL_LOG"
      [ "$APT_INSTALL_STATUS" -eq 0 ] || return "$APT_INSTALL_STATUS"
      if [ "$APT_PROVIDES_DOCKER" = true ]; then
        : >"$MOCK_OFFICIAL_DOCKER"
        [ "$APT_CREATES_SHADOW" != true ] || : >"$MOCK_DOCKER"
      fi
      [ "$APT_PROVIDES_BUILDX" != true ] || : >"$MOCK_BIN/buildx.ok"
      [ "$APT_PROVIDES_COMPOSE" != true ] || : >"$MOCK_BIN/compose.ok"
      ;;
    'usermod -aG') return "$USERMOD_STATUS" ;;
    *)
      if { [ "${1:-}" = "$MOCK_DOCKER" ] || [ "${1:-}" = "$MOCK_OFFICIAL_DOCKER" ]; } && [ "${2:-}" = info ]; then
        return "$SUDO_INFO_STATUS"
      fi
      fail "unexpected sudo invocation: $*"
      ;;
  esac
}

docker_systemctl() {
  local scope="$1"
  shift
  printf '%s\0' "$scope" "$@" >>"$SYSTEMCTL_LOG"
  case "$scope" in
    system) return "$SYSTEMCTL_STATUS" ;;
    user)
      case "$*" in
        show-environment) return "$USER_SYSTEMCTL_STATUS" ;;
        'enable --now docker') return "$USER_SERVICE_STATUS" ;;
        *) fail "unexpected user systemctl invocation: $*" ;;
      esac
      ;;
    *) fail "unexpected systemctl scope: $scope" ;;
  esac
}

run_rootless_docker_installer() {
  printf '%s\0' "$@" >>"$INSTALLER_LOG"
  [ "$ROOTLESS_INSTALL_STATUS" -eq 0 ] || return "$ROOTLESS_INSTALL_STATUS"
  DOCKER_AVAILABLE=true
  : >"$MOCK_DOCKER"
  chmod +x "$MOCK_DOCKER"
}

docker_github_latest_asset_url() {
  local repo="$1" pattern="$2" lookup_kind url
  printf '%s|%s\n' "$repo" "$pattern" >>"$GITHUB_LOG"
  case "$repo|$pattern" in
    'docker/buildx|'^'buildx-v'*'linux-amd64$') lookup_kind=buildx-release; url='mock://buildx/buildx-v1.linux-amd64' ;;
    'docker/buildx|'^'buildx-v'*'linux-arm64$') lookup_kind=buildx-release; url='mock://buildx/buildx-v1.linux-arm64' ;;
    'docker/buildx|^checksums\.txt$') lookup_kind=buildx-manifest; url='mock://buildx/checksums.txt' ;;
    'docker/compose|^docker-compose-linux-x86_64$') lookup_kind=compose-release; url='mock://compose/docker-compose-linux-x86_64' ;;
    'docker/compose|^docker-compose-linux-aarch64$') lookup_kind=compose-release; url='mock://compose/docker-compose-linux-aarch64' ;;
    'docker/compose|^checksums\.txt$') lookup_kind=compose-manifest; url='mock://compose/checksums.txt' ;;
    *) fail "unexpected GitHub asset lookup: $repo $pattern" ;;
  esac
  [ "$LOOKUP_FAIL_KIND" != "$lookup_kind" ] || return 1
  printf '%s\n' "$url"
}

docker_fetch_url() {
  local url="$1" output="$2" kind payload_name payload hash binary
  printf '%s\n' "$url" >>"$FETCH_URL_LOG"
  printf '%s\n' "$output" >>"$FETCH_TARGET_LOG"
  case "$url" in
    https://download.docker.com/linux/ubuntu/gpg) kind=gpg; payload="$GPG_PAYLOAD" ;;
    https://get.docker.com/rootless) kind=rootless; payload='rootless installer fixture' ;;
    mock://buildx/checksums.txt)
      kind=buildx-checksum
      binary="$LAST_BUILDX_TARGET"
      hash="$(sha256_file "$binary")"
      [ "$BUILDX_CHECKSUM_MODE" != mismatch ] || hash=0000000000000000000000000000000000000000000000000000000000000000
      payload_name="$(basename "$binary")"
      [ "$BUILDX_CHECKSUM_MODE" != missing ] || payload_name=wrong-buildx-name
      payload="$hash  $payload_name"
      ;;
    mock://compose/checksums.txt)
      kind=compose-checksum
      binary="$LAST_COMPOSE_TARGET"
      hash="$(sha256_file "$binary")"
      [ "$COMPOSE_CHECKSUM_MODE" != mismatch ] || hash=0000000000000000000000000000000000000000000000000000000000000000
      payload_name="$(basename "$binary")"
      [ "$COMPOSE_CHECKSUM_MODE" != missing ] || payload_name=wrong-compose-name
      payload="$hash  $payload_name"
      ;;
    mock://buildx/*) kind=buildx; payload='buildx plugin fixture'; LAST_BUILDX_TARGET="$output" ;;
    mock://compose/*) kind=compose; payload='compose plugin fixture'; LAST_COMPOSE_TARGET="$output" ;;
    *) fail "unexpected download: $url" ;;
  esac
  [ "$FETCH_FAIL_KIND" != "$kind" ] || return 1
  if [ "$EMPTY_KIND" = "$kind" ]; then
    : >"$output"
  else
    printf '%s\n' "$payload" >"$output"
  fi
}

reset_case() {
  local name="$1"
  HOME="$tmp_root/$name/home with spaces"
  export HOME
  MOCK_BIN="$tmp_root/$name/mock-bin"
  PATH="$MOCK_BIN:/usr/bin:/bin"
  export PATH
  MOCK_DOCKER="$MOCK_BIN/docker"
  MOCK_OFFICIAL_DOCKER="$tmp_root/$name/usr-bin/docker"
  MOCK_ETC="$tmp_root/$name/etc-capture"
  MOCK_SYSTEM_ROOT="$tmp_root/$name/system-root"
  FETCH_URL_LOG="$tmp_root/$name/fetch-urls.log"
  FETCH_TARGET_LOG="$tmp_root/$name/fetch-targets.log"
  SUDO_LOG="$tmp_root/$name/sudo-args.bin"
  APT_INSTALL_LOG="$tmp_root/$name/apt-install-args.bin"
  SYSTEMCTL_LOG="$tmp_root/$name/systemctl-args.bin"
  DOCKER_EXEC_LOG="$tmp_root/$name/docker-args.bin"
  INSTALLER_LOG="$tmp_root/$name/installer-args.bin"
  GITHUB_LOG="$tmp_root/$name/github.log"
  DISCOVERY_LOG="$tmp_root/$name/discovery.log"
  PLUGIN_FILE_LOG="$tmp_root/$name/plugin-file-args.bin"
  SYSTEM_FILE_LOG="$tmp_root/$name/system-file-args.bin"
  SYSTEM_FILE_TEXT_LOG="$tmp_root/$name/system-file-ops.log"
  CASE_STDOUT="$tmp_root/$name/stdout.log"
  CASE_STDERR="$tmp_root/$name/stderr.log"
  export HOME MOCK_BIN MOCK_DOCKER MOCK_OFFICIAL_DOCKER MOCK_ETC MOCK_SYSTEM_ROOT FETCH_URL_LOG FETCH_TARGET_LOG
  unset XDG_STATE_HOME DOCKER_HOST
  mkdir -p "$HOME" "$MOCK_BIN" "$MOCK_ETC" "$(dirname "$MOCK_OFFICIAL_DOCKER")"
  : >"$FETCH_URL_LOG"
  : >"$FETCH_TARGET_LOG"
  : >"$SUDO_LOG"
  : >"$APT_INSTALL_LOG"
  : >"$SYSTEMCTL_LOG"
  : >"$DOCKER_EXEC_LOG"
  : >"$INSTALLER_LOG"
  : >"$GITHUB_LOG"
  : >"$DISCOVERY_LOG"
  : >"$PLUGIN_FILE_LOG"
  : >"$SYSTEM_FILE_LOG"
  : >"$SYSTEM_FILE_TEXT_LOG"
  : >"$CASE_STDOUT"
  : >"$CASE_STDERR"
  DOCKER_AVAILABLE=false
  SUDO_AVAILABLE=false
  DOCKER_VERSION_STATUS=0
  SHADOW_DOCKER_VERSION_STATUS=0
  COMPOSE_STATUS=1
  BUILDX_STATUS=1
  INFO_STATUS=0
  SECURITY_OPTIONS='[]'
  CONTEXT_HOST='unix:///var/run/docker.sock'
  SUDO_INFO_STATUS=0
  ROOTLESS_INSTALL_STATUS=0
  USER_SYSTEMCTL_STATUS=0
  USER_SERVICE_STATUS=0
  SYSTEMCTL_STATUS=0
  USERMOD_STATUS=0
  APT_UPDATE_STATUS=0
  APT_INSTALL_STATUS=0
  ARCH=x86_64
  MOCK_UID=1000
  MOCK_USER=tester
  UIDMAP_PRESENT=true
  GIDMAP_PRESENT=true
  SUBUID_TOTAL=65536
  SUBGID_TOTAL=65536
  OS_ID=ubuntu
  OS_CODENAME=noble
  DPKG_ARCH=amd64
  BUILDX_CHECKSUM_MODE=good
  COMPOSE_CHECKSUM_MODE=good
  EMPTY_KIND=''
  FETCH_FAIL_KIND=''
  LOOKUP_FAIL_KIND=''
  APT_PROVIDES_DOCKER=true
  APT_PROVIDES_BUILDX=true
  APT_PROVIDES_COMPOSE=true
  APT_CREATES_SHADOW=false
  PLUGIN_STAGE_STATUS=0
  PLUGIN_PUBLISH_STATUS=0
  STAGED_PLUGIN_STATUS=0
  POST_PUBLISH_BUILDX_STATUS=0
  POST_PUBLISH_COMPOSE_STATUS=0
  GPG_PAYLOAD=$'-----BEGIN PGP PUBLIC KEY BLOCK-----\n\nZG9ja2VyIGdwZyBmaXh0dXJl\n-----END PGP PUBLIC KEY BLOCK-----'
  SYSTEM_FILE_FAIL_MATCH=''
  SYSTEM_FILE_FAIL_STATUS=0
  SYSTEM_FILE_PROBE_STATUS=0
  SYSTEM_RESTORE_FAIL_MATCH=''
  SYSTEM_RESTORE_FAIL_STATUS=0
  INSTALLED_PACKAGES=()
  LAST_BUILDX_TARGET=''
  LAST_COMPOSE_TARGET=''
  SERVER_DOCKER_REUSED_WITH_WARNINGS=false
  SERVER_DOCKER_NEEDS_RELOGIN=false
  SERVER_ROOTLESS_DOCKER=false
}

linux_arch() {
  printf '%s\n' "$ARCH"
}

seed_system_repository_files() {
  mkdir -p "$MOCK_ETC"
  printf '%s\n' original-key >"$MOCK_ETC/keyrings-docker.asc"
  printf '%s\n' original-source >"$MOCK_ETC/docker.sources"
  chmod 0600 "$MOCK_ETC/keyrings-docker.asc"
  chmod 0640 "$MOCK_ETC/docker.sources"
}

assert_original_system_repository_files() {
  local message="$1"
  assert_eq original-key "$(<"$MOCK_ETC/keyrings-docker.asc")" "$message restores the original Docker key"
  assert_eq original-source "$(<"$MOCK_ETC/docker.sources")" "$message restores the original Docker source"
  assert_eq 600 "$(stat -c '%a' "$MOCK_ETC/keyrings-docker.asc")" "$message preserves the original key mode"
  assert_eq 640 "$(stat -c '%a' "$MOCK_ETC/docker.sources")" "$message preserves the original source mode"
}

assert_system_repository_files_absent() {
  local message="$1"
  [ ! -e "$MOCK_ETC/keyrings-docker.asc" ] || fail "$message removes the installer-created Docker key"
  [ ! -e "$MOCK_ETC/docker.sources" ] || fail "$message removes the installer-created Docker source"
}

reset_case existing-healthy
DOCKER_AVAILABLE=true
COMPOSE_STATUS=0
BUILDX_STATUS=0
install_docker >"$CASE_STDOUT" 2>"$CASE_STDERR"
assert_contains "$(<"$CASE_STDOUT")" 'Docker version 99.0.0, build fixture' 'existing Docker reports its client version'
assert_empty "$CASE_STDERR" 'healthy existing Docker emits no warnings'
read_nul_log "$DOCKER_EXEC_LOG"
expected_existing_calls=(
  "$MOCK_DOCKER" --version
  "$MOCK_DOCKER" --version
  "$MOCK_DOCKER" compose version
  "$MOCK_DOCKER" buildx version
  "$MOCK_DOCKER" info
  "$MOCK_DOCKER" info --format '{{json .SecurityOptions}}'
  "$MOCK_DOCKER" context inspect --format '{{.Endpoints.docker.Host}}'
)
assert_eq "${#expected_existing_calls[@]}" "${#NUL_ARGS[@]}" 'healthy existing Docker runs only report and capability probes'
for docker_index in "${!expected_existing_calls[@]}"; do
  assert_eq "${expected_existing_calls[$docker_index]}" "${NUL_ARGS[$docker_index]}" "healthy existing Docker argument $docker_index"
done
assert_empty "$DISCOVERY_LOG" 'existing Docker returns before sudo discovery'
assert_empty "$FETCH_URL_LOG" 'existing Docker does not download'
assert_empty "$SUDO_LOG" 'existing Docker does not invoke sudo'
assert_empty "$INSTALLER_LOG" 'existing Docker does not invoke the rootless installer'
assert_empty "$SYSTEMCTL_LOG" 'existing Docker does not manage services'
assert_empty "$GITHUB_LOG" 'existing Docker does not resolve plugin releases'
assert_eq false "$SERVER_DOCKER_REUSED_WITH_WARNINGS" 'healthy Docker has no warning state'

reset_case existing-resets-result-state
DOCKER_AVAILABLE=true
COMPOSE_STATUS=0
BUILDX_STATUS=0
SERVER_DOCKER_REUSED_WITH_WARNINGS=true
SERVER_DOCKER_NEEDS_RELOGIN=true
SERVER_ROOTLESS_DOCKER=true
SERVER_DOCKER_BIN=/stale/docker
install_docker >/dev/null
assert_eq false "$SERVER_DOCKER_REUSED_WITH_WARNINGS" 'existing probe resets stale warning state'
assert_eq false "$SERVER_DOCKER_NEEDS_RELOGIN" 'existing probe resets stale relogin state'
assert_eq false "$SERVER_ROOTLESS_DOCKER" 'system existing probe resets stale rootless state'
assert_eq "$MOCK_DOCKER" "$SERVER_DOCKER_BIN" 'existing probe exports the selected Docker binary'

for rootless_signal in security context environment; do
  reset_case "existing-rootless-$rootless_signal"
  DOCKER_AVAILABLE=true
  COMPOSE_STATUS=0
  BUILDX_STATUS=0
  case "$rootless_signal" in
    security) SECURITY_OPTIONS='["name=rootless"]' ;;
    context) CONTEXT_HOST='unix:///run/user/1000/docker.sock' ;;
    environment) DOCKER_HOST='unix:///run/user/1000/docker.sock'; export DOCKER_HOST ;;
  esac
  install_docker >/dev/null
  assert_eq true "$SERVER_ROOTLESS_DOCKER" "existing rootless $rootless_signal signal is detected"
  assert_eq 'unix:///run/user/1000/docker.sock' "$DOCKER_HOST" "existing rootless $rootless_signal signal selects the user socket"
  assert_eq "$MOCK_DOCKER" "$SERVER_DOCKER_BIN" "existing rootless $rootless_signal signal retains the selected binary"
done

for missing_capability in compose buildx info; do
  reset_case "existing-warning-$missing_capability"
  DOCKER_AVAILABLE=true
  COMPOSE_STATUS=0
  BUILDX_STATUS=0
  INFO_STATUS=0
  case "$missing_capability" in
    compose) COMPOSE_STATUS=1; warning_name='Docker Compose' ;;
    buildx) BUILDX_STATUS=1; warning_name='Docker Buildx' ;;
    info) INFO_STATUS=1; warning_name='Docker daemon' ;;
  esac
  install_docker >"$CASE_STDOUT" 2>"$CASE_STDERR"
  expected_existing_calls=(
    "$MOCK_DOCKER" --version
    "$MOCK_DOCKER" --version
    "$MOCK_DOCKER" compose version
    "$MOCK_DOCKER" buildx version
    "$MOCK_DOCKER" info
    "$MOCK_DOCKER" info --format '{{json .SecurityOptions}}'
    "$MOCK_DOCKER" context inspect --format '{{.Endpoints.docker.Host}}'
  )
  assert_contains "$(<"$CASE_STDOUT")" 'Docker version 99.0.0, build fixture' "$missing_capability warning reuse reports the client version"
  assert_contains "$(<"$CASE_STDERR")" "$warning_name" "$missing_capability warning names the failed probe"
  assert_eq 1 "$(grep -c '^WARN:' "$CASE_STDERR")" "$missing_capability emits one focused warning"
  read_nul_log "$DOCKER_EXEC_LOG"
  assert_eq "${#expected_existing_calls[@]}" "${#NUL_ARGS[@]}" "$missing_capability warning still runs every existing-Docker probe"
  for docker_index in "${!expected_existing_calls[@]}"; do
    assert_eq "${expected_existing_calls[$docker_index]}" "${NUL_ARGS[$docker_index]}" "$missing_capability warning Docker argument $docker_index"
  done
  assert_eq true "$SERVER_DOCKER_REUSED_WITH_WARNINGS" "$missing_capability warning sets reuse state"
  assert_empty "$DISCOVERY_LOG" "$missing_capability warning returns before sudo discovery"
  assert_empty "$FETCH_URL_LOG" "$missing_capability warning never reinstalls"
  assert_empty "$SUDO_LOG" "$missing_capability warning never invokes sudo"
  assert_empty "$INSTALLER_LOG" "$missing_capability warning never invokes rootless installer"
  assert_empty "$SYSTEMCTL_LOG" "$missing_capability warning never manages services"
  assert_empty "$GITHUB_LOG" "$missing_capability warning never resolves releases"
done

reset_case sudo-install
SUDO_AVAILABLE=true
install_docker
expected_source=$'Types: deb\nURIs: https://download.docker.com/linux/ubuntu\nSuites: noble\nComponents: stable\nArchitectures: amd64\nSigned-By: /etc/apt/keyrings/docker.asc'
assert_eq "$expected_source" "$(<"$MOCK_ETC/docker.sources")" 'system install writes exact Docker deb822 source'
assert_eq "$GPG_PAYLOAD" "$(<"$MOCK_ETC/keyrings-docker.asc")" 'system install writes downloaded armored key'
read_nul_log "$SUDO_LOG"
sudo_joined="$(printf '<%s>' "${NUL_ARGS[@]}")"
assert_contains "$sudo_joined" '<apt-get><update>' 'system install updates apt metadata'
read_nul_log "$APT_INSTALL_LOG"
expected_apt_install=(apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)
assert_eq "${#expected_apt_install[@]}" "${#NUL_ARGS[@]}" 'system install apt vector has no extra arguments'
for apt_index in "${!expected_apt_install[@]}"; do
  assert_eq "${expected_apt_install[$apt_index]}" "${NUL_ARGS[$apt_index]}" "system install apt argument $apt_index"
done
assert_contains "$sudo_joined" '<usermod><-aG><docker><tester>' 'system install adds the current user to docker group'
assert_contains "$sudo_joined" "<$MOCK_OFFICIAL_DOCKER><info>" 'system verification checks the official daemon CLI through sudo'
read_nul_log "$SYSTEMCTL_LOG"
assert_eq 'system' "${NUL_ARGS[0]}" 'system service uses system scope'
assert_eq enable "${NUL_ARGS[1]}" 'system service is enabled'
assert_eq --now "${NUL_ARGS[2]}" 'system service is started immediately'
assert_eq docker "${NUL_ARGS[3]}" 'Docker service name'
assert_eq true "$SERVER_DOCKER_NEEDS_RELOGIN" 'system install records group relogin requirement'
assert_eq "$MOCK_OFFICIAL_DOCKER" "$SERVER_DOCKER_BIN" 'system install exports the official Docker CLI path'
assert_temp_targets_removed

reset_case system-shadowed-cli
SUDO_AVAILABLE=true
APT_CREATES_SHADOW=true
SHADOW_DOCKER_VERSION_STATUS=1
install_docker >"$CASE_STDOUT" 2>"$CASE_STDERR"
assert_contains "$(<"$CASE_STDERR")" 'PATH' 'system install warns about a shadowing Docker command'
assert_contains "$(<"$CASE_STDERR")" "$MOCK_DOCKER" 'shadow warning names the earlier Docker command'
docker_shadow_calls="$(tr '\0' ' ' <"$DOCKER_EXEC_LOG")"
assert_not_contains "$docker_shadow_calls" "$MOCK_DOCKER --version" 'system verification never executes the broken PATH shadow'
assert_contains "$docker_shadow_calls" "$MOCK_OFFICIAL_DOCKER --version" 'system verification executes the official client'
read_nul_log "$SUDO_LOG"
shadow_sudo_calls="$(printf '<%s>' "${NUL_ARGS[@]}")"
assert_contains "$shadow_sudo_calls" "<$MOCK_OFFICIAL_DOCKER><info>" 'shadowed system install uses official Docker for sudo info'
assert_not_contains "$shadow_sudo_calls" "<$MOCK_DOCKER><info>" 'shadowed system install never gives the arbitrary PATH command to sudo'
assert_eq "$MOCK_OFFICIAL_DOCKER" "$SERVER_DOCKER_BIN" 'shadowed system install exports the official Docker path'
[ ! -e "$HOME/.local/state/tabby-config/docker-install-incomplete" ] || fail 'shadowed successful install clears its state marker'

reset_case system-resume-after-client
SUDO_AVAILABLE=true
SYSTEMCTL_STATUS=1
system_resume_output="$(install_docker 2>&1)" && fail 'first system attempt must fail after installing the client'
state_marker="$HOME/.local/state/tabby-config/docker-install-incomplete"
assert_eq system "$(<"$state_marker")" 'failed system attempt preserves its branch marker'
assert_eq 7 "$(wc -c <"$state_marker")" 'system branch marker has exactly system plus one newline'
[ -e "$MOCK_OFFICIAL_DOCKER" ] || fail 'failed system attempt leaves the installed official client discoverable'
first_system_apt_bytes="$(wc -c <"$APT_INSTALL_LOG")"
SYSTEMCTL_STATUS=0
install_docker
[ ! -e "$state_marker" ] || fail 'successful system retry clears its branch marker'
[ "$(wc -c <"$APT_INSTALL_LOG")" -gt "$first_system_apt_bytes" ] || fail 'system retry resumes installation instead of reusing the partial client'
second_system_apt_bytes="$(wc -c <"$APT_INSTALL_LOG")"
install_docker
assert_eq "$second_system_apt_bytes" "$(wc -c <"$APT_INSTALL_LOG")" 'successful system rerun skips installation after marker clearance'

reset_case rootless-resume-after-client
USER_SERVICE_STATUS=1
rootless_resume_output="$(install_docker 2>&1)" && fail 'first rootless attempt must fail after installing the client'
state_marker="$HOME/.local/state/tabby-config/docker-install-incomplete"
assert_eq rootless "$(<"$state_marker")" 'failed rootless attempt preserves its branch marker'
assert_eq 9 "$(wc -c <"$state_marker")" 'rootless branch marker has exactly rootless plus one newline'
[ -e "$MOCK_DOCKER" ] || fail 'failed rootless attempt leaves a discoverable client'
first_rootless_systemctl_bytes="$(wc -c <"$SYSTEMCTL_LOG")"
first_rootless_installer_bytes="$(wc -c <"$INSTALLER_LOG")"
USER_SERVICE_STATUS=0
install_docker
[ ! -e "$state_marker" ] || fail 'successful rootless retry clears its branch marker'
[ "$(wc -c <"$SYSTEMCTL_LOG")" -gt "$first_rootless_systemctl_bytes" ] || fail 'rootless retry resumes through service enable'
assert_eq "$first_rootless_installer_bytes" "$(wc -c <"$INSTALLER_LOG")" 'rootless retry reuses the partial client instead of rerunning its installer'
first_rootless_fetch_count="$(wc -l <"$FETCH_URL_LOG")"
install_docker
assert_eq "$first_rootless_fetch_count" "$(wc -l <"$FETCH_URL_LOG")" 'successful rootless rerun skips installation after marker clearance'

reset_case invalid-resume-marker
state_marker="$HOME/.local/state/tabby-config/docker-install-incomplete"
mkdir -p "$(dirname "$state_marker")"
printf '%s\n' invalid-branch >"$state_marker"
invalid_marker_output="$(install_docker 2>&1)" && fail 'invalid Docker resume marker must fail closed'
assert_contains "$invalid_marker_output" 'invalid' 'invalid marker failure is actionable'
assert_empty "$FETCH_URL_LOG" 'invalid marker fails before download'
assert_empty "$SUDO_LOG" 'invalid marker fails before mutation'

reset_case conflict-packages
SUDO_AVAILABLE=true
INSTALLED_PACKAGES[docker.io]=true
INSTALLED_PACKAGES[containerd]=true
conflict_output="$(install_docker 2>&1)" && fail 'conflicting packages must fail'
assert_contains "$conflict_output" 'docker.io containerd' 'conflict failure names exact installed packages'
assert_contains "$conflict_output" 'sudo apt-get remove docker.io containerd' 'conflict failure gives actionable official removal command'
assert_empty "$FETCH_URL_LOG" 'conflicts fail before repository download'
assert_empty "$SUDO_LOG" 'conflicts fail before apt mutation'

reset_case rootless-install
install_docker
assert_file_contains "$FETCH_URL_LOG" 'https://get.docker.com/rootless' 'rootless installer is downloaded'
assert_file_contains "$FETCH_URL_LOG" 'mock://buildx/buildx-v1.linux-amd64' 'x86_64 Buildx asset mapping'
assert_file_contains "$FETCH_URL_LOG" 'mock://compose/docker-compose-linux-x86_64' 'x86_64 Compose asset mapping'
assert_eq true "$SERVER_ROOTLESS_DOCKER" 'rootless state is exported'
assert_eq "unix:///run/user/1000/docker.sock" "$DOCKER_HOST" 'rootless daemon socket is exported'
assert_eq 1 "$(awk -F: -v bin="$HOME/bin" '{ for (i=1;i<=NF;i++) if ($i==bin) n++ } END { print n+0 }' <<<"$PATH")" 'HOME bin is prepended once'
[ -x "$HOME/.docker/cli-plugins/docker-buildx" ] || fail 'Buildx plugin is installed executable'
[ -x "$HOME/.docker/cli-plugins/docker-compose" ] || fail 'Compose plugin is installed executable'
read_nul_log "$INSTALLER_LOG"
assert_eq 1 "${#NUL_ARGS[@]}" 'rootless installer receives one argument'
assert_contains "${NUL_ARGS[0]}" '/rootless.sh' 'rootless installer receives the private file path'
read_nul_log "$SYSTEMCTL_LOG"
systemctl_joined="$(printf '<%s>' "${NUL_ARGS[@]}")"
assert_contains "$systemctl_joined" '<user><show-environment>' 'rootless prerequisites probe user systemd'
assert_contains "$systemctl_joined" '<user><enable><--now><docker>' 'rootless service is enabled and started'
assert_empty "$SUDO_LOG" 'rootless branch never invokes apt or sudo'
assert_temp_targets_removed

rootless_fetch_count="$(wc -l <"$FETCH_URL_LOG")"
rootless_systemctl_bytes="$(wc -c <"$SYSTEMCTL_LOG")"
unset SERVER_DOCKER_BIN SERVER_ROOTLESS_DOCKER SERVER_DOCKER_NEEDS_RELOGIN
unset SERVER_DOCKER_REUSED_WITH_WARNINGS DOCKER_HOST
SECURITY_OPTIONS='["name=rootless"]'
CONTEXT_HOST='unix:///run/user/1000/docker.sock'
install_docker
assert_eq "$MOCK_DOCKER" "${SERVER_DOCKER_BIN:-}" 'fresh rerun exports the reused rootless Docker binary'
assert_eq true "${SERVER_ROOTLESS_DOCKER:-false}" 'fresh rerun redetects rootless Docker mode'
assert_eq false "${SERVER_DOCKER_NEEDS_RELOGIN:-true}" 'fresh rootless rerun does not retain relogin state'
assert_eq 'unix:///run/user/1000/docker.sock' "${DOCKER_HOST:-}" 'fresh rerun restores the rootless Docker socket'
assert_eq "$rootless_fetch_count" "$(wc -l <"$FETCH_URL_LOG")" 'fresh rootless rerun does not redownload Docker assets'
assert_eq "$rootless_systemctl_bytes" "$(wc -c <"$SYSTEMCTL_LOG")" 'fresh rootless rerun does not repeat user service mutation'

for prerequisite in root uidmap gidmap subuid-missing subuid-small subgid-missing subgid-small systemd; do
  reset_case "prerequisite-$prerequisite"
  case "$prerequisite" in
    root) MOCK_UID=0 ; remedy='non-root user' ;;
    uidmap) UIDMAP_PRESENT=false; remedy='sudo apt-get install uidmap' ;;
    gidmap) GIDMAP_PRESENT=false; remedy='sudo apt-get install uidmap' ;;
    subuid-missing) SUBUID_TOTAL=0; allocation_total=0; remedy='sudo usermod --add-subuids' ;;
    subuid-small) SUBUID_TOTAL=65535; allocation_total=65535; remedy='sudo usermod --add-subuids' ;;
    subgid-missing) SUBGID_TOTAL=0; allocation_total=0; remedy='sudo usermod --add-subgids' ;;
    subgid-small) SUBGID_TOTAL=65535; allocation_total=65535; remedy='sudo usermod --add-subgids' ;;
    systemd) USER_SYSTEMCTL_STATUS=1; remedy='systemctl --user' ;;
  esac
  prerequisite_output="$(install_docker 2>&1)" && fail "$prerequisite must fail"
  assert_contains "$prerequisite_output" "$remedy" "$prerequisite failure names its remedy"
  case "$prerequisite" in
    subuid-*)
      assert_contains "$prerequisite_output" '/etc/subuid' "$prerequisite names the allocation file"
      assert_contains "$prerequisite_output" tester "$prerequisite names the affected user"
      assert_contains "$prerequisite_output" "provides $allocation_total" "$prerequisite reports the detected allocation total"
      assert_contains "$prerequisite_output" '>=65536 total' "$prerequisite names the required total"
      assert_contains "$prerequisite_output" 'Administrator template' "$prerequisite labels the admin action as a template"
      assert_contains "$prerequisite_output" 'non-overlapping' "$prerequisite requires a collision-safe range"
      assert_contains "$prerequisite_output" '<START>-<END>' "$prerequisite provides a safe admin template"
      assert_not_contains "$prerequisite_output" '100000-165535' "$prerequisite does not propose a potentially overlapping range"
      ;;
    subgid-*)
      assert_contains "$prerequisite_output" '/etc/subgid' "$prerequisite names the allocation file"
      assert_contains "$prerequisite_output" tester "$prerequisite names the affected user"
      assert_contains "$prerequisite_output" "provides $allocation_total" "$prerequisite reports the detected allocation total"
      assert_contains "$prerequisite_output" '>=65536 total' "$prerequisite names the required total"
      assert_contains "$prerequisite_output" 'Administrator template' "$prerequisite labels the admin action as a template"
      assert_contains "$prerequisite_output" 'non-overlapping' "$prerequisite requires a collision-safe range"
      assert_contains "$prerequisite_output" '<START>-<END>' "$prerequisite provides a safe admin template"
      assert_not_contains "$prerequisite_output" '100000-165535' "$prerequisite does not propose a potentially overlapping range"
      ;;
  esac
  assert_empty "$FETCH_URL_LOG" "$prerequisite fails before any download"
  assert_empty "$SUDO_LOG" "$prerequisite never tries apt"
done

reset_case arm64-assets
ARCH=arm64
install_docker
assert_file_contains "$FETCH_URL_LOG" 'mock://buildx/buildx-v1.linux-arm64' 'arm64 Buildx asset mapping'
assert_file_contains "$FETCH_URL_LOG" 'mock://compose/docker-compose-linux-aarch64' 'arm64 Compose asset mapping'

for unsafe in missing mismatch; do
  reset_case "buildx-checksum-$unsafe"
  BUILDX_CHECKSUM_MODE="$unsafe"
  checksum_output="$(install_docker 2>&1)" && fail "Buildx $unsafe checksum must fail"
  assert_contains "$checksum_output" 'checksum' "Buildx $unsafe checksum failure is actionable"
  [ ! -e "$HOME/.docker/cli-plugins/docker-buildx" ] || fail "Buildx $unsafe checksum never installs Buildx"
  assert_temp_targets_removed

  reset_case "compose-checksum-$unsafe"
  COMPOSE_CHECKSUM_MODE="$unsafe"
  checksum_output="$(install_docker 2>&1)" && fail "Compose $unsafe checksum must fail"
  assert_contains "$checksum_output" 'checksum' "Compose $unsafe checksum failure is actionable"
  [ -x "$HOME/.docker/cli-plugins/docker-buildx" ] || fail "Compose $unsafe checksum case reaches Compose after verified Buildx install"
  [ ! -e "$HOME/.docker/cli-plugins/docker-compose" ] || fail "Compose $unsafe checksum never installs Compose"
  assert_temp_targets_removed
done

reset_case empty-gpg
SUDO_AVAILABLE=true
EMPTY_KIND=gpg
empty_output="$(install_docker 2>&1)" && fail 'empty Docker GPG download must fail'
assert_contains "$empty_output" 'signing key is empty' 'empty Docker GPG failure is explicit'
[ ! -e "$MOCK_ETC/keyrings-docker.asc" ] || fail 'empty Docker GPG is never installed'
assert_empty "$SUDO_LOG" 'empty Docker GPG fails before sudo mutation'
assert_temp_targets_removed

reset_case invalid-gpg-armor
SUDO_AVAILABLE=true
GPG_PAYLOAD=$'-----BEGIN PGP PUBLIC KEY BLOCK-----\nmissing end marker'
invalid_gpg_output="$(install_docker 2>&1)" && fail 'structurally invalid Docker GPG key must fail'
assert_contains "$invalid_gpg_output" 'PGP PUBLIC KEY BLOCK' 'invalid Docker GPG failure names the required structure'
[ ! -e "$MOCK_ETC/keyrings-docker.asc" ] || fail 'invalid Docker GPG is never published'
assert_empty "$SUDO_LOG" 'invalid Docker GPG fails before sudo mutation'
assert_temp_targets_removed

for invalid_armor in empty-body garbage-body trailing-garbage; do
  reset_case "invalid-gpg-$invalid_armor"
  SUDO_AVAILABLE=true
  case "$invalid_armor" in
    empty-body) GPG_PAYLOAD=$'-----BEGIN PGP PUBLIC KEY BLOCK-----\n\n-----END PGP PUBLIC KEY BLOCK-----' ;;
    garbage-body) GPG_PAYLOAD=$'-----BEGIN PGP PUBLIC KEY BLOCK-----\n\nnot!base64\n-----END PGP PUBLIC KEY BLOCK-----' ;;
    trailing-garbage) GPG_PAYLOAD=$'-----BEGIN PGP PUBLIC KEY BLOCK-----\n\nZG9ja2Vy\n-----END PGP PUBLIC KEY BLOCK-----\ngarbage' ;;
  esac
  invalid_gpg_output="$(install_docker 2>&1)" && fail "$invalid_armor Docker GPG key must fail"
  assert_contains "$invalid_gpg_output" 'PGP PUBLIC KEY BLOCK' "$invalid_armor failure names the required structure"
  [ ! -e "$MOCK_ETC/keyrings-docker.asc" ] || fail "$invalid_armor Docker GPG is never published"
  assert_empty "$SYSTEM_FILE_LOG" "$invalid_armor fails before system path probes or publication"
  assert_temp_targets_removed
done

reset_case repository-probe-failure
SUDO_AVAILABLE=true
SYSTEM_FILE_PROBE_STATUS=46
probe_output="$(install_docker 2>&1)" && fail 'system repository path probe failure must fail closed'
assert_contains "$probe_output" 'probe' 'system repository path probe failure is actionable'
system_file_ops="$(<"$SYSTEM_FILE_TEXT_LOG")"
assert_not_contains "$system_file_ops" 'install|' 'path probe failure stops before publication'
assert_not_contains "$system_file_ops" 'move|' 'path probe failure stops before publication rename'
assert_temp_targets_removed

reset_case repository-unsupported-target
SUDO_AVAILABLE=true
mkdir -p "$MOCK_ETC/keyrings-docker.asc"
unsupported_output="$(install_docker 2>&1)" && fail 'directory at the Docker key path must fail closed'
assert_contains "$unsupported_output" 'unexpected Docker apt key path status' 'unsupported system target failure is actionable'
system_file_ops="$(<"$SYSTEM_FILE_TEXT_LOG")"
assert_not_contains "$system_file_ops" 'copy|' 'unsupported target fails before snapshot'
assert_not_contains "$system_file_ops" 'install|' 'unsupported target fails before publication'
assert_not_contains "$system_file_ops" 'move|' 'unsupported target fails before publication rename'
assert_temp_targets_removed

reset_case repository-symlink-directory-publish
SUDO_AVAILABLE=true
key_referent="$MOCK_ETC/key-referent"
mkdir -p "$key_referent"
ln -s "$key_referent" "$MOCK_ETC/keyrings-docker.asc"
install_docker
[ -f "$MOCK_ETC/keyrings-docker.asc" ] && [ ! -L "$MOCK_ETC/keyrings-docker.asc" ] ||
  fail 'successful repository publication replaces the key symlink-to-directory at the exact target'
assert_eq "$GPG_PAYLOAD" "$(<"$MOCK_ETC/keyrings-docker.asc")" 'successful repository publication writes the key at the exact target'
[ -z "$(find "$key_referent" -mindepth 1 -print -quit)" ] ||
  fail 'successful repository publication leaves no artifact inside the key symlink referent'
assert_temp_targets_removed

reset_case repository-symlink-directory-rollback
SUDO_AVAILABLE=true
key_referent="$MOCK_ETC/key-referent"
mkdir -p "$key_referent"
ln -s "$key_referent" "$MOCK_ETC/keyrings-docker.asc"
APT_UPDATE_STATUS=50
symlink_directory_output="$(install_docker 2>&1)" && fail 'apt failure with a key symlink-to-directory must fail'
[ -L "$MOCK_ETC/keyrings-docker.asc" ] || fail 'rollback restores the original key symlink-to-directory at the exact target'
assert_eq "$key_referent" "$(readlink "$MOCK_ETC/keyrings-docker.asc")" 'rollback restores the key symlink-to-directory referent'
[ -z "$(find "$key_referent" -mindepth 1 -print -quit)" ] ||
  fail 'repository rollback leaves no publication or restoration artifact inside the key symlink referent'
assert_temp_targets_removed

reset_case repository-dangling-symlink-rollback
SUDO_AVAILABLE=true
mkdir -p "$MOCK_ETC"
ln -s missing-original-key "$MOCK_ETC/keyrings-docker.asc"
ln -s missing-original-source "$MOCK_ETC/docker.sources"
APT_UPDATE_STATUS=47
symlink_output="$(install_docker 2>&1)" && fail 'apt failure with dangling repository symlinks must fail'
[ -L "$MOCK_ETC/keyrings-docker.asc" ] || fail 'rollback restores the original dangling key symlink type'
[ -L "$MOCK_ETC/docker.sources" ] || fail 'rollback restores the original dangling source symlink type'
assert_eq missing-original-key "$(readlink "$MOCK_ETC/keyrings-docker.asc")" 'rollback restores the dangling key symlink target'
assert_eq missing-original-source "$(readlink "$MOCK_ETC/docker.sources")" 'rollback restores the dangling source symlink target'
assert_temp_targets_removed

for rollback_failure in apt-update apt-install key-publication source-publication; do
  reset_case "repository-rollback-$rollback_failure"
  SUDO_AVAILABLE=true
  seed_system_repository_files
  case "$rollback_failure" in
    apt-update) APT_UPDATE_STATUS=41 ;;
    apt-install) APT_INSTALL_STATUS=42 ;;
    key-publication)
      SYSTEM_FILE_FAIL_MATCH='move:/etc/apt/keyrings/docker.asc.tabby-config.stage'
      SYSTEM_FILE_FAIL_STATUS=43
      ;;
    source-publication)
      SYSTEM_FILE_FAIL_MATCH='move:/etc/apt/sources.list.d/docker.sources.tabby-config.stage'
      SYSTEM_FILE_FAIL_STATUS=44
      ;;
  esac
  rollback_output="$(install_docker 2>&1)" && fail "$rollback_failure must fail and roll back repository configuration"
  assert_original_system_repository_files "$rollback_failure"
  assert_file_contains "$SYSTEM_FILE_TEXT_LOG" 'copy|/etc/apt/keyrings/docker.asc|' "$rollback_failure snapshots the existing key"
  assert_file_contains "$SYSTEM_FILE_TEXT_LOG" 'copy|/etc/apt/sources.list.d/docker.sources|' "$rollback_failure snapshots the existing source"
  grep -E '^restore\|.*/docker\.asc\.previous\|/etc/apt/keyrings/docker\.asc\.tabby-config\.stage\.[0-9]+$' "$SYSTEM_FILE_TEXT_LOG" >/dev/null ||
    fail "$rollback_failure restores the key through its destination-adjacent stage"
  grep -E '^restore\|.*/docker\.sources\.previous\|/etc/apt/sources\.list\.d/docker\.sources\.tabby-config\.stage\.[0-9]+$' "$SYSTEM_FILE_TEXT_LOG" >/dev/null ||
    fail "$rollback_failure restores the source through its destination-adjacent stage"
  assert_temp_targets_removed
done

reset_case repository-rollback-absent
SUDO_AVAILABLE=true
APT_UPDATE_STATUS=45
rollback_output="$(install_docker 2>&1)" && fail 'apt failure with absent repository files must fail'
[ ! -e "$MOCK_ETC/keyrings-docker.asc" ] || fail 'rollback removes only the installer-created key when no original existed'
[ ! -e "$MOCK_ETC/docker.sources" ] || fail 'rollback removes only the installer-created source when no original existed'
assert_file_contains "$SYSTEM_FILE_TEXT_LOG" 'remove|/etc/apt/keyrings/docker.asc' 'absent-key rollback uses the exact official path'
assert_file_contains "$SYSTEM_FILE_TEXT_LOG" 'remove|/etc/apt/sources.list.d/docker.sources' 'absent-source rollback uses the exact official path'
assert_temp_targets_removed

reset_case repository-rollback-recovery-retained
SUDO_AVAILABLE=true
seed_system_repository_files
APT_UPDATE_STATUS=48
SYSTEM_RESTORE_FAIL_MATCH=docker.sources.previous
SYSTEM_RESTORE_FAIL_STATUS=49
rollback_output="$(install_docker 2>&1)" && fail 'rollback restoration failure must remain nonzero'
assert_contains "$rollback_output" 'recovery snapshots retained at' 'rollback failure reports its recovery directory'
recovery_key_target="$(sed -n '1p' "$FETCH_TARGET_LOG")"
recovery_directory="$(dirname "$recovery_key_target")"
[ -d "$recovery_directory" ] || fail 'rollback failure retains the temporary recovery directory'
assert_eq original-key "$(<"$recovery_directory/docker.asc.previous")" 'retained recovery directory preserves the key snapshot'
assert_eq original-source "$(<"$recovery_directory/docker.sources.previous")" 'retained recovery directory preserves the source snapshot'
assert_eq 600 "$(stat -c '%a' "$recovery_directory/docker.asc.previous")" 'retained key snapshot preserves its mode'
assert_eq 640 "$(stat -c '%a' "$recovery_directory/docker.sources.previous")" 'retained source snapshot preserves its mode'

for empty_kind in rootless buildx buildx-checksum compose compose-checksum; do
  reset_case "empty-$empty_kind"
  EMPTY_KIND="$empty_kind"
  empty_output="$(install_docker 2>&1)" && fail "empty $empty_kind download must fail"
  assert_contains "$empty_output" 'empty' "empty $empty_kind failure is explicit"
  case "$empty_kind" in
    rootless|buildx|buildx-checksum)
      [ ! -e "$HOME/.docker/cli-plugins/docker-buildx" ] || fail "empty $empty_kind never installs Buildx"
      [ "$empty_kind" != rootless ] || assert_empty "$INSTALLER_LOG" 'empty rootless script is never executed'
      ;;
    compose|compose-checksum)
      [ -x "$HOME/.docker/cli-plugins/docker-buildx" ] || fail "empty $empty_kind case independently reaches Compose after Buildx"
      [ ! -e "$HOME/.docker/cli-plugins/docker-compose" ] || fail "empty $empty_kind never installs Compose"
      ;;
  esac
  assert_temp_targets_removed
done

reset_case existing-plugin-reuse
BUILDX_STATUS=0
COMPOSE_STATUS=0
install_docker
assert_empty "$GITHUB_LOG" 'working user plugins are reused without asset lookup'

reset_case conflicting-plugin-backup
mkdir -p "$HOME/.docker/cli-plugins"
printf '%s\n' preserve-buildx >"$HOME/.docker/cli-plugins/docker-buildx"
install_docker
backup_path="$(find "$HOME/.docker/cli-plugins" -maxdepth 1 -name 'docker-buildx.bak.*' -print -quit)"
[ -n "$backup_path" ] || fail 'conflicting Buildx plugin is backed up'
assert_eq preserve-buildx "$(<"$backup_path")" 'Buildx backup preserves prior content'

for publication_failure in stage staged-invalid rename post-publish; do
  reset_case "plugin-publication-$publication_failure"
  plugin_target="$HOME/.docker/cli-plugins/docker-buildx"
  mkdir -p "$(dirname "$plugin_target")"
  printf '%s\n' original-buildx >"$plugin_target"
  case "$publication_failure" in
    stage) PLUGIN_STAGE_STATUS=31 ;;
    staged-invalid) STAGED_PLUGIN_STATUS=32 ;;
    rename) PLUGIN_PUBLISH_STATUS=33 ;;
    post-publish) POST_PUBLISH_BUILDX_STATUS=34 ;;
  esac
  publication_output="$(install_docker 2>&1)" && fail "$publication_failure plugin publication must fail"
  assert_eq original-buildx "$(<"$plugin_target")" "$publication_failure restores the original Buildx target"
  [ -z "$(find "$(dirname "$plugin_target")" -maxdepth 1 -name '.docker-buildx.stage.*' -print -quit)" ] ||
    fail "$publication_failure cleans destination-adjacent plugin staging files"
  assert_temp_targets_removed
done

reset_case plugin-post-publish-no-original
POST_PUBLISH_BUILDX_STATUS=35
plugin_target="$HOME/.docker/cli-plugins/docker-buildx"
publication_output="$(install_docker 2>&1)" && fail 'post-publish verification without an original plugin must fail'
[ ! -e "$plugin_target" ] || fail 'post-publish failure without an original leaves no Buildx target'
[ -z "$(find "$(dirname "$plugin_target")" -maxdepth 1 -name '.docker-buildx.stage.*' -print -quit)" ] ||
  fail 'post-publish failure without an original cleans staging files'
assert_temp_targets_removed

reset_case gpg-fetch-failure
SUDO_AVAILABLE=true
FETCH_FAIL_KIND=gpg
gpg_output="$(install_docker 2>&1)" && fail 'Docker GPG fetch failure must propagate'
assert_contains "$gpg_output" 'failed to download' 'Docker GPG fetch failure is actionable'
assert_empty "$SUDO_LOG" 'Docker GPG fetch failure stops before sudo mutation'
assert_temp_targets_removed

reset_case apt-update-failure
SUDO_AVAILABLE=true
APT_UPDATE_STATUS=7
apt_output="$(install_docker 2>&1)" && fail 'apt update failure must propagate'
assert_contains "$apt_output" 'apt-get update failed' 'apt update failure is actionable'
assert_empty "$APT_INSTALL_LOG" 'apt update failure stops before package installation'
assert_empty "$SYSTEMCTL_LOG" 'apt update failure stops before service mutation'
assert_system_repository_files_absent 'apt update failure rollback'
assert_temp_targets_removed

reset_case apt-install-failure
SUDO_AVAILABLE=true
APT_INSTALL_STATUS=8
apt_output="$(install_docker 2>&1)" && fail 'exact package install failure must propagate'
assert_contains "$apt_output" 'apt-get install failed' 'package install failure is actionable'
[ -s "$APT_INSTALL_LOG" ] || fail 'package install failure reaches the exact install invocation'
assert_empty "$SYSTEMCTL_LOG" 'package install failure stops before service mutation'
assert_system_repository_files_absent 'package install failure rollback'
assert_temp_targets_removed

reset_case system-service-failure
SUDO_AVAILABLE=true
SYSTEMCTL_STATUS=9
system_output="$(install_docker 2>&1)" && fail 'system Docker service failure must propagate'
assert_contains "$system_output" 'system Docker service' 'system Docker service failure is actionable'
sudo_calls="$(tr '\0' ' ' <"$SUDO_LOG")"
assert_not_contains "$sudo_calls" 'usermod' 'system service failure stops before group mutation'
assert_system_repository_files_absent 'system service failure rollback'
assert_temp_targets_removed

reset_case usermod-failure
SUDO_AVAILABLE=true
USERMOD_STATUS=10
usermod_output="$(install_docker 2>&1)" && fail 'Docker group usermod failure must propagate'
assert_contains "$usermod_output" 'docker group' 'usermod failure is actionable'
assert_empty "$DOCKER_EXEC_LOG" 'usermod failure stops before client verification'
assert_system_repository_files_absent 'usermod failure rollback'
assert_temp_targets_removed

reset_case system-client-failure
SUDO_AVAILABLE=true
DOCKER_VERSION_STATUS=11
client_output="$(install_docker 2>&1)" && fail 'installed Docker client failure must propagate'
assert_contains "$client_output" 'docker --version' 'installed client failure is actionable'
docker_calls="$(tr '\0' ' ' <"$DOCKER_EXEC_LOG")"
assert_not_contains "$docker_calls" 'buildx' 'client failure stops before Buildx verification'
assert_system_repository_files_absent 'client verification failure rollback'
assert_temp_targets_removed

reset_case system-buildx-failure
SUDO_AVAILABLE=true
APT_PROVIDES_BUILDX=false
buildx_output="$(install_docker 2>&1)" && fail 'installed Docker Buildx failure must propagate'
assert_contains "$buildx_output" 'Buildx verification failed' 'installed Buildx failure is actionable'
docker_calls="$(tr '\0' ' ' <"$DOCKER_EXEC_LOG")"
assert_not_contains "$docker_calls" 'compose' 'Buildx failure stops before Compose verification'
assert_system_repository_files_absent 'Buildx verification failure rollback'
assert_temp_targets_removed

reset_case system-compose-failure
SUDO_AVAILABLE=true
APT_PROVIDES_COMPOSE=false
compose_output="$(install_docker 2>&1)" && fail 'installed Docker Compose failure must propagate'
assert_contains "$compose_output" 'Compose verification failed' 'installed Compose failure is actionable'
sudo_calls="$(tr '\0' ' ' <"$SUDO_LOG")"
assert_not_contains "$sudo_calls" "$MOCK_DOCKER info" 'Compose failure stops before daemon verification'
assert_system_repository_files_absent 'Compose verification failure rollback'
assert_temp_targets_removed

reset_case system-daemon-failure
SUDO_AVAILABLE=true
SUDO_INFO_STATUS=12
daemon_output="$(install_docker 2>&1)" && fail 'sudo docker info failure must propagate'
assert_contains "$daemon_output" 'sudo docker info' 'sudo daemon failure is actionable'
assert_system_repository_files_absent 'daemon verification failure rollback'
assert_temp_targets_removed

for plugin_failure in release download manifest-fetch; do
  reset_case "plugin-$plugin_failure-failure"
  case "$plugin_failure" in
    release) LOOKUP_FAIL_KIND=buildx-release; failure_text='release asset' ;;
    download) FETCH_FAIL_KIND=buildx; failure_text='download the official Docker buildx plugin' ;;
    manifest-fetch) FETCH_FAIL_KIND=buildx-checksum; failure_text='download the Docker buildx checksum manifest' ;;
  esac
  plugin_output="$(install_docker 2>&1)" && fail "plugin $plugin_failure failure must propagate"
  assert_contains "$plugin_output" "$failure_text" "plugin $plugin_failure failure is actionable"
  [ ! -e "$HOME/.docker/cli-plugins/docker-buildx" ] || fail "plugin $plugin_failure failure never installs Buildx"
  assert_not_contains "$(<"$GITHUB_LOG")" 'docker/compose' "plugin $plugin_failure failure stops before Compose lookup"
  assert_not_contains "$(<"$FETCH_URL_LOG")" 'mock://compose/' "plugin $plugin_failure failure stops before Compose download"
  read_nul_log "$SYSTEMCTL_LOG"
  expected_failed_plugin_systemctl=(user show-environment)
  assert_eq "${#expected_failed_plugin_systemctl[@]}" "${#NUL_ARGS[@]}" "plugin $plugin_failure failure never enables the user Docker service"
  for systemctl_index in "${!expected_failed_plugin_systemctl[@]}"; do
    assert_eq "${expected_failed_plugin_systemctl[$systemctl_index]}" "${NUL_ARGS[$systemctl_index]}" "plugin $plugin_failure systemctl argument $systemctl_index"
  done
  case "$plugin_failure" in
    release) assert_not_contains "$(<"$FETCH_URL_LOG")" 'mock://buildx/' 'release lookup failure stops before plugin download' ;;
    download) assert_not_contains "$(<"$FETCH_URL_LOG")" 'mock://buildx/checksums.txt' 'plugin download failure stops before manifest fetch' ;;
  esac
  assert_temp_targets_removed
done

reset_case rootless-installer-failure
ROOTLESS_INSTALL_STATUS=1
installer_output="$(install_docker 2>&1)" && fail 'rootless installer failure must propagate'
assert_contains "$installer_output" 'rootless Docker installer failed' 'rootless installer failure is actionable'
assert_temp_targets_removed

reset_case rootless-systemctl-failure
USER_SERVICE_STATUS=1
service_output="$(install_docker 2>&1)" && fail 'rootless service failure must propagate'
assert_contains "$service_output" 'user Docker service' 'rootless service failure is actionable'
assert_temp_targets_removed

reset_case rootless-idempotent
install_docker
first_fetch_count="$(wc -l <"$FETCH_URL_LOG")"
first_path="$PATH"
install_docker
assert_eq "$first_fetch_count" "$(wc -l <"$FETCH_URL_LOG")" 'second run performs no downloads'
assert_eq "$first_path" "$PATH" 'second run does not duplicate HOME bin'

reset_case unsupported-os
SUDO_AVAILABLE=true
OS_ID=debian
os_output="$(install_docker 2>&1)" && fail 'non-Ubuntu system install must fail'
assert_contains "$os_output" 'Ubuntu' 'unsupported system OS error names Ubuntu requirement'
assert_empty "$FETCH_URL_LOG" 'unsupported OS fails before download'

printf 'Docker installation checks passed\n'
