# Tabby OSC Notify Cross-Platform Installation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Automatically and safely install the pinned `tabby-osc-notify@1.0.0` plugin from every desktop installer on both `main` and `server`, while preserving the server-only Tabby skip path and existing user plugins.

**Architecture:** Store the immutable npm tarball URL and SHA-256 beside the repository's other third-party locks. Add focused Bash helpers that derive Tabby's platform-specific plugin directory, validate the archive and package metadata in a staging directory, and replace only `node_modules/tabby-osc-notify` after all checks pass. Exercise the implementation with an offline synthetic tarball, then merge the verified `main` work into `server` and adapt its notification documentation and skip-path assertions.

**Tech Stack:** Bash 3.2-compatible shell, `tar`, `curl`/`wget`, `sha256sum` or `shasum`, Git, existing shell test harnesses, Tabby 1.0.234 plugin layout.

---

## File map

- Create `tests/test_tabby_plugin_install.sh`: offline contract tests for paths, archive safety, checksum handling, idempotence, backup behavior, preservation of unrelated files, and skip dispatch.
- Modify `bootstrap/plugins.lock.sh`: pin the package name, version, immutable tarball URL, and SHA-256.
- Modify `bootstrap/common.sh`: add Tabby skip helpers on `main`, plugin path/manifest/archive helpers, safe installation, and payload dispatch.
- Modify `README.md`: state that all desktop installers install the pinned plugin automatically and document restart/notification-permission requirements.
- Modify `tests/test_codex_notifications.sh` on `server`: replace the old manual-install documentation expectation with the automatic-install contract.
- Create `docs/superpowers/plans/2026-07-16-tabby-osc-notify-plugin-install.md`: this execution plan.
- Preserve `install/ubuntu-user.sh` on `server`: its existing `DOTFILES_SKIP_TABBY=1` must skip both config and plugin through the shared dispatch function.

### Task 1: Add the failing cross-platform plugin contract

**Files:**

- Create: `tests/test_tabby_plugin_install.sh`
- Read: `bootstrap/common.sh`
- Read: `bootstrap/plugins.lock.sh`

- [ ] **Step 1: Create the executable offline test with `apply_patch`**

The test must source `bootstrap/common.sh`, verify the real lock values, and build fixtures without contacting npm. Use this complete structure:

