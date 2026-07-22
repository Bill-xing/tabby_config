#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALLER="$REPO_ROOT/install/ubuntu-user.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_eq() {
  local expected="$1" actual="$2" message="$3"
  [ "$expected" = "$actual" ] || fail "$message: expected '$expected', got '$actual'"
}

assert_contains() {
  local haystack="$1" needle="$2" message="$3"
  case "$haystack" in
    *"$needle"*) ;;
    *) fail "$message: missing '$needle'" ;;
  esac
}

assert_not_contains() {
  local haystack="$1" needle="$2" message="$3"
  case "$haystack" in
    *"$needle"*) fail "$message: unexpectedly contained '$needle'" ;;
    *) ;;
  esac
}

grep -F 'if [ "${BASH_SOURCE[0]}" = "$0" ]; then' "$INSTALLER" >/dev/null ||
  fail 'ubuntu-user installer must guard main before it can be sourced safely'

option_state="$(bash -c '
  set +e +u
  set +o pipefail
  source "$1"
  case "$-" in *e*) errexit=on ;; *) errexit=off ;; esac
  case "$-" in *u*) nounset=on ;; *) nounset=off ;; esac
  if shopt -qo pipefail; then pipefail=on; else pipefail=off; fi
  printf "%s %s %s\n" "$errexit" "$nounset" "$pipefail"
' bash "$INSTALLER")"
assert_eq 'off off off' "$option_state" 'sourcing ubuntu-user preserves disabled Bash options'

tmp_root="$(mktemp -d)"
trap 'rm -rf "$tmp_root"' EXIT
export HOME="$tmp_root/source-home"
export XDG_CONFIG_HOME="$tmp_root/source-config"
export XDG_DATA_HOME="$tmp_root/source-data"
export XDG_STATE_HOME="$tmp_root/source-state"
export XDG_CACHE_HOME="$tmp_root/source-cache"
export PATH="$tmp_root/source-bin:/usr/bin:/bin"
mkdir -p "$HOME" "$tmp_root/source-bin"

source_before="$(find "$tmp_root/source-home" -mindepth 1 -print | LC_ALL=C sort)"
# shellcheck source=install/ubuntu-user.sh
source "$INSTALLER"
source_after="$(find "$tmp_root/source-home" -mindepth 1 -print | LC_ALL=C sort)"
assert_eq "$source_before" "$source_after" 'sourcing ubuntu-user has no filesystem side effects'
declare -F main >/dev/null || fail 'sourcing ubuntu-user defines main'

eval "$(declare -f verify_server_bootstrap | sed '1s/verify_server_bootstrap/verify_server_bootstrap_real/')"
eval "$(declare -f summarize_server_bootstrap | sed '1s/summarize_server_bootstrap/summarize_server_bootstrap_real/')"
eval "$(declare -f install_user_cli_stack | sed '1s/install_user_cli_stack/install_user_cli_stack_real/')"
eval "$(declare -f install_config_payload | sed '1s/install_config_payload/install_config_payload_real/')"

record() {
  printf '%s' "$1" >>"$EVENT_LOG"
  shift
  if [ "$#" -gt 0 ]; then
    printf '|%s' "$*" >>"$EVENT_LOG"
  fi
  printf '\n' >>"$EVENT_LOG"
}

maybe_fail() {
  [ "${FAIL_AT:-}" != "$1" ] || return 23
}

is_linux() {
  record validate-linux
  [ "${MOCK_LINUX:-true}" = true ]
}

need_cmd() {
  record need "$1"
  maybe_fail "need-$1"
}

detect_proxy_candidate() {
  record detect-proxy
  printf '%s\n' "$MOCK_PROXY"
}

sudo_available() {
  record detect-sudo
  [ "$MOCK_SUDO" = true ]
}

ensure_base_dirs() { record ensure-base; maybe_fail ensure-base; }
install_user_local_zsh() { record zsh; maybe_fail zsh; }
install_user_cli_stack() { record cli; maybe_fail cli; }
install_user_tree_sitter_cli() { record tree-sitter; maybe_fail tree-sitter; }
install_user_release_tool() { record release "$1 ${2:-}"; maybe_fail "release-$1"; }
install_oh_my_zsh_stack() { record oh-my-zsh; maybe_fail oh-my-zsh; }
install_tmux_plugins() { record tmux-plugins; maybe_fail tmux-plugins; }

