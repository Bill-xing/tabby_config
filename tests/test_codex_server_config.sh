#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FRAGMENT="$REPO_ROOT/config/codex/server.toml"
MERGER="$REPO_ROOT/bootstrap/merge_codex_config.py"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_file_contains() {
  local path="$1"
  local expected="$2"

  grep -F -- "$expected" "$path" >/dev/null ||
    fail "expected $path to contain: $expected"
}

assert_before() {
  local path="$1"
  local first="$2"
  local second="$3"
  local first_line second_line

  first_line="$(grep -nF -- "$first" "$path" | head -n 1 | cut -d: -f1)"
  second_line="$(grep -nF -- "$second" "$path" | head -n 1 | cut -d: -f1)"
  [ -n "$first_line" ] && [ -n "$second_line" ] && [ "$first_line" -lt "$second_line" ] ||
    fail "expected '$first' before '$second' in $path"
}

assert_rejected() {
  local fragment="$1"
  local existing="$2"
  local message="$3"

  if python3 "$MERGER" "$fragment" "$existing" \
    >"$tmp_dir/rejected.out" 2>"$tmp_dir/rejected.err"; then
    fail "$message"
  fi
  [ ! -s "$tmp_dir/rejected.out" ] ||
    fail "$message: rejected merge emitted partial stdout"
  [ -s "$tmp_dir/rejected.err" ] ||
    fail "$message: rejected merge did not explain the error"
}

assert_fallback_rejected() {
  local fragment="$1"
  local existing="$2"
  local message="$3"

  if python3 "$tmp_dir/fallback_runner.py" "$MERGER" "$fragment" "$existing" \
    >"$tmp_dir/rejected.out" 2>"$tmp_dir/rejected.err"; then
    fail "$message"
  fi
  [ ! -s "$tmp_dir/rejected.out" ] ||
    fail "$message: rejected fallback merge emitted partial stdout"
  [ -s "$tmp_dir/rejected.err" ] ||
    fail "$message: rejected fallback merge did not explain the error"
}

[ -f "$FRAGMENT" ] || fail "missing canonical Codex server config"
[ -f "$MERGER" ] || fail "missing generic Codex config merger"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

cat >"$tmp_dir/fallback_runner.py" <<'PY'
import importlib.util
import sys

merger_path = sys.argv[1]
spec = importlib.util.spec_from_file_location("merge_codex_config_fallback", merger_path)
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
module.tomllib = None
raise SystemExit(module.main([merger_path, *sys.argv[2:]]))
PY

cat >"$tmp_dir/canonical.toml" <<'EOF'
model = "gpt-5.6-sol"
model_reasoning_effort = "high"
service_tier = "fast"
approvals_reviewer = "auto_review"
web_search = "live"
sandbox_mode = "workspace-write"
approval_policy = "on-request"

[tui]
status_line = ["model-with-reasoning", "current-dir", "context-remaining", "fast-mode"]
status_line_use_colors = true
notifications = ["agent-turn-complete", "approval-requested"]
notification_method = "osc9"
notification_condition = "always"

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

cmp -s "$tmp_dir/canonical.toml" "$FRAGMENT" ||
  fail "config/codex/server.toml must match the canonical server config exactly"
python3 - "$FRAGMENT" "$MERGER" <<'PY'
import importlib.util
import pathlib
import sys

fragment_path, merger_path = map(pathlib.Path, sys.argv[1:])
spec = importlib.util.spec_from_file_location("merge_codex_config", merger_path)
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
module.parse_fragment(fragment_path.read_text(encoding="utf-8"))
PY

python3 "$MERGER" "$FRAGMENT" >"$tmp_dir/empty-merge.toml"
cmp -s "$FRAGMENT" "$tmp_dir/empty-merge.toml" ||
  fail "merging into an empty config must reproduce the fragment exactly"

cat >"$tmp_dir/existing.toml" <<'EOF'
# keep this top-level comment
model = "gpt-old"
custom_top = "keep"
approval_policy = "never" # replace this managed line

[tui]
# keep this TUI comment
animations = true
notifications = false
status_line = ["old"]

[tui.model_availability_nux]
"gpt-5.6-sol" = 1
"custom-model" = 9

[projects."/srv/app"]
trust_level = "trusted"

[mcp_servers.keep]
command = "keep-mcp"

[plugins."other@local"]
enabled = false

[features]
custom_feature = true
remote_plugin = true

[plugins."figma@openai-curated"]
enabled = false

