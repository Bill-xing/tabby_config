# Tabby Config Repository Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `${HOME}/code/tabby_config` as an independent, committed cross-platform dotfiles repository that preserves the shared configuration from `wezterm_config` while replacing every production WezTerm integration with a privacy-safe Tabby configuration and installer flow.

**Architecture:** Seed the new repository from the source repository's fixed commit, then add a hand-constructed allowlisted Tabby YAML snapshot. Keep normal dotfiles on the existing link-or-copy path, but route Tabby's single mutable `config.yaml` through a dedicated copy-only installer with explicit platform path calculation and backup behavior. Test YAML content, privacy boundaries, path calculation, copy semantics, installer references, and source-repository invariants without installing packages or touching the real HOME.

**Tech Stack:** Bash 4+, PowerShell, YAML, Ruby standard-library `yaml/json/digest` for validation, Python 3 GitHub Release resolver, Git.

---

## Fixed inputs and invariants

- Source repository: `${HOME}/code/wezterm_config`
- Required source commit: `bcec1a38b17f5df544367028d21693f21b225a04`
- Target repository: `${HOME}/code/tabby_config`
- Target branch: `main`
- Execution worktree: `${HOME}/code/tabby_config/.worktrees/tabby-config-implementation`
- Execution branch: `feature/tabby-config-implementation`
- Existing target design commit: `d1b1ffa`
- No Git remote may be added.
- The source repository must remain clean and at the required commit throughout execution.
- No production file in the target may contain a case-insensitive `wezterm` reference at completion.
- `docs/superpowers/` may mention WezTerm as historical design context.

## Final file responsibilities

- `config/tabby/config.yaml`: public, allowlisted Tabby settings snapshot; never contains runtime SSH or sync state.
- `bootstrap/common.sh`: shared platform detection, Tabby path calculation, copy-only config deployment, backups, and Linux release installer.
- `install/macos.sh`: Homebrew package installation plus the Tabby cask.
- `install/ubuntu.sh`: Ubuntu dependencies plus the latest architecture-matched Tabby `.deb`.
- `install/windows-msys2.sh`: MSYS2 payload plus WinGet Tabby installation.
- `install/windows.ps1`: native Windows bootstrap using `Eugeny.Tabby`.
- `tests/test_tabby_config_install.sh`: YAML/privacy validation, platform-path tests, backup/copy tests, and static installer assertions.
- `README.md`: installation, paths, privacy model, current Tabby settings, and verification.
- `当前环境常用快捷键速查.md`: current Tabby 1.0.234 shortcuts and configuration location.

### Task 1: Seed the shared repository baseline

**Files:**

- Preserve from target setup: `.gitignore` containing the source rules plus `.worktrees/`
- Create from source: `README.md`
- Create from source: `bootstrap/common.sh`
- Create from source: `bootstrap/github_release_asset.py`
- Create from source: `bootstrap/plugins.lock.sh`
- Create from source: `config/lazygit/config.yml`
- Create from source: `config/nvim/.gitignore`
- Create from source: `config/nvim/.neoconf.json`
- Create from source: `config/nvim/LICENSE`
- Create from source: `config/nvim/README.md`
- Create from source: `config/nvim/init.lua`
- Create from source: `config/nvim/lazy-lock.json`
- Create from source: `config/nvim/lazyvim.json`
- Create from source: `config/nvim/lua/config/autocmds.lua`
- Create from source: `config/nvim/lua/config/lazy.lua`
- Create from source: `config/nvim/lua/config/keymaps.lua`
- Create from source: `config/nvim/lua/config/options.lua`
- Create from source: `config/nvim/lua/plugins/example.lua`
- Create from source: `config/nvim/stylua.toml`
- Create from source: `config/tmux/.tmux.conf`
- Create from source: `config/yazi/keymap.toml`
- Create from source: `config/yazi/yazi.toml`
- Create from source: `config/zsh/.p10k.zsh`
- Create from source: `config/zsh/.zshrc`
- Create from source: `install/macos.sh`
- Create from source: `install/ubuntu.sh`
- Create from source: `install/windows-msys2.sh`
- Create from source: `install/windows.ps1`
- Create from source: `lazygit操作指南.md`
- Create from source: `当前环境常用快捷键速查.md`
- Deliberately exclude: `config/wezterm/wezterm.lua`

- [ ] **Step 1: Verify the source and target preconditions**

Run:

~~~bash
test "$(git -C ${HOME}/code/wezterm_config rev-parse HEAD)" = \
  "bcec1a38b17f5df544367028d21693f21b225a04"
test -z "$(git -C ${HOME}/code/wezterm_config status --porcelain)"
test "$(git branch --show-current)" = "main"
test -z "$(git remote)"
test "$(git rev-list --max-parents=0 HEAD)" = "$(git rev-parse d1b1ffa)"
~~~

