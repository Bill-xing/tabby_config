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

assert_file_contains() {
  local path="$1" expected="$2" message="$3"
  grep -F -- "$expected" "$path" >/dev/null || fail "$message: missing '$expected'"
}

assert_no_file_contains() {
  local path="$1" expected="$2" message="$3"
  if grep -F -- "$expected" "$path" >/dev/null; then
    fail "$message: unexpectedly found '$expected'"
  fi
}

read_nul_log() {
  local path="$1"
  NUL_ARGS=()
  [ -s "$path" ] && mapfile -d '' -t NUL_ARGS <"$path"
}

# shellcheck source=bootstrap/common.sh
source "$REPO_ROOT/bootstrap/common.sh"
# shellcheck source=bootstrap/server/environment.sh
source "$REPO_ROOT/bootstrap/server/environment.sh"
# shellcheck source=bootstrap/server/miniforge.sh
source "$REPO_ROOT/bootstrap/server/miniforge.sh"
# shellcheck source=bootstrap/server/monitoring.sh
source "$REPO_ROOT/bootstrap/server/monitoring.sh"

tmp_root="$(mktemp -d)"
trap 'rm -rf "$tmp_root"' EXIT

declare -A TOOL_PATH=()
declare -A TOOL_VERSION_STATUS=()
CONDA_VERSION_STATUS=0
CONDA_ACTION_STATUS=0
APT_ACTION_STATUS=0
SUDO_AVAILABLE=false

monitoring_command_discovery() {
  local tool="$1"
  [ -n "${TOOL_PATH[$tool]:-}" ] || return 1
  printf '%s\n' "${TOOL_PATH[$tool]}"
}

make_tool() {
  local tool="$1" path="$2" status="${3:-0}"
  mkdir -p "$(dirname "$path")"
  cat >"$path" <<EOF
#!/usr/bin/env bash
[ "\${1:-}" = --version ] || exit 1
exit $status
EOF
  chmod +x "$path"
  TOOL_PATH["$tool"]="$path"
}

mark_conda_tools() {
  local prefix="$1"
  shift
  local tool
  mkdir -p "$prefix/conda-meta" "$prefix/bin"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$prefix/bin/python"
  chmod +x "$prefix/bin/python"
  for tool in "$@"; do
    make_tool "$tool" "$prefix/bin/$tool" "${TOOL_VERSION_STATUS[$tool]:-0}"
  done
}

conda_discovery() {
  printf '%s\n' conda
}

conda() {
  local action="${1:-}" prefix='' arg
  local -a packages=()
  shift || true
  case "$action" in
    --version) return "$CONDA_VERSION_STATUS" ;;
    create|install)
      printf '%s\0' "$action" "$@" >>"$CONDA_LOG"
      [ "$CONDA_ACTION_STATUS" -eq 0 ] || return "$CONDA_ACTION_STATUS"
      while [ "$#" -gt 0 ]; do
        arg="$1"
        shift
        case "$arg" in
          --prefix) prefix="$1"; shift ;;
          --yes) ;;
          *) packages+=("$arg") ;;
        esac
      done
      [ -n "$prefix" ] || fail 'conda invocation omitted --prefix'
      mark_conda_tools "$prefix" "${packages[@]}"
      ;;
    *) fail "unexpected conda action: $action" ;;
  esac
}

run_server_sudo() {
  local action="${1:-}" package
  printf '%s\0' "$@" >>"$APT_LOG"
  [ "$APT_ACTION_STATUS" -eq 0 ] || return "$APT_ACTION_STATUS"
  case "$action" in
    apt-get)
      shift
      case "${1:-}" in
        update) ;;
        install)
          shift
          [ "${1:-}" = -y ] || fail 'apt install omitted -y'
          shift
          for package in "$@"; do
            make_tool "$package" "$SYSTEM_BIN/$package" "${TOOL_VERSION_STATUS[$package]:-0}"
          done
          ;;
        *) fail "unexpected apt action: ${1:-}" ;;
      esac
      ;;
    *) fail "unexpected sudo command: $action" ;;
  esac
}

server_has_sudo() {
  [ "$SUDO_AVAILABLE" = true ]
}

reset_case() {
  local name="$1"
  HOME="$tmp_root/$name/home with spaces"
  export HOME
  PATH="$tmp_root/$name/path-bin:/usr/bin:/bin"
  export PATH
  SYSTEM_BIN="$tmp_root/$name/system bin"
  CONDA_LOG="$tmp_root/$name/conda-args.bin"
  APT_LOG="$tmp_root/$name/apt-args.bin"
  export SYSTEM_BIN CONDA_LOG APT_LOG
  mkdir -p "$HOME" "${PATH%%:*}" "$SYSTEM_BIN"
  : >"$CONDA_LOG"
  : >"$APT_LOG"
  TOOL_PATH=()
  TOOL_VERSION_STATUS=()
  CONDA_VERSION_STATUS=0
  CONDA_ACTION_STATUS=0
  APT_ACTION_STATUS=0
  SUDO_AVAILABLE=false
}

set_existing_tools() {
  local tool
  for tool in "$@"; do
    make_tool "$tool" "$SYSTEM_BIN/$tool"
  done
}

reset_case existing-all
set_existing_tools nvitop btop htop
install_monitoring_tools
assert_eq 0 "$(wc -c <"$APT_LOG")" 'existing tools do not invoke apt'
assert_eq 0 "$(wc -c <"$CONDA_LOG")" 'existing tools do not invoke conda'
[ ! -e "$HOME/.local/bin/nvitop" ] || fail 'existing tools do not mutate local bin'

