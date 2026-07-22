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
  local haystack="$1" needle="$2" message="$3"
  case "$haystack" in
    *"$needle"*) ;;
    *) fail "$message: missing '$needle'" ;;
  esac
}

read_nul_log() {
  local path="$1"
  NUL_ARGS=()
  [ -s "$path" ] && mapfile -d '' -t NUL_ARGS <"$path"
}

# shellcheck source=bootstrap/common.sh
source "$REPO_ROOT/bootstrap/common.sh"
# shellcheck source=bootstrap/server/codex.sh
source "$REPO_ROOT/bootstrap/server/codex.sh"

tmp_root="$(mktemp -d)"
trap 'rm -rf "$tmp_root"' EXIT

declare -A PLUGIN_ADD_STATUS_BY_SELECTOR=()

codex_command_discovery() {
  [ "$1" = codex ] && [ "$CODEX_DISCOVERY" = present ] || return 1
  printf '%s\n' "$MOCK_BIN/codex"
}

codex_npm_discovery() {
  [ "$1" = npm ] && [ -n "$NPM_PATH" ] || return 1
  printf '%s\n' "$NPM_PATH"
}

codex_cli() {
  printf '%s\0' "$@" >>"$CODEX_LOG"
  case "${1:-}" in
    --version) return "$CODEX_VERSION_STATUS" ;;
    plugin)
      case "${2:-}" in
        list)
          [ "$PLUGIN_LIST_STATUS" -eq 0 ] || return "$PLUGIN_LIST_STATUS"
          printf '%s\n' "$PLUGIN_LIST"
          ;;
        add)
          printf '%s\n' "$3" >>"$PLUGIN_ADD_CALL_LOG"
          [ "${PLUGIN_ADD_STATUS_BY_SELECTOR[$3]:-$PLUGIN_ADD_STATUS}" -eq 0 ] ||
            return "${PLUGIN_ADD_STATUS_BY_SELECTOR[$3]:-$PLUGIN_ADD_STATUS}"
          [ "$#" -eq 3 ] || fail 'plugin add received unexpected arguments'
          printf 'add:%s\n' "$3" >>"$EVENT_LOG"
          if [ "$PLUGIN_ADD_PUBLISH" = true ]; then
            PLUGIN_LIST="${PLUGIN_LIST}${PLUGIN_LIST:+$'\n'}$3 installed, enabled"
          fi
          ;;
        *) return 64 ;;
      esac
      ;;
    *) return 64 ;;
  esac
}

codex_clone_repo_at_ref() {
  local repo="$1" ref="$2" target="$3"
  printf '%s\0' "$@" >>"$CLONE_LOG"
  printf 'clone\n' >>"$EVENT_LOG"
  [ "$CLONE_STATUS" -eq 0 ] || return "$CLONE_STATUS"
  if [ "$CLONE_CREATE_GIT" = true ]; then
    mkdir -p "$target/.git"
  else
    mkdir -p "$target"
  fi
  if [ "$CLONE_CREATE_VALID_SOURCE" = true ]; then
    make_complete_skill "$target" no
  else
    printf '%s\n' 'not a skill' >"$target/SKILL.md"
  fi
  GIT_HEAD="${CLONED_GIT_HEAD:-$ref}"
}

codex_git() {
  [ "$1" = -C ] && [ "$3" = rev-parse ] && [ "$4" = HEAD ] || return 64
  printf '%s\n' "$GIT_HEAD"
}

codex_npm() {
  printf '%s\0' "$@" >>"$NPM_LOG"
  printf 'npm\n' >>"$EVENT_LOG"
  if [ "$NPM_STATUS" -eq 0 ] && [ "$NPM_CREATES_DEPENDENCY" = true ]; then
    mkdir -p "$2/node_modules/beautiful-mermaid"
    printf '%s\n' '{}' >"$2/node_modules/beautiful-mermaid/package.json"
  fi
  return "$NPM_STATUS"
}

install_codex_server_config() {
  printf 'config\n' >>"$EVENT_LOG"
  return "$CONFIG_STATUS"
}

