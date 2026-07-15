# tmux Powerline Bar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reproduce the designed minimal tmux bottom bar on the `server` branch and deploy its tmux-powerline user configuration on every supported installation path.

**Architecture:** Fast-forward local `main` to `origin/main`, then merge it into the published `server` branch without rewriting history. Store a small user config plus a theme that inherits the pinned plugin's `default.sh`, deploy the whole directory through `link_or_copy`, and verify file contents, copy-mode installation, documentation, and rendering.

**Tech Stack:** Bash, tmux, erikw/tmux-powerline at `d70011158dc389070d6ed7a67b65367206b6ddec`, Git.

---

### Task 1: Align `main` and `server`

**Files:**
- Bring into `server`: `docs/superpowers/specs/2026-07-15-tmux-powerline-bar-design.md`

- [ ] **Step 1: Refresh and fast-forward local `main`**

Run:

```bash
git fetch origin --prune
git switch main
git pull --ff-only origin main
```

Expected: local `main` points to `4aa5b7c` or a newer fast-forward descendant of it.

- [ ] **Step 2: Merge `main` into `server` without rewriting the published server commit**

Run:

```bash
git switch server
git merge --no-edit main
```

Expected: the merge succeeds, preserves `adde7aa`, and adds the tmux-powerline design document.

- [ ] **Step 3: Verify the branch topology**

Run:

```bash
git merge-base --is-ancestor main server
git merge-base --is-ancestor adde7aa server
git status --short --branch
```

Expected: both ancestry checks exit 0 and the `server` worktree is clean.

### Task 2: Capture the minimal tmux-powerline configuration

**Files:**
- Create: `tests/test_tmux_powerline_config.sh`
- Create: `config/tmux-powerline/config.sh`
- Create: `config/tmux-powerline/themes/minimal.sh`

- [ ] **Step 1: Write the failing content test**

Create `tests/test_tmux_powerline_config.sh` with these checks before adding the configuration files:

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
POWERLINE_CONFIG="$REPO_ROOT/config/tmux-powerline/config.sh"
POWERLINE_THEME="$REPO_ROOT/config/tmux-powerline/themes/minimal.sh"

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

[ -f "$POWERLINE_CONFIG" ] || fail "missing tmux-powerline config"
[ -f "$POWERLINE_THEME" ] || fail "missing minimal tmux-powerline theme"
assert_file_contains "$POWERLINE_CONFIG" 'export TMUX_POWERLINE_THEME="minimal"'
assert_file_contains "$POWERLINE_CONFIG" 'export TMUX_POWERLINE_DIR_USER_THEMES="${XDG_CONFIG_HOME:-$HOME/.config}/tmux-powerline/themes"'
assert_file_contains "$POWERLINE_CONFIG" 'export TMUX_POWERLINE_STATUS_INTERVAL="1"'
assert_file_contains "$POWERLINE_CONFIG" 'export TMUX_POWERLINE_STATUS_JUSTIFICATION="centre"'
assert_file_contains "$POWERLINE_CONFIG" 'export TMUX_POWERLINE_SEG_TMUX_SESSION_INFO_FORMAT="#S:#I.#P"'
assert_file_contains "$POWERLINE_THEME" 'source "${TMUX_POWERLINE_DIR_THEMES}/default.sh"'
assert_file_contains "$POWERLINE_THEME" '"tmux_session_info 148 234"'
assert_file_contains "$POWERLINE_THEME" 'TMUX_POWERLINE_RIGHT_STATUS_SEGMENTS=()'

printf 'tmux-powerline content checks passed\n'
```

- [ ] **Step 2: Run the content test to verify it fails**

Run:

```bash
bash tests/test_tmux_powerline_config.sh
```

Expected: FAIL with `missing tmux-powerline config`.

- [ ] **Step 3: Add the minimal user configuration**

Create `config/tmux-powerline/config.sh`:

```bash
# shellcheck shell=bash

export TMUX_POWERLINE_PATCHED_FONT_IN_USE="true"
export TMUX_POWERLINE_THEME="minimal"
export TMUX_POWERLINE_DIR_USER_THEMES="${XDG_CONFIG_HOME:-$HOME/.config}/tmux-powerline/themes"
export TMUX_POWERLINE_DIR_USER_SEGMENTS="${XDG_CONFIG_HOME:-$HOME/.config}/tmux-powerline/segments"

