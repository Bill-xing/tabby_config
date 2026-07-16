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