```bash
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
  [ "$actual" = "$expected" ] ||
    fail "$message: expected '$expected', got '$actual'"
}

assert_file_contains() {
  local path="$1"
  local expected="$2"
  grep -F -- "$expected" "$path" >/dev/null ||
    fail "expected $path to contain: $expected"
}

# shellcheck source=bootstrap/common.sh
source "$REPO_ROOT/bootstrap/common.sh"

assert_eq "tabby-osc-notify" "$TABBY_OSC_NOTIFY_NAME" "locked package name"
assert_eq "1.0.0" "$TABBY_OSC_NOTIFY_VERSION" "locked package version"
assert_eq \
  "https://registry.npmjs.org/tabby-osc-notify/-/tabby-osc-notify-1.0.0.tgz" \
  "$TABBY_OSC_NOTIFY_TARBALL_URL" \
  "locked tarball URL"
assert_eq \
  "a48fad95d94768b683f273397d7d818c526de969b3247c430bd309b3b0bb36d8" \
  "$TABBY_OSC_NOTIFY_SHA256" \
  "locked tarball SHA-256"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

export HOME="$tmp_dir/home"
export XDG_CONFIG_HOME="$tmp_dir/xdg-config"
export APPDATA="$tmp_dir/windows-appdata"
mkdir -p "$HOME"

date() {
  if [ "$#" -eq 1 ] && [ "$1" = "+%Y%m%d%H%M%S" ]; then
    printf '%s\n' "20260716124500"
  else
    command date "$@"
  fi
}

assert_eq \
  "$XDG_CONFIG_HOME/tabby/plugins" \
  "$(tabby_plugins_path linux)" \
  "Linux Tabby plugin path"
assert_eq \
  "$HOME/Library/Application Support/tabby/plugins" \
  "$(tabby_plugins_path macos)" \
  "macOS Tabby plugin path"
assert_eq \
  "$APPDATA/Tabby/plugins" \
  "$(tabby_plugins_path windows)" \
  "Windows Tabby plugin path"

safe_list="$tmp_dir/safe.list"
unsafe_list="$tmp_dir/unsafe.list"
printf '%s\n' 'package/' 'package/package.json' 'package/dist/index.js' >"$safe_list"
printf '%s\n' 'package/' 'package/../escape' >"$unsafe_list"
tabby_plugin_archive_list_is_safe "$safe_list" || fail "safe archive list was rejected"
if tabby_plugin_archive_list_is_safe "$unsafe_list"; then
  fail "unsafe archive list was accepted"
fi

make_fixture() {
  local output="$1"
  local package_name="$2"
  local package_version="$3"
  local root="$tmp_dir/fixture-$package_name-$package_version"

  mkdir -p "$root/package/dist"
  printf '{\n  "name": "%s",\n  "version": "%s",\n  "main": "dist/index.js",\n  "keywords": ["tabby-plugin"]\n}\n' \
    "$package_name" "$package_version" >"$root/package/package.json"
  printf '%s\n' 'module.exports = {}' >"$root/package/dist/index.js"
  tar -czf "$output" -C "$root" package
}

good_fixture="$tmp_dir/good.tgz"
bad_fixture="$tmp_dir/bad.tgz"
make_fixture "$good_fixture" "tabby-osc-notify" "1.0.0"
make_fixture "$bad_fixture" "tabby-wrong-plugin" "1.0.0"

FIXTURE="$good_fixture"
fetch_url() {
  cp "$FIXTURE" "$2"
}
TABBY_OSC_NOTIFY_SHA256="$(sha256_file "$good_fixture")"

plugin_root="$(tabby_plugins_path linux)"
target="$plugin_root/node_modules/tabby-osc-notify"
other_plugin="$plugin_root/node_modules/tabby-background"
mkdir -p "$other_plugin"
printf '%s\n' 'keep background' >"$other_plugin/marker"
printf '%s\n' 'keep lock' >"$plugin_root/package-lock.json"

install_tabby_osc_notify linux
[ -f "$target/package.json" ] || fail "plugin package.json was not installed"
[ -f "$target/dist/index.js" ] || fail "plugin entry point was not installed"
assert_file_contains "$target/package.json" '"name": "tabby-osc-notify"'
assert_file_contains "$target/package.json" '"version": "1.0.0"'
assert_file_contains "$other_plugin/marker" 'keep background'
assert_file_contains "$plugin_root/package-lock.json" 'keep lock'

fetch_url() {
  fail "idempotent install attempted another download"
}
install_tabby_osc_notify linux
[ ! -d "$plugin_root/backups" ] ||
  [ -z "$(find "$plugin_root/backups" -mindepth 1 -maxdepth 1 -print -quit)" ] ||
  fail "idempotent install created a backup"

printf '%s\n' '{"name":"tabby-osc-notify","version":"0.9.0"}' >"$target/package.json"
printf '%s\n' 'old plugin entry' >"$target/dist/index.js"
FIXTURE="$good_fixture"
fetch_url() {
  cp "$FIXTURE" "$2"
}
install_tabby_osc_notify linux
assert_file_contains "$target/package.json" '"version": "1.0.0"'
backup="$(find "$plugin_root/backups" -mindepth 1 -maxdepth 1 -type d -name 'tabby-osc-notify.bak.*' -print -quit)"
[ -n "$backup" ] || fail "old plugin backup was not created"
assert_file_contains "$backup/package.json" '"version":"0.9.0"'
assert_eq \
  "$plugin_root/backups/tabby-osc-notify.bak.20260716124500.1" \
  "$(next_tabby_plugin_backup_path "$plugin_root" "tabby-osc-notify")" \
  "collision-safe plugin backup path"
assert_file_contains "$other_plugin/marker" 'keep background'
assert_file_contains "$plugin_root/package-lock.json" 'keep lock'

printf '%s\n' '{"name":"tabby-osc-notify","version":"0.8.0"}' >"$target/package.json"
before_failure="$(cksum <"$target/package.json")"
TABBY_OSC_NOTIFY_SHA256="$(printf '%064d' 0)"
if (install_tabby_osc_notify linux); then
  fail "checksum mismatch unexpectedly succeeded"
fi
assert_eq "$before_failure" "$(cksum <"$target/package.json")" "checksum failure preservation"

FIXTURE="$bad_fixture"
TABBY_OSC_NOTIFY_SHA256="$(sha256_file "$bad_fixture")"
if (install_tabby_osc_notify linux); then
  fail "wrong package metadata unexpectedly succeeded"
fi
assert_eq "$before_failure" "$(cksum <"$target/package.json")" "metadata failure preservation"

calls="$tmp_dir/payload-calls"
install_tabby_config() {
  printf '%s\n' config >>"$calls"
}
install_tabby_osc_notify() {
  printf '%s\n' plugin >>"$calls"
}

unset DOTFILES_SKIP_TABBY
install_tabby_payload
assert_eq $'config\nplugin' "$(<"$calls")" "normal Tabby payload calls"

: >"$calls"
export DOTFILES_SKIP_TABBY=1
install_tabby_payload
[ ! -s "$calls" ] || fail "skip flag still installed Tabby payload"

printf 'Tabby OSC notify plugin install checks passed\n'
```