install_config_payload() {
  record payload "tabby=${DOTFILES_SKIP_TABBY:-} codex=${DOTFILES_SKIP_CODEX_SERVER_CONFIG:-}"
  [ "${DOTFILES_SKIP_TABBY:-}" = 1 ] || fail 'Tabby skip must be set before config payload'
  [ "${DOTFILES_SKIP_CODEX_SERVER_CONFIG:-}" = 1 ] || fail 'Codex config skip must be set before config payload'
  maybe_fail payload
}

install_ssh_zsh_handoff() { record ssh-handoff; maybe_fail ssh-handoff; }
install_miniforge() { record miniforge; maybe_fail miniforge; }

install_monitoring_tools() {
  local value=false
  server_has_sudo && value=true
  printf '%s\n' "$value" >>"$MODULE_SUDO_LOG"
  record monitoring
  maybe_fail monitoring
}

install_docker() {
  local value=false
  server_has_sudo && value=true
  printf '%s\n' "$value" >>"$MODULE_SUDO_LOG"
  record docker
  maybe_fail docker || return 23
  SERVER_DOCKER_BIN="$MOCK_DOCKER_BIN"
  SERVER_ROOTLESS_DOCKER="$MOCK_ROOTLESS"
  SERVER_DOCKER_NEEDS_RELOGIN="$MOCK_RELOGIN"
  SERVER_DOCKER_REUSED_WITH_WARNINGS="$MOCK_DOCKER_WARNINGS"
  export SERVER_DOCKER_BIN SERVER_ROOTLESS_DOCKER
  export SERVER_DOCKER_NEEDS_RELOGIN SERVER_DOCKER_REUSED_WITH_WARNINGS
}

server_conda_usable() {
  [ "${MOCK_LOCAL_CONDA_USABLE:-true}" = true ]
}

server_git() {
  record git "$*"
  case "$*" in
    'config --global user.name Bill-xing') maybe_fail git-name ;;
    'config --global user.email bill.xjm@gmail.com') maybe_fail git-email ;;
    *) fail "unexpected Git mutation during orchestration: $*" ;;
  esac
}

write_server_shell_environment() {
  record shell-env "$1 $2 $3"
  if [ ! -f "$SHELL_FIXTURE" ]; then
    printf '%s\n' '# managed server environment' >"$SHELL_FIXTURE"
  fi
  maybe_fail shell-env
}

record_codex_npm_action() {
  SERVER_CODEX_NPM_ACTION="$MOCK_NPM_ACTION"
  export SERVER_CODEX_NPM_ACTION
}

install_codex_server() { record codex; maybe_fail codex; }
verify_server_bootstrap() { record verify; maybe_fail verify; }
summarize_server_bootstrap() {
  record summary "rootless=${SERVER_ROOTLESS_DOCKER:-false} relogin=${SERVER_DOCKER_NEEDS_RELOGIN:-false} warnings=${SERVER_DOCKER_REUSED_WITH_WARNINGS:-false} npm=${SERVER_CODEX_NPM_ACTION:-unknown}"
  maybe_fail summary
}

