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
COMPOSE_STATUS=1
BUILDX_STATUS=1
INFO_STATUS=0
SUDO_INFO_STATUS=0
ROOTLESS_INSTALL_STATUS=0
USER_SYSTEMCTL_STATUS=0
USER_SERVICE_STATUS=0
SYSTEMCTL_STATUS=0
APT_STATUS=0
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
CHECKSUM_MODE=good
EMPTY_KIND=''
declare -A INSTALLED_PACKAGES=()

docker_command_discovery() {
  case "$1" in
    docker)
      [ "$DOCKER_AVAILABLE" = true ] || [ -e "$MOCK_DOCKER" ] || return 1
      printf '%s\n' "$MOCK_DOCKER"
      ;;
    newuidmap) [ "$UIDMAP_PRESENT" = true ] && printf '%s\n' "$MOCK_BIN/newuidmap" ;;
    newgidmap) [ "$GIDMAP_PRESENT" = true ] && printf '%s\n' "$MOCK_BIN/newgidmap" ;;
    *) return 1 ;;
  esac
}

docker_execute() {
  printf '%s\0' "$@" >>"$DOCKER_EXEC_LOG"
  shift
  case "$*" in
    --version) printf '%s\n' 'Docker version 99.0.0, build fixture'; return "$DOCKER_VERSION_STATUS" ;;
    'compose version') [ -e "$MOCK_BIN/compose.ok" ] || [ -x "$HOME/.docker/cli-plugins/docker-compose" ] || return "$COMPOSE_STATUS" ;;
    'buildx version') [ -e "$MOCK_BIN/buildx.ok" ] || [ -x "$HOME/.docker/cli-plugins/docker-buildx" ] || return "$BUILDX_STATUS" ;;
    info) return "$INFO_STATUS" ;;
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
  local src target
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
    'apt-get update') return "$APT_STATUS" ;;
    'apt-get install')
      printf '%s\0' "$@" >>"$APT_INSTALL_LOG"
      [ "$APT_STATUS" -eq 0 ] || return "$APT_STATUS"
      DOCKER_AVAILABLE=true
      : >"$MOCK_DOCKER"
      : >"$MOCK_BIN/buildx.ok"
      : >"$MOCK_BIN/compose.ok"
      ;;
    'usermod -aG') return 0 ;;
    *)
      if [ "${1:-}" = "$MOCK_DOCKER" ] && [ "${2:-}" = info ]; then
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
}

docker_github_latest_asset_url() {
  local repo="$1" pattern="$2"
  printf '%s|%s\n' "$repo" "$pattern" >>"$GITHUB_LOG"
  case "$repo|$pattern" in
    'docker/buildx|'^'buildx-v'*'linux-amd64$') printf '%s\n' 'mock://buildx/buildx-v1.linux-amd64' ;;
    'docker/buildx|'^'buildx-v'*'linux-arm64$') printf '%s\n' 'mock://buildx/buildx-v1.linux-arm64' ;;
    'docker/buildx|^checksums\.txt$') printf '%s\n' 'mock://buildx/checksums.txt' ;;
    'docker/compose|^docker-compose-linux-x86_64$') printf '%s\n' 'mock://compose/docker-compose-linux-x86_64' ;;
    'docker/compose|^docker-compose-linux-aarch64$') printf '%s\n' 'mock://compose/docker-compose-linux-aarch64' ;;
    'docker/compose|^checksums\.txt$') printf '%s\n' 'mock://compose/checksums.txt' ;;
    *) fail "unexpected GitHub asset lookup: $repo $pattern" ;;
  esac
}