export TMUX_POWERLINE_STATUS_VISIBILITY="on"
export TMUX_POWERLINE_WINDOW_STATUS_LINE="0"
export TMUX_POWERLINE_STATUS_INTERVAL="1"
export TMUX_POWERLINE_STATUS_JUSTIFICATION="centre"
export TMUX_POWERLINE_STATUS_LEFT_LENGTH="60"
export TMUX_POWERLINE_STATUS_RIGHT_LENGTH="90"
export TMUX_POWERLINE_WINDOW_STATUS_SEPARATOR=""

export TMUX_POWERLINE_SEG_TMUX_SESSION_INFO_FORMAT="#S:#I.#P"
```

Create `config/tmux-powerline/themes/minimal.sh`:

```bash
# shellcheck shell=bash

# Inherit window formatting, separators, and the colour235 status background
# from the default theme bundled with the pinned tmux-powerline checkout.
# shellcheck disable=SC1090
source "${TMUX_POWERLINE_DIR_THEMES}/default.sh"

TMUX_POWERLINE_LEFT_STATUS_SEGMENTS=(
  "tmux_session_info 148 234"
)
TMUX_POWERLINE_RIGHT_STATUS_SEGMENTS=()
```

- [ ] **Step 4: Run the content test to verify it passes**

Run:

```bash
bash tests/test_tmux_powerline_config.sh
```

Expected: `tmux-powerline content checks passed`.

- [ ] **Step 5: Commit the captured configuration and test**

Run:

```bash
git add config/tmux-powerline tests/test_tmux_powerline_config.sh
git commit -m "feat: capture tmux powerline bar config"
```

### Task 3: Deploy the configuration directory

**Files:**
- Modify: `tests/test_tmux_powerline_config.sh`
- Modify: `bootstrap/common.sh`

- [ ] **Step 1: Extend the test with copy-mode deployment assertions**

Append before the final success message in `tests/test_tmux_powerline_config.sh`:

```bash
# shellcheck source=bootstrap/common.sh
source "$REPO_ROOT/bootstrap/common.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

export HOME="$tmp_dir/home"
export XDG_CONFIG_HOME="$tmp_dir/xdg-config"
export DOTFILES_LINK_MODE=copy
export DOTFILES_SKIP_TABBY=1
mkdir -p "$HOME"

install_config_payload

installed_powerline="$XDG_CONFIG_HOME/tmux-powerline"
[ -d "$installed_powerline" ] || fail "tmux-powerline directory was not installed"
[ ! -L "$installed_powerline" ] || fail "copy mode installed a symlink"
cmp -s "$POWERLINE_CONFIG" "$installed_powerline/config.sh" ||
  fail "installed tmux-powerline config differs from source"
cmp -s "$POWERLINE_THEME" "$installed_powerline/themes/minimal.sh" ||
  fail "installed minimal theme differs from source"

assert_file_contains \
  "$REPO_ROOT/bootstrap/common.sh" \
  'link_or_copy "$REPO_ROOT/config/tmux-powerline" "$cfg/tmux-powerline"'
```

- [ ] **Step 2: Run the deployment test to verify it fails**

Run:

```bash
bash tests/test_tmux_powerline_config.sh
```

Expected: FAIL with `tmux-powerline directory was not installed`.

- [ ] **Step 3: Deploy the directory through the shared installer**

Add this call in `install_config_payload` immediately after the `.tmux.conf` deployment in `bootstrap/common.sh`:

```bash
link_or_copy "$REPO_ROOT/config/tmux-powerline" "$cfg/tmux-powerline"
```

- [ ] **Step 4: Run the deployment and existing regression tests**

Run:

```bash
bash tests/test_tmux_powerline_config.sh
bash tests/test_tabby_config_install.sh
```

Expected: both scripts exit 0; the new script prints its content/deployment success messages and the existing script ends with `Tabby production documentation checks passed`.

- [ ] **Step 5: Commit the installer change**

Run:

```bash
git add bootstrap/common.sh tests/test_tmux_powerline_config.sh
git commit -m "feat: deploy tmux powerline config"
```

### Task 4: Document desktop and server behavior

**Files:**
- Modify: `tests/test_tmux_powerline_config.sh`
- Modify: `README.md`
- Modify: `docs/server-quickstart.md`

- [ ] **Step 1: Add failing documentation assertions**

Append these checks before the final success message in `tests/test_tmux_powerline_config.sh`:

```bash
README="$REPO_ROOT/README.md"
SERVER_GUIDE="$REPO_ROOT/docs/server-quickstart.md"