Expected: every command exits 0 and prints nothing except values captured internally by `test`.

- [ ] **Step 2: Mechanically copy the tracked shared baseline**

Run from `${HOME}/code/tabby_config`:

~~~bash
git -C ${HOME}/code/wezterm_config archive HEAD -- \
  README.md \
  bootstrap \
  config/lazygit \
  config/nvim \
  config/tmux \
  config/yazi \
  config/zsh \
  install \
  lazygit操作指南.md \
  当前环境常用快捷键速查.md |
  tar -x -C ${HOME}/code/tabby_config
~~~

Expected: the listed files appear in the target; `config/wezterm/` does not exist; `docs/superpowers/`, `.gitignore`, and `.git/` remain intact.

- [ ] **Step 3: Verify the mechanical copy and exclusion**

Run:

~~~bash
test ! -e config/wezterm/wezterm.lua
git check-ignore -q .worktrees/
grep -Fx '.DS_Store' .gitignore
grep -Fx '.nvimlog' .gitignore
grep -Fx '*.bak.*' .gitignore
grep -Fx '__pycache__/' .gitignore
grep -Fx '*.pyc' .gitignore
grep -Fx '.worktrees/' .gitignore
git diff --no-index \
  ${HOME}/code/wezterm_config/config/zsh \
  config/zsh
git diff --no-index \
  ${HOME}/code/wezterm_config/config/tmux \
  config/tmux
git diff --no-index \
  ${HOME}/code/wezterm_config/config/nvim \
  config/nvim
git diff --no-index \
  ${HOME}/code/wezterm_config/config/yazi \
  config/yazi
git diff --no-index \
  ${HOME}/code/wezterm_config/config/lazygit \
  config/lazygit
~~~

Expected: all commands exit 0; the five `git diff --no-index` commands produce no output.

- [ ] **Step 4: Commit the shared baseline**

Run:

~~~bash
git add .gitignore README.md bootstrap config install \
  lazygit操作指南.md 当前环境常用快捷键速查.md
git commit -m "chore: seed shared dotfiles"
~~~

Expected: commit succeeds; the design document remains tracked; `git status --short` is empty.

### Task 2: Add the allowlisted Tabby snapshot

**Files:**

- Create: `tests/test_tabby_config_install.sh`
- Create: `config/tabby/config.yaml`

- [ ] **Step 1: Write the failing YAML and privacy validation**

Create `tests/test_tabby_config_install.sh` with exactly:

~~~bash
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

ruby - "$TABBY_CONFIG" <<'RUBY'
require "yaml"
require "json"
require "digest"

path = ARGV.fetch(0)
config = YAML.safe_load_file(path, aliases: false)

def assert(condition, message)
  raise message unless condition
