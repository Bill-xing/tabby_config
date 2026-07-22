#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FRAGMENT="$REPO_ROOT/config/codex/server.toml"
MERGER="$REPO_ROOT/bootstrap/merge_codex_config.py"
TMUX_CONFIG="$REPO_ROOT/config/tmux/.tmux.conf"
TABBY_CONFIG="$REPO_ROOT/config/tabby/config.yaml"
README="$REPO_ROOT/README.md"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local message="$3"
  [ "$actual" = "$expected" ] ||
    fail "$message: expected '$expected', got '$actual'"
}

assert_file_contains() {
  local path="$1"
  local expected="$2"

  grep -F -- "$expected" "$path" >/dev/null ||
    fail "expected $path to contain: $expected"
}

assert_file_not_contains() {
  local path="$1"
  local unexpected="$2"

  if grep -F -- "$unexpected" "$path" >/dev/null; then
    fail "expected $path not to contain: $unexpected"
  fi
}

[ -f "$FRAGMENT" ] || fail "missing Codex server fragment"
assert_eq "1" "$(grep -c '^\[tui\]$' "$FRAGMENT")" "fragment [tui] table count"
assert_file_contains \
  "$FRAGMENT" \
  'notifications = ["agent-turn-complete", "approval-requested"]'
assert_file_contains "$FRAGMENT" 'notification_method = "osc9"'
assert_file_contains "$FRAGMENT" 'notification_condition = "always"'
assert_file_contains "$FRAGMENT" 'model = "gpt-5.6-sol"'
assert_file_contains "$FRAGMENT" 'status_line_use_colors = true'
assert_file_contains "$FRAGMENT" '[plugins."superpowers@openai-curated"]'
assert_eq \
  "23" \
  "$(awk 'NF && $1 !~ /^#/ { count++ } END { print count + 0 }' "$FRAGMENT")" \
  "fragment meaningful line count"

[ -f "$MERGER" ] || fail "missing Codex config merge tool"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

python3 "$MERGER" "$FRAGMENT" >"$tmp_dir/new.toml"
cmp -s "$FRAGMENT" "$tmp_dir/new.toml" ||
  fail "merging into an empty config must reproduce the fragment"

cat >"$tmp_dir/existing.toml" <<'EOF'
model = "gpt-test"
approval_policy = "on-request"

[tui]
notifications = false
notification_method = "bel"
notification_condition = "unfocused"
EOF

cat >"$tmp_dir/expected.toml" <<'EOF'
model = "gpt-5.6-sol"
approval_policy = "on-request"
model_reasoning_effort = "high"
service_tier = "fast"
approvals_reviewer = "auto_review"
web_search = "live"
sandbox_mode = "workspace-write"

[tui]
notifications = ["agent-turn-complete", "approval-requested"]
notification_method = "osc9"
notification_condition = "always"
status_line = ["model-with-reasoning", "current-dir", "context-remaining", "fast-mode"]
status_line_use_colors = true

[tui.model_availability_nux]
"gpt-5.6-sol" = 4

[features]
remote_plugin = false

[plugins."figma@openai-curated"]
enabled = true

[plugins."superpowers@openai-curated"]
enabled = true

[sandbox_workspace_write]
network_access = true
EOF

python3 "$MERGER" "$FRAGMENT" "$tmp_dir/existing.toml" >"$tmp_dir/merged.toml"
cmp -s "$tmp_dir/expected.toml" "$tmp_dir/merged.toml" ||
  fail "merge must install all managed Codex server keys"

python3 "$MERGER" "$FRAGMENT" "$tmp_dir/merged.toml" >"$tmp_dir/idempotent.toml"
cmp -s "$tmp_dir/merged.toml" "$tmp_dir/idempotent.toml" ||
  fail "an already merged config must remain byte-identical"

awk '
  /^\[tui\]$/ { skip = 1; next }
  /^\[tui\.model_availability_nux\]$/ { skip = 0 }
  !skip { print }
' "$FRAGMENT" >"$tmp_dir/no-tui.toml"
cat >>"$tmp_dir/no-tui.toml" <<'EOF'

[history]
persistence = "save-all"
EOF

cp "$FRAGMENT" "$tmp_dir/no-tui-expected.toml"
cat >>"$tmp_dir/no-tui-expected.toml" <<'EOF'

[history]
persistence = "save-all"
EOF

python3 "$MERGER" "$FRAGMENT" "$tmp_dir/no-tui.toml" >"$tmp_dir/no-tui-merged.toml"
cmp -s "$tmp_dir/no-tui-expected.toml" "$tmp_dir/no-tui-merged.toml" ||
  fail "merge must insert all missing managed sections"

