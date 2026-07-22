# Server Provisioning Expansion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Expand `install/ubuntu-user.sh` into an idempotent Ubuntu server bootstrap for Docker, Miniforge, monitoring tools, Git identity, proxy aliases, and Codex configuration while leaving Tabby untouched.

**Architecture:** Keep `install/ubuntu-user.sh` as the only public entry point and move new behavior into focused shell modules under `bootstrap/server/`. Pure parsing and TOML merging live in small Python helpers so they can be tested without changing the real machine. Each module detects existing state, applies only missing managed state, verifies the result, and can be sourced with mocked command wrappers in tests.

**Tech Stack:** Bash, Python 3 standard library, Git, apt, Docker Engine/Rootless Docker, Miniforge/conda, Codex CLI

---

## File Structure

- Create `bootstrap/proxy_endpoint.py`: normalize a proxy candidate to a credential-free host and port.
- Create `bootstrap/server/environment.sh`: detect sudo/proxy state and render managed Bash/Zsh environment files.
- Create `bootstrap/server/miniforge.sh`: reuse or install Miniforge and expose conda to both shells.
- Create `bootstrap/server/monitoring.sh`: install `nvitop`, `btop`, and `htop` through apt or an isolated conda prefix.
- Create `bootstrap/server/docker.sh`: choose existing, system Docker CE, or Rootless Docker and verify plugins.
- Create `bootstrap/server/codex.sh`: install selected plugins, the pinned `pretty-mermaid` skill, and merge Codex settings.
- Create `bootstrap/merge_codex_config.py`: merge arbitrary owned one-line TOML keys while preserving unrelated sections.
- Create `config/codex/server.toml`: canonical Codex settings selected in the design.
- Modify `bootstrap/common.sh`: add a reusable managed-block helper and use the generic Codex merger.
- Modify `bootstrap/plugins.lock.sh`: pin the `pretty-mermaid` repository revision.
- Modify `config/zsh/.zshrc`: remove the hard-coded proxy port and source the generated server environment.
- Modify `install/ubuntu-user.sh`: source and call the new modules in dependency order.
- Create `tests/test_server_environment.sh`, `tests/test_miniforge_install.sh`, `tests/test_monitoring_install.sh`, `tests/test_docker_install.sh`, and `tests/test_codex_server_config.sh`.
- Modify `tests/test_codex_notifications.sh`: point existing notification coverage at the generic merger.
- Modify `README.md` and `docs/server-quickstart.md`: document behavior, security constraints, and verification.

### Task 1: Proxy Detection and Idempotent Shell Environment

**Files:**
- Create: `bootstrap/proxy_endpoint.py`
- Create: `bootstrap/server/environment.sh`
- Create: `tests/test_server_environment.sh`
- Modify: `bootstrap/common.sh`
- Modify: `config/zsh/.zshrc`

- [ ] **Step 1: Write the failing proxy and managed-block tests**

Create `tests/test_server_environment.sh` with isolated homes and command fixtures. The assertions must cover environment precedence, Git fallback, Clash fallback, the `7890` fallback, credential removal, IPv4 rendering, and two-run idempotency:

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() { [ "$1" = "$2" ] || fail "$3: expected '$1', got '$2'"; }

# shellcheck source=bootstrap/common.sh
source "$REPO_ROOT/bootstrap/common.sh"
# shellcheck source=bootstrap/server/environment.sh
source "$REPO_ROOT/bootstrap/server/environment.sh"

tmp_root="$(mktemp -d)"
trap 'rm -rf "$tmp_root"' EXIT
export HOME="$tmp_root/home"
export XDG_CONFIG_HOME="$HOME/.config"
mkdir -p "$HOME/tools/clash-for-linux" "$XDG_CONFIG_HOME"

git_global_proxy() { printf '%s\n' "${TEST_GIT_PROXY:-}"; }

export http_proxy='http://alice:secret@10.0.0.8:8123'
assert_eq 'http://alice:secret@10.0.0.8:8123' "$(detect_proxy_candidate)" 'environment proxy precedence'
assert_eq $'10.0.0.8\t8123' "$(python3 "$REPO_ROOT/bootstrap/proxy_endpoint.py" "$(detect_proxy_candidate)")" 'credential-free endpoint'

unset http_proxy
TEST_GIT_PROXY='socks5://127.0.0.1:1080'
assert_eq "$TEST_GIT_PROXY" "$(detect_proxy_candidate)" 'Git proxy fallback'

TEST_GIT_PROXY=''
printf 'export MIXED_PORT="9090"\n' >"$HOME/tools/clash-for-linux/.env"
assert_eq 'http://127.0.0.1:9090' "$(detect_proxy_candidate)" 'Clash port fallback'

rm "$HOME/tools/clash-for-linux/.env"
assert_eq 'http://127.0.0.1:7890' "$(detect_proxy_candidate)" 'default proxy fallback'

write_server_shell_environment 'http://alice:secret@10.0.0.8:8123' false false
write_server_shell_environment 'http://alice:secret@10.0.0.8:8123' false false

proxy_file="$XDG_CONFIG_HOME/tabby-config/proxy-aliases.sh"
shell_file="$XDG_CONFIG_HOME/tabby-config/server-env.sh"
grep -F '10.0.0.8:8123' "$proxy_file" >/dev/null || fail 'detected endpoint missing'
! grep -F 'secret' "$proxy_file" >/dev/null || fail 'proxy credentials leaked'
assert_eq '1' "$(grep -c '^alias proxyon=' "$proxy_file")" 'proxyon count'
assert_eq '1' "$(grep -c '^# >>> tabby_config server environment >>>$' "$HOME/.bashrc")" 'bash managed source count'
grep -F 'proxy-aliases.sh' "$shell_file" >/dev/null || fail 'proxy file not sourced'