- [ ] **Step 2: Make the test executable**

Run:

```bash
chmod 0755 tests/test_tabby_plugin_install.sh
```

Expected: `test -x tests/test_tabby_plugin_install.sh` returns zero.

- [ ] **Step 3: Run the test and verify the red state**

Run:

```bash
bash tests/test_tabby_plugin_install.sh
```

Expected: non-zero exit because `TABBY_OSC_NOTIFY_NAME` or `tabby_plugins_path` is not defined yet.

- [ ] **Step 4: Commit the verified red contract**

```bash
git add tests/test_tabby_plugin_install.sh
git commit -m "test: define Tabby OSC notify install contract"
```

Expected: the commit contains only the new executable test; its focused run remains red for the expected missing-feature reason.

### Task 2: Implement the pinned safe installer

**Files:**

- Modify: `bootstrap/plugins.lock.sh`
- Modify: `bootstrap/common.sh`
- Test: `tests/test_tabby_plugin_install.sh`

- [ ] **Step 1: Add immutable plugin lock values**

Append this exact block to `bootstrap/plugins.lock.sh`:

```bash
export TABBY_OSC_NOTIFY_NAME="tabby-osc-notify"
export TABBY_OSC_NOTIFY_VERSION="1.0.0"
export TABBY_OSC_NOTIFY_TARBALL_URL="https://registry.npmjs.org/tabby-osc-notify/-/tabby-osc-notify-1.0.0.tgz"
export TABBY_OSC_NOTIFY_SHA256="a48fad95d94768b683f273397d7d818c526de969b3247c430bd309b3b0bb36d8"
```

- [ ] **Step 2: Add flag helpers after the platform predicates on `main`**

`server` already has these functions; the later merge must keep one copy:

```bash
flag_enabled() {
  case "${1:-0}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

skip_tabby() {
  flag_enabled "${DOTFILES_SKIP_TABBY:-0}"
}
```

- [ ] **Step 3: Add path, metadata, checksum, archive, and backup helpers after `tabby_config_path`**