[sandbox_workspace_write]
writable_roots = ["/srv/app"]
network_access = false
EOF

cat >"$tmp_dir/expected.toml" <<'EOF'
# keep this top-level comment
model = "gpt-5.6-sol"
custom_top = "keep"
approval_policy = "on-request"
model_reasoning_effort = "high"
service_tier = "fast"
approvals_reviewer = "auto_review"
web_search = "live"
sandbox_mode = "workspace-write"

[tui]
# keep this TUI comment
animations = true
notifications = ["agent-turn-complete", "approval-requested"]
status_line = ["model-with-reasoning", "current-dir", "context-remaining", "fast-mode"]
status_line_use_colors = true
notification_method = "osc9"
notification_condition = "always"

[tui.model_availability_nux]
"gpt-5.6-sol" = 4
"custom-model" = 9

[projects."/srv/app"]
trust_level = "trusted"

[mcp_servers.keep]
command = "keep-mcp"

[plugins."other@local"]
enabled = false

[features]
custom_feature = true
remote_plugin = false

[plugins."figma@openai-curated"]
enabled = true

[sandbox_workspace_write]
writable_roots = ["/srv/app"]
network_access = true

[plugins."superpowers@openai-curated"]
enabled = true
EOF

python3 "$MERGER" "$FRAGMENT" "$tmp_dir/existing.toml" >"$tmp_dir/merged.toml"
cmp -s "$tmp_dir/expected.toml" "$tmp_dir/merged.toml" ||
  fail "full merge output did not preserve unrelated config and replace managed keys exactly"
assert_file_contains "$tmp_dir/merged.toml" '[projects."/srv/app"]'
assert_file_contains "$tmp_dir/merged.toml" '[mcp_servers.keep]'
assert_file_contains "$tmp_dir/merged.toml" '[plugins."other@local"]'
assert_file_contains "$tmp_dir/merged.toml" '# keep this TUI comment'
assert_file_contains "$tmp_dir/merged.toml" 'custom_top = "keep"'
assert_file_contains "$tmp_dir/merged.toml" '"gpt-5.6-sol" = 4'

python3 "$MERGER" "$FRAGMENT" "$tmp_dir/merged.toml" >"$tmp_dir/second-merge.toml"
cmp -s "$tmp_dir/merged.toml" "$tmp_dir/second-merge.toml" ||
  fail "a second merge must be byte-identical"

cat >"$tmp_dir/nested-first.toml" <<'EOF'
custom_top = true

[tui.experimental]
enabled = true

[plugins."unrelated"]
enabled = false
EOF
python3 "$MERGER" "$FRAGMENT" "$tmp_dir/nested-first.toml" >"$tmp_dir/ordered.toml"
assert_before "$tmp_dir/ordered.toml" 'approval_policy = "on-request"' '[tui]'
assert_before "$tmp_dir/ordered.toml" '[tui]' '[tui.experimental]'
assert_before "$tmp_dir/ordered.toml" '[tui.model_availability_nux]' '[features]'
assert_before "$tmp_dir/ordered.toml" '[features]' '[plugins."figma@openai-curated"]'
assert_before \
  "$tmp_dir/ordered.toml" \
  '[plugins."figma@openai-curated"]' \
  '[plugins."superpowers@openai-curated"]'
assert_before \
  "$tmp_dir/ordered.toml" \
  '[plugins."superpowers@openai-curated"]' \
  '[sandbox_workspace_write]'

cat >"$tmp_dir/duplicate-existing-table.toml" <<'EOF'
[tui]
animations = true
[tui]
show_tooltips = true
EOF
assert_rejected "$FRAGMENT" "$tmp_dir/duplicate-existing-table.toml" \
  "duplicate managed existing tables must be rejected"

cat >"$tmp_dir/duplicate-existing-key.toml" <<'EOF'
[tui]
notifications = false
notifications = true
EOF
assert_rejected "$FRAGMENT" "$tmp_dir/duplicate-existing-key.toml" \
  "duplicate managed existing keys must be rejected"

cat >"$tmp_dir/duplicate-existing-top.toml" <<'EOF'
model = "one"
model = "two"
EOF
assert_rejected "$FRAGMENT" "$tmp_dir/duplicate-existing-top.toml" \
  "duplicate managed top-level keys must be rejected"