printf 'Server environment checks passed\n'
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test_server_environment.sh`

Expected: FAIL because `bootstrap/server/environment.sh` and `bootstrap/proxy_endpoint.py` do not exist.

- [ ] **Step 3: Implement proxy normalization**

Create `bootstrap/proxy_endpoint.py` as a dependency-free CLI. It must never echo user-info:

```python
#!/usr/bin/env python3
from __future__ import annotations

import sys
from urllib.parse import urlsplit

DEFAULT_PORTS = {"http": 80, "https": 443, "socks": 1080, "socks5": 1080, "socks5h": 1080}


def endpoint(raw: str) -> tuple[str, int]:
    candidate = raw.strip()
    if "://" not in candidate:
        candidate = f"http://{candidate}"
    parsed = urlsplit(candidate)
    if not parsed.hostname:
        raise ValueError("proxy URL has no host")
    port = parsed.port or DEFAULT_PORTS.get(parsed.scheme.lower())
    if port is None or not 1 <= port <= 65535:
        raise ValueError("proxy URL has no valid port")
    return parsed.hostname, port


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(f"usage: {argv[0]} PROXY_URL", file=sys.stderr)
        return 2
    try:
        host, port = endpoint(argv[1])
    except ValueError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    print(f"{host}\t{port}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
```

- [ ] **Step 4: Add an idempotent managed-block helper**

Add this interface to `bootstrap/common.sh`; it replaces the content between exact markers and leaves the rest of the file unchanged:

```bash
upsert_managed_block() {
  local target="$1" name="$2" content="$3"
  local begin="# >>> tabby_config ${name} >>>"
  local end="# <<< tabby_config ${name} <<<"
  local tmp

  mkdir -p "$(dirname "$target")"
  touch "$target"
  tmp="$(mktemp "${target}.tmp.XXXXXX")"
  awk -v begin="$begin" -v end="$end" '
    $0 == begin { skipping = 1; next }
    $0 == end { skipping = 0; next }
    !skipping { print }
  ' "$target" >"$tmp"
  {
    [ ! -s "$tmp" ] || printf '\n'
    printf '%s\n%s\n%s\n' "$begin" "$content" "$end"
  } >>"$tmp"
  mv "$tmp" "$target"
}
```

- [ ] **Step 5: Implement environment detection and rendering**

Create `bootstrap/server/environment.sh` with these public functions and no top-level mutation:

```bash
#!/usr/bin/env bash

SERVER_BOOTSTRAP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

sudo_available() {
  command -v sudo >/dev/null 2>&1 || return 1
  sudo -n true >/dev/null 2>&1 && return 0
  [ -t 0 ] && sudo -v
}

git_global_proxy() {
  git config --global --get http.proxy 2>/dev/null || true
}

detect_proxy_candidate() {
  local name value clash_env port
  for name in http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY; do
    value="${!name:-}"
    [ -z "$value" ] || { printf '%s\n' "$value"; return 0; }
  done
  value="$(git_global_proxy)"
  [ -z "$value" ] || { printf '%s\n' "$value"; return 0; }
  clash_env="$HOME/tools/clash-for-linux/.env"
  if [ -r "$clash_env" ]; then
    port="$(sed -n 's/^[[:space:]]*export[[:space:]]\+MIXED_PORT=["'"']\{0,1\}\([0-9]\+\).*/\1/p' "$clash_env" | sed -n '1p')"
    [ -z "$port" ] || { printf 'http://127.0.0.1:%s\n' "$port"; return 0; }
  fi
  printf '%s\n' 'http://127.0.0.1:7890'
}

write_server_shell_environment() {
  local proxy_url="$1" conda_enabled="$2" rootless_enabled="$3"
  local cfg endpoint host port proxy_file shell_file shell_body
  cfg="${XDG_CONFIG_HOME:-$HOME/.config}/tabby-config"
  endpoint="$(python3 "$SERVER_BOOTSTRAP_DIR/bootstrap/proxy_endpoint.py" "$proxy_url")"
  IFS=$'\t' read -r host port <<<"$endpoint"
  mkdir -p "$cfg"
  proxy_file="$cfg/proxy-aliases.sh"
  shell_file="$cfg/server-env.sh"
  render_proxy_aliases "$host" "$port" >"${proxy_file}.tmp"
  mv "${proxy_file}.tmp" "$proxy_file"
  shell_body='[ -r "${XDG_CONFIG_HOME:-$HOME/.config}/tabby-config/proxy-aliases.sh" ] && . "${XDG_CONFIG_HOME:-$HOME/.config}/tabby-config/proxy-aliases.sh"'
  if [ "$conda_enabled" = true ]; then
    shell_body="export PATH=\"\$HOME/miniforge3/condabin:\$PATH\"\n${shell_body}"
  fi
  if [ "$rootless_enabled" = true ]; then
    shell_body="export PATH=\"\$HOME/bin:\$PATH\"\nexport DOCKER_HOST=\"unix:///run/user/\$(id -u)/docker.sock\"\n${shell_body}"
  fi
  printf '%b\n' "$shell_body" >"${shell_file}.tmp"
  mv "${shell_file}.tmp" "$shell_file"
  upsert_managed_block "$HOME/.bashrc" 'server environment' \
    '[ -r "${XDG_CONFIG_HOME:-$HOME/.config}/tabby-config/server-env.sh" ] && . "${XDG_CONFIG_HOME:-$HOME/.config}/tabby-config/server-env.sh"'
}

render_proxy_aliases() {
  local host="$1" port="$2" url_host nc_host
  case "$host" in
    *:*) url_host="[$host]"; nc_host="[$host]" ;;
    *) url_host="$host"; nc_host="$host" ;;
  esac
  cat <<EOF