```bash
tabby_plugins_path() {
  local platform="${1:-$(platform_name)}"
  printf '%s\n' "$(dirname "$(tabby_config_path "$platform")")/plugins"
}

package_json_string_field() {
  local field="$1"
  local path="$2"

  sed -n \
    "s/^[[:space:]]*\"${field}\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" \
    "$path" | sed -n '1p'
}

tabby_osc_notify_package_is_valid() {
  local target="$1"

  [ -d "$target" ] &&
    [ ! -L "$target" ] &&
    [ -f "$target/package.json" ] &&
    [ -f "$target/dist/index.js" ] &&
    [ "$(package_json_string_field name "$target/package.json")" = "$TABBY_OSC_NOTIFY_NAME" ] &&
    [ "$(package_json_string_field version "$target/package.json")" = "$TABBY_OSC_NOTIFY_VERSION" ]
}

sha256_file() {
  local path="$1"

  if have sha256sum; then
    sha256sum "$path" | awk '{ print $1 }'
  elif have shasum; then
    shasum -a 256 "$path" | awk '{ print $1 }'
  else
    warn "Cannot verify SHA-256 (sha256sum or shasum is required)"
    return 1
  fi
}

tabby_plugin_archive_list_is_safe() {
  local list_file="$1"
  local entry saw_member=0

  while IFS= read -r entry || [ -n "$entry" ]; do
    [ -n "$entry" ] || continue
    case "$entry" in
      /*|../*|*/../*|*/..|.|./*|*/./*|*/.) return 1 ;;
    esac
    case "$entry" in
      package|package/*) saw_member=1 ;;
      *) return 1 ;;
    esac
  done <"$list_file"

  [ "$saw_member" -eq 1 ]
}

next_tabby_plugin_backup_path() {
  local plugin_root="$1"
  local package_name="$2"
  local stamp backup suffix

  stamp="$(date +%Y%m%d%H%M%S)"
  backup="$plugin_root/backups/${package_name}.bak.${stamp}"
  suffix=1
  while [ -e "$backup" ] || [ -L "$backup" ]; do
    backup="$plugin_root/backups/${package_name}.bak.${stamp}.${suffix}"
    suffix=$((suffix + 1))
  done
  printf '%s\n' "$backup"
}
```

- [ ] **Step 4: Add the staged installer after `install_tabby_config`**

```bash
install_tabby_osc_notify() {
  local platform="${1:-$(platform_name)}"
  local plugin_root node_modules target tmp_dir archive archive_list unpacked staged
  local actual_sha backup=""

  plugin_root="$(tabby_plugins_path "$platform")"
  node_modules="$plugin_root/node_modules"
  target="$node_modules/$TABBY_OSC_NOTIFY_NAME"

  if tabby_osc_notify_package_is_valid "$target"; then
    log "Reusing $TABBY_OSC_NOTIFY_NAME@$TABBY_OSC_NOTIFY_VERSION"
    return 0
  fi

  mkdir -p "$node_modules"
  tmp_dir="$(mktemp -d "$plugin_root/.${TABBY_OSC_NOTIFY_NAME}.install.XXXXXX")"
  trap 'rm -rf "$tmp_dir"' RETURN
  archive="$tmp_dir/plugin.tgz"
  archive_list="$tmp_dir/archive.list"
  unpacked="$tmp_dir/unpacked"

  log "Installing $TABBY_OSC_NOTIFY_NAME@$TABBY_OSC_NOTIFY_VERSION"
  if ! fetch_url "$TABBY_OSC_NOTIFY_TARBALL_URL" "$archive"; then
    warn "Failed to download $TABBY_OSC_NOTIFY_TARBALL_URL"
    return 1
  fi
  if ! actual_sha="$(sha256_file "$archive")"; then
    return 1
  fi
  if [ "$actual_sha" != "$TABBY_OSC_NOTIFY_SHA256" ]; then
    warn "SHA-256 mismatch for $TABBY_OSC_NOTIFY_NAME: $actual_sha"
    return 1
  fi
  if ! tar -tzf "$archive" >"$archive_list"; then
    warn "Cannot list $TABBY_OSC_NOTIFY_NAME archive"
    return 1
  fi
  if ! tabby_plugin_archive_list_is_safe "$archive_list"; then
    warn "Unsafe paths in $TABBY_OSC_NOTIFY_NAME archive"
    return 1
  fi

  mkdir -p "$unpacked"
  if ! tar -xzf "$archive" -C "$unpacked"; then
    warn "Cannot extract $TABBY_OSC_NOTIFY_NAME archive"
    return 1
  fi
  staged="$unpacked/package"
  chmod -R u+rwX "$staged"
  if ! tabby_osc_notify_package_is_valid "$staged"; then
    warn "Unexpected package metadata for $TABBY_OSC_NOTIFY_NAME"
    return 1
  fi

  if [ -e "$target" ] || [ -L "$target" ]; then
    mkdir -p "$plugin_root/backups"
    backup="$(next_tabby_plugin_backup_path "$plugin_root" "$TABBY_OSC_NOTIFY_NAME")"
    log "Backing up $target -> $backup"
    if ! mv "$target" "$backup"; then
      warn "Cannot back up existing $TABBY_OSC_NOTIFY_NAME"
      return 1
    fi
  fi

  if ! mv "$staged" "$target"; then
    if [ -n "$backup" ]; then
      mv "$backup" "$target" || warn "Cannot restore $backup"
    fi
    warn "Cannot install $TABBY_OSC_NOTIFY_NAME into $target"
    return 1
  fi

  log "Installed $TABBY_OSC_NOTIFY_NAME@$TABBY_OSC_NOTIFY_VERSION; restart Tabby to load it"
}

install_tabby_payload() {
  if skip_tabby; then
    log "Skipping Tabby config and plugins (DOTFILES_SKIP_TABBY is enabled)"
  else
    install_tabby_config
    install_tabby_osc_notify
  fi
}
```