docker_fetch_url() {
  local url="$1" output="$2" kind payload_name payload hash binary
  printf '%s\n' "$url" >>"$FETCH_URL_LOG"
  printf '%s\n' "$output" >>"$FETCH_TARGET_LOG"
  case "$url" in
    https://download.docker.com/linux/ubuntu/gpg) kind=gpg; payload='docker gpg fixture' ;;
    https://get.docker.com/rootless) kind=rootless; payload='rootless installer fixture' ;;
    mock://buildx/checksums.txt)
      kind=buildx-checksum
      binary="$LAST_BUILDX_TARGET"
      hash="$(sha256_file "$binary")"
      [ "$CHECKSUM_MODE" != mismatch ] || hash=0000000000000000000000000000000000000000000000000000000000000000
      payload_name="$(basename "$binary")"
      [ "$CHECKSUM_MODE" != missing ] || payload_name=wrong-buildx-name
      printf '%s  %s\n' "$hash" "$payload_name" >"$output"
      return 0
      ;;
    mock://compose/checksums.txt)
      kind=compose-checksum
      binary="$LAST_COMPOSE_TARGET"
      hash="$(sha256_file "$binary")"
      [ "$CHECKSUM_MODE" != mismatch ] || hash=0000000000000000000000000000000000000000000000000000000000000000
      payload_name="$(basename "$binary")"
      [ "$CHECKSUM_MODE" != missing ] || payload_name=wrong-compose-name
      printf '%s  %s\n' "$hash" "$payload_name" >"$output"
      return 0
      ;;
    mock://buildx/*) kind=buildx; payload='buildx plugin fixture'; LAST_BUILDX_TARGET="$output" ;;
    mock://compose/*) kind=compose; payload='compose plugin fixture'; LAST_COMPOSE_TARGET="$output" ;;
    *) fail "unexpected download: $url" ;;
  esac
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
  MOCK_ETC="$tmp_root/$name/etc-capture"
  FETCH_URL_LOG="$tmp_root/$name/fetch-urls.log"
  FETCH_TARGET_LOG="$tmp_root/$name/fetch-targets.log"
  SUDO_LOG="$tmp_root/$name/sudo-args.bin"
  APT_INSTALL_LOG="$tmp_root/$name/apt-install-args.bin"
  SYSTEMCTL_LOG="$tmp_root/$name/systemctl-args.bin"
  DOCKER_EXEC_LOG="$tmp_root/$name/docker-args.bin"
  INSTALLER_LOG="$tmp_root/$name/installer-args.bin"
  GITHUB_LOG="$tmp_root/$name/github.log"
  DISCOVERY_LOG="$tmp_root/$name/discovery.log"
  export HOME MOCK_BIN MOCK_DOCKER MOCK_ETC FETCH_URL_LOG FETCH_TARGET_LOG
  mkdir -p "$HOME" "$MOCK_BIN" "$MOCK_ETC"
  : >"$FETCH_URL_LOG"
  : >"$FETCH_TARGET_LOG"
  : >"$SUDO_LOG"
  : >"$APT_INSTALL_LOG"
  : >"$SYSTEMCTL_LOG"
  : >"$DOCKER_EXEC_LOG"
  : >"$INSTALLER_LOG"
  : >"$GITHUB_LOG"
  : >"$DISCOVERY_LOG"
  DOCKER_AVAILABLE=false
  SUDO_AVAILABLE=false
  DOCKER_VERSION_STATUS=0
  COMPOSE_STATUS=1
  BUILDX_STATUS=1
  INFO_STATUS=0
  SUDO_INFO_STATUS=0
  ROOTLESS_INSTALL_STATUS=0
  USER_SYSTEMCTL_STATUS=0
  USER_SERVICE_STATUS=0
  SYSTEMCTL_STATUS=0
  APT_STATUS=0
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
  CHECKSUM_MODE=good
  EMPTY_KIND=''
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

reset_case existing-healthy
DOCKER_AVAILABLE=true
COMPOSE_STATUS=0
BUILDX_STATUS=0
install_docker
assert_empty "$DISCOVERY_LOG" 'existing Docker returns before sudo discovery'
assert_empty "$FETCH_URL_LOG" 'existing Docker does not download'
assert_empty "$SUDO_LOG" 'existing Docker does not invoke sudo'
assert_eq false "$SERVER_DOCKER_REUSED_WITH_WARNINGS" 'healthy Docker has no warning state'

reset_case existing-warnings
DOCKER_AVAILABLE=true
COMPOSE_STATUS=1
BUILDX_STATUS=1
INFO_STATUS=1
install_docker
assert_eq true "$SERVER_DOCKER_REUSED_WITH_WARNINGS" 'missing optional capabilities set warning state'
assert_empty "$DISCOVERY_LOG" 'warning reuse still returns before sudo discovery'
assert_empty "$FETCH_URL_LOG" 'warning reuse never reinstalls'