end

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
assert(
  config.keys.sort == allowed_root_keys.sort,
  "unexpected root keys: #{(config.keys - allowed_root_keys).inspect}",
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
~~~

Make it executable:

~~~bash
chmod +x tests/test_tabby_config_install.sh
~~~

- [ ] **Step 2: Run the validation and confirm it fails**

Run:

~~~bash
bash tests/test_tabby_config_install.sh
~~~

Expected: non-zero exit with `No such file or directory` for `config/tabby/config.yaml`.

- [ ] **Step 3: Add the exact allowlisted Tabby YAML**

Create `config/tabby/config.yaml` with exactly:

~~~yaml
version: 8
profiles: []
groups: []
hotkeys:
  toggle-window:
    - Ctrl-Space
  copy-current-path: []
  ctrl-c:
    - Ctrl-C
  copy:
    - Ctrl-Shift-C
  paste:
    - Ctrl-Shift-V
    - Shift-Insert
  select-all:
    - Ctrl-Shift-A
  clear: []
  zoom-in:
    - Ctrl-=
    - Ctrl-Shift-=
  zoom-out:
    - Ctrl--
    - Ctrl-Shift--
  reset-zoom:
    - Ctrl-0
  home:
    - Home
  end:
    - End
  previous-word:
    - Ctrl-Left
  next-word:
    - Ctrl-Right
  delete-previous-word:
    - Ctrl-Backspace
  delete-line:
    - Ctrl-Shift-Backspace
  delete-next-word:
    - Ctrl-Delete
  search:
    - Ctrl-Shift-F
  pane-focus-all:
    - Ctrl-Shift-I
  focus-all-tabs:
    - Ctrl-Alt-Shift-I
  scroll-to-top:
    - Ctrl-PageUp
  scroll-page-up:
    - Alt-PageUp
  scroll-up:
    - Ctrl-Shift-Up
  scroll-down:
    - Ctrl-Shift-Down
  scroll-page-down:
    - Alt-PageDown
  scroll-to-bottom:
    - Ctrl-PageDown
  restart-telnet-session: []
  restart-ssh-session: []
  launch-winscp: []
  open-sftp: []
  settings-tab: {}
  settings:
    - Ctrl-,
  serial:
    - Alt-K
  restart-serial-session: []
  new-tab:
    - Ctrl-Shift-T
  new-window:
    - Ctrl-Shift-N
  profile: {}
  profile-selectors: {}
  group-selectors: {}
  toggle-fullscreen:
    - F11
  close-tab:
    - Ctrl-Shift-W
  reopen-tab:
    - Ctrl-Shift-Z
  toggle-last-tab: []
  rename-tab:
    - Ctrl-Shift-R
  next-tab:
    - Ctrl-Shift-Right
    - Ctrl-Tab
  previous-tab:
    - Ctrl-Shift-Left
    - Ctrl-Shift-Tab
  move-tab-left:
    - Ctrl-Shift-PageUp
  move-tab-right:
    - Ctrl-Shift-PageDown
  rearrange-panes:
    - Ctrl-Shift
  duplicate-tab: []
  restart-tab: []
  reconnect-tab: []
  disconnect-tab: []
  explode-tab:
    - Ctrl-Shift-.
  combine-tabs:
    - Ctrl-Shift-,
  tab-1:
    - Alt-1
  tab-2:
    - Alt-2
  tab-3:
    - Alt-3
  tab-4:
    - Alt-4
  tab-5:
    - Alt-5
  tab-6:
    - Alt-6
  tab-7:
    - Alt-7
  tab-8:
    - Alt-8
  tab-9:
    - Alt-9
  tab-10:
    - Alt-0
  tab-11: []
  tab-12: []
  tab-13: []
  tab-14: []
  tab-15: []
  tab-16: []
  tab-17: []
  tab-18: []
  tab-19: []
  tab-20: []
  split-right:
    - Ctrl-Shift-S
  split-bottom:
    - Ctrl-Shift-D
  split-left: []
  split-top: []
  pane-nav-right:
    - Ctrl-Alt-Right
  pane-nav-down:
    - Ctrl-Alt-Down
  pane-nav-up:
    - Ctrl-Alt-Up
  pane-nav-left:
    - Ctrl-Alt-Left
  pane-nav-previous:
    - Ctrl-Alt-[
  pane-nav-next:
    - Ctrl-Alt-]
  pane-nav-1: []
  pane-nav-2: []
  pane-nav-3: []
  pane-nav-4: []
  pane-nav-5: []
  pane-nav-6: []
  pane-nav-7: []
  pane-nav-8: []
  pane-nav-9: []
  pane-maximize:
    - Ctrl-Alt-Enter
  pane-increase-vertical: []
  pane-decrease-vertical: []
  pane-increase-horizontal: []
  pane-decrease-horizontal: []
  close-pane: []
  switch-profile:
    - Ctrl-Alt-T
  profile-selector:
    - Ctrl-Shift-E
  command-selector:
    - Ctrl-Shift-P
terminal:
  searchOptions: {}
  colorScheme:
    name: AdventureTime
    foreground: '#f8dcc0'
    background: '#1f1d45'
    cursor: '#efbf38'
    colors:
      - '#050404'
      - '#bd0013'
      - '#4ab118'
      - '#e7741e'
      - '#0f4ac6'
      - '#665993'
      - '#70a598'
      - '#f8dcc0'
      - '#4e7cbf'
      - '#fc5f5a'
      - '#9eff6e'
      - '#efc11a'
      - '#1997c6'
      - '#9b5953'
      - '#c8faf4'
      - '#f6f5fb'
  lightColorScheme:
    name: Tabby Default Light
    foreground: '#4d4d4c'
    background: '#ffffff'
    cursor: '#4d4d4c'
    colors:
      - '#000000'
      - '#c82829'
      - '#718c00'
      - '#eab700'
      - '#4271ae'
      - '#8959a8'
      - '#3e999f'
      - '#ffffff'
      - '#000000'
      - '#c82829'
      - '#718c00'
      - '#eab700'
      - '#4271ae'
      - '#8959a8'
      - '#3e999f'
      - '#ffffff'
  customColorSchemes: []
  fontSize: 20
clickableLinks: {}
accessibility: {}
appearance:
  opacity: 0.84
  vibrancy: true
hacks: {}
providerBlacklist: []
commandBlacklist: []
profileBlacklist: []
enableWelcomeTab: false
pluginBlacklist: []
profileDefaults:
  ssh:
    disableDynamicTitle: true
~~~

- [ ] **Step 4: Run the validation and confirm it passes**

Run:

~~~bash
bash tests/test_tabby_config_install.sh
~~~

Expected output:

~~~text
tabby config content and privacy checks passed
~~~

- [ ] **Step 5: Commit the public snapshot**

Run:

~~~bash
git add config/tabby/config.yaml tests/test_tabby_config_install.sh
git commit -m "feat: add sanitized Tabby config"
~~~

Expected: commit succeeds and `git status --short` is empty.

### Task 3: Implement copy-only Tabby config deployment

**Files:**

- Modify: `tests/test_tabby_config_install.sh`
- Modify: `bootstrap/common.sh`

- [ ] **Step 1: Extend the test with path, copy, and backup assertions**

Append the following exact block to `tests/test_tabby_config_install.sh`:

~~~bash

# shellcheck source=bootstrap/common.sh
source "$REPO_ROOT/bootstrap/common.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

export HOME="$tmp_dir/home"
export XDG_CONFIG_HOME="$tmp_dir/xdg-config"
export APPDATA="$tmp_dir/windows-appdata"
export DOTFILES_LINK_MODE=symlink
mkdir -p "$HOME"

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

shopt -s nullglob
backups=("$target".bak.*)
shopt -u nullglob
[ "${#backups[@]}" -eq 1 ] || fail "expected exactly one timestamped backup"
assert_eq \
  "private runtime state" \
  "$(sed -n '1p' "${backups[0]}")" \
  "backup content"
[ ! -L "$target" ] || fail "replacement Tabby config must remain a regular file"
cmp -s "$TABBY_CONFIG" "$target" || fail "replacement config differs from source"

printf 'tabby config path, copy, and backup checks passed\n'
~~~

- [ ] **Step 2: Run the extended test and confirm it fails**

Run:

~~~bash
bash tests/test_tabby_config_install.sh
~~~

Expected: the YAML checks pass, then the script exits non-zero because `tabby_config_path` is not defined.

- [ ] **Step 3: Add path calculation and copy-only deployment**

In `bootstrap/common.sh`, insert this exact code after `ensure_base_dirs()`:

~~~bash
tabby_config_path() {
  local platform="${1:-$(platform_name)}"
  local appdata_unix

  case "$platform" in
    linux)
      printf '%s\n' "$(config_home)/tabby/config.yaml"
      ;;
    macos)
      printf '%s\n' "$HOME/Library/Application Support/tabby/config.yaml"
      ;;
    windows)
      appdata_unix="$(windows_to_unix_path "${APPDATA:-}")"
      [ -n "$appdata_unix" ] || die "APPDATA is required to install the Windows Tabby config"
      printf '%s\n' "$appdata_unix/Tabby/config.yaml"
      ;;
    *)
      die "unsupported platform for Tabby config: $platform"
      ;;
  esac
}

