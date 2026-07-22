#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local message="$3"
  [ "$expected" = "$actual" ] || fail "$message: expected '$expected', got '$actual'"
}

assert_contains() {
  local path="$1"
  local expected="$2"
  grep -F -- "$expected" "$path" >/dev/null ||
    fail "expected $path to contain: $expected"
}

assert_not_contains() {
  local path="$1"
  local expected="$2"
  if grep -F -- "$expected" "$path" >/dev/null; then
    fail "expected $path not to contain: $expected"
  fi
}

assert_files_equal() {
  local expected="$1"
  local actual="$2"
  local message="$3"

  cmp -s "$expected" "$actual" || fail "$message"
}

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

export HOME="$tmp_dir/home"
export XDG_CONFIG_HOME="$tmp_dir/xdg-config"
mkdir -p "$HOME"

# shellcheck source=bootstrap/common.sh
source "$REPO_ROOT/bootstrap/common.sh"
# shellcheck source=bootstrap/server/environment.sh
source "$REPO_ROOT/bootstrap/server/environment.sh"

broken_bashrc="$tmp_dir/broken-bashrc"
printf '%s\n' \
  '# unrelated setting' \
  '# >>> tabby_config server-environment >>>' \
  'partially written managed content' \
  '# unrelated setting after the partial block' >"$broken_bashrc"
original_broken_bashrc="$tmp_dir/original-broken-bashrc"
cp "$broken_bashrc" "$original_broken_bashrc"
if upsert_managed_block "$broken_bashrc" server-environment 'replacement content'; then
  fail 'unterminated managed blocks must be rejected without rewriting bashrc'
fi
assert_files_equal "$original_broken_bashrc" "$broken_bashrc" 'unterminated managed block preserves bashrc bytes'

orphan_end_bashrc="$tmp_dir/orphan-end-bashrc"
printf '%s\n' \
  '# unrelated setting' \
  '# <<< tabby_config server-environment <<<' \
  '# unrelated setting after the orphan end marker' >"$orphan_end_bashrc"
original_orphan_end_bashrc="$tmp_dir/original-orphan-end-bashrc"
cp "$orphan_end_bashrc" "$original_orphan_end_bashrc"
if upsert_managed_block "$orphan_end_bashrc" server-environment 'replacement content'; then
  fail 'orphan managed end markers must be rejected without rewriting bashrc'
fi
assert_files_equal "$original_orphan_end_bashrc" "$orphan_end_bashrc" 'orphan managed end marker preserves bashrc bytes'

symlink_target="$tmp_dir/symlink-target-bashrc"
symlink_bashrc="$tmp_dir/symlink-bashrc"
printf '%s\n' '# unrelated symlinked bashrc setting' >"$symlink_target"
ln -s "$symlink_target" "$symlink_bashrc"
upsert_managed_block "$symlink_bashrc" server-environment 'symlink replacement content'
[ -L "$symlink_bashrc" ] || fail 'managed block update preserves bashrc symlinks'
assert_contains "$symlink_target" 'symlink replacement content'

git_global_proxy() {
  printf '%s\n' "${MOCK_GIT_PROXY:-}"
}

sudo_call_count=0
sudo_available() {
  sudo_call_count=$((sudo_call_count + 1))
  return 0
}

SERVER_HAS_SUDO=true
server_has_sudo || fail 'literal SERVER_HAS_SUDO=true enables sudo'
assert_eq 0 "$sudo_call_count" 'literal true does not call sudo_available'
SERVER_HAS_SUDO=false
if server_has_sudo; then
  fail 'literal SERVER_HAS_SUDO=false disables sudo'
fi
assert_eq 0 "$sudo_call_count" 'literal false does not call sudo_available'
SERVER_HAS_SUDO=invalid
server_has_sudo || fail 'invalid SERVER_HAS_SUDO falls back to sudo_available'
assert_eq 1 "$sudo_call_count" 'invalid SERVER_HAS_SUDO calls sudo_available'
unset SERVER_HAS_SUDO
server_has_sudo || fail 'unset SERVER_HAS_SUDO falls back to sudo_available'
assert_eq 2 "$sudo_call_count" 'unset SERVER_HAS_SUDO calls sudo_available'

clear_proxy_environment() {
  unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY
  unset MOCK_GIT_PROXY
}

clear_proxy_environment
http_proxy='http://first.example:8123'
https_proxy='http://second.example:8443'
assert_eq 'http://first.example:8123' "$(detect_proxy_candidate)" 'http_proxy takes precedence'

clear_proxy_environment
HTTPS_PROXY='https://upper.example:9443'
assert_eq 'https://upper.example:9443' "$(detect_proxy_candidate)" 'uppercase HTTPS proxy is considered'

clear_proxy_environment
MOCK_GIT_PROXY='http://git.example:9000'
assert_eq 'http://git.example:9000' "$(detect_proxy_candidate)" 'Git proxy is used as fallback'