cat >"$tmp_dir/dotted.toml" <<'EOF'
tui.notifications = true
EOF
if python3 "$MERGER" "$FRAGMENT" "$tmp_dir/dotted.toml" \
  >"$tmp_dir/rejected.toml" 2>"$tmp_dir/rejected.err"; then
  fail "conflicting dotted tui keys must be rejected"
fi
[ ! -s "$tmp_dir/rejected.toml" ] ||
  fail "a rejected merge must not emit partial config"

cat >"$tmp_dir/duplicate-table.toml" <<'EOF'
[tui]
animations = true

[tui]
show_tooltips = true
EOF
if python3 "$MERGER" "$FRAGMENT" "$tmp_dir/duplicate-table.toml" \
  >"$tmp_dir/rejected.toml" 2>"$tmp_dir/rejected.err"; then
  fail "duplicate [tui] tables must be rejected"
fi
[ ! -s "$tmp_dir/rejected.toml" ] ||
  fail "a rejected duplicate table merge must not emit partial config"

cat >"$tmp_dir/multiline.toml" <<'EOF'
[tui]
notifications = [
  "agent-turn-complete",
  "approval-requested",
]
EOF
if python3 "$MERGER" "$FRAGMENT" "$tmp_dir/multiline.toml" \
  >"$tmp_dir/rejected.toml" 2>"$tmp_dir/rejected.err"; then
  fail "multiline managed tui values must be rejected rather than corrupted"
fi
[ ! -s "$tmp_dir/rejected.toml" ] ||
  fail "a rejected multiline value merge must not emit partial config"

printf 'Codex server fragment and merge checks passed\n'

# shellcheck source=bootstrap/common.sh
source "$REPO_ROOT/bootstrap/common.sh"

assert_file_contains "$REPO_ROOT/bootstrap/common.sh" 'install_codex_server_config()'
assert_file_contains "$REPO_ROOT/bootstrap/common.sh" '  install_codex_server_config'
assert_file_contains "$REPO_ROOT/bootstrap/common.sh" 'cp -p "$target" "$backup"'
assert_file_contains "$REPO_ROOT/bootstrap/common.sh" 'mv -f "$temp_file" "$target"'

export HOME="$tmp_dir/home"
unset CODEX_HOME
mkdir -p "$HOME"

date() {
  if [ "$#" -eq 1 ] && [ "$1" = "+%Y%m%d%H%M%S" ]; then
    printf '%s\n' "20260716120000"
  else
    command date "$@"
  fi
}

MOCK_CODEX_AVAILABLE=1
MOCK_CODEX_BACKUP_COPY_FAILURE=0
MOCK_CODEX_PUBLISH_FAILURE=0

have() {
  if [ "$1" = "codex" ]; then
    [ "$MOCK_CODEX_AVAILABLE" -eq 1 ]
    return
  fi
  command -v "$1" >/dev/null 2>&1
}

cp() {
  if [ "$MOCK_CODEX_BACKUP_COPY_FAILURE" -eq 1 ] &&
    [ "${1:-}" = "-p" ] && [[ "${3:-}" == *.bak.* ]]; then
    [ -f "${2:-}" ] || fail "backup copy must run while the live target exists"
    printf '%s\n' 'partial backup' >"$3"
    return 1
  fi
  command cp "$@"
}

mv() {
  if [ "$MOCK_CODEX_PUBLISH_FAILURE" -eq 1 ] &&
    [ "${1:-}" = "-f" ] && [[ "${2:-}" == *.tmp.* ]]; then
    [ -f "${3:-}" ] || fail "publish must leave the live target in place until rename"
    return 1
  fi
  command mv "$@"
}

install_codex_server_config
target="$HOME/.codex/config.toml"
[ -f "$target" ] || fail "Codex config was not installed"
cmp -s "$FRAGMENT" "$target" ||
  fail "first Codex config install must reproduce the fragment"

cat >"$target" <<'EOF'
model = "gpt-test"
approval_policy = "on-request"

[tui]
status_line = ["model", "current-dir"]
notifications = false
notification_method = "bel"
notification_condition = "unfocused"
EOF
chmod 640 "$target"
command cp "$target" "$tmp_dir/original-config.toml"

install_codex_server_config
backup="${target}.bak.20260716120000"
[ -f "$backup" ] || fail "changed Codex config must be backed up"
cmp -s "$tmp_dir/original-config.toml" "$backup" ||
  fail "Codex config backup must preserve the original bytes"
assert_eq "640" "$(_tabby_file_mode "$backup")" "Codex backup mode"
assert_file_contains "$target" 'model = "gpt-5.6-sol"'
assert_file_contains "$target" 'approval_policy = "on-request"'
assert_file_contains \
  "$target" \
  'notifications = ["agent-turn-complete", "approval-requested"]'
