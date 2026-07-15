#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TABBY_CONFIG="$REPO_ROOT/config/tabby/config.yaml"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local message="$3"
  [ "$actual" = "$expected" ] || fail "$message: expected '$expected', got '$actual'"
}

assert_file_contains() {
  local path="$1"
  local expected="$2"

  grep -F -- "$expected" "$path" >/dev/null ||
    fail "expected $path to contain: $expected"
}

assert_file_not_contains_ci() {
  local path="$1"
  local forbidden="$2"

  if grep -Fi -- "$forbidden" "$path" >/dev/null; then
    fail "expected $path not to contain: $forbidden"
  fi
}

README="$REPO_ROOT/README.md"
SHORTCUT_GUIDE="$REPO_ROOT/当前环境常用快捷键速查.md"
LAZYGIT_GUIDE="$REPO_ROOT/lazygit操作指南.md"

ruby - "$TABBY_CONFIG" <<'RUBY'
require "yaml"
require "json"
require "digest"

path = ARGV.fetch(0)
raw_config = File.binread(path)

def assert(condition, message)
  raise message unless condition
end

canonical_config = raw_config.gsub("\r\n", "\n")
assert(
  !canonical_config.include?("\r"),
  "public Tabby snapshot contains unsupported bare CR line endings",
)
snapshot_digest = Digest::SHA256.hexdigest(canonical_config)
assert(
  snapshot_digest == "7ff19c05e513d74db10be6a7f888313ea5a66acb1cda858fedbd2ce69d86e137",
  "public Tabby snapshot bytes changed: #{snapshot_digest}",
)
config = YAML.safe_load(canonical_config, aliases: false)

allowed_root_keys = %w[
  version
  profiles
  groups
  hotkeys
  terminal
  clickableLinks
  accessibility
  appearance
  hacks
  providerBlacklist
  commandBlacklist
  profileBlacklist
  enableWelcomeTab
  pluginBlacklist
  profileDefaults
]

assert(config.is_a?(Hash), "Tabby config root must be a mapping")
missing_root_keys = allowed_root_keys - config.keys
unexpected_root_keys = config.keys - allowed_root_keys
assert(
  missing_root_keys.empty? && unexpected_root_keys.empty?,
  "root key mismatch: missing #{missing_root_keys.inspect}, unexpected #{unexpected_root_keys.inspect}",
)
assert(config["version"] == 8, "version must be 8")
assert(config["profiles"] == [], "profiles must be empty")
assert(config["groups"] == [], "groups must be empty")
assert(!config.key?("ssh"), "root ssh state must not be tracked")
assert(!config.key?("configSync"), "configSync must not be tracked")
assert(!config.key?("vault"), "vault must not be tracked")

hotkeys = config.fetch("hotkeys")
assert(hotkeys.length == 103, "expected 103 hotkey actions")
hotkey_digest = Digest::SHA256.hexdigest(JSON.generate(hotkeys))
assert(
  hotkey_digest == "0c312163f4f17cf825ebca74843c672e54a8d37c46e6f59b1c4e2c25b56f606c",
  "hotkey snapshot digest changed",
)

terminal = config.fetch("terminal")
assert(terminal["fontSize"] == 20, "fontSize must be 20")
assert(terminal.dig("colorScheme", "name") == "AdventureTime", "dark scheme must be AdventureTime")
assert(
  terminal.dig("colorScheme", "colors") == [
    "#050404", "#bd0013", "#4ab118", "#e7741e",
    "#0f4ac6", "#665993", "#70a598", "#f8dcc0",
    "#4e7cbf", "#fc5f5a", "#9eff6e", "#efc11a",
    "#1997c6", "#9b5953", "#c8faf4", "#f6f5fb",
  ],
  "AdventureTime palette changed",
)
assert(
  terminal.dig("lightColorScheme", "name") == "Tabby Default Light",
  "light scheme must be Tabby Default Light",
)
assert(
  terminal.dig("lightColorScheme", "colors").length == 16,
  "light palette must contain 16 colors",
)
assert(terminal["customColorSchemes"] == [], "customColorSchemes must be empty")

assert(config.dig("appearance", "opacity") == 0.84, "opacity must be 0.84")
assert(config.dig("appearance", "vibrancy") == true, "vibrancy must be enabled")
assert(config["enableWelcomeTab"] == false, "welcome tab must be disabled")
assert(
  config.dig("profileDefaults", "ssh", "disableDynamicTitle") == true,
  "SSH dynamic titles must be disabled by default",
)

forbidden_keys = %w[
  knownHosts
  token
  password
  passphrase
  privateKey
  privateKeys
  vault
  configSync
]
forbidden_paths = []
string_values = []