assert_file_contains "$README" 'config/tmux-powerline/config.sh'
assert_file_contains "$README" 'config/tmux-powerline/themes/minimal.sh'
assert_file_contains "$README" '${XDG_CONFIG_HOME:-$HOME/.config}/tmux-powerline'
assert_file_contains "$README" 'session/window/pane'
assert_file_contains "$README" 'powerline.sh left'
assert_file_contains "$README" 'powerline.sh right'
assert_file_contains "$SERVER_GUIDE" '"$HOME/.config/tmux-powerline"'
assert_file_contains "$SERVER_GUIDE" 'powerline.sh left'
assert_file_contains "$SERVER_GUIDE" 'powerline.sh right'
```

- [ ] **Step 2: Run the documentation test to verify it fails**

Run:

```bash
bash tests/test_tmux_powerline_config.sh
```

Expected: FAIL because `README.md` does not yet mention `config/tmux-powerline/config.sh`.

- [ ] **Step 3: Update `README.md`**

Document both tracked files in the directory overview, the deployment target `${XDG_CONFIG_HOME:-$HOME/.config}/tmux-powerline`, and the visible bar structure: session/window/pane on the left, window list in the centre, and no right segments. Replace the old hand-written status-bar description with the tmux-powerline behavior and add these verification commands:

```bash
~/.tmux/plugins/tmux-powerline/powerline.sh left
~/.tmux/plugins/tmux-powerline/powerline.sh right
```

- [ ] **Step 4: Update `docs/server-quickstart.md`**

Add `"$HOME/.config/tmux-powerline"` to the configuration-link verification loop. Add the same left/right rendering commands after the isolated tmux validation so the user-local server path verifies the captured bar configuration.

- [ ] **Step 5: Run all repository tests**

Run:

```bash
bash tests/test_tmux_powerline_config.sh
bash tests/test_tabby_config_install.sh
```

Expected: both scripts exit 0.

- [ ] **Step 6: Commit the documentation and assertions**

Run:

```bash
git add README.md docs/server-quickstart.md tests/test_tmux_powerline_config.sh
git commit -m "docs: explain tmux powerline bar"
```

### Task 5: Verify rendering and final branch state

**Files:**
- Verify: `config/tmux-powerline/config.sh`
- Verify: `config/tmux-powerline/themes/minimal.sh`
- Verify: `bootstrap/common.sh`
- Verify: `README.md`
- Verify: `docs/server-quickstart.md`

- [ ] **Step 1: Render both sides with the pinned local plugin**

Run:

```bash
XDG_CONFIG_HOME="$PWD/config" ~/.tmux/plugins/tmux-powerline/powerline.sh left
XDG_CONFIG_HOME="$PWD/config" ~/.tmux/plugins/tmux-powerline/powerline.sh right
```

Expected: left output contains `#S:#I.#P`, `colour148`, and `colour234`; right output is empty.

- [ ] **Step 2: Run syntax and whitespace checks**

Run:

```bash
bash -n bootstrap/common.sh tests/test_tmux_powerline_config.sh config/tmux-powerline/config.sh config/tmux-powerline/themes/minimal.sh
git diff --check main...server
```

Expected: both commands exit 0 with no diagnostics.

- [ ] **Step 3: Re-run all tests from a clean command invocation**

Run:

```bash
bash tests/test_tmux_powerline_config.sh
bash tests/test_tabby_config_install.sh
```

Expected: both scripts exit 0.

- [ ] **Step 4: Inspect commits and working tree**

Run:

```bash
git log --oneline --decorate main..server
git status --short --branch
```

Expected: `server` contains the preserved server bootstrap commit, the merged design, and the tmux implementation commits; the worktree is clean. Do not push unless the user explicitly requests it.