# Generated by tabby_config. Re-run install/ubuntu-user.sh to refresh.
_tabby_proxy_on() {
  export http_proxy="http://${url_host}:${port}"
  export https_proxy="http://${url_host}:${port}"
  export all_proxy="socks5://${url_host}:${port}"
  export HTTP_PROXY="\$http_proxy"
  export HTTPS_PROXY="\$https_proxy"
  export ALL_PROXY="\$all_proxy"
  export no_proxy="127.0.0.1,localhost,::1"
  export NO_PROXY="\$no_proxy"
  export GIT_SSH_COMMAND='ssh -o "ProxyCommand=nc -X 5 -x ${nc_host}:${port} %h %p"'
  printf 'proxy on: ${host}:${port}\n'
}
_tabby_proxy_off() {
  unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY
  unset no_proxy NO_PROXY GIT_SSH_COMMAND
  printf 'proxy off\n'
}
alias proxyon=_tabby_proxy_on
alias proxyoff=_tabby_proxy_off
EOF
}
```

Extend `proxy_endpoint.py` with `HOST_RE = re.compile(r"^[A-Za-z0-9._:-]+$")` and reject a hostname that does not match it before returning. This makes the heredoc safe without `eval`; only the normalized host and numeric port are persisted, and IPv6 hosts are bracketed in URLs.

- [ ] **Step 6: Remove the fixed proxy and source managed server state in Zsh**

Delete the hard-coded `10808` `proxyon`/`proxyoff` definitions from `config/zsh/.zshrc`. Add this after the XDG variables are initialized:

```zsh
_dotfiles_source_if_exists "${XDG_CONFIG_HOME:-$HOME/.config}/tabby-config/server-env.sh"
```

Place it after `_dotfiles_source_if_exists` is defined, not before.

- [ ] **Step 7: Run tests and commit**

Run: `bash tests/test_server_environment.sh && bash -n bootstrap/common.sh bootstrap/server/environment.sh && zsh -n config/zsh/.zshrc`

Expected: `Server environment checks passed`, then no syntax errors.

```bash
git add bootstrap/common.sh bootstrap/proxy_endpoint.py bootstrap/server/environment.sh config/zsh/.zshrc tests/test_server_environment.sh
git commit -m "feat: detect proxy and manage server shell environment"
```

### Task 2: Miniforge Installation

**Files:**
- Create: `bootstrap/server/miniforge.sh`
- Create: `tests/test_miniforge_install.sh`

- [ ] **Step 1: Write the failing Miniforge branch test**

Create `tests/test_miniforge_install.sh`. Override `fetch_url`, `sha256_file`, `linux_arch`, and the installer runner so the test verifies:

```bash
# Existing conda is reused without a download.
conda() { [ "$1" = --version ] && printf 'conda 26.1.0\n'; }
install_miniforge
[ "$FETCH_COUNT" -eq 0 ] || fail 'existing conda triggered a download'

# Missing conda maps x86_64 to Miniforge3-Linux-x86_64.sh,
# fetches both installer and .sha256, runs batch mode into ~/miniforge3,
# and sets auto_activate_base=false.
unset -f conda
linux_arch() { printf 'x86_64\n'; }
install_miniforge
assert_file_contains "$CALL_LOG" 'Miniforge3-Linux-x86_64.sh'
assert_file_contains "$CALL_LOG" '-b -p'
assert_file_contains "$CALL_LOG" 'config --set auto_activate_base false'

# A checksum mismatch fails before the installer runner is called.
```

Use a temporary HOME, fixture installer, and call log; do not access the network or real conda configuration.

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test_miniforge_install.sh`

Expected: FAIL because `bootstrap/server/miniforge.sh` does not exist.

- [ ] **Step 3: Implement Miniforge reuse, checksum verification, and installation**

Create `bootstrap/server/miniforge.sh` with this interface:

```bash
#!/usr/bin/env bash

conda_bin() {
  if command -v conda >/dev/null 2>&1; then command -v conda
  elif [ -x "$HOME/miniforge3/bin/conda" ]; then printf '%s\n' "$HOME/miniforge3/bin/conda"
  else return 1
  fi
}

run_miniforge_installer() { bash "$@"; }

install_miniforge() {
  local arch asset url tmp_dir expected actual conda
  if conda="$(conda_bin)" && "$conda" --version >/dev/null 2>&1; then
    log "Reusing conda: $($conda --version)"
    "$conda" config --set auto_activate_base false
    return 0
  fi
  case "$(linux_arch)" in
    x86_64) arch=x86_64 ;;
    arm64) arch=aarch64 ;;
  esac
  asset="Miniforge3-Linux-${arch}.sh"
  url="https://github.com/conda-forge/miniforge/releases/latest/download/${asset}"
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"; trap - RETURN' RETURN
  fetch_url "$url" "$tmp_dir/$asset"
  fetch_url "${url}.sha256" "$tmp_dir/${asset}.sha256"
  expected="$(awk 'NR == 1 {print $1}' "$tmp_dir/${asset}.sha256")"
  actual="$(sha256_file "$tmp_dir/$asset")"
  [ -n "$expected" ] && [ "$actual" = "$expected" ] || die "Miniforge SHA-256 mismatch"
  run_miniforge_installer "$tmp_dir/$asset" -b -p "$HOME/miniforge3"
  conda="$HOME/miniforge3/bin/conda"
  "$conda" config --set auto_activate_base false
  "$conda" --version >/dev/null
}
```

The module must not call `conda init`, because `~/.zshrc` is a repository symlink. Shell visibility is handled by Task 1's managed environment file.

- [ ] **Step 4: Run tests and commit**

Run: `bash tests/test_miniforge_install.sh && bash -n bootstrap/server/miniforge.sh`

Expected: `Miniforge installation checks passed` and no syntax errors.

```bash
git add bootstrap/server/miniforge.sh tests/test_miniforge_install.sh
git commit -m "feat: add idempotent Miniforge installation"
```

### Task 3: Monitoring Tools

**Files:**
- Create: `bootstrap/server/monitoring.sh`
- Create: `tests/test_monitoring_install.sh`

- [ ] **Step 1: Write failing apt and conda branch tests**

Create `tests/test_monitoring_install.sh` with mocked `command -v`, `sudo_available`, `run_server_sudo`, and conda functions. Assert these exact behaviors:

```text
existing nvitop/btop/htop -> no apt or conda mutation
sudo available -> apt-get update; apt-get install -y btop htop; conda prefix contains only missing nvitop
sudo unavailable -> dedicated conda prefix contains missing nvitop btop htop
successful conda install -> ~/.local/bin symlinks point into ~/.local/share/tabby-config/monitoring/bin
failed version probe -> module returns nonzero
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test_monitoring_install.sh`

Expected: FAIL because `bootstrap/server/monitoring.sh` does not exist.

- [ ] **Step 3: Implement isolated monitoring-tool installation**

Create `bootstrap/server/monitoring.sh` around these functions:

```bash
run_server_sudo() { sudo "$@"; }

tool_usable() {
  command -v "$1" >/dev/null 2>&1 && "$1" --version >/dev/null 2>&1
}

install_conda_monitoring_tools() {
  local conda="$1" env_prefix="$2"; shift 2
  [ "$#" -gt 0 ] || return 0
  if [ -x "$env_prefix/bin/python" ]; then
    "$conda" install --yes --prefix "$env_prefix" "$@"
  else
    "$conda" create --yes --prefix "$env_prefix" "$@"
  fi
  mkdir -p "$HOME/.local/bin"
  local tool
  for tool in "$@"; do
    [ -x "$env_prefix/bin/$tool" ] && ln -sfn "$env_prefix/bin/$tool" "$HOME/.local/bin/$tool"
  done
}

install_monitoring_tools() {
  local conda env_prefix="$HOME/.local/share/tabby-config/monitoring"
  local -a conda_packages=() apt_packages=()
  conda="$(conda_bin)" || die 'conda is required before monitoring-tool installation'
  tool_usable nvitop || conda_packages+=(nvitop)
  if server_has_sudo; then
    tool_usable btop || apt_packages+=(btop)
    tool_usable htop || apt_packages+=(htop)
    if [ "${#apt_packages[@]}" -gt 0 ]; then
      run_server_sudo apt-get update
      run_server_sudo apt-get install -y "${apt_packages[@]}"
    fi
  else
    tool_usable btop || conda_packages+=(btop)
    tool_usable htop || conda_packages+=(htop)
  fi
  install_conda_monitoring_tools "$conda" "$env_prefix" "${conda_packages[@]}"
  tool_usable nvitop && tool_usable btop && tool_usable htop || die 'monitoring-tool verification failed'
}
```

Define the shared cached decision in `environment.sh` and use `server_has_sudo`, rather than calling `sudo_available` directly, in both monitoring and Docker modules:

```bash
server_has_sudo() {
  if [ -n "${SERVER_HAS_SUDO+x}" ]; then
    [ "$SERVER_HAS_SUDO" = true ]
  else
    sudo_available
  fi
}
```

When creating symlinks, only link known executable names, not every conda environment binary.

- [ ] **Step 4: Run tests and commit**

Run: `bash tests/test_monitoring_install.sh && bash -n bootstrap/server/monitoring.sh`

Expected: `Monitoring installation checks passed` and no syntax errors.

```bash
git add bootstrap/server/monitoring.sh tests/test_monitoring_install.sh
git commit -m "feat: install server monitoring tools"
```

### Task 4: Docker Selection and Installation

**Files:**
- Create: `bootstrap/server/docker.sh`
- Create: `tests/test_docker_install.sh`

- [ ] **Step 1: Write failing tests for all three Docker branches**

Create `tests/test_docker_install.sh` with command wrappers and a call log. Test independently:

```text
docker already exists -> no sudo, curl, apt, or rootless installer call
docker absent + sudo -> official Ubuntu source installed and exactly five requested packages passed to apt
docker absent + no sudo -> newuidmap/newgidmap and subuid/subgid checked before rootless installer
rootless success -> docker-buildx and docker-compose user plugins installed
missing rootless prerequisite -> nonzero result names uidmap and the missing subordinate-ID file
every successful branch probes docker version and docker compose version
```

Do not run Docker, sudo, systemctl, apt, or the network in the test.

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test_docker_install.sh`

Expected: FAIL because `bootstrap/server/docker.sh` does not exist.

- [ ] **Step 3: Implement existing-Docker reuse**

Start `bootstrap/server/docker.sh` with overrideable wrappers and a strict early return:

```bash
run_docker_sudo() { sudo "$@"; }
run_docker_systemctl() { systemctl "$@"; }

docker_cli_usable() { command -v docker >/dev/null 2>&1 && docker --version >/dev/null 2>&1; }

report_existing_docker() {
  SERVER_DOCKER_REUSED_WITH_WARNINGS=false
  docker --version
  if ! docker compose version; then
    SERVER_DOCKER_REUSED_WITH_WARNINGS=true
    warn 'Docker Compose plugin is not available; existing Docker is preserved as requested'
  fi
  docker info >/dev/null 2>&1 || warn 'Docker daemon is unavailable or current user lacks permission'
}
```

`install_docker` must call this branch before checking sudo and must not reinstall an existing CLI.

- [ ] **Step 4: Implement system Docker CE installation**

Use Docker's official Ubuntu source without a `curl | sh` pipeline. Generate the deb822 source file in a temporary directory, then install it with sudo:

```bash
install_system_docker() {
  local tmp_dir codename arch
  . /etc/os-release
  [ "${ID:-}" = ubuntu ] || die 'system Docker CE installation currently supports Ubuntu only'
  codename="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
  [ -n "$codename" ] || die 'cannot determine Ubuntu codename'
  arch="$(dpkg --print-architecture)"
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"; trap - RETURN' RETURN
  fetch_url 'https://download.docker.com/linux/ubuntu/gpg' "$tmp_dir/docker.asc"
  printf '%s\n' \
    'Types: deb' \
    'URIs: https://download.docker.com/linux/ubuntu' \
    "Suites: $codename" \
    'Components: stable' \
    "Architectures: $arch" \
    'Signed-By: /etc/apt/keyrings/docker.asc' >"$tmp_dir/docker.sources"
  run_docker_sudo install -m 0755 -d /etc/apt/keyrings
  run_docker_sudo install -m 0644 "$tmp_dir/docker.asc" /etc/apt/keyrings/docker.asc
  run_docker_sudo install -m 0644 "$tmp_dir/docker.sources" /etc/apt/sources.list.d/docker.sources
  run_docker_sudo apt-get update
  run_docker_sudo apt-get install -y \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  run_docker_sudo systemctl enable --now docker
  run_docker_sudo usermod -aG docker "$(id -un)"
}
```

Before apt installation, detect `docker.io`, `docker-compose`, `docker-compose-v2`, `docker-doc`, `podman-docker`, `containerd`, and `runc`. If any are installed while no `docker` CLI is usable, stop and print Docker's documented removal command; do not silently remove packages or data.

- [ ] **Step 5: Implement Rootless Docker and user plugins**

Validate `newuidmap`, `newgidmap`, `/etc/subuid`, `/etc/subgid`, and `systemctl --user` first. Download `https://get.docker.com/rootless` to a temporary file, inspect that it is nonempty, and execute it as `sh rootless-install.sh`; never pipe network content into a shell.