walk = lambda do |value, path_parts|
  case value
  when Hash
    value.each do |key, child|
      child_path = path_parts + [key]
      forbidden_paths << child_path.join(".") if forbidden_keys.include?(key)
      walk.call(child, child_path)
    end
  when Array
    value.each_with_index { |child, index| walk.call(child, path_parts + [index.to_s]) }
  when String
    string_values << value
  end
end
walk.call(config, [])

assert(forbidden_paths.empty?, "forbidden keys found: #{forbidden_paths.inspect}")
assert(
  string_values.none? { |value| value.match?(/\b(?:\d{1,3}\.){3}\d{1,3}\b/) },
  "IPv4 address found in public config",
)

puts "tabby config content and privacy checks passed"
RUBY

# shellcheck source=bootstrap/common.sh
source "$REPO_ROOT/bootstrap/common.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

export HOME="$tmp_dir/home"
export XDG_CONFIG_HOME="$tmp_dir/xdg-config"
export APPDATA="$tmp_dir/windows-appdata"
export DOTFILES_LINK_MODE=symlink
mkdir -p "$HOME"

date() {
  if [ "$#" -eq 1 ] && [ "$1" = "+%Y%m%d%H%M%S" ]; then
    printf '%s\n' "20260715133000"
  else
    command date "$@"
  fi
}

assert_eq \
  "$XDG_CONFIG_HOME/tabby/config.yaml" \
  "$(tabby_config_path linux)" \
  "Linux Tabby config path"
assert_eq \
  "$HOME/Library/Application Support/tabby/config.yaml" \
  "$(tabby_config_path macos)" \
  "macOS Tabby config path"
assert_eq \
  "$APPDATA/Tabby/config.yaml" \
  "$(tabby_config_path windows)" \
  "Windows Tabby config path"

if (unset APPDATA; tabby_config_path windows >/dev/null 2>&1); then
  fail "Windows path calculation must reject a missing APPDATA"
fi

if (tabby_config_path plan9 >/dev/null 2>&1); then
  fail "unsupported platforms must be rejected"
fi

target="$(tabby_config_path linux)"
install_tabby_config linux

[ -f "$target" ] || fail "Tabby config was not copied"
[ ! -L "$target" ] || fail "Tabby config must never be a symlink"
cmp -s "$TABBY_CONFIG" "$target" || fail "copied Tabby config differs from source"

printf 'private runtime state\n' >"$target"
install_tabby_config linux

first_backup="${target}.bak.20260715133000"
[ -f "$first_backup" ] || fail "expected first timestamped backup"
cmp -s <(printf 'private runtime state\n') "$first_backup" ||
  fail "first backup content differs from original runtime config"
[ ! -L "$target" ] || fail "replacement Tabby config must remain a regular file"
cmp -s "$TABBY_CONFIG" "$target" || fail "replacement config differs from source"

install_tabby_config linux

second_backup="${target}.bak.20260715133000.1"
shopt -s nullglob
backups=("$target".bak.*)
shopt -u nullglob
[ "${#backups[@]}" -eq 2 ] || fail "expected exactly two timestamped backups"
[ -f "$second_backup" ] || fail "expected collision-safe timestamped backup"
cmp -s <(printf 'private runtime state\n') "$first_backup" ||
  fail "first backup content changed after collision"
cmp -s "$TABBY_CONFIG" "$second_backup" ||
  fail "collision backup differs from public Tabby config"
[ ! -L "$target" ] || fail "replacement Tabby config must remain a regular file"
cmp -s "$TABBY_CONFIG" "$target" || fail "replacement config differs from source"

printf 'tabby config path, copy, and backup checks passed\n'

assert_file_contains "$REPO_ROOT/bootstrap/common.sh" "install_tabby_linux()"
assert_file_contains "$REPO_ROOT/bootstrap/common.sh" "Eugeny/tabby"
assert_file_not_contains_ci "$REPO_ROOT/bootstrap/common.sh" "ensure_wezterm_apt_repo"
assert_file_not_contains_ci "$REPO_ROOT/bootstrap/common.sh" "apt.fury.io/wez"

assert_file_contains "$REPO_ROOT/install/macos.sh" "brew install --cask tabby"
assert_file_not_contains_ci "$REPO_ROOT/install/macos.sh" "wezterm"

assert_file_contains "$REPO_ROOT/install/ubuntu.sh" "install_tabby_linux"
assert_file_not_contains_ci "$REPO_ROOT/install/ubuntu.sh" "wezterm"

assert_file_contains "$REPO_ROOT/install/windows-msys2.sh" "Eugeny.Tabby"
assert_file_not_contains_ci "$REPO_ROOT/install/windows-msys2.sh" "wezterm"

assert_file_contains "$REPO_ROOT/install/windows.ps1" "Eugeny.Tabby"
assert_file_not_contains_ci "$REPO_ROOT/install/windows.ps1" "wezterm"