cat >"$tmp_dir/duplicate-fragment-table.toml" <<'EOF'
[tui]
notifications = false
[tui]
animations = true
EOF
assert_rejected "$tmp_dir/duplicate-fragment-table.toml" "$tmp_dir/existing.toml" \
  "duplicate managed fragment tables must be rejected"

cat >"$tmp_dir/duplicate-fragment-key.toml" <<'EOF'
[tui]
notifications = false
notifications = true
EOF
assert_rejected "$tmp_dir/duplicate-fragment-key.toml" "$tmp_dir/existing.toml" \
  "duplicate managed fragment keys must be rejected"

cat >"$tmp_dir/duplicate-fragment-top.toml" <<'EOF'
model = "one"
model = "two"
EOF
assert_rejected "$tmp_dir/duplicate-fragment-top.toml" "$tmp_dir/existing.toml" \
  "duplicate managed fragment top-level keys must be rejected"

cat >"$tmp_dir/inline-conflict.toml" <<'EOF'
tui = { notifications = false }
EOF
assert_rejected "$FRAGMENT" "$tmp_dir/inline-conflict.toml" \
  "inline table conflicts must be rejected"

cat >"$tmp_dir/dotted-conflict.toml" <<'EOF'
tui.notifications = false
EOF
assert_rejected "$FRAGMENT" "$tmp_dir/dotted-conflict.toml" \
  "dotted key conflicts must be rejected"

cat >"$tmp_dir/plugin-dotted-conflict.toml" <<'EOF'
plugins."figma@openai-curated".enabled = false
EOF
assert_rejected "$FRAGMENT" "$tmp_dir/plugin-dotted-conflict.toml" \
  "quoted dotted key conflicts must be rejected"

cat >"$tmp_dir/dotted-fragment.toml" <<'EOF'
tui.notifications = false
EOF
assert_rejected "$tmp_dir/dotted-fragment.toml" "$tmp_dir/existing.toml" \
  "dotted managed fragment keys must be rejected"

cat >"$tmp_dir/multiline-existing-array.toml" <<'EOF'
[tui]
status_line = [
  "model",
]
EOF
assert_rejected "$FRAGMENT" "$tmp_dir/multiline-existing-array.toml" \
  "multiline managed existing arrays must be rejected"

cat >"$tmp_dir/multiline-existing-string.toml" <<'EOF'
model = """
gpt-old
"""
EOF
assert_rejected "$FRAGMENT" "$tmp_dir/multiline-existing-string.toml" \
  "multiline managed existing strings must be rejected"

cat >"$tmp_dir/inline-existing-value.toml" <<'EOF'
[tui]
status_line = { value = "model" }
EOF
assert_rejected "$FRAGMENT" "$tmp_dir/inline-existing-value.toml" \
  "managed existing inline table values must be rejected"

cat >"$tmp_dir/multiline-fragment.toml" <<'EOF'
[tui]
status_line = [
  "model",
]
EOF
assert_rejected "$tmp_dir/multiline-fragment.toml" "$tmp_dir/existing.toml" \
  "multiline managed fragment values must be rejected"

cat >"$tmp_dir/multiline-string-fragment.toml" <<'EOF'
model = """
gpt-new
"""
EOF
assert_rejected "$tmp_dir/multiline-string-fragment.toml" "$tmp_dir/existing.toml" \
  "multiline managed fragment strings must be rejected"

cat >"$tmp_dir/inline-fragment.toml" <<'EOF'
[tui]
status_line = { value = "model" }
EOF
assert_rejected "$tmp_dir/inline-fragment.toml" "$tmp_dir/existing.toml" \
  "managed fragment inline table values must be rejected"