- [ ] **Step 5: Route the shared payload through `install_tabby_payload`**

Replace the direct `install_tabby_config` call in `install_config_payload` with:

```bash
  install_tabby_payload
```

On `server`, replace its existing inline `if skip_tabby` block with the same single call. Do not change `install/ubuntu-user.sh`; its exported flag is the integration point.

- [ ] **Step 6: Run the focused test and fix only contract mismatches**

Run:

```bash
bash tests/test_tabby_plugin_install.sh
```

Expected final line:

```text
Tabby OSC notify plugin install checks passed
```

- [ ] **Step 7: Run the real upstream tarball against an isolated home**

Run:

```bash
tmp_home="$(mktemp -d)"
HOME="$tmp_home" XDG_CONFIG_HOME="$tmp_home/xdg" bash -c '
  source bootstrap/common.sh
  install_tabby_osc_notify linux
  test -f "$XDG_CONFIG_HOME/tabby/plugins/node_modules/tabby-osc-notify/dist/index.js"
'
```

Expected: checksum verification succeeds and the command exits zero without writing to the real Tabby directory.

- [ ] **Step 8: Commit the green installer slice on `main`**

```bash
git add bootstrap/plugins.lock.sh bootstrap/common.sh tests/test_tabby_plugin_install.sh
git commit -m "feat: install pinned Tabby OSC notify plugin"
```

### Task 3: Document automatic desktop installation on `main`

**Files:**

- Modify: `README.md`
- Test: `tests/test_tabby_plugin_install.sh`

- [ ] **Step 1: Add documentation assertions before editing README**

Append these assertions before the test's final success message:

```bash
README="$REPO_ROOT/README.md"
assert_file_contains "$README" 'tabby-osc-notify@1.0.0'
assert_file_contains "$README" '自动安装'
assert_file_contains "$README" '重启 Tabby'
assert_file_contains "$README" '通知权限'
```

- [ ] **Step 2: Run the focused test to verify documentation is red**

Run: `bash tests/test_tabby_plugin_install.sh`

Expected: failure naming the first missing README text.

- [ ] **Step 3: Update README with exact user-facing behavior**

Make these scoped edits:

- Add `tabby-osc-notify@1.0.0` to each desktop platform's installation summary.
- In the Tabby section, state that the desktop installers automatically download the checksum-pinned plugin without requiring Node/npm.
- State that Tabby must be closed during installation and restarted afterward.
- State that macOS, Windows, or Linux notification permission still needs to allow Tabby notifications.
- Add `tabby-osc-notify` to the fixed third-party dependency list.
- Keep the privacy warning that the full local Tabby config and runtime `plugins/` directory are not committed.

- [ ] **Step 4: Run focused tests**

```bash
bash tests/test_tabby_plugin_install.sh
bash tests/test_tabby_config_install.sh
```

Expected: both scripts exit zero and print their success summaries.

- [ ] **Step 5: Commit the documentation slice on `main`**

```bash
git add README.md tests/test_tabby_plugin_install.sh
git commit -m "docs: explain automatic Tabby notification plugin install"
```

### Task 4: Verify the complete `main` branch

**Files:**

- Verify: `bootstrap/common.sh`
- Verify: `bootstrap/plugins.lock.sh`
- Verify: `install/macos.sh`
- Verify: `install/ubuntu.sh`
- Verify: `install/windows-msys2.sh`
- Verify: `tests/test_tabby_plugin_install.sh`
- Verify: `tests/test_tabby_config_install.sh`