reset_case sudo-install
SUDO_AVAILABLE=true
install_docker
expected_source=$'Types: deb\nURIs: https://download.docker.com/linux/ubuntu\nSuites: noble\nComponents: stable\nArchitectures: amd64\nSigned-By: /etc/apt/keyrings/docker.asc'
assert_eq "$expected_source" "$(<"$MOCK_ETC/docker.sources")" 'system install writes exact Docker deb822 source'
assert_eq 'docker gpg fixture' "$(<"$MOCK_ETC/keyrings-docker.asc")" 'system install writes downloaded key'
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
assert_contains "$sudo_joined" "<$MOCK_DOCKER><info>" 'system verification checks daemon through sudo'
read_nul_log "$SYSTEMCTL_LOG"
assert_eq 'system' "${NUL_ARGS[0]}" 'system service uses system scope'
assert_eq enable "${NUL_ARGS[1]}" 'system service is enabled'
assert_eq --now "${NUL_ARGS[2]}" 'system service is started immediately'
assert_eq docker "${NUL_ARGS[3]}" 'Docker service name'
assert_eq true "$SERVER_DOCKER_NEEDS_RELOGIN" 'system install records group relogin requirement'
assert_temp_targets_removed

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

for prerequisite in root uidmap gidmap subuid-missing subuid-small subgid-missing subgid-small systemd; do
  reset_case "prerequisite-$prerequisite"
  case "$prerequisite" in
    root) MOCK_UID=0 ; remedy='non-root user' ;;
    uidmap) UIDMAP_PRESENT=false; remedy='sudo apt-get install uidmap' ;;
    gidmap) GIDMAP_PRESENT=false; remedy='sudo apt-get install uidmap' ;;
    subuid-missing) SUBUID_TOTAL=0; remedy='sudo usermod --add-subuids' ;;
    subuid-small) SUBUID_TOTAL=65535; remedy='sudo usermod --add-subuids' ;;
    subgid-missing) SUBGID_TOTAL=0; remedy='sudo usermod --add-subgids' ;;
    subgid-small) SUBGID_TOTAL=65535; remedy='sudo usermod --add-subgids' ;;
    systemd) USER_SYSTEMCTL_STATUS=1; remedy='systemctl --user' ;;
  esac
  prerequisite_output="$(install_docker 2>&1)" && fail "$prerequisite must fail"
  assert_contains "$prerequisite_output" "$remedy" "$prerequisite failure names its remedy"
  assert_empty "$FETCH_URL_LOG" "$prerequisite fails before any download"
  assert_empty "$SUDO_LOG" "$prerequisite never tries apt"
done

reset_case arm64-assets
ARCH=arm64
install_docker
assert_file_contains "$FETCH_URL_LOG" 'mock://buildx/buildx-v1.linux-arm64' 'arm64 Buildx asset mapping'
assert_file_contains "$FETCH_URL_LOG" 'mock://compose/docker-compose-linux-aarch64' 'arm64 Compose asset mapping'

for unsafe in mismatch missing; do
  reset_case "checksum-$unsafe"
  CHECKSUM_MODE="$unsafe"
  checksum_output="$(install_docker 2>&1)" && fail "$unsafe plugin checksum must fail"
  assert_contains "$checksum_output" 'checksum' "$unsafe checksum failure is actionable"
  [ ! -e "$HOME/.docker/cli-plugins/docker-buildx" ] || fail "$unsafe checksum never installs Buildx"
  assert_temp_targets_removed
done

for empty_kind in rootless buildx compose; do
  reset_case "empty-$empty_kind"
  EMPTY_KIND="$empty_kind"
  empty_output="$(install_docker 2>&1)" && fail "empty $empty_kind download must fail"
  assert_contains "$empty_output" 'empty' "empty $empty_kind failure is explicit"
  case "$empty_kind" in
    rootless|buildx) [ ! -e "$HOME/.docker/cli-plugins/docker-buildx" ] || fail "empty $empty_kind never installs Buildx" ;;
    compose) [ ! -e "$HOME/.docker/cli-plugins/docker-compose" ] || fail 'empty Compose is never installed' ;;
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

reset_case apt-failure
SUDO_AVAILABLE=true
APT_STATUS=1
apt_output="$(install_docker 2>&1)" && fail 'apt failure must propagate'
assert_contains "$apt_output" 'apt-get' 'apt failure is actionable'
assert_temp_targets_removed

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