cat >"$tmp_dir/malformed-fragment.toml" <<'EOF'
[tui
notifications = false
EOF
assert_rejected "$tmp_dir/malformed-fragment.toml" "$tmp_dir/existing.toml" \
  "malformed fragments must be rejected"

cat >"$tmp_dir/malformed-existing.toml" <<'EOF'
[unrelated
value = true
EOF
assert_rejected "$FRAGMENT" "$tmp_dir/malformed-existing.toml" \
  "malformed existing configs must be rejected"

printf '[tui]\r\nnotifications = true\r\n' >"$tmp_dir/crlf-fragment.toml"
printf 'custom = true\r\n\r\n[tui]\r\nanimations = true' >"$tmp_dir/crlf-existing.toml"
printf \
  'custom = true\r\n\r\n[tui]\r\nanimations = true\r\nnotifications = true\r\n' \
  >"$tmp_dir/crlf-expected.toml"
python3 "$MERGER" "$tmp_dir/crlf-fragment.toml" >"$tmp_dir/crlf-empty.toml"
cmp -s "$tmp_dir/crlf-fragment.toml" "$tmp_dir/crlf-empty.toml" ||
  fail "empty CRLF merges must preserve fragment bytes"
python3 "$MERGER" "$tmp_dir/crlf-fragment.toml" "$tmp_dir/crlf-existing.toml" \
  >"$tmp_dir/crlf-merged.toml"
cmp -s "$tmp_dir/crlf-expected.toml" "$tmp_dir/crlf-merged.toml" ||
  fail "CRLF merges must use consistent line endings and add a final newline"

if python3 "$MERGER" "$tmp_dir/missing-fragment.toml" \
  >"$tmp_dir/rejected.out" 2>"$tmp_dir/rejected.err"; then
  fail "a missing fragment path must be rejected"
fi
[ ! -s "$tmp_dir/rejected.out" ] || fail "missing fragment failure emitted stdout"

if python3 "$MERGER" "$FRAGMENT" "$tmp_dir/missing-existing.toml" \
  >"$tmp_dir/rejected.out" 2>"$tmp_dir/rejected.err"; then
  fail "an explicitly named missing existing config must be rejected"
fi
[ ! -s "$tmp_dir/rejected.out" ] || fail "missing existing failure emitted stdout"

if python3 "$MERGER" >"$tmp_dir/rejected.out" 2>"$tmp_dir/rejected.err"; then
  fail "invalid CLI arguments must be rejected"
fi
[ ! -s "$tmp_dir/rejected.out" ] || fail "invalid CLI arguments emitted stdout"

cat >"$tmp_dir/fallback-invalid-fragment.toml" <<'EOF'
model = @@@
EOF
assert_fallback_rejected \
  "$tmp_dir/fallback-invalid-fragment.toml" \
  "$tmp_dir/existing.toml" \
  "fallback validation must reject malformed fragment values"

cat >"$tmp_dir/fallback-invalid-existing.toml" <<'EOF'
custom_value = @@@
EOF
assert_fallback_rejected \
  "$FRAGMENT" \
  "$tmp_dir/fallback-invalid-existing.toml" \
  "fallback validation must reject malformed existing values"

assert_fallback_rejected \
  "$FRAGMENT" \
  "$tmp_dir/duplicate-existing-key.toml" \
  "fallback validation must reject duplicate keys"
assert_fallback_rejected \
  "$FRAGMENT" \
  "$tmp_dir/duplicate-existing-table.toml" \
  "fallback validation must reject duplicate tables"

for invalid_value in truth 01 1__2 0xGG 2026-W30-3 2026-07-22T12:34:56z; do
  printf 'custom_value = %s\n' "$invalid_value" >"$tmp_dir/fallback-invalid-scalar.toml"
  assert_fallback_rejected \
    "$FRAGMENT" \
    "$tmp_dir/fallback-invalid-scalar.toml" \
    "fallback validation must reject invalid scalar: $invalid_value"
done

printf 'custom_value = "unterminated\n' >"$tmp_dir/fallback-unclosed-string.toml"
assert_fallback_rejected \
  "$FRAGMENT" \
  "$tmp_dir/fallback-unclosed-string.toml" \
  "fallback validation must reject unclosed strings"

printf 'custom_value = [1, 2\n' >"$tmp_dir/fallback-unclosed-array.toml"
assert_fallback_rejected \
  "$FRAGMENT" \
  "$tmp_dir/fallback-unclosed-array.toml" \
  "fallback validation must reject unclosed arrays"

printf 'custom_value = { name = "broken"\n' >"$tmp_dir/fallback-unclosed-inline.toml"
assert_fallback_rejected \
  "$FRAGMENT" \
  "$tmp_dir/fallback-unclosed-inline.toml" \
  "fallback validation must reject unclosed inline tables"

printf 'custom_value = { name = "broken", }\n' >"$tmp_dir/fallback-inline-trailing-comma.toml"
assert_fallback_rejected \
  "$FRAGMENT" \
  "$tmp_dir/fallback-inline-trailing-comma.toml" \
  "fallback validation must reject inline-table trailing commas"

printf 'custom_value = [1 2]\n' >"$tmp_dir/fallback-array-missing-comma.toml"
assert_fallback_rejected \
  "$FRAGMENT" \
  "$tmp_dir/fallback-array-missing-comma.toml" \
  "fallback validation must reject arrays with missing commas"

printf 'custom_value = "\\UFFFFFFFF"\n' >"$tmp_dir/fallback-invalid-unicode.toml"
assert_fallback_rejected \
  "$FRAGMENT" \
  "$tmp_dir/fallback-invalid-unicode.toml" \
  "fallback validation must reject invalid Unicode code points"

cat >"$tmp_dir/fallback-multiline-inline.toml" <<'EOF'
custom_value = { text = """
not allowed
""" }
EOF
assert_fallback_rejected \
  "$FRAGMENT" \
  "$tmp_dir/fallback-multiline-inline.toml" \
  "fallback validation must reject multiline inline tables"

printf 'bad key = true\n' >"$tmp_dir/fallback-broken-key.toml"
assert_fallback_rejected \
  "$FRAGMENT" \
  "$tmp_dir/fallback-broken-key.toml" \
  "fallback validation must reject broken keys"

printf 'custom_value true\n' >"$tmp_dir/fallback-missing-equals.toml"
assert_fallback_rejected \
  "$FRAGMENT" \
  "$tmp_dir/fallback-missing-equals.toml" \
  "fallback validation must reject missing assignment operators"

cat >"$tmp_dir/fallback-path-collision.toml" <<'EOF'
custom = true
custom.child = false
EOF
assert_fallback_rejected \
  "$FRAGMENT" \
  "$tmp_dir/fallback-path-collision.toml" \
  "fallback validation must reject scalar and child-key collisions"

cat >"$tmp_dir/fallback-scalar-table-collision.toml" <<'EOF'
custom = true

[custom]
EOF
assert_fallback_rejected \
  "$FRAGMENT" \
  "$tmp_dir/fallback-scalar-table-collision.toml" \
  "fallback validation must reject scalar and table collisions"

cat >"$tmp_dir/fallback-dotted-table-collision.toml" <<'EOF'
custom.child = false

[custom]
other = true
EOF
assert_fallback_rejected \
  "$FRAGMENT" \
  "$tmp_dir/fallback-dotted-table-collision.toml" \
  "fallback validation must reject dotted-key and table collisions"

cat >"$tmp_dir/fallback-managed-scalar-table.toml" <<'EOF'
[tui.notifications]
EOF
assert_fallback_rejected \
  "$FRAGMENT" \
  "$tmp_dir/fallback-managed-scalar-table.toml" \
  "fallback merge must reject tables at managed scalar paths"

cat >"$tmp_dir/fallback-valid-existing.toml" <<'EOF'
# preserve fallback comments and common values
custom_date = 2026-07-22T12:34:56Z
custom_numbers = [1, -2, 3.5, 6.02e23, true, "text"]
custom_inline = { name = "value", count = 2 }
custom_multiline = [
  "one", # keep array comment
  "two",
]

[projects."/srv/app"]
trust_level = "trusted"

[mcp_servers.keep]
command = "keep-mcp"
args = ["--flag", "value"]

[[workers]]
name = "one"

[[workers]]
name = "two"
EOF
python3 "$tmp_dir/fallback_runner.py" \
  "$MERGER" \
  "$FRAGMENT" \
  "$tmp_dir/fallback-valid-existing.toml" \
  >"$tmp_dir/fallback-valid-merged.toml"
assert_file_contains \
  "$tmp_dir/fallback-valid-merged.toml" \
  '# preserve fallback comments and common values'
assert_file_contains "$tmp_dir/fallback-valid-merged.toml" 'custom_date = 2026-07-22T12:34:56Z'
assert_file_contains "$tmp_dir/fallback-valid-merged.toml" '[projects."/srv/app"]'
assert_file_contains "$tmp_dir/fallback-valid-merged.toml" '[mcp_servers.keep]'
[ "$(grep -c '^\[\[workers\]\]$' "$tmp_dir/fallback-valid-merged.toml")" -eq 2 ] ||
  fail "fallback validation must preserve repeated array-of-table headers"
python3 "$tmp_dir/fallback_runner.py" \
  "$MERGER" \
  "$FRAGMENT" \
  "$tmp_dir/fallback-valid-merged.toml" \
  >"$tmp_dir/fallback-valid-second.toml"
cmp -s "$tmp_dir/fallback-valid-merged.toml" "$tmp_dir/fallback-valid-second.toml" ||
  fail "fallback validation must preserve byte-identical second merges"

printf 'Codex server config merge checks passed\n'