reset_flow_case() {
  local name="$1"
  HOME="$tmp_root/$name/home"
  XDG_CONFIG_HOME="$tmp_root/$name/config"
  XDG_DATA_HOME="$tmp_root/$name/data"
  XDG_STATE_HOME="$tmp_root/$name/state"
  XDG_CACHE_HOME="$tmp_root/$name/cache"
  EVENT_LOG="$tmp_root/$name/events"
  MODULE_SUDO_LOG="$tmp_root/$name/module-sudo"
  SHELL_FIXTURE="$tmp_root/$name/server-env.fixture"
  export HOME XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME
  export EVENT_LOG MODULE_SUDO_LOG SHELL_FIXTURE
  mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME" "$XDG_CACHE_HOME"
  : >"$EVENT_LOG"
  : >"$MODULE_SUDO_LOG"
  MOCK_LINUX=true
  MOCK_SUDO=true
  MOCK_PROXY='http://proxy.example:8080'
  MOCK_DOCKER_BIN='/fixture/bin/docker'
  MOCK_ROOTLESS=false
  MOCK_RELOGIN=true
  MOCK_DOCKER_WARNINGS=false
  MOCK_NPM_ACTION=installed
  MOCK_LOCAL_CONDA_USABLE=true
  FAIL_AT=''
  unset SERVER_HAS_SUDO SERVER_DOCKER_BIN SERVER_ROOTLESS_DOCKER
  unset SERVER_DOCKER_NEEDS_RELOGIN SERVER_DOCKER_REUSED_WITH_WARNINGS
  unset SERVER_CODEX_NPM_ACTION DOTFILES_SKIP_TABBY DOTFILES_SKIP_CODEX_SERVER_CONFIG
}

expected_prefix=$'validate-linux\nneed|apt-get\nneed|cc\nneed|cmp\nneed|curl\nneed|dpkg-deb\nneed|file\nneed|git\nneed|python3\nneed|tar\nneed|tmux\nneed|unzip\ndetect-proxy\ndetect-sudo\nensure-base\nzsh\ncli\ntree-sitter\nrelease|nvim install_neovim_linux\nrelease|lazygit install_lazygit_linux\nrelease|yazi install_yazi_linux\noh-my-zsh\ntmux-plugins\npayload|tabby=1 codex=1\nssh-handoff\nminiforge\nmonitoring\ndocker\ngit|config --global user.name Bill-xing\ngit|config --global user.email bill.xjm@gmail.com'
expected_full="${expected_prefix}"$'\nshell-env|http://proxy.example:8080 true false\ncodex\nverify\nsummary|rootless=false relogin=true warnings=false npm=installed'

reset_flow_case system-flow
mkdir -p "$HOME/miniforge3/bin"
: >"$HOME/miniforge3/bin/conda"
chmod +x "$HOME/miniforge3/bin/conda"
main >"$tmp_root/system-flow.out" 2>&1 || fail 'system orchestration unexpectedly failed'
main_output="$(<"$tmp_root/system-flow.out")"
assert_not_contains "$main_output" 'proxy.example' 'orchestration does not log proxy endpoint'
assert_eq true "$SERVER_HAS_SUDO" 'sudo capability is cached as literal true'
assert_eq $'true\ntrue' "$(<"$MODULE_SUDO_LOG")" 'monitoring and Docker reuse cached sudo=true'
assert_eq 1 "$(grep -c '^detect-sudo$' "$EVENT_LOG")" 'sudo is detected exactly once'
assert_eq 2 "$(grep -c '^git|' "$EVENT_LOG")" 'only two Git mutations occur'
assert_eq "$expected_full" "$(<"$EVENT_LOG")" 'complete existing and server flow order and argv'
[ -z "${DOTFILES_SKIP_CODEX_SERVER_CONFIG+x}" ] || fail 'successful payload restores an initially unset Codex skip flag'
[ -z "${DOTFILES_SKIP_TABBY+x}" ] || fail 'successful payload restores an initially unset Tabby skip flag'

path_after_first_main="$PATH"
main 2>&1 >/dev/null || fail 'second orchestration run unexpectedly failed'
assert_eq 1 "$(grep -c '^# managed server environment$' "$SHELL_FIXTURE")" 'two runs do not duplicate managed shell config'
assert_eq "$path_after_first_main" "$PATH" 'two main calls leave PATH byte-identical'

reset_flow_case rootless-flow
MOCK_SUDO=false
MOCK_ROOTLESS=true
MOCK_RELOGIN=false
MOCK_NPM_ACTION=skipped-missing-node-or-npm
main 2>&1 >/dev/null || fail 'rootless orchestration unexpectedly failed'
assert_eq false "$SERVER_HAS_SUDO" 'sudo capability is cached as literal false'
assert_eq $'false\nfalse' "$(<"$MODULE_SUDO_LOG")" 'monitoring and Docker reuse cached sudo=false'
assert_eq 1 "$(grep -c '^detect-sudo$' "$EVENT_LOG")" 'sudo=false is detected exactly once'
assert_contains "$(<"$EVENT_LOG")" 'shell-env|http://proxy.example:8080 false true' 'local Miniforge absence and rootless state reach shell writer'
assert_contains "$(<"$EVENT_LOG")" 'summary|rootless=true relogin=false warnings=false npm=skipped-missing-node-or-npm' 'rootless state reaches summary'

