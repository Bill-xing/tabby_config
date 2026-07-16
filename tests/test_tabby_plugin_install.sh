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

target_tree_fingerprint() {
  local root="$1"

  [ -d "$root" ] || fail "cannot fingerprint missing target tree: $root"
  (
    cd "$root"
    find . -print | LC_ALL=C sort | while IFS= read -r path; do
      if [ -L "$path" ]; then
        printf 'L %s -> %s\n' "$path" "$(readlink "$path")"
      elif [ -f "$path" ]; then
        printf 'F %s ' "$path"
        cksum <"$path"
      elif [ -d "$path" ]; then
        printf 'D %s\n' "$path"
      else
        printf 'O %s\n' "$path"
      fi
    done
  ) | cksum
}

assert_path_missing() {
  local path="$1"
  [ ! -e "$path" ] && [ ! -L "$path" ] ||
    fail "unexpected path exists: $path"
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
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$APPDATA"

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

write_fixture_package() {
  local root="$1"
  local package_name="$2"
  local package_version="$3"
  local include_entry="$4"

  rm -rf "$root"
  mkdir -p "$root/package/dist"
  printf '{\n  "name": "%s",\n  "version": "%s",\n  "main": "dist/index.js",\n  "keywords": ["tabby-plugin"]\n}\n' \
    "$package_name" "$package_version" >"$root/package/package.json"
  if [ "$include_entry" = "yes" ]; then
    printf '%s\n' 'module.exports = {}' >"$root/package/dist/index.js"
  fi
}

make_fixture() {
  local output="$1"
  local package_name="$2"
  local package_version="$3"
  local include_entry="${4:-yes}"
  local root="${output}.root"

  write_fixture_package "$root" "$package_name" "$package_version" "$include_entry"
  tar -czf "$output" -C "$root" package
}

make_unsafe_symlink_fixture() {
  local output="$1"
  local outside_sentinel="$2"
  local root="${output}.root"

  write_fixture_package "$root" "tabby-osc-notify" "1.0.0" yes
  ln -s "$outside_sentinel" "$root/package/dist/escape"
  tar -czf "$output" -C "$root" package
}

good_fixture="$tmp_dir/good.tgz"
wrong_name_fixture="$tmp_dir/wrong-name.tgz"
wrong_version_fixture="$tmp_dir/wrong-version.tgz"
missing_entry_fixture="$tmp_dir/missing-entry.tgz"
unsafe_symlink_fixture="$tmp_dir/unsafe-symlink.tgz"
outside_sentinel="$tmp_dir/outside-sentinel"
make_fixture "$good_fixture" "tabby-osc-notify" "1.0.0"
make_fixture "$wrong_name_fixture" "tabby-wrong-plugin" "1.0.0"
make_fixture "$wrong_version_fixture" "tabby-osc-notify" "9.9.9"
make_fixture "$missing_entry_fixture" "tabby-osc-notify" "1.0.0" no
assert_path_missing "$outside_sentinel"
make_unsafe_symlink_fixture "$unsafe_symlink_fixture" "$outside_sentinel"

good_fixture_sha="$(sha256_file "$good_fixture")"
FIXTURE="$good_fixture"
FETCH_FORBIDDEN=0
fetch_url() {
  local url="$1"
  local output="$2"

  assert_eq "$TABBY_OSC_NOTIFY_TARBALL_URL" "$url" "plugin download URL"
  [ "$FETCH_FORBIDDEN" != "1" ] || fail "idempotent install attempted another download"
  cp "$FIXTURE" "$output"
}

plugin_root="$(tabby_plugins_path linux)"
target="$plugin_root/node_modules/tabby-osc-notify"
other_plugin="$plugin_root/node_modules/tabby-background"
mkdir -p "$other_plugin"
printf '%s\n' 'keep background' >"$other_plugin/marker"
printf '%s\n' 'keep lock' >"$plugin_root/package-lock.json"

assert_fresh_fixture_install() {
  local platform="$1"
  local expected_target="$2"
  local platform_root
  local platform_target

  platform_root="$(tabby_plugins_path "$platform")"
  platform_target="$platform_root/node_modules/tabby-osc-notify"
  assert_eq "$expected_target" "$platform_target" "$platform final plugin path"
  assert_path_missing "$expected_target"

  FIXTURE="$good_fixture"
  FETCH_FORBIDDEN=0
  TABBY_OSC_NOTIFY_SHA256="$good_fixture_sha"
  install_tabby_osc_notify "$platform"

  [ -f "$expected_target/package.json" ] ||
    fail "$platform plugin package.json was not installed at $expected_target"
  [ -f "$expected_target/dist/index.js" ] ||
    fail "$platform plugin entry point was not installed at $expected_target"
  assert_file_contains "$expected_target/package.json" '"name": "tabby-osc-notify"'
  assert_file_contains "$expected_target/package.json" '"version": "1.0.0"'
}

assert_fresh_fixture_install \
  linux \
  "$XDG_CONFIG_HOME/tabby/plugins/node_modules/tabby-osc-notify"
assert_fresh_fixture_install \
  macos \
  "$HOME/Library/Application Support/tabby/plugins/node_modules/tabby-osc-notify"
assert_fresh_fixture_install \
  windows \
  "$APPDATA/Tabby/plugins/node_modules/tabby-osc-notify"

assert_file_contains "$other_plugin/marker" 'keep background'
assert_file_contains "$plugin_root/package-lock.json" 'keep lock'

installed_tree_before="$(target_tree_fingerprint "$target")"
installed_entry_before="$(cksum <"$target/dist/index.js")"
FETCH_FORBIDDEN=1
install_tabby_osc_notify linux
FETCH_FORBIDDEN=0
assert_eq \
  "$installed_tree_before" \
  "$(target_tree_fingerprint "$target")" \
  "idempotent install target tree"
assert_eq \
  "$installed_entry_before" \
  "$(cksum <"$target/dist/index.js")" \
  "idempotent install entry point"
[ ! -d "$plugin_root/backups" ] ||
  [ -z "$(find "$plugin_root/backups" -mindepth 1 -maxdepth 1 -print -quit)" ] ||
  fail "idempotent install created a backup"

printf '%s\n' '{"name":"tabby-osc-notify","version":"0.9.0"}' >"$target/package.json"
printf '%s\n' 'old plugin entry' >"$target/dist/index.js"
printf '%s\n' 'old plugin marker' >"$target/dist/old-marker"
old_tree_before="$(target_tree_fingerprint "$target")"
FIXTURE="$good_fixture"
TABBY_OSC_NOTIFY_SHA256="$good_fixture_sha"
install_tabby_osc_notify linux
assert_file_contains "$target/package.json" '"version": "1.0.0"'
backup="$(find "$plugin_root/backups" -mindepth 1 -maxdepth 1 -type d -name 'tabby-osc-notify.bak.*' -print -quit)"
[ -n "$backup" ] || fail "old plugin backup was not created"
assert_file_contains "$backup/package.json" '"version":"0.9.0"'
assert_file_contains "$backup/dist/index.js" 'old plugin entry'
assert_file_contains "$backup/dist/old-marker" 'old plugin marker'
assert_eq \
  "$old_tree_before" \
  "$(target_tree_fingerprint "$backup")" \
  "old plugin backup tree"
assert_eq \
  "$plugin_root/backups/tabby-osc-notify.bak.20260716124500.1" \
  "$(next_tabby_plugin_backup_path "$plugin_root" "tabby-osc-notify")" \
  "collision-safe plugin backup path"
assert_file_contains "$other_plugin/marker" 'keep background'
assert_file_contains "$plugin_root/package-lock.json" 'keep lock'

printf '%s\n' '{"name":"tabby-osc-notify","version":"0.8.0"}' >"$target/package.json"
printf '%s\n' 'preserve target entry' >"$target/dist/index.js"
printf '%s\n' 'preserve target marker' >"$target/dist/preserve-marker"

assert_install_failure_preserves_target() {
  local fixture="$1"
  local expected_sha="$2"
  local label="$3"
  local before_tree
  local before_entry

  before_tree="$(target_tree_fingerprint "$target")"
  before_entry="$(cksum <"$target/dist/index.js")"
  FIXTURE="$fixture"
  FETCH_FORBIDDEN=0
  TABBY_OSC_NOTIFY_SHA256="$expected_sha"

  if (install_tabby_osc_notify linux); then
    fail "$label unexpectedly succeeded"
  fi

  assert_eq \
    "$before_tree" \
    "$(target_tree_fingerprint "$target")" \
    "$label target tree preservation"
  assert_eq \
    "$before_entry" \
    "$(cksum <"$target/dist/index.js")" \
    "$label entry point preservation"
  assert_file_contains "$target/dist/preserve-marker" 'preserve target marker'
}

assert_install_failure_preserves_target \
  "$good_fixture" \
  "$(printf '%064d' 0)" \
  "checksum mismatch"
assert_install_failure_preserves_target \
  "$wrong_name_fixture" \
  "$(sha256_file "$wrong_name_fixture")" \
  "wrong package name"
assert_install_failure_preserves_target \
  "$wrong_version_fixture" \
  "$(sha256_file "$wrong_version_fixture")" \
  "wrong package version"
assert_install_failure_preserves_target \
  "$missing_entry_fixture" \
  "$(sha256_file "$missing_entry_fixture")" \
  "missing plugin entry point"

assert_path_missing "$outside_sentinel"
assert_install_failure_preserves_target \
  "$unsafe_symlink_fixture" \
  "$(sha256_file "$unsafe_symlink_fixture")" \
  "unsafe symlink archive"
assert_path_missing "$outside_sentinel"
assert_file_contains "$other_plugin/marker" 'keep background'
assert_file_contains "$plugin_root/package-lock.json" 'keep lock'

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

desktop_calls="$tmp_dir/desktop-payload-calls"
ensure_base_dirs() {
  :
}
link_or_copy() {
  :
}
install_windows_mirrors() {
  :
}
install_tabby_config() {
  printf '%s\n' direct-config >>"$desktop_calls"
}
install_tabby_payload() {
  printf '%s\n' tabby-payload >>"$desktop_calls"
}

unset DOTFILES_SKIP_TABBY
install_config_payload
assert_eq \
  "tabby-payload" \
  "$(<"$desktop_calls")" \
  "desktop config payload Tabby dispatch"
assert_eq \
  "1" \
  "$(wc -l <"$desktop_calls" | tr -d ' ')" \
  "desktop config payload Tabby call count"

printf 'Tabby OSC notify plugin install checks passed\n'