reset_case sudo-missing
SUDO_AVAILABLE=true
install_monitoring_tools
read_nul_log "$APT_LOG"
assert_eq 7 "${#NUL_ARGS[@]}" 'sudo uses exactly update and one install command'
assert_eq apt-get "${NUL_ARGS[0]}" 'apt update command'
assert_eq update "${NUL_ARGS[1]}" 'apt update once'
assert_eq apt-get "${NUL_ARGS[2]}" 'apt install command'
assert_eq install "${NUL_ARGS[3]}" 'apt install subcommand'
assert_eq -y "${NUL_ARGS[4]}" 'apt install confirmation'
assert_eq btop "${NUL_ARGS[5]}" 'apt installs btop only'
assert_eq htop "${NUL_ARGS[6]}" 'apt installs htop only'
read_nul_log "$CONDA_LOG"
assert_eq 5 "${#NUL_ARGS[@]}" 'conda creates nvitop isolated prefix'
assert_eq create "${NUL_ARGS[0]}" 'absent nvitop prefix uses create'
assert_eq --yes "${NUL_ARGS[1]}" 'conda passes yes'
assert_eq --prefix "${NUL_ARGS[2]}" 'conda passes prefix'
assert_eq "$HOME/.local/share/tabby-config/nvitop" "${NUL_ARGS[3]}" 'nvitop uses isolated user prefix'
assert_eq nvitop "${NUL_ARGS[4]}" 'conda installs only nvitop'

reset_case rootless-missing
install_monitoring_tools
read_nul_log "$CONDA_LOG"
assert_eq 7 "${#NUL_ARGS[@]}" 'rootless conda creates monitoring prefix with exact missing packages'
assert_eq create "${NUL_ARGS[0]}" 'missing rootless prefix uses create'
assert_eq --yes "${NUL_ARGS[1]}" 'rootless conda passes yes'
assert_eq --prefix "${NUL_ARGS[2]}" 'rootless conda passes prefix'
assert_eq "$HOME/.local/share/tabby-config/monitoring" "${NUL_ARGS[3]}" 'rootless uses dedicated monitoring prefix'
assert_eq nvitop "${NUL_ARGS[4]}" 'rootless installs nvitop'
assert_eq btop "${NUL_ARGS[5]}" 'rootless installs btop'
assert_eq htop "${NUL_ARGS[6]}" 'rootless installs htop'
assert_eq 0 "$(wc -c <"$APT_LOG")" 'rootless does not invoke apt'

reset_case recognized-prefix
mkdir -p "$HOME/.local/share/tabby-config/monitoring/conda-meta"
install_monitoring_tools
read_nul_log "$CONDA_LOG"
assert_eq install "${NUL_ARGS[0]}" 'recognized prefix uses conda install'

reset_case symlinks
install_monitoring_tools
for tool in nvitop btop htop; do
  link="$HOME/.local/bin/$tool"
  [ -L "$link" ] || fail "$tool gets a stable symlink"
  case "$(readlink "$link")" in
    "$HOME/.local/share/tabby-config/monitoring/bin/$tool") ;;
    *) fail "$tool link points outside monitoring prefix" ;;
  esac
done
[ ! -e "$HOME/.local/bin/conda" ] && [ ! -L "$HOME/.local/bin/conda" ] || fail 'only known tools are linked'
[ ! -e "$HOME/.local/bin/python" ] && [ ! -L "$HOME/.local/bin/python" ] || fail 'environment binaries are not linked'

reset_case backup-local-file
mkdir -p "$HOME/.local/bin"
printf 'preserve me\n' >"$HOME/.local/bin/nvitop"
install_monitoring_tools
[ -L "$HOME/.local/bin/nvitop" ] || fail 'nvitop replaces managed target with symlink'
backup_path="$(find "$HOME/.local/bin" -maxdepth 1 -name 'nvitop.bak.*' -print -quit)"
[ -n "$backup_path" ] || fail 'existing nvitop file is backed up'
assert_eq 'preserve me' "$(<"$backup_path")" 'backup preserves existing file'

reset_case apt-failure
SUDO_AVAILABLE=true
APT_ACTION_STATUS=1
if (install_monitoring_tools); then
  fail 'apt failure must be nonzero'
fi

reset_case conda-failure
CONDA_ACTION_STATUS=1
if (install_monitoring_tools); then
  fail 'conda failure must be nonzero'
fi

reset_case post-version-failure
TOOL_VERSION_STATUS[htop]=1
if (install_monitoring_tools); then
  fail 'failed post-install version probe must be nonzero'
fi

reset_case conda-unusable
CONDA_VERSION_STATUS=1
if (install_monitoring_tools); then
  fail 'missing tools with unusable conda must be nonzero'
fi
assert_eq 0 "$(wc -c <"$APT_LOG")" 'unusable conda fails before sudo apt mutation when nvitop is missing'

reset_case idempotent
install_monitoring_tools
first_conda_bytes="$(wc -c <"$CONDA_LOG")"
first_apt_bytes="$(wc -c <"$APT_LOG")"
install_monitoring_tools
assert_eq "$first_conda_bytes" "$(wc -c <"$CONDA_LOG")" 'rerun does not invoke conda'
assert_eq "$first_apt_bytes" "$(wc -c <"$APT_LOG")" 'rerun does not invoke apt'
assert_eq 1 "$(printf '%s\n' "$PATH" | awk -F: -v local_bin="$HOME/.local/bin" '{ for (i = 1; i <= NF; i++) if ($i == local_bin) count++ } END { print count + 0 }')" \
  'rerun does not duplicate local bin in PATH'

reset_case spaces
install_monitoring_tools
read_nul_log "$CONDA_LOG"
assert_eq "$HOME/.local/share/tabby-config/monitoring" "${NUL_ARGS[3]}" 'space-containing prefix remains one conda argument'

printf 'Monitoring installation checks passed\n'