- [ ] **Step 1: Run Bash syntax checks**

```bash
bash -n bootstrap/common.sh bootstrap/plugins.lock.sh \
  install/macos.sh install/ubuntu.sh install/windows-msys2.sh \
  tests/test_tabby_plugin_install.sh tests/test_tabby_config_install.sh
```

Expected: no output and exit status zero.

- [ ] **Step 2: Run every test tracked on `main`**

```bash
for test_script in tests/test_*.sh; do
  printf '==> %s\n' "$test_script"
  bash "$test_script"
done
```

Expected: every script exits zero.

- [ ] **Step 3: Check whitespace and the exact diff**

```bash
git diff --check origin/main...HEAD
git status --short --branch
git log --oneline --decorate origin/main..HEAD
```

Expected: no whitespace errors; only the design, plan, installer, test, and README changes are present.

### Task 5: Merge and adapt the verified change on `server`

**Files:**

- Merge: all verified `main` files
- Modify: `README.md`
- Modify: `bootstrap/common.sh` only if conflict resolution is needed
- Modify: `tests/test_codex_notifications.sh`
- Verify unchanged: `install/ubuntu-user.sh`

- [ ] **Step 1: Refresh and switch to the latest server branch**

```bash
git fetch origin main server
git switch -c server --track origin/server
git merge --no-ff main
```

Expected: a merge begins from `origin/server` and may report scoped conflicts in `README.md` or `bootstrap/common.sh` because server already contains OSC 9 and skip logic.

- [ ] **Step 2: Resolve `bootstrap/common.sh` without duplicating helpers**

The resolved server file must contain exactly one definition of each of these functions:

```text
flag_enabled
skip_tabby
force_install
tabby_plugins_path
install_tabby_config
install_tabby_osc_notify
install_tabby_payload
install_codex_notifications
```

`install_config_payload` must still call `install_codex_notifications`, deploy tmux-powerline, and call `install_tabby_payload`. Confirm with:

```bash
for function_name in flag_enabled skip_tabby force_install tabby_plugins_path \
  install_tabby_config install_tabby_osc_notify install_tabby_payload \
  install_codex_notifications; do
  test "$(grep -c "^${function_name}()" bootstrap/common.sh)" -eq 1
done
```

Expected: the loop exits zero.

- [ ] **Step 3: Resolve README by preserving server notification guidance and replacing manual installation**

Keep the Codex `[tui]` configuration, tmux passthrough command, silent bell guidance, and OSC 9 test command. Replace the instruction to search and install the plugin manually with text stating:

```text
标准 macOS、Ubuntu 和 Windows/MSYS2 安装入口会自动安装校验和锁定的 tabby-osc-notify@1.0.0；完成后重启 Tabby，并在操作系统设置中允许 Tabby 发送通知。
```

Also retain the explanation that `install/ubuntu-user.sh` does not install or configure Tabby on a remote server.

- [ ] **Step 4: Strengthen the server notification test**

Add these exact assertions near the existing README checks in `tests/test_codex_notifications.sh`:

```bash
assert_file_contains "$README" 'tabby-osc-notify@1.0.0'
assert_file_contains "$README" '自动安装'
assert_file_contains "$README" '重启 Tabby'
assert_file_contains "$README" '通知权限'
```

Keep all existing assertions for `notification_method = "osc9"`, `allow-passthrough`, terminal bell, and the tmux-wrapped test sequence.

- [ ] **Step 5: Verify the server-only skip integration**

Run:

```bash
grep -F 'export DOTFILES_SKIP_TABBY=1' install/ubuntu-user.sh
bash tests/test_tabby_plugin_install.sh
bash tests/test_codex_notifications.sh
bash tests/test_tabby_config_install.sh
bash tests/test_tmux_powerline_config.sh
```

Expected: grep prints the export line and every test exits zero.

- [ ] **Step 6: Finish the merge commit**

```bash
git add README.md bootstrap/common.sh bootstrap/plugins.lock.sh \
  tests/test_tabby_plugin_install.sh tests/test_codex_notifications.sh \
  docs/superpowers/specs/2026-07-16-tabby-osc-notify-plugin-install-design.md \
  docs/superpowers/plans/2026-07-16-tabby-osc-notify-plugin-install.md
git commit
```