make_complete_skill() {
  local target="$1" with_dependency="$2"
  mkdir -p "$target/scripts"
  printf '%s\n' '---' 'name: pretty-mermaid' '---' >"$target/SKILL.md"
  printf '%s\n' '{}' >"$target/package.json"
  printf '%s\n' '// render' >"$target/scripts/render.mjs"
  printf '%s\n' '// batch' >"$target/scripts/batch.mjs"
  printf '%s\n' '// themes' >"$target/scripts/themes.mjs"
  if [ "$with_dependency" = yes ]; then
    mkdir -p "$target/node_modules/beautiful-mermaid"
    printf '%s\n' '{}' >"$target/node_modules/beautiful-mermaid/package.json"
  fi
}

reset_case() {
  local name="$1"
  HOME="$tmp_root/$name/home with spaces"
  CODEX_HOME="$HOME/codex home"
  MOCK_BIN="$tmp_root/$name/mock bin"
  CODEX_LOG="$tmp_root/$name/codex-args.bin"
  CLONE_LOG="$tmp_root/$name/clone-args.bin"
  NPM_LOG="$tmp_root/$name/npm-args.bin"
  PLUGIN_ADD_CALL_LOG="$tmp_root/$name/plugin-add-calls.log"
  EVENT_LOG="$tmp_root/$name/events.log"
  export HOME CODEX_HOME MOCK_BIN CODEX_LOG CLONE_LOG NPM_LOG EVENT_LOG PLUGIN_ADD_CALL_LOG
  mkdir -p "$HOME" "$MOCK_BIN"
  : >"$CODEX_LOG"
  : >"$CLONE_LOG"
  : >"$NPM_LOG"
  : >"$PLUGIN_ADD_CALL_LOG"
  : >"$EVENT_LOG"
  CODEX_DISCOVERY=present
  CODEX_VERSION_STATUS=0
  PLUGIN_LIST_STATUS=0
  PLUGIN_ADD_STATUS=0
  PLUGIN_ADD_STATUS_BY_SELECTOR=()
  PLUGIN_ADD_PUBLISH=true
  PLUGIN_LIST=''
  CLONE_STATUS=0
  CLONE_CREATE_GIT=true
  CLONE_CREATE_VALID_SOURCE=true
  GIT_HEAD=''
  CLONED_GIT_HEAD=''
  NPM_PATH=''
  NPM_STATUS=0
  NPM_CREATES_DEPENDENCY=true
  CONFIG_STATUS=0
  unset DOTFILES_FORCE_INSTALL
}

plugin_add_count() {
  grep -c '^add:' "$EVENT_LOG" || true
}

reset_case missing-codex
CODEX_DISCOVERY=missing
if install_codex_server >/dev/null 2>&1; then
  fail 'missing Codex must fail before mutation'
fi
[ ! -e "$CODEX_HOME" ] || fail 'missing Codex created CODEX_HOME'
assert_eq 0 "$(wc -c <"$CLONE_LOG")" 'missing Codex does not clone'

reset_case unusable-codex
CODEX_VERSION_STATUS=9
if install_codex_server >"$tmp_root/unusable.out" 2>&1; then
  fail 'unusable Codex must fail before mutation'
fi
assert_contains "$(<"$tmp_root/unusable.out")" 'codex --version' 'unusable Codex error is actionable'
[ ! -e "$CODEX_HOME" ] || fail 'unusable Codex created CODEX_HOME'

reset_case old-codex
PLUGIN_LIST_STATUS=42
if install_codex_server >"$tmp_root/old.out" 2>&1; then
  fail 'Codex without plugin support must fail'
fi
assert_contains "$(<"$tmp_root/old.out")" 'plugin' 'missing plugin support error is actionable'
assert_eq 0 "$(plugin_add_count)" 'old Codex does not add plugins'