install_tabby_config() {
  local platform="${1:-$(platform_name)}"
  local source_file="$REPO_ROOT/config/tabby/config.yaml"
  local target

  [ -f "$source_file" ] || die "missing Tabby config: $source_file"
  target="$(tabby_config_path "$platform")"

  warn "Close Tabby before installing config; a running app may overwrite this file on exit"
  mkdir -p "$(dirname "$target")"

  if [ -e "$target" ] || [ -L "$target" ]; then
    backup_existing "$target"
  fi

  cp "$source_file" "$target"
}
~~~

Then replace the WezTerm line inside `install_config_payload()`:

~~~diff
-  link_or_copy "$REPO_ROOT/config/wezterm/wezterm.lua" "$HOME/.wezterm.lua"
+  install_tabby_config
~~~

Do not call `link_or_copy` for the Tabby file and do not consult `DOTFILES_LINK_MODE` inside `install_tabby_config`.

- [ ] **Step 4: Run the test and syntax checks**

Run:

~~~bash
bash -n bootstrap/common.sh tests/test_tabby_config_install.sh
bash tests/test_tabby_config_install.sh
~~~

Expected output includes:

~~~text
tabby config content and privacy checks passed
tabby config path, copy, and backup checks passed
~~~

Warnings about closing Tabby and one backup log line are expected on stderr/stdout. Both commands exit 0.

- [ ] **Step 5: Commit copy-only deployment**

Run:

~~~bash
git add bootstrap/common.sh tests/test_tabby_config_install.sh
git commit -m "feat: deploy Tabby config safely"
~~~

Expected: commit succeeds and `git status --short` is empty.

### Task 4: Replace terminal installation on all platforms

**Files:**

- Modify: `tests/test_tabby_config_install.sh`
- Modify: `bootstrap/common.sh`
- Modify: `install/macos.sh`
- Modify: `install/ubuntu.sh`
- Modify: `install/windows-msys2.sh`
- Modify: `install/windows.ps1`

- [ ] **Step 1: Add failing static installer assertions**

Append this exact block to `tests/test_tabby_config_install.sh`:

~~~bash

assert_file_contains() {
  local path="$1"
  local text="$2"
  grep -F -- "$text" "$path" >/dev/null ||
    fail "$path does not contain required text: $text"
}

assert_file_not_contains() {
  local path="$1"
  local text="$2"
  if grep -Fi -- "$text" "$path" >/dev/null; then
    fail "$path contains forbidden text: $text"
  fi
}