Expected: one merge commit combining the new `main` implementation with the existing server notification work.

### Task 6: Verify both branches, install the current Mac plugin, and publish

**Files:**

- Verify: all changed files on `main` and `server`
- Runtime target: `~/Library/Application Support/tabby/plugins/node_modules/tabby-osc-notify`

- [ ] **Step 1: Run the full server test suite and syntax checks**

```bash
bash -n bootstrap/common.sh bootstrap/plugins.lock.sh install/*.sh tests/test_*.sh
for test_script in tests/test_*.sh; do
  printf '==> %s\n' "$test_script"
  bash "$test_script"
done
git diff --check origin/server...HEAD
```

Expected: all commands exit zero.

- [ ] **Step 2: Return to `main` and re-run its complete verification**

```bash
git switch main
bash -n bootstrap/common.sh bootstrap/plugins.lock.sh install/*.sh tests/test_*.sh
for test_script in tests/test_*.sh; do bash "$test_script"; done
git diff --check origin/main...HEAD
```

Expected: all commands exit zero.

- [ ] **Step 3: Install into the current Mac Tabby environment**

Confirm Tabby is closed, then invoke the shared installer from the verified `main` checkout:

```bash
pgrep -x Tabby >/dev/null && {
  printf '%s\n' 'Close Tabby before continuing' >&2
  exit 1
}
source bootstrap/common.sh
install_tabby_osc_notify macos
```

If direct filesystem installation is blocked by the execution sandbox, use Tabby's native Settings → Plugins interface to install the same pinned package, then verify the resulting package metadata. Do not weaken filesystem permissions or change ownership to bypass the sandbox.

- [ ] **Step 4: Verify the installed package and OSC 9 behavior**

```bash
plugin="$HOME/Library/Application Support/tabby/plugins/node_modules/tabby-osc-notify"
test "$(package_json_string_field name "$plugin/package.json")" = "tabby-osc-notify"
test "$(package_json_string_field version "$plugin/package.json")" = "1.0.0"
test -f "$plugin/dist/index.js"
```

Start Tabby, confirm the plugin appears under installed plugins, and run:

```bash
printf '\033]9;Codex 通知测试\007'
```

Expected: a desktop notification appears. The user may need to grant Tabby notification permission the first time.

- [ ] **Step 5: Push the verified branches from the writable clone**

```bash
git push origin main:main
git switch server
git push origin server:server
```

Expected: both pushes are fast-forward updates. If either remote branch moved, stop, fetch, integrate the new commits, rerun that branch's tests, and only then retry.

- [ ] **Step 6: Synchronize the `main` working-tree files back to the user-visible workspace**

Copy only the changed `main` files from the writable clone into `/Users/xingjianming/code/tabby_config`:

```bash
clone=/tmp/tabby-config-codex.Bc3r8W/repo
workspace=/Users/xingjianming/code/tabby_config
install -m 0644 "$clone/README.md" "$workspace/README.md"
install -m 0755 "$clone/bootstrap/common.sh" "$workspace/bootstrap/common.sh"
install -m 0755 "$clone/bootstrap/plugins.lock.sh" "$workspace/bootstrap/plugins.lock.sh"
install -m 0755 "$clone/tests/test_tabby_plugin_install.sh" "$workspace/tests/test_tabby_plugin_install.sh"
install -m 0644 \
  "$clone/docs/superpowers/specs/2026-07-16-tabby-osc-notify-plugin-install-design.md" \
  "$workspace/docs/superpowers/specs/2026-07-16-tabby-osc-notify-plugin-install-design.md"
install -m 0644 \
  "$clone/docs/superpowers/plans/2026-07-16-tabby-osc-notify-plugin-install.md" \
  "$workspace/docs/superpowers/plans/2026-07-16-tabby-osc-notify-plugin-install.md"
```

Then run from that workspace:

```bash
git diff --check
git status --short
```

Expected: the workspace shows the same `main` file content; its read-only `.git` may still report the files as uncommitted until the environment permits a normal pull.