reset_flow_case existing-warning-flow
MOCK_SUDO=false
MOCK_DOCKER_WARNINGS=true
MOCK_RELOGIN=false
main 2>&1 >/dev/null || fail 'existing-warning orchestration unexpectedly failed'
assert_contains "$(<"$EVENT_LOG")" 'summary|rootless=false relogin=false warnings=true npm=installed' 'existing Docker warning state reaches summary'

reset_flow_case credential-proxy
MOCK_PROXY='http://user:top-secret@proxy.example:8080'
credential_output="$(main 2>&1)" || fail 'credential-bearing proxy orchestration unexpectedly failed'
assert_not_contains "$credential_output" 'top-secret' 'raw proxy credentials are never logged'

reset_flow_case proxy-fallback
MOCK_PROXY='http://127.0.0.1:7890'
main >/dev/null 2>&1 || fail 'proxy fallback orchestration unexpectedly failed'
assert_contains "$(<"$EVENT_LOG")" 'shell-env|http://127.0.0.1:7890 false false' 'detected proxy fallback reaches shell environment only as an argument'

reset_flow_case stale-local-conda
mkdir -p "$HOME/miniforge3/bin"
: >"$HOME/miniforge3/bin/conda"
chmod +x "$HOME/miniforge3/bin/conda"
MOCK_LOCAL_CONDA_USABLE=false
main >/dev/null 2>&1 || fail 'stale local conda orchestration unexpectedly failed'
assert_contains "$(<"$EVENT_LOG")" 'shell-env|http://proxy.example:8080 false false' 'stale local Miniforge executable does not enable shell integration'

reset_flow_case payload-failure-restores-flag
export DOTFILES_SKIP_CODEX_SERVER_CONFIG=prior-value
export DOTFILES_SKIP_TABBY=prior-tabby-value
FAIL_AT=payload
if main >/dev/null 2>&1; then
  fail 'payload failure did not propagate'
fi
assert_eq prior-value "$DOTFILES_SKIP_CODEX_SERVER_CONFIG" 'payload failure restores the caller Codex skip flag'
assert_eq prior-tabby-value "$DOTFILES_SKIP_TABBY" 'payload failure restores the caller Tabby skip flag'

for failure in miniforge monitoring docker git-name git-email shell-env codex verify; do
  reset_flow_case "failure-$failure"
  FAIL_AT="$failure"
  if main >"$tmp_root/failure-$failure.out" 2>&1; then
    fail "$failure failure did not propagate"
  fi
  case "$failure" in
    miniforge) later='monitoring' ;;
    monitoring) later='docker' ;;
    docker) later='git|config --global user.name' ;;
    git-name) later='git|config --global user.email' ;;
    git-email) later='shell-env' ;;
    shell-env) later='codex' ;;
    codex) later='verify' ;;
    verify) later='summary' ;;
  esac
  if grep -Fx -- "$later" "$EVENT_LOG" >/dev/null; then
    fail "$failure failure did not short-circuit before $later"
  fi
done

# A nested child failure must not be hidden by later successful siblings.
reset_flow_case nested-cli-failure
linux_arch() { printf '%s\n' x86_64; }
install_github_archive_binary() {
  record cli-child "$3"
  [ "$3" != fd ]
}
install_github_binary() {
  record cli-child "$3"
}
install_user_cli_stack() {
  install_user_cli_stack_real
}
if main >/dev/null 2>&1; then
  fail 'fd installer failure was masked by later CLI installer success'
fi
grep -Fx 'cli-child|fd' "$EVENT_LOG" >/dev/null || fail 'nested CLI regression did not reach fd'
if grep -Fx 'cli-child|rg' "$EVENT_LOG" >/dev/null; then
  fail 'nested CLI failure did not stop before the next child installer'