printf 'cross-platform Tabby installer checks passed\n'

for production_doc in "$README" "$SHORTCUT_GUIDE" "$LAZYGIT_GUIDE"; do
  assert_file_not_contains_ci "$production_doc" "wezterm"
done

assert_file_contains "$README" "Tabby"
assert_file_contains "$README" 'config/tabby/config.yaml'
assert_file_contains "$README" 'brew install --cask tabby'
assert_file_contains "$README" 'Eugeny/tabby'
assert_file_contains "$README" 'Eugeny.Tabby'
assert_file_contains "$README" '${XDG_CONFIG_HOME:-$HOME/.config}/tabby/config.yaml'
assert_file_contains "$README" '$HOME/Library/Application Support/tabby/config.yaml'
assert_file_contains "$README" '%APPDATA%\Tabby\config.yaml'
assert_file_contains "$README" '强制复制为普通文件，绝不创建符号链接'
assert_file_contains "$README" 'config.yaml.bak.YYYYMMDDHHMMSS'
assert_file_not_contains_ci "$README" 'config.yaml.bak.<timestamp>'
assert_file_contains "$README" '.1`、`.2'
assert_file_contains "$README" '部署前请关闭 Tabby'
assert_file_contains "$README" '按字段白名单重建'
assert_file_contains "$README" '不是将完整本机文件复制后再依赖黑名单清理'
assert_file_contains "$README" 'AdventureTime'
assert_file_contains "$README" 'Tabby Default Light'
assert_file_contains "$README" '20px'
assert_file_contains "$README" '0.84'
assert_file_contains "$README" '`vibrancy`'
assert_file_contains "$README" '欢迎页关闭'
assert_file_contains "$README" 'SSH profile 默认关闭动态标题'
assert_file_contains "$README" '根级 `ssh`'
assert_file_contains "$README" 'SSH known-host'
assert_file_contains "$README" '连接 `profile`'
assert_file_contains "$README" '`configSync`'
assert_file_contains "$README" '`vault`'
assert_file_contains "$README" '令牌、密码、密钥路径'
assert_file_contains "$README" 'Electron 运行态数据'
assert_file_contains "$README" '不要把本机完整的 Tabby `config.yaml` 直接复制回仓库'
assert_file_contains "$README" '更新快照时，必须重新执行字段白名单筛选'
assert_file_contains "$README" 'tabby --version'

assert_file_contains "$SHORTCUT_GUIDE" 'Tabby | `1.0.234`'
assert_file_contains "$SHORTCUT_GUIDE" '| Tabby | `~/.config/tabby/config.yaml` |'
assert_file_contains "$SHORTCUT_GUIDE" '白名单快照来源'
assert_file_contains "$SHORTCUT_GUIDE" 'config/tabby/config.yaml'
assert_file_contains "$SHORTCUT_GUIDE" '${XDG_CONFIG_HOME:-$HOME/.config}/tabby/config.yaml'
assert_file_contains "$SHORTCUT_GUIDE" '$HOME/Library/Application Support/tabby/config.yaml'
assert_file_contains "$SHORTCUT_GUIDE" '%APPDATA%\Tabby\config.yaml'
assert_file_contains "$SHORTCUT_GUIDE" 'Tabby Default Light'
assert_file_contains "$SHORTCUT_GUIDE" '`vibrancy`'
assert_file_contains "$SHORTCUT_GUIDE" 'SSH profile 默认关闭动态标题'
assert_file_contains "$SHORTCUT_GUIDE" 'SSH known-host'
assert_file_contains "$SHORTCUT_GUIDE" '连接 profile'
assert_file_contains "$SHORTCUT_GUIDE" '同步信息（`configSync`）'
assert_file_contains "$SHORTCUT_GUIDE" '`vault`'
assert_file_contains "$SHORTCUT_GUIDE" '### 4.2 窗口与标签'
assert_file_contains "$SHORTCUT_GUIDE" '### 4.3 编辑、搜索与滚动'
assert_file_contains "$SHORTCUT_GUIDE" '### 4.4 分屏'
assert_file_contains "$SHORTCUT_GUIDE" '`Ctrl-Space`'
assert_file_contains "$SHORTCUT_GUIDE" '`Alt-1` 到 `Alt-0`'
assert_file_contains "$SHORTCUT_GUIDE" '`Ctrl-Shift-P`'
assert_file_contains "$SHORTCUT_GUIDE" '`Ctrl-Shift-C` / `Ctrl-Shift-V`'
assert_file_contains "$SHORTCUT_GUIDE" '`Ctrl-Shift-S` / `Ctrl-Shift-D`'
assert_file_contains "$SHORTCUT_GUIDE" '`Ctrl-Alt-Enter`'

printf 'Tabby production documentation checks passed\n'