reset_case installed-plugins
PLUGIN_LIST=$'figma@openai-curated installed, enabled\nsuperpowers@openai-curated installed, disabled\ngmail@openai-curated installed, enabled\nnotion@openai-curated installed, enabled'
ensure_codex_plugin figma@openai-curated
ensure_codex_plugin superpowers@openai-curated
assert_eq 0 "$(plugin_add_count)" 'installed enabled or disabled plugins are reused'

reset_case exact-plugin-selector
PLUGIN_LIST=$'figma@openai-curated-extra installed, enabled\nsuperpowers@openai-curated not installed'
if codex_plugin_installed figma@openai-curated; then
  fail 'prefix selector must not count as installed'
fi
if codex_plugin_installed superpowers@openai-curated; then
  fail 'not installed status must not count as installed'
fi
ensure_codex_plugin figma@openai-curated
assert_eq 1 "$(plugin_add_count)" 'missing exact selector is added once'
assert_eq 'add:figma@openai-curated' "$(<"$EVENT_LOG")" 'only requested plugin is added'

reset_case plugin-add-failures
PLUGIN_LIST_STATUS=8
if ensure_codex_plugin figma@openai-curated >/dev/null 2>&1; then
  fail 'plugin list failure must propagate'
fi
PLUGIN_LIST_STATUS=0
PLUGIN_ADD_STATUS=7
if ensure_codex_plugin figma@openai-curated >/dev/null 2>&1; then
  fail 'plugin add failure must propagate'
fi

reset_case plugin-post-add-missing
PLUGIN_ADD_PUBLISH=false
if ensure_codex_plugin figma@openai-curated >/dev/null 2>&1; then
  fail 'plugin add must verify the selector appears in a later list'
fi
PLUGIN_ADD_PUBLISH=true
ensure_codex_plugin figma@openai-curated
assert_eq $'figma@openai-curated\nfigma@openai-curated' "$(<"$PLUGIN_ADD_CALL_LOG")" \
  'post-add failure can be retried safely'

reset_case valid-skill
make_complete_skill "$CODEX_HOME/skills/pretty-mermaid" yes
install_pretty_mermaid
assert_eq 0 "$(wc -c <"$CLONE_LOG")" 'valid skill is reused without clone'
assert_eq 0 "$(wc -c <"$NPM_LOG")" 'valid skill is reused without npm'

reset_case invalid-skill
mkdir -p "$CODEX_HOME/skills/pretty-mermaid"
printf '%s\n' '---' 'name: pretty-mermaid' '---' >"$CODEX_HOME/skills/pretty-mermaid/SKILL.md"
NPM_PATH="$MOCK_BIN/npm"
install_pretty_mermaid
find "$CODEX_HOME/skills" -maxdepth 1 -name 'pretty-mermaid.bak.*' -print -quit | grep -q . ||
  fail 'invalid skill must be backed up before replacement'
read_nul_log "$CLONE_LOG"
assert_eq "$PRETTY_MERMAID_REPO" "${NUL_ARGS[0]:-}" 'clone receives pinned repository'
assert_eq "$PRETTY_MERMAID_REF" "${NUL_ARGS[1]:-}" 'clone receives pinned ref'
assert_eq "$CODEX_HOME/skills/pretty-mermaid" "${NUL_ARGS[2]:-}" 'clone receives exact target'
read_nul_log "$NPM_LOG"
assert_eq --prefix "${NUL_ARGS[0]:-}" 'npm uses prefix option'
assert_eq "$CODEX_HOME/skills/pretty-mermaid" "${NUL_ARGS[1]:-}" 'npm receives exact target'
assert_eq install "${NUL_ARGS[2]:-}" 'npm installs dependencies'
assert_eq --omit=dev "${NUL_ARGS[3]:-}" 'npm omits dev dependencies'
assert_eq --ignore-scripts "${NUL_ARGS[4]:-}" 'npm never runs lifecycle scripts'

reset_case clone-without-git
CLONE_CREATE_GIT=false
if install_pretty_mermaid >/dev/null 2>&1; then
  fail 'new clone without a git checkout must fail pinned verification'
fi

reset_case bad-pinned-checkout
CLONED_GIT_HEAD=wrong
if install_pretty_mermaid >/dev/null 2>&1; then
  fail 'pinned checkout verification must fail on a wrong ref'