fi
if grep -Fx tree-sitter "$EVENT_LOG" >/dev/null || grep -Fx summary "$EVENT_LOG" >/dev/null; then
  fail 'nested CLI failure did not stop later bootstrap modules'
fi
install_user_cli_stack() { record cli; maybe_fail cli; }

reset_flow_case nested-config-failure
ensure_base_dirs() { record ensure-base; maybe_fail ensure-base; }
link_or_copy() {
  record config-link "$1 $2"
  case "$1" in */config/zsh/.p10k.zsh) return 29 ;; esac
}
install_tabby_payload() { record config-tabby; }
is_windows() { return 1; }
install_config_payload() {
  install_config_payload_real
}
if main >/dev/null 2>&1; then
  fail 'config link failure was masked by later payload success'
fi
grep -F 'config-link|' "$EVENT_LOG" | grep -F '.p10k.zsh' >/dev/null ||
  fail 'nested config regression did not reach the failing p10k link'
if grep -F 'config-link|' "$EVENT_LOG" | grep -F '.tmux.conf' >/dev/null; then
  fail 'nested config failure did not stop before the next link'
fi
if grep -Fx ssh-handoff "$EVENT_LOG" >/dev/null || grep -Fx summary "$EVENT_LOG" >/dev/null; then
  fail 'nested config failure did not stop later bootstrap modules'
fi
install_config_payload() {
  record payload "tabby=${DOTFILES_SKIP_TABBY:-} codex=${DOTFILES_SKIP_CODEX_SERVER_CONFIG:-}"
  [ "${DOTFILES_SKIP_TABBY:-}" = 1 ] || fail 'Tabby skip must be set before config payload'
  [ "${DOTFILES_SKIP_CODEX_SERVER_CONFIG:-}" = 1 ] || fail 'Codex config skip must be set before config payload'
  maybe_fail payload
}

# Exercise the real read-only final verifier through replaceable host predicates.
verify_git_name='Bill-xing'
verify_git_email='bill.xjm@gmail.com'
verify_conda=true
verify_monitoring=true
verify_docker=true
verify_codex=true
verify_plugins=true
verify_skill=true
verify_dependencies=true
verify_npm=true
verify_node=true
verify_config=true
DOCKER_VERSION_LOG="$tmp_root/docker-version-calls"
PLUGIN_VERIFY_LOG="$tmp_root/plugin-verify-calls"
: >"$DOCKER_VERSION_LOG"
: >"$PLUGIN_VERIFY_LOG"

server_git() {
  case "$*" in
    'config --global --get user.name') printf '%s\n' "$verify_git_name" ;;
    'config --global --get user.email') printf '%s\n' "$verify_git_email" ;;
    *) return 64 ;;
  esac
}
conda_bin() { printf '%s\n' /fixture/miniforge3/bin/conda; }
server_conda_usable() { [ "$verify_conda" = true ]; }
server_monitoring_tool_usable() { [ "$verify_monitoring" = true ]; }
server_monitoring_tool_path() { printf '/fixture/bin/%s\n' "$1"; }
server_docker_version() {
  printf '%s\n' "$1" >>"$DOCKER_VERSION_LOG"
  [ "$verify_docker" = true ] && printf '%s\n' 'Docker version fixture'
}
codex_usable() { [ "$verify_codex" = true ]; }
codex_plugin_installed() {
  printf '%s\n' "$1" >>"$PLUGIN_VERIFY_LOG"
  [ "$verify_plugins" = true ]
}
pretty_mermaid_target() { printf '%s\n' /fixture/codex/skills/pretty-mermaid; }
pretty_mermaid_existing_reusable() { [ "$verify_skill" = true ]; }
pretty_mermaid_dependencies_ready() { [ "$verify_dependencies" = true ]; }
codex_npm_discovery() { [ "$verify_npm" = true ]; }
codex_node_discovery() { [ "$verify_node" = true ]; }
codex_server_config_managed() { [ "$verify_config" = true ]; }