clear_proxy_environment
mkdir -p "$HOME/tools/clash-for-linux"
cat >"$HOME/tools/clash-for-linux/.env" <<'EOF'
MIXED_PORT=17890
EOF
assert_eq 'http://127.0.0.1:17890' "$(detect_proxy_candidate)" 'Clash mixed port is used as fallback'
rm "$HOME/tools/clash-for-linux/.env"
assert_eq 'http://127.0.0.1:7890' "$(detect_proxy_candidate)" 'default proxy fallback is used'

assert_eq $'proxy.example\t8080' \
  "$(python3 "$REPO_ROOT/bootstrap/proxy_endpoint.py" 'http://user:secret@proxy.example:8080')" \
  'proxy endpoint removes credentials'
assert_eq $'proxy.example\t8080' \
  "$(python3 "$REPO_ROOT/bootstrap/proxy_endpoint.py" '  proxy.example:8080  ')" \
  'proxy endpoint trims surrounding whitespace'
assert_eq $'proxy.example\t80' \
  "$(python3 "$REPO_ROOT/bootstrap/proxy_endpoint.py" 'http://proxy.example')" \
  'proxy endpoint uses the HTTP default port when no delimiter is present'
if python3 "$REPO_ROOT/bootstrap/proxy_endpoint.py" 'http://proxy.example:' >/dev/null 2>&1; then
  fail 'proxy endpoint rejects an explicitly empty port delimiter'
fi
if python3 "$REPO_ROOT/bootstrap/proxy_endpoint.py" 'http://proxy.example:99999' >/dev/null 2>&1; then
  fail 'proxy endpoint rejects out-of-range ports'
fi

aliases="$(render_proxy_aliases '2001:db8::1' 1080)"
case "$aliases" in
  *'http://[2001:db8::1]:1080'*'socks5://[2001:db8::1]:1080'*'nc -X 5 -x [2001:db8::1]:1080'*) ;;
  *) fail 'proxy aliases use normalized IPv6 endpoint values' ;;
esac
case "$aliases" in
  *'HTTP_PROXY'*'HTTPS_PROXY'*'ALL_PROXY'*'NO_PROXY'*'GIT_SSH_COMMAND'*'unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY no_proxy NO_PROXY GIT_SSH_COMMAND'*) ;;
  *) fail 'proxy aliases export and clear all managed variables' ;;
esac

ipv4_aliases="$(render_proxy_aliases '127.0.0.1' 7890)"
case "$ipv4_aliases" in
  *'http://127.0.0.1:7890'*'socks5://127.0.0.1:7890'*) ;;
  *) fail 'proxy aliases render IPv4 endpoint values' ;;
esac

write_server_shell_environment 'http://user:secret@proxy.example:8080' true true
config_dir="$XDG_CONFIG_HOME/tabby-config"
proxy_file="$config_dir/proxy-aliases.sh"
server_file="$config_dir/server-env.sh"
[ -f "$proxy_file" ] || fail 'proxy aliases file was written'
[ -f "$server_file" ] || fail 'server environment file was written'
assert_contains "$proxy_file" 'proxy.example:8080'
assert_not_contains "$proxy_file" 'user:secret'
assert_contains "$server_file" '$HOME/miniforge3/condabin'
assert_contains "$server_file" '$HOME/bin'
assert_contains "$server_file" 'DOCKER_HOST=unix:///run/user/$(id -u)/docker.sock'
assert_contains "$HOME/.bashrc" '# >>> tabby_config server-environment >>>'

# shellcheck source=/dev/null
source "$proxy_file"
_tabby_proxy_on
assert_eq 'http://proxy.example:8080' "$http_proxy" 'proxy-on exports HTTP proxy'
assert_eq 'socks5://proxy.example:8080' "$ALL_PROXY" 'proxy-on exports SOCKS proxy'
assert_eq "ssh -o ProxyCommand='nc -X 5 -x proxy.example:8080 %h %p'" "$GIT_SSH_COMMAND" 'proxy-on exports Git SSH command'
_tabby_proxy_off
[ -z "${http_proxy+x}" ] || fail 'proxy-off clears HTTP proxy'
[ -z "${GIT_SSH_COMMAND+x}" ] || fail 'proxy-off clears Git SSH command'

first_bashrc="$(cat "$HOME/.bashrc")"
write_server_shell_environment 'http://user:changed@proxy.example:8080' false false
second_bashrc="$(cat "$HOME/.bashrc")"
assert_eq 1 "$(grep -Fc '# >>> tabby_config server-environment >>>' "$HOME/.bashrc")" 'bashrc has one managed source block'
assert_contains "$server_file" '# conda integration disabled'
assert_contains "$server_file" '# rootless Docker integration disabled'
assert_not_contains "$server_file" '$HOME/miniforge3/condabin'
assert_not_contains "$server_file" 'DOCKER_HOST=unix:///run/user/$(id -u)/docker.sock'
[ "$first_bashrc" = "$second_bashrc" ] || fail 'identical managed bashrc source block is preserved across reruns'

printf 'server environment tests passed\n'