assert_file_contains "$REPO_ROOT/bootstrap/common.sh" "install_tabby_linux()"
assert_file_contains "$REPO_ROOT/bootstrap/common.sh" "Eugeny/tabby"
assert_file_not_contains "$REPO_ROOT/bootstrap/common.sh" "ensure_wezterm_apt_repo"
assert_file_not_contains "$REPO_ROOT/bootstrap/common.sh" "apt.fury.io/wez"

assert_file_contains "$REPO_ROOT/install/macos.sh" "brew install --cask tabby"
assert_file_contains "$REPO_ROOT/install/ubuntu.sh" "install_tabby_linux"
assert_file_contains "$REPO_ROOT/install/windows-msys2.sh" "Eugeny.Tabby"
assert_file_contains "$REPO_ROOT/install/windows.ps1" "Eugeny.Tabby"

for installer in \
  "$REPO_ROOT/install/macos.sh" \
  "$REPO_ROOT/install/ubuntu.sh" \
  "$REPO_ROOT/install/windows-msys2.sh" \
  "$REPO_ROOT/install/windows.ps1"; do
  assert_file_not_contains "$installer" "wezterm"
done

printf 'cross-platform Tabby installer checks passed\n'
~~~

- [ ] **Step 2: Run the test and confirm the static checks fail**

Run:

~~~bash
bash tests/test_tabby_config_install.sh
~~~

Expected: config/path/copy checks pass; the script then exits non-zero because `install_tabby_linux()` is absent and old WezTerm references remain.

- [ ] **Step 3: Replace the Linux WezTerm repository helper**

In `bootstrap/common.sh`, replace the complete `ensure_wezterm_apt_repo()` function with:

~~~bash
install_tabby_linux() {
  local arch pattern url tmp_dir asset_name

  arch="$(linux_arch)"
  case "$arch" in
    x86_64) pattern='tabby-[0-9.]+-linux-x64\.deb$' ;;
    arm64) pattern='tabby-[0-9.]+-linux-arm64\.deb$' ;;
  esac

  url="$(github_latest_asset_url 'Eugeny/tabby' "$pattern")"
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' RETURN
  asset_name="$(basename "$url")"

  log "Installing Tabby from $url"
  fetch_url "$url" "$tmp_dir/$asset_name"
  run_root apt-get install -y "$tmp_dir/$asset_name"
}
~~~

The regular expression contains one backslash before `.deb`; it must match release assets such as `tabby-1.0.234-linux-x64.deb`.

- [ ] **Step 4: Update the macOS installer**

Apply these exact changes to `install/macos.sh`:

~~~diff
 log "Installing Homebrew packages"
-brew install tmux neovim lazygit yazi wezterm direnv eza bat fzf ripgrep fd
+brew install tmux neovim lazygit yazi direnv eza bat fzf ripgrep fd
+brew install --cask tabby
@@
-log "Done. Restart the shell or run: exec zsh"
+log "Done. Restart the shell or run: exec zsh, then start Tabby"
~~~

- [ ] **Step 5: Update the Ubuntu installer**

Apply these exact changes to `install/ubuntu.sh`:

~~~diff
-ensure_wezterm_apt_repo
-run_root apt-get update
-run_root apt-get install -y wezterm
+install_tabby_linux
~~~

Keep the existing final Zsh message unchanged.

- [ ] **Step 6: Update the MSYS2 installer**

Apply these exact changes to `install/windows-msys2.sh`:

~~~diff
 if command -v winget.exe >/dev/null 2>&1; then
-  log "Installing WezTerm and Lazygit through winget"
-  winget.exe install -e --id Wez.WezTerm --accept-package-agreements --accept-source-agreements || true
+  log "Installing Tabby and Lazygit through winget"
+  winget.exe install -e --id Eugeny.Tabby --accept-package-agreements --accept-source-agreements || true
   winget.exe install -e --id JesseDuffield.lazygit --accept-package-agreements --accept-source-agreements || true
 else
-  warn "winget.exe not found; install WezTerm and Lazygit manually on Windows"
+  warn "winget.exe not found; install Tabby and Lazygit manually on Windows"
 fi
 
-log "Done. Start WezTerm and point it at MSYS2 zsh if needed"
+log "Done. Start Tabby and select an MSYS2 shell profile if needed"
~~~

- [ ] **Step 7: Update the PowerShell installer**

Apply this exact replacement to `install/windows.ps1`:

~~~diff
-winget.exe install -e --id Wez.WezTerm --accept-package-agreements --accept-source-agreements
+winget.exe install -e --id Eugeny.Tabby --accept-package-agreements --accept-source-agreements
~~~

- [ ] **Step 8: Run installer tests and syntax checks**

Run:

~~~bash
bash -n bootstrap/*.sh install/*.sh tests/*.sh
bash tests/test_tabby_config_install.sh
~~~

Expected output includes all three success lines:

~~~text
tabby config content and privacy checks passed
tabby config path, copy, and backup checks passed
cross-platform Tabby installer checks passed
~~~

Both commands exit 0.

- [ ] **Step 9: Commit cross-platform installation**

Run:

~~~bash
git add bootstrap/common.sh install tests/test_tabby_config_install.sh
git commit -m "feat: install Tabby across platforms"
~~~

Expected: commit succeeds and `git status --short` is empty.

### Task 5: Replace production documentation with Tabby guidance

**Files:**

- Modify: `README.md`
- Modify: `当前环境常用快捷键速查.md`
- Inspect without modification unless necessary: `lazygit操作指南.md`

- [ ] **Step 1: Demonstrate the current documentation failure**

Run:

~~~bash
rg -n -i 'wezterm' README.md 当前环境常用快捷键速查.md lazygit操作指南.md
~~~

Expected: matches appear in `README.md` and `当前环境常用快捷键速查.md`; no match appears in `lazygit操作指南.md`.

- [ ] **Step 2: Apply the exact README substitutions**

Make these direct replacements in `README.md`:

~~~text
`WezTerm` -> `Tabby` in the opening inventory
`config/wezterm/wezterm.lua`: WezTerm 跨平台配置
  -> `config/tabby/config.yaml`: 经过白名单筛选的 Tabby 跨平台配置
Windows 方案以 MSYS2 为 Unix 工具栈，WezTerm 和 Lazygit 通过 `winget` 安装。
  -> Windows 方案以 MSYS2 为 Unix 工具栈，Tabby 和 Lazygit 通过 `winget` 安装。
~~~

Replace the existing general deployment-policy bullet with:

~~~markdown
- 安装默认在 Unix 上对普通 dotfiles 使用软链接，在 Windows / MSYS2 上默认复制；可通过 `DOTFILES_LINK_MODE=symlink|copy` 覆盖。
- Tabby 的 `config.yaml` 在所有平台都强制复制并先备份旧文件，绝不软链接，避免 Tabby 把 SSH known-host 等本机数据回写到仓库。
~~~

Replace the macOS installation bullets that mention WezTerm with:

~~~markdown
- Homebrew: `tmux` `neovim` `lazygit` `yazi` `direnv` `eza` `bat` `fzf` `ripgrep` `fd`
- Homebrew cask: `tabby`
- 可选 Nerd Font: `font-jetbrains-mono-nerd-font`
- 固定版本的 `oh-my-zsh` / `powerlevel10k` / zsh 插件 / tmux 插件
- 当前普通 dotfiles 到 `~/.zshrc` `~/.p10k.zsh` `~/.tmux.conf` `~/.config/*`
- Tabby 配置复制到 `~/Library/Application Support/tabby/config.yaml`
~~~

Replace the Ubuntu WezTerm bullet with:

~~~markdown
- Tabby: 从官方 GitHub Release 下载与 `x86_64` / `arm64` 匹配的最新 `.deb`，再由 `apt` 安装
~~~

Replace the Windows WinGet and mirror bullets with:

~~~markdown
- `winget`: `Tabby`、`Lazygit`
- 配置镜像：
  - `~/.zshrc` `~/.p10k.zsh` `~/.tmux.conf`
  - `~/.config/nvim` / `~/.config/yazi` / `~/.config/lazygit`
  - Windows 原生位置：`%LOCALAPPDATA%\nvim`、`%APPDATA%\yazi\config`、`%APPDATA%\lazygit`
  - Tabby 白名单配置复制到 `%APPDATA%\Tabby\config.yaml`
~~~

Replace the complete `### WezTerm` section with:

~~~markdown
### Tabby

`config/tabby/config.yaml` 是从当前 Tabby 1.0.234 配置按白名单重建的公开快照：

- 保留当前完整快捷键映射
- 深色方案为 `AdventureTime`，同时保留 `Tabby Default Light`
- 字体大小为 `20`
- 窗口透明度为 `0.84`，启用 `vibrancy`
- 关闭欢迎页
- SSH profile 默认关闭动态标题
- 不包含根级 `ssh`、known-host、连接 profile、`configSync`、vault、令牌、密码、密钥路径或 Electron 运行态文件
- Linux 复制到 `${XDG_CONFIG_HOME:-$HOME/.config}/tabby/config.yaml`
- macOS 复制到 `~/Library/Application Support/tabby/config.yaml`
- Windows 复制到 `%APPDATA%\Tabby\config.yaml`

安装前请先完全退出 Tabby。已有 `config.yaml` 会备份为 `config.yaml.bak.YYYYMMDDHHMMSS`。

> 不要把本机完整的 Tabby `config.yaml` 直接复制回仓库；它可能包含 SSH known-host、连接信息或同步凭据。更新仓库快照时必须重新执行字段白名单筛选。
~~~

Replace `wezterm -V` in the verification block with:

~~~bash
tabby --version
~~~

Append this bullet to `## 已知说明`:

~~~markdown
- Tabby 配置始终复制，不受 `DOTFILES_LINK_MODE` 影响；应用后续写入只发生在平台配置目录的本机副本。
~~~

- [ ] **Step 3: Replace the shortcut guide's environment metadata**

In `当前环境常用快捷键速查.md`, apply these exact replacements:

~~~diff
-| WezTerm | `20240203-110809-5046fc22` |
+| Tabby | `1.0.234` |
@@
-| WezTerm | `~/.wezterm.lua` | 已发现分屏、关闭 pane、全屏、鼠标行为自定义 |
+| Tabby | `~/.config/tabby/config.yaml` | 已发现完整快捷键、AdventureTime 配色、20px 字体、透明度和 pane 设置 |
@@
-- `tmux / zsh / WezTerm / LazyVim / yazi`：以下内容里会明确区分“本机自定义”与“默认常用”。
+- `tmux / zsh / Tabby / LazyVim / yazi`：以下内容里会明确区分“本机自定义”与“默认常用”。
~~~

- [ ] **Step 4: Replace section 4 with current Tabby shortcuts**

Replace everything from `## 4. WezTerm` through the horizontal rule immediately before `## 5. LazyVim / Neovim` with:

~~~markdown
## 4. Tabby

### 4.1 当前环境里的关键设定

- 当前版本为 `1.0.234`
- 深色配色为 `AdventureTime`
- 字体大小为 `20`
- 窗口透明度为 `0.84`，启用 `vibrancy`
- 欢迎页已关闭
- 当前仓库只保存公开设置，不保存 SSH known-host、连接 profile、同步信息或 vault

### 4.2 窗口与 tab

| 快捷键 | 作用 | 来源 |
| --- | --- | --- |
| `Ctrl-Space` | 显示 / 隐藏 Tabby 窗口 | 本机配置 |
| `F11` | 切换全屏 | 本机配置 |
| `Ctrl-Shift-T` | 新建 tab | 本机配置 |
| `Ctrl-Shift-N` | 新建窗口 | 本机配置 |
| `Ctrl-Shift-W` | 关闭当前 tab | 本机配置 |
| `Ctrl-Shift-Z` | 重新打开最近关闭的 tab | 本机配置 |
| `Ctrl-Shift-R` | 重命名当前 tab | 本机配置 |
| `Ctrl-Tab` / `Ctrl-Shift-Right` | 下一个 tab | 本机配置 |
| `Ctrl-Shift-Tab` / `Ctrl-Shift-Left` | 上一个 tab | 本机配置 |
| `Alt-1` 到 `Alt-0` | 直达第 1 到第 10 个 tab | 本机配置 |
| `Ctrl-,` | 打开设置 | 本机配置 |
| `Ctrl-Shift-P` | 打开命令选择器 | 本机配置 |
| `Ctrl-Shift-E` | 打开 profile 选择器 | 本机配置 |

### 4.3 终端编辑、搜索与滚动

| 快捷键 | 作用 | 来源 |
| --- | --- | --- |
| `Ctrl-Shift-C` | 复制 | 本机配置 |
| `Ctrl-Shift-V` / `Shift-Insert` | 粘贴 | 本机配置 |
| `Ctrl-Shift-A` | 全选 | 本机配置 |
| `Ctrl-Shift-F` | 搜索当前终端输出 | 本机配置 |
| `Ctrl-=` / `Ctrl-Shift-=` | 放大字体 | 本机配置 |
| `Ctrl--` / `Ctrl-Shift--` | 缩小字体 | 本机配置 |
| `Ctrl-0` | 重置缩放 | 本机配置 |
| `Ctrl-Left` / `Ctrl-Right` | 前一个 / 后一个单词 | 本机配置 |
| `Ctrl-Backspace` / `Ctrl-Delete` | 删除前一个 / 后一个单词 | 本机配置 |
| `Ctrl-PageUp` / `Ctrl-PageDown` | 滚动到顶部 / 底部 | 本机配置 |
| `Alt-PageUp` / `Alt-PageDown` | 向上 / 向下翻页 | 本机配置 |
| `Ctrl-Shift-Up` / `Ctrl-Shift-Down` | 向上 / 向下滚动 | 本机配置 |

### 4.4 pane

| 快捷键 | 作用 | 来源 |
| --- | --- | --- |
| `Ctrl-Shift-S` | 向右分 pane | 本机配置 |
| `Ctrl-Shift-D` | 向下分 pane | 本机配置 |
| `Ctrl-Alt-Left/Right/Up/Down` | 在 pane 间移动焦点 | 本机配置 |
| `Ctrl-Alt-Enter` | 最大化 / 还原当前 pane | 本机配置 |

### 4.5 使用建议

- 如果你把 tmux 跑在 Tabby 里，建议分清两层：
  - Tabby 分屏：`Ctrl-Shift-S` / `Ctrl-Shift-D`
  - tmux 分屏：`Ctrl-b |` / `Ctrl-b -`
- 如果你已经在 tmux 里长期工作，Tabby 更适合负责：
  - tab 和窗口管理
  - 系统剪贴板
  - 搜索历史输出
  - 临时性的 GUI 级 pane 分割

---
~~~

- [ ] **Step 5: Update the minimal-memory and reference sections**

Replace the complete `### 8.3 WezTerm` subsection with:

~~~markdown
### 8.3 Tabby

- `Ctrl-Shift-T`
- `Ctrl-Shift-S`
- `Ctrl-Shift-D`
- `Ctrl-Shift-W`
- `Ctrl-Shift-F`
- `Ctrl-Alt-Left/Right/Up/Down`
~~~

In `### 9.1 本机配置`, replace:

~~~markdown
- `~/.wezterm.lua`
~~~

with:

~~~markdown
- `~/.config/tabby/config.yaml`
~~~

- [ ] **Step 6: Verify all production WezTerm references are gone**

Run:

~~~bash
if rg -n -i 'wezterm' \
  README.md \
  bootstrap \
  config \
  install \
  当前环境常用快捷键速查.md \
  lazygit操作指南.md; then
  exit 1
fi
~~~

Expected: no output and exit 0.

- [ ] **Step 7: Commit documentation**

Run:

~~~bash
git add README.md 当前环境常用快捷键速查.md
git commit -m "docs: document Tabby workflow"
~~~

Expected: commit succeeds and `git status --short` is empty.

### Task 6: Run final verification and prove repository isolation

**Files:**

- Verify only: all production and test files
- Verify only: `${HOME}/code/wezterm_config`

- [ ] **Step 1: Run syntax and behavioral tests**

Run:

~~~bash
bash -n bootstrap/*.sh install/*.sh tests/*.sh
bash tests/test_tabby_config_install.sh
~~~

Expected: both commands exit 0. The test output includes:

~~~text
tabby config content and privacy checks passed
tabby config path, copy, and backup checks passed
cross-platform Tabby installer checks passed
~~~

- [ ] **Step 2: Re-run the production residual and privacy scans**

Run:

~~~bash
if rg -n -i 'wezterm' \
  README.md \
  bootstrap \
  config \
  install \
  当前环境常用快捷键速查.md \
  lazygit操作指南.md; then
  exit 1
fi

if rg -n \
  '^(ssh|configSync|vault):|knownHosts|password:|passphrase:|privateKeys?:|token:' \
  config/tabby/config.yaml; then
  exit 1
fi
~~~

Expected: no output and exit 0.

- [ ] **Step 3: Verify the shared configuration remained byte-for-byte equal**

Run:

~~~bash
git diff --no-index ${HOME}/code/wezterm_config/config/zsh config/zsh
git diff --no-index ${HOME}/code/wezterm_config/config/tmux config/tmux
git diff --no-index ${HOME}/code/wezterm_config/config/nvim config/nvim
git diff --no-index ${HOME}/code/wezterm_config/config/yazi config/yazi
git diff --no-index ${HOME}/code/wezterm_config/config/lazygit config/lazygit
git diff --no-index \
  ${HOME}/code/wezterm_config/bootstrap/plugins.lock.sh \
  bootstrap/plugins.lock.sh
git diff --no-index \
  ${HOME}/code/wezterm_config/bootstrap/github_release_asset.py \
  bootstrap/github_release_asset.py
~~~

Expected: all commands exit 0 and produce no output.

- [ ] **Step 4: Verify Tabby itself and the final Git state**

Run:

~~~bash
tabby --version
git diff --check
test "$(git branch --show-current)" = "main"
test -z "$(git remote)"
test -z "$(git status --porcelain)"
git log --oneline --decorate -8
~~~

Expected:

- `tabby --version` prints `1.0.234`.
- `git diff --check` prints nothing.
- branch, remote, and clean-worktree tests exit 0.
- the log shows the design and plan commits plus the implementation commits from Tasks 1–5.

- [ ] **Step 5: Prove the source repository is untouched**

Run:

~~~bash
test "$(git -C ${HOME}/code/wezterm_config rev-parse HEAD)" = \
  "bcec1a38b17f5df544367028d21693f21b225a04"
test -z "$(git -C ${HOME}/code/wezterm_config status --porcelain)"
git -C ${HOME}/code/wezterm_config status --short --branch
~~~

Expected:

~~~text
## main...origin/main
~~~

No follow-up mutation, remote creation, package installation, or push is part of this plan.