fi

reset_case npm-failure
NPM_PATH="$MOCK_BIN/npm"
NPM_STATUS=5
if install_pretty_mermaid >/dev/null 2>&1; then
  fail 'npm failure must propagate'
fi

reset_case dependency-retry
make_complete_skill "$CODEX_HOME/skills/pretty-mermaid" no
NPM_PATH="$MOCK_BIN/npm"
NPM_STATUS=5
if install_pretty_mermaid >/dev/null 2>&1; then
  fail 'npm failure on an existing source must propagate'
fi
pretty_mermaid_source_valid "$CODEX_HOME/skills/pretty-mermaid" ||
  fail 'npm failure must retain a valid source checkout for retry'
NPM_STATUS=0
install_pretty_mermaid
pretty_mermaid_dependencies_ready "$CODEX_HOME/skills/pretty-mermaid" ||
  fail 'rerun installs the missing rendering dependency'
assert_eq 0 "$(wc -c <"$CLONE_LOG")" 'dependency retry does not reclone a valid source'

reset_case dependency-after-npm-available
make_complete_skill "$CODEX_HOME/skills/pretty-mermaid" no
install_pretty_mermaid >"$tmp_root/npm-later.out" 2>&1
assert_eq 0 "$(wc -c <"$NPM_LOG")" 'missing npm does not attempt installation'
NPM_PATH="$MOCK_BIN/npm"
install_pretty_mermaid
pretty_mermaid_dependencies_ready "$CODEX_HOME/skills/pretty-mermaid" ||
  fail 'npm installed later satisfies a previously valid source checkout'

reset_case npm-absent
install_pretty_mermaid >"$tmp_root/npm-absent.out" 2>&1
pretty_mermaid_source_valid "$CODEX_HOME/skills/pretty-mermaid" ||
  fail 'source skill remains valid when npm is absent'
assert_contains "$(<"$tmp_root/npm-absent.out")" 'Node.js/npm' 'missing npm warns clearly'

reset_case full-install
PLUGIN_LIST='unrelated@local 1.0.0 installed enabled'
printf '%s\n' 'unrelated plugin config' >"$HOME/unrelated-plugin-state"
install_codex_server
assert_eq 2 "$(plugin_add_count)" 'server install adds exactly the two required plugins'
assert_eq config "$(tail -n 1 "$EVENT_LOG")" 'config merge runs last'
[ -f "$HOME/unrelated-plugin-state" ] || fail 'unrelated plugin state is preserved'
first_add_count="$(plugin_add_count)"
first_clone_size="$(wc -c <"$CLONE_LOG")"
first_npm_size="$(wc -c <"$NPM_LOG")"
install_codex_server
assert_eq "$first_add_count" "$(plugin_add_count)" 'second run does not add plugins'
assert_eq "$first_clone_size" "$(wc -c <"$CLONE_LOG")" 'second run does not clone skill'
assert_eq "$first_npm_size" "$(wc -c <"$NPM_LOG")" 'second run does not install npm dependencies'

reset_case partial-failure-rerun
PLUGIN_ADD_STATUS_BY_SELECTOR[superpowers@openai-curated]=6
if install_codex_server >/dev/null 2>&1; then
  fail 'partial plugin failure must fail'
fi
assert_eq 'figma@openai-curated installed, enabled' "$PLUGIN_LIST" \
  'first plugin add persists before second plugin failure'
PLUGIN_ADD_STATUS_BY_SELECTOR[superpowers@openai-curated]=0
install_codex_server
assert_eq $'figma@openai-curated\nsuperpowers@openai-curated\nsuperpowers@openai-curated' \
  "$(<"$PLUGIN_ADD_CALL_LOG")" 'rerun adds only the previously failed plugin'

reset_case config-failure
CONFIG_STATUS=4
if install_codex_server >/dev/null 2>&1; then
  fail 'config merge failure must propagate'
fi

printf 'Codex bootstrap tests passed.\n'