SERVER_DOCKER_BIN=/fixture/bin/docker
SERVER_DOCKER_REUSED_WITH_WARNINGS=false
verify_server_bootstrap_real || fail 'valid final state was rejected'
assert_eq 1 "$(wc -l <"$DOCKER_VERSION_LOG" | tr -d ' ')" 'final verifier checks only the selected Docker version'
assert_eq $'figma@openai-curated\nsuperpowers@openai-curated' "$(<"$PLUGIN_VERIFY_LOG")" 'final verifier checks the exact two Codex plugin selectors'

SERVER_DOCKER_REUSED_WITH_WARNINGS=true
warning_output="$(verify_server_bootstrap_real 2>&1)" || fail 'existing Docker warnings must remain non-fatal'
assert_contains "$warning_output" 'existing Docker installation' 'existing Docker warning is reported'

SERVER_DOCKER_REUSED_WITH_WARNINGS=false
verify_dependencies=false
verify_npm=false
verify_node=false
dependency_output="$(verify_server_bootstrap_real 2>&1)" || fail 'missing optional dependency is allowed without Node/npm'
assert_contains "$dependency_output" 'Node.js/npm' 'allowed dependency omission remains visible'
verify_npm=true
verify_node=true
if verify_server_bootstrap_real >/dev/null 2>&1; then
  fail 'missing pretty-mermaid dependency must fail when Node/npm are available'
fi
verify_dependencies=true

for failure in git-name git-email conda monitoring docker codex plugins skill config; do
  verify_git_name='Bill-xing'
  verify_git_email='bill.xjm@gmail.com'
  verify_conda=true
  verify_monitoring=true
  verify_docker=true
  verify_codex=true
  verify_plugins=true
  verify_skill=true
  verify_config=true
  SERVER_DOCKER_BIN=/fixture/bin/docker
  case "$failure" in
    git-name) verify_git_name=wrong ;;
    git-email) verify_git_email=wrong ;;
    conda) verify_conda=false ;;
    monitoring) verify_monitoring=false ;;
    docker) verify_docker=false ;;
    codex) verify_codex=false ;;
    plugins) verify_plugins=false ;;
    skill) verify_skill=false ;;
    config) verify_config=false ;;
  esac
  if verify_server_bootstrap_real >/dev/null 2>&1; then
    fail "final verifier accepted invalid $failure state"
  fi
done

# Exercise the real summary for system, rootless, relogin, warning, and npm states.
SERVER_CONDA_BIN=/fixture/miniforge3/bin/conda
SERVER_MONITORING_LOCATIONS='nvitop=/fixture/bin/nvitop btop=/fixture/bin/btop htop=/fixture/bin/htop'
SERVER_DOCKER_BIN=/fixture/bin/docker
SERVER_DOCKER_VERSION='Docker version fixture'
SERVER_ROOTLESS_DOCKER=true
SERVER_DOCKER_NEEDS_RELOGIN=false
SERVER_DOCKER_REUSED_WITH_WARNINGS=false
SERVER_CODEX_NPM_ACTION=installed
summary_output="$(summarize_server_bootstrap_real 2>&1)"
assert_contains "$summary_output" 'Tabby was not installed or configured' 'summary states Tabby is untouched'
assert_contains "$summary_output" '/fixture/miniforge3/bin/conda' 'summary identifies conda location'
assert_contains "$summary_output" 'nvitop=/fixture/bin/nvitop' 'summary identifies monitoring locations'
assert_contains "$summary_output" 'rootless' 'summary identifies rootless Docker mode'
assert_contains "$summary_output" 'user systemd' 'summary identifies rootless user service action'
assert_contains "$summary_output" 'npm' 'summary identifies npm action'

SERVER_ROOTLESS_DOCKER=false
SERVER_DOCKER_NEEDS_RELOGIN=true
SERVER_CODEX_NPM_ACTION=not-needed
summary_output="$(summarize_server_bootstrap_real 2>&1)"
assert_contains "$summary_output" 'system' 'summary identifies system Docker mode'
assert_contains "$summary_output" 'log out and back in' 'summary identifies Docker relogin requirement'

printf 'server bootstrap flow tests passed.\n'