Install official user-level plugin binaries using the existing GitHub release resolver:

```bash
install_rootless_cli_plugin() {
  local repo="$1" pattern="$2" target_name="$3"
  local url tmp_dir
  url="$(github_latest_asset_url "$repo" "$pattern")"
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"; trap - RETURN' RETURN
  fetch_url "$url" "$tmp_dir/$target_name"
  mkdir -p "$HOME/.docker/cli-plugins"
  install -m 0755 "$tmp_dir/$target_name" "$HOME/.docker/cli-plugins/$target_name"
}
```

Map repository patterns by architecture:

```text
x86_64: docker/compose -> docker-compose-linux-x86_64; docker/buildx -> buildx-*.linux-amd64
arm64:  docker/compose -> docker-compose-linux-aarch64; docker/buildx -> buildx-*.linux-arm64
```

Install them as `docker-compose` and `docker-buildx`, set a module variable `SERVER_ROOTLESS_DOCKER=true`, start `docker.service` with user systemd, and verify `docker info`, `docker buildx version`, and `docker compose version` with `DOCKER_HOST=unix:///run/user/$(id -u)/docker.sock`.

- [ ] **Step 6: Run tests and commit**

Run: `bash tests/test_docker_install.sh && bash -n bootstrap/server/docker.sh`

Expected: `Docker installation checks passed` and no syntax errors.

```bash
git add bootstrap/server/docker.sh tests/test_docker_install.sh
git commit -m "feat: install system or rootless Docker"
```

### Task 5: General Codex TOML Merge

**Files:**
- Create: `bootstrap/merge_codex_config.py`
- Create: `config/codex/server.toml`
- Modify: `bootstrap/common.sh`
- Modify: `tests/test_codex_notifications.sh`
- Create: `tests/test_codex_server_config.sh`

- [ ] **Step 1: Write the canonical managed fragment**

Create `config/codex/server.toml` exactly as approved:

```toml
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
```

- [ ] **Step 2: Write failing generic-merger tests**

Create `tests/test_codex_server_config.sh` with fixtures proving that the merger:

- reproduces the fragment when no existing file is supplied;
- replaces owned top-level and table keys;
- inserts missing owned tables before or after unrelated tables without duplication;
- preserves `[projects."/srv/app"]`, `[mcp_servers.local]`, an unrelated plugin, comments, and unknown top-level keys;
- produces byte-identical output on a second merge;
- rejects duplicate managed tables, duplicate managed keys, inline managed tables, and multiline managed values.

Update `tests/test_codex_notifications.sh` to invoke `bootstrap/merge_codex_config.py`; keep every existing notification assertion.

- [ ] **Step 3: Run tests to verify they fail**

Run: `bash tests/test_codex_notifications.sh && bash tests/test_codex_server_config.sh`

Expected: FAIL because the generic merger does not exist.

- [ ] **Step 4: Implement the generic section-aware merger**

Create `bootstrap/merge_codex_config.py` by extracting the safe line-based behavior from `merge_codex_tui_config.py`. Use this complete structure; quoted keys are required for `"gpt-5.6-sol"`:

```python
#!/usr/bin/env python3
from __future__ import annotations

import re
import sys
from pathlib import Path

TableName = str | None
Managed = dict[TableName, dict[str, str]]
TABLE_RE = re.compile(r"^\s*\[([^\[\]]+)\]\s*(?:#.*)?(?:\r?\n)?$")
ASSIGNMENT_RE = re.compile(
    r'^\s*((?:[A-Za-z0-9_-]+)|(?:"(?:[^"\\]|\\.)+"))\s*=.*$'
)


class MergeError(ValueError):
    pass


def read_text(path: Path) -> str:
    with path.open("r", encoding="utf-8", newline="") as handle:
        return handle.read()


def table_name(line: str) -> str | None:
    match = TABLE_RE.match(line)
    return match.group(1).strip() if match else None


def value_spans_multiple_lines(line: str) -> bool:
    value = line.split("=", 1)[1].split("#", 1)[0].strip()
    if value.startswith("[") and not value.endswith("]"):
        return True
    if value.startswith("{") and not value.endswith("}"):
        return True
    return any(value.startswith(d) and value.count(d) < 2 for d in ('"""', "'''"))


def parse_fragment(fragment: str) -> tuple[str, list[TableName], Managed]:
    canonical = fragment if fragment.endswith(("\n", "\r")) else f"{fragment}\n"
    order: list[TableName] = [None]
    managed: Managed = {None: {}}
    current: TableName = None
    for line in canonical.splitlines(keepends=True):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        name = table_name(line)
        if name is not None:
            if name in managed:
                raise MergeError(f"duplicate fragment table: {name}")
            current = name
            order.append(name)
            managed[name] = {}
            continue
        match = ASSIGNMENT_RE.match(line)
        if not match or value_spans_multiple_lines(line):
            raise MergeError(f"unsupported fragment line: {line.rstrip()}")
        key = match.group(1)
        if key in managed[current]:
            raise MergeError(f"duplicate fragment key in {current or 'top level'}: {key}")
        managed[current][key] = line if line.endswith(("\n", "\r")) else f"{line}\n"
    return canonical, order, managed


def sections(lines: list[str]) -> dict[TableName, list[tuple[int, int]]]:
    found: dict[TableName, list[tuple[int, int]]] = {None: []}
    first_header = next((i for i, line in enumerate(lines) if table_name(line) is not None), len(lines))
    found[None].append((0, first_header))
    index = first_header
    while index < len(lines):
        name = table_name(lines[index])
        if name is None:
            index += 1
            continue
        end = index + 1
        while end < len(lines) and table_name(lines[end]) is None:
            end += 1
        found.setdefault(name, []).append((index, end))
        index = end
    return found


def reject_inline_conflicts(lines: list[str], order: list[TableName]) -> None:
    current: TableName = None
    managed_tables = {name for name in order if name is not None}
    for line in lines:
        name = table_name(line)
        if name is not None:
            current = name
            continue
        for target in managed_tables:
            if current is None:
                relative = target
            elif target.startswith(f"{current}."):
                relative = target[len(current) + 1 :]
            else:
                continue
            root = relative.split(".", 1)[0]
            if re.match(rf"^\s*{re.escape(root)}\s*(?:=|\.)", line):
                raise MergeError(f"inline or dotted table conflicts with [{target}]")


def merge_section(lines: list[str], name: TableName, desired: dict[str, str]) -> list[str]:
    current_sections = sections(lines)
    spans = current_sections.get(name, [])
    if len(spans) > 1:
        raise MergeError(f"duplicate managed table: {name or 'top level'}")
    if not spans:
        if lines and lines[-1].strip():
            lines.append("\n")
        lines.append(f"[{name}]\n")
        lines.extend(desired.values())
        return lines

    start, end = spans[0]
    body_start = start if name is None else start + 1
    seen: set[str] = set()
    for index in range(body_start, end):
        match = ASSIGNMENT_RE.match(lines[index])
        if not match:
            continue
        key = match.group(1)
        if key not in desired:
            continue
        if key in seen:
            raise MergeError(f"duplicate managed key in {name or 'top level'}: {key}")
        if value_spans_multiple_lines(lines[index]):
            raise MergeError(f"multiline managed key is unsafe: {key}")
        lines[index] = desired[key]
        seen.add(key)

    missing = [key for key in desired if key not in seen]
    insert_at = end
    while insert_at > body_start and not lines[insert_at - 1].strip():
        insert_at -= 1
    lines[insert_at:insert_at] = [desired[key] for key in missing]
    return lines


def merge_config(fragment: str, existing: str) -> str:
    canonical, order, managed = parse_fragment(fragment)
    if not existing:
        return canonical
    lines = existing.splitlines(keepends=True)
    reject_inline_conflicts(lines, order)
    for name in order:
        lines = merge_section(lines, name, managed[name])
    result = "".join(lines)
    return result if result.endswith(("\n", "\r")) else f"{result}\n"


def main(argv: list[str]) -> int:
    if len(argv) not in (2, 3):
        print(f"usage: {argv[0]} FRAGMENT [EXISTING_CONFIG]", file=sys.stderr)
        return 2
    try:
        fragment = read_text(Path(argv[1]))
        existing = read_text(Path(argv[2])) if len(argv) == 3 and Path(argv[2]).exists() else ""
        sys.stdout.write(merge_config(fragment, existing))
    except (OSError, UnicodeError, MergeError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
```

Treat content before the first table as `None`. Recompute table spans after every insertion so line indexes remain valid. Reject any managed table or managed assignment that appears more than once. When a managed table is absent, append its canonical header and keys in fragment order. Preserve a final newline.

Do not parse and rewrite the entire TOML document with `tomllib`; that would discard comments and formatting.

- [ ] **Step 5: Switch the existing notification installer to the generic merger**

In `bootstrap/common.sh`, change only the merger path used by `install_codex_notifications`:

```bash
local merger="$REPO_ROOT/bootstrap/merge_codex_config.py"
```

Remove `bootstrap/merge_codex_tui_config.py` in this task after `rg 'merge_codex_tui_config'` confirms that no production or test path still references it.

- [ ] **Step 6: Run tests and commit**

Run:

```bash
bash tests/test_codex_notifications.sh
bash tests/test_codex_server_config.sh
python3 -m py_compile bootstrap/merge_codex_config.py
rg 'merge_codex_tui_config' . --glob '!docs/superpowers/**'
```

Expected: both tests pass, compilation succeeds, and the final `rg` has no output if the old file was removed.

```bash
git add bootstrap/common.sh bootstrap/merge_codex_config.py config/codex/server.toml tests/test_codex_notifications.sh tests/test_codex_server_config.sh
git add -u bootstrap/merge_codex_tui_config.py
git commit -m "feat: merge complete Codex server configuration"
```

### Task 6: Codex Plugins and Pinned Skill

**Files:**
- Create: `bootstrap/server/codex.sh`
- Create: `tests/test_codex_bootstrap.sh`
- Modify: `bootstrap/plugins.lock.sh`

- [ ] **Step 1: Pin Pretty Mermaid**

Add this immutable source to `bootstrap/plugins.lock.sh`:

```bash
PRETTY_MERMAID_REPO="https://github.com/imxv/pretty-mermaid-skills.git"
PRETTY_MERMAID_REF="e33f086d3b5bcec9f28632e4bd9c348b02bb2278"
```

- [ ] **Step 2: Write failing Codex bootstrap tests**

Create `tests/test_codex_bootstrap.sh` with a temporary `CODEX_HOME` and mocked `codex`, `clone_repo_at_ref`, `npm`, and merge runner. Verify:

```text
missing codex -> clear nonzero error
installed/enabled figma and superpowers -> no plugin add calls
missing plugin -> exactly one `codex plugin add selector` call
valid pretty-mermaid SKILL.md -> no clone
missing skill -> pinned repository and commit cloned to $CODEX_HOME/skills/pretty-mermaid
existing unrelated skill/plugin -> untouched
changed config -> timestamped backup plus atomic replacement
unchanged config -> no backup
merge failure -> original file remains byte-identical
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `bash tests/test_codex_bootstrap.sh`

Expected: FAIL because `bootstrap/server/codex.sh` does not exist.

- [ ] **Step 4: Implement plugin and skill installation**

Create `bootstrap/server/codex.sh` with these public behaviors:

```bash
codex_plugin_installed() {
  local selector="$1"
  codex plugin list 2>/dev/null | awk -v selector="$selector" '$1 == selector && $2 ~ /^installed/ { found=1 } END { exit !found }'
}

ensure_codex_plugin() {
  local selector="$1"
  codex_plugin_installed "$selector" || codex plugin add "$selector"
}

pretty_mermaid_valid() {
  local target="${CODEX_HOME:-$HOME/.codex}/skills/pretty-mermaid"
  [ -f "$target/SKILL.md" ] && grep -F 'name: pretty-mermaid' "$target/SKILL.md" >/dev/null
}

install_pretty_mermaid() {
  local target="${CODEX_HOME:-$HOME/.codex}/skills/pretty-mermaid"
  pretty_mermaid_valid && { log 'Reusing pretty-mermaid skill'; return 0; }
  if [ -e "$target" ] || [ -L "$target" ]; then backup_existing "$target"; fi
  clone_repo_at_ref "$PRETTY_MERMAID_REPO" "$PRETTY_MERMAID_REF" "$target"
  if command -v npm >/dev/null 2>&1; then
    npm --prefix "$target" install --omit=dev --ignore-scripts
  else
    warn 'pretty-mermaid installed; Node.js/npm is required before rendering diagrams'
  fi
  pretty_mermaid_valid || die 'pretty-mermaid skill verification failed'
}
```

The top-level function is:

```bash
install_codex_server() {
  command -v codex >/dev/null 2>&1 && codex --version >/dev/null 2>&1 ||
    die 'Codex CLI must be installed before running the server bootstrap'
  ensure_codex_plugin 'figma@openai-curated'
  ensure_codex_plugin 'superpowers@openai-curated'
  install_pretty_mermaid
  install_codex_server_config
}
```

- [ ] **Step 5: Implement atomic full-config installation**

Use `config/codex/server.toml` and `bootstrap/merge_codex_config.py` with this atomic implementation:

```bash
install_codex_server_config() {
  local source_file="$REPO_ROOT/config/codex/server.toml"
  local merger="$REPO_ROOT/bootstrap/merge_codex_config.py"
  local codex_home="${CODEX_HOME:-$HOME/.codex}" target temp_file
  target="$codex_home/config.toml"
  mkdir -p "$codex_home"
  temp_file="$(mktemp "${target}.tmp.XXXXXX")"
  if [ -e "$target" ] || [ -L "$target" ]; then
    if ! python3 "$merger" "$source_file" "$target" >"$temp_file"; then
      rm -f "$temp_file"
      die "failed to merge Codex server config into $target"
    fi
    if cmp -s "$temp_file" "$target"; then
      rm -f "$temp_file"
      return 0
    fi
    backup_existing "$target"
  elif ! python3 "$merger" "$source_file" >"$temp_file"; then
    rm -f "$temp_file"
    die 'failed to create Codex server config'
  fi
  mv "$temp_file" "$target"
}
```

- [ ] **Step 6: Run tests and commit**

Run: `bash tests/test_codex_bootstrap.sh && bash -n bootstrap/server/codex.sh`

Expected: `Codex bootstrap checks passed` and no syntax errors.

```bash
git add bootstrap/plugins.lock.sh bootstrap/server/codex.sh tests/test_codex_bootstrap.sh
git commit -m "feat: install Codex plugins and skills"
```

### Task 7: Integrate the Complete Ubuntu User Bootstrap

**Files:**
- Modify: `install/ubuntu-user.sh`
- Create: `tests/test_server_bootstrap_flow.sh`

- [ ] **Step 1: Write a failing orchestration-order test**

Create `tests/test_server_bootstrap_flow.sh` that copies `install/ubuntu-user.sh` into a fixture, replaces sourced module functions with log-only doubles, and asserts this order after the existing CLI stack:

```text
detect environment
install_miniforge
install_monitoring_tools
install_docker
git config --global user.name Bill-xing
git config --global user.email bill.xjm@gmail.com
write_server_shell_environment
install_codex_server
verify_server_bootstrap
```

Also assert `DOTFILES_SKIP_TABBY=1` is exported before `install_config_payload`, and no function whose name contains `tabby` is called except the existing payload dispatcher operating in skip mode.

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test_server_bootstrap_flow.sh`

Expected: FAIL because the new modules are not sourced or called.

- [ ] **Step 3: Source modules and add final verification**

Near the existing `common.sh` source in `install/ubuntu-user.sh`, source modules in dependency order:

```bash
# shellcheck source=bootstrap/server/environment.sh
source "$SCRIPT_DIR/../bootstrap/server/environment.sh"
# shellcheck source=bootstrap/server/miniforge.sh
source "$SCRIPT_DIR/../bootstrap/server/miniforge.sh"
# shellcheck source=bootstrap/server/monitoring.sh
source "$SCRIPT_DIR/../bootstrap/server/monitoring.sh"
# shellcheck source=bootstrap/server/docker.sh
source "$SCRIPT_DIR/../bootstrap/server/docker.sh"
# shellcheck source=bootstrap/server/codex.sh
source "$SCRIPT_DIR/../bootstrap/server/codex.sh"
```

Add a verifier that checks the requested identity and commands without pulling a test container image:

```bash
verify_server_bootstrap() {
  [ "$(git config --global --get user.name)" = 'Bill-xing' ] || die 'global Git user.name verification failed'
  [ "$(git config --global --get user.email)" = 'bill.xjm@gmail.com' ] || die 'global Git user.email verification failed'
  conda_bin >/dev/null || die 'conda verification failed'
  nvitop --version >/dev/null || die 'nvitop verification failed'
  btop --version >/dev/null || die 'btop verification failed'
  htop --version >/dev/null || die 'htop verification failed'
  docker --version >/dev/null || die 'Docker CLI verification failed'
  if [ "${SERVER_DOCKER_REUSED_WITH_WARNINGS:-false}" = true ]; then
    warn 'Docker Compose verification skipped because an existing Docker installation was reused'
  else
    docker compose version >/dev/null || die 'Docker Compose verification failed'
  fi
  pretty_mermaid_valid || die 'pretty-mermaid verification failed'
}
```

An existing Docker CLI with missing Compose remains a warning and sets `SERVER_DOCKER_REUSED_WITH_WARNINGS=true`; it never triggers reinstallation.

- [ ] **Step 4: Wire the complete execution flow**

After the existing repository CLI and config payload succeeds, add:

```bash
proxy_candidate="$(detect_proxy_candidate)"
SERVER_HAS_SUDO=false
sudo_available && SERVER_HAS_SUDO=true

install_miniforge
install_monitoring_tools
install_docker
git config --global user.name 'Bill-xing'
git config --global user.email 'bill.xjm@gmail.com'
write_server_shell_environment \
  "$proxy_candidate" \
  true \
  "${SERVER_ROOTLESS_DOCKER:-false}"
install_codex_server
verify_server_bootstrap
```

Cache the sudo result so monitoring and Docker do not prompt separately. Both modules call the `server_has_sudo` function defined in Task 3.

- [ ] **Step 5: Run integration tests and commit**

Run:

```bash
bash tests/test_server_bootstrap_flow.sh
bash -n bootstrap/*.sh bootstrap/server/*.sh install/*.sh
zsh -n config/zsh/.zshrc
```

Expected: flow test passes and every shell file parses.

```bash
git add install/ubuntu-user.sh bootstrap/server tests/test_server_bootstrap_flow.sh
git commit -m "feat: integrate complete server bootstrap"
```

### Task 8: Documentation and Full Regression

**Files:**
- Modify: `README.md`
- Modify: `docs/server-quickstart.md`

- [ ] **Step 1: Update the public installation summary**

In `README.md`, update the Ubuntu SSH/no-sudo section to say that `install/ubuntu-user.sh` now:

- always skips Tabby;
- reuses Docker, otherwise installs system Docker CE with sudo or Rootless Docker without sudo;
- installs Miniforge only when conda is missing;
- installs `nvitop`, `btop`, and `htop`;
- sets the requested global Git identity;
- detects the current proxy and generates `proxyon`/`proxyoff`;
- installs Figma, Superpowers, and Pretty Mermaid for Codex;
- safely merges the full Codex server configuration.

Do not copy the private subscription URL, proxy credentials, tokens, or secrets from `服务器开荒快速指南.md`.

- [ ] **Step 2: Expand the server quick-start with branch and verification details**

In `docs/server-quickstart.md`, add exact commands:

```bash
git config --global --get user.name
git config --global --get user.email
conda --version
nvitop --version
btop --version
htop --version
docker --version
docker buildx version
docker compose version
codex plugin list | grep -E '^(figma|superpowers)@openai-curated'
test -f "${CODEX_HOME:-$HOME/.codex}/skills/pretty-mermaid/SKILL.md"
```

Document that Docker group membership may require a new login and is root-equivalent; Rootless Docker may require an administrator to install `uidmap` and configure `/etc/subuid` and `/etc/subgid`; `proxyon` defaults to `127.0.0.1:7890` only when no current proxy can be discovered; and Codex must already be installed.

- [ ] **Step 3: Run the complete regression suite**

Run:

```bash
for test_file in tests/test_*.sh; do
  bash "$test_file"
done
python3 -m py_compile bootstrap/*.py
git diff --check
```

Expected: every test prints its success message, Python compilation succeeds, and `git diff --check` is silent.

- [ ] **Step 4: Perform a fixture-home idempotency run**

Run the orchestration fixture twice with network/system mutations mocked:

```bash
bash tests/test_server_bootstrap_flow.sh --twice
```

Expected: the second run reports reuse for Docker, conda, monitoring tools, plugins, and skill; managed-block counts remain one; Codex config is unchanged; no Tabby path is created.

- [ ] **Step 5: Review tracked content for secrets and commit**

Run:

```bash
git diff --cached --name-only
git diff -- README.md docs/server-quickstart.md
rg -n 'CLASH_SUBSCRIPTION_URL|SECRET=|token[=:]|alice:secret' README.md docs bootstrap config tests install
```

Expected: only public documentation/config/test fixtures are present; the final `rg` either has no output or only the intentionally fake `alice:secret` test input, which is never written to generated output.

```bash
git add README.md docs/server-quickstart.md
git commit -m "docs: document expanded server provisioning"
```

## Final Execution Verification

After all tasks are implemented, run the installer on the target server only after reviewing every sudo command it will issue:

```bash
time ./install/ubuntu-user.sh
```

Then start a fresh login shell and verify:

```bash
exec zsh -l
git config --global --get-regexp '^user\.(name|email)$'
conda --version
nvitop --version
btop --version
htop --version
docker --version
docker buildx version
docker compose version
codex plugin list | grep -E '^(figma|superpowers)@openai-curated'
test -f "${CODEX_HOME:-$HOME/.codex}/skills/pretty-mermaid/SKILL.md"
```

Expected Git output:

```text
user.name Bill-xing
user.email bill.xjm@gmail.com
```

Finally, run `proxyon`, inspect only the host/port portion of the exported variables, run `proxyoff`, and confirm the proxy variables and `GIT_SSH_COMMAND` are unset. Do not print credentials to the terminal or logs.