assert_file_contains "$target" 'notification_method = "osc9"'
assert_file_contains "$target" 'notification_condition = "always"'

install_codex_server_config
shopt -s nullglob
backups=("$target".bak.*)
shopt -u nullglob
assert_eq "1" "${#backups[@]}" "idempotent install backup count"

export CODEX_HOME="$tmp_dir/no-backup-codex"
install_codex_server_config
install_codex_server_config
shopt -s nullglob
backups=("$CODEX_HOME/config.toml".bak.*)
shopt -u nullglob
assert_eq "0" "${#backups[@]}" "unchanged config backup count"

export CODEX_HOME="$tmp_dir/backup-failure-codex"
mkdir -p "$CODEX_HOME"
target="$CODEX_HOME/config.toml"
cat >"$target" <<'EOF'
model = "backup-failure-original"
custom = "keep"
EOF
chmod 640 "$target"
command cp "$target" "$tmp_dir/backup-failure-original.toml"
MOCK_CODEX_BACKUP_COPY_FAILURE=1
if install_codex_server_config; then
  fail "Codex backup-copy failure must propagate"
fi
MOCK_CODEX_BACKUP_COPY_FAILURE=0
cmp -s "$tmp_dir/backup-failure-original.toml" "$target" ||
  fail "backup-copy failure must leave the live config byte-identical"
shopt -s nullglob
backups=("$target".bak.*)
temps=("$target".tmp.*)
shopt -u nullglob
assert_eq "0" "${#backups[@]}" "failed backup must remove partial backup files"
assert_eq "0" "${#temps[@]}" "failed backup must remove merge temp files"
assert_eq "640" "$(_tabby_file_mode "$target")" "backup-failure target mode"

export CODEX_HOME="$tmp_dir/publish-failure-codex"
mkdir -p "$CODEX_HOME"
target="$CODEX_HOME/config.toml"
cat >"$target" <<'EOF'
model = "publish-failure-original"
custom = "keep"
EOF
chmod 640 "$target"
command cp "$target" "$tmp_dir/publish-failure-original.toml"
MOCK_CODEX_PUBLISH_FAILURE=1
if install_codex_server_config; then
  fail "Codex atomic-publish failure must propagate"
fi
MOCK_CODEX_PUBLISH_FAILURE=0
cmp -s "$tmp_dir/publish-failure-original.toml" "$target" ||
  fail "publish failure must leave the live config byte-identical"
backup="${target}.bak.20260716120000"
[ -f "$backup" ] || fail "publish failure must retain the recovery backup"
cmp -s "$tmp_dir/publish-failure-original.toml" "$backup" ||
  fail "publish-failure backup must preserve the original bytes"
assert_eq "640" "$(_tabby_file_mode "$backup")" "publish-failure backup mode"
shopt -s nullglob
temps=("$target".tmp.*)
shopt -u nullglob
assert_eq "0" "${#temps[@]}" "failed publish must remove merge temp files"

unset CODEX_HOME
export HOME="$tmp_dir/no-codex-home"
mkdir -p "$HOME"
MOCK_CODEX_AVAILABLE=0
install_codex_server_config
[ ! -e "$HOME/.codex" ] ||
  fail "installer must not create Codex config when Codex is unavailable"

printf 'Codex server config install and backup checks passed\n'

assert_file_contains "$TABBY_CONFIG" '  bell: off'
assert_file_contains "$TMUX_CONFIG" 'set -gq allow-passthrough on'
assert_file_contains "$README" 'tabby-osc-notify@1.0.0'
assert_file_contains "$README" '自动安装'
assert_file_contains "$README" '重启 Tabby'
assert_file_contains "$README" '通知权限'
assert_file_contains \
  "$README" \
  '标准 macOS、Ubuntu 和 Windows/MSYS2 安装入口会自动安装校验和锁定的 tabby-osc-notify@1.0.0；完成后重启 Tabby，并在操作系统设置中允许 Tabby 发送通知。'
assert_file_not_contains "$README" '搜索并安装第三方插件'
assert_file_contains "$README" 'notifications = ["agent-turn-complete", "approval-requested"]'
assert_file_contains "$README" 'notification_method = "osc9"'
assert_file_contains "$README" 'notification_condition = "always"'
assert_file_contains "$README" 'Terminal bell'
assert_file_contains "$README" "printf '\\033Ptmux;\\033\\033]9;Codex 通知测试\\007\\033\\\\'"

printf 'Tabby and tmux desktop notification checks passed\n'
