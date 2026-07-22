# Server Provisioning Expansion Design

## Goal

Expand the repository's Ubuntu user installer into an idempotent server bootstrap that configures every item requested by the server quick-start guide except Tabby. The bootstrap installs or configures Docker, Miniforge, `nvitop`, `btop`, `htop`, Codex plugins and skills, Codex `config.toml`, shared shell aliases, and the global Git identity.

The installer remains safe to rerun and preserves unrelated user configuration.

## Scope

The implementation will:

- keep `install/ubuntu-user.sh` as the single entry point;
- leave Tabby software, configuration, and plugins untouched;
- configure global Git identity as `Bill-xing <bill.xjm@gmail.com>`;
- install Miniforge only when no usable `conda` command exists;
- install the requested monitoring tools;
- reuse an existing Docker installation or select system Docker versus Rootless Docker based on sudo availability;
- install or enable the selected Codex plugins and skill;
- incrementally merge the guide's managed Codex settings;
- generate shared proxy aliases from the active proxy address;
- document installation behavior and verification commands.

The implementation will not install Gmail or Notion plugins, duplicate Codex system skills, install Clash, or copy secrets from the local quick-start guide into tracked files.

## Architecture

`install/ubuntu-user.sh` remains the public entry point and invokes focused modules for environment detection, Miniforge, monitoring tools, Docker, shell aliases, Git, and Codex. The default execution path runs every module; there are no opt-in flags for required components.

Each module follows the same contract:

1. detect whether its desired state is already satisfied;
2. install or update only repository-owned state;
3. verify its result;
4. return a nonzero status with an actionable message if a required result cannot be achieved.

Common download, temporary-directory, backup, logging, and managed-block helpers remain centralized in `bootstrap/common.sh` or small purpose-specific helpers. This keeps the entry-point script readable and makes detection and merge behavior independently testable.

## Environment Detection

The installer determines these facts once and passes them to the relevant modules:

- operating-system family and release;
- CPU architecture;
- whether `sudo` exists and the current user can successfully authenticate with it;
- existing commands and their versions;
- active proxy URL;
- availability of user-level systemd for Rootless Docker.

Proxy discovery uses the first valid value in this order:

1. `http_proxy`, `https_proxy`, `all_proxy`, then their uppercase variants;
2. global Git `http.proxy`;
3. `MIXED_PORT` from `~/tools/clash-for-linux/.env`;
4. `http://127.0.0.1:7890` as the fallback.

When a full proxy URL is detected, its host and port are retained. A Clash `MIXED_PORT` or fallback value uses `127.0.0.1` as the host. Credentials embedded in a proxy URL are never printed in logs.

## Docker

Docker handling has three mutually exclusive paths:

1. If `docker` already exists, the installer does not reinstall it. It reports the client version, daemon reachability, Compose availability, and whether the current user can access the daemon.
2. If Docker is absent and sudo is available, the installer configures Docker's official package repository for the detected Ubuntu release and architecture, then installs exactly:
   - `docker-ce`
   - `docker-ce-cli`
   - `containerd.io`
   - `docker-buildx-plugin`
   - `docker-compose-plugin`
3. If Docker is absent and sudo is unavailable, the installer uses Docker's official Rootless installation flow in the current user's home directory.

The system path enables the Docker service and adds the current user to the `docker` group so Docker can be used without prefixing every command with sudo. The summary warns that group membership requires a new login and grants root-equivalent access to the Docker daemon.

The Rootless path configures the user's PATH, `DOCKER_HOST`, and user-level systemd service. It validates Rootless prerequisites before installation. If a missing prerequisite requires an administrator, the module stops with the exact missing package names and suggested administrator command instead of falling back to an incomplete installation.

Requested Docker CE package names apply to the sudo/system path. They cannot be installed through the system package manager without administrative privileges; the no-sudo path therefore installs the official Rootless distribution instead.

## Miniforge and Monitoring Tools

If `conda` is already usable, the installer preserves and reuses it. Otherwise it downloads the current Miniforge installer for the detected architecture, verifies the published checksum, and installs it under the current user's home directory. Bash and Zsh integration is added idempotently, and `auto_activate_base` is set to `false`.

`nvitop` is installed into an isolated user-level Python tool environment so it does not modify the system Python environment.

When sudo is available, `btop` and `htop` are installed with the operating system package manager. Without sudo, they are installed into a dedicated Miniforge tools environment and exposed through stable commands under `~/.local/bin`. This environment is separate from Miniforge's `base` environment.

Every tool module skips an already usable command and verifies the final executable with its version command.

## Git and Shell Aliases

The installer sets only these global Git keys:

```text
user.name=Bill-xing
user.email=bill.xjm@gmail.com
```

Repository-level Git configuration and all unrelated global keys are preserved.

Ordinary aliases already supplied by the repository remain unchanged. Proxy behavior is moved into a generated, repository-managed file at `~/.config/tabby-config/proxy-aliases.sh`, which is sourced once from both Bash and Zsh startup configuration. The managed file defines:

- `proxyon`, exporting lowercase and uppercase HTTP, HTTPS, and SOCKS proxy variables;
- `proxyon`'s matching `GIT_SSH_COMMAND`, using the detected proxy host and port;
- `proxyoff`, removing every variable set by `proxyon`.

Rerunning the installer regenerates the proxy file from the environment detected during that run. Managed source blocks are replaced rather than appended, so shell startup files cannot accumulate duplicate lines.

## Codex Configuration, Plugins, and Skills

The installer first verifies that Codex CLI is available. It then ensures these selected additions are installed and enabled:

- `figma@openai-curated` plugin;
- `superpowers@openai-curated` plugin;
- `pretty-mermaid` skill.

Codex-bundled system skills are detected but not downloaded again. Gmail and Notion are outside the selected scope. Existing plugins and skills are preserved.

Before changing `~/.codex/config.toml`, the installer creates a timestamped backup. A deterministic TOML section merger manages the guide's requested values:

- top-level model, reasoning, service tier, approval, Web search, and sandbox settings;
- TUI status line, color, notification, and availability settings;
- `features.remote_plugin`;
- enabled state for the selected Figma and Superpowers plugins;
- workspace-write network access.

The merger replaces the owned keys, inserts missing owned tables, and retains all unrelated content, including project trust entries, MCP configuration, other plugins, comments where safely possible, and unknown future fields. It rejects duplicate or structurally ambiguous managed tables rather than overwriting a file it cannot merge safely.

## Execution Flow

The entry point performs work in this order:

1. validate platform, architecture, paths, network helpers, sudo, and proxy state;
2. perform the repository's existing user-local shell and CLI installation;
3. install or reuse Miniforge;
4. install `nvitop`, `btop`, and `htop`;
5. install or reuse Docker;
6. set the global Git identity and generate shared aliases;
7. install or enable Codex plugins and `pretty-mermaid`, then merge `config.toml`;
8. run final verification and print a concise summary, including login or administrator actions still required.

Tabby is explicitly excluded from every stage.

## Failure Handling and Security

All downloads use HTTPS. Where the upstream publishes a checksum, it is verified before execution or extraction. Temporary directories are removed through exit traps.

The installer does not log or commit proxy credentials, subscription URLs, access tokens, Codex credentials, or values copied from the untracked `服务器开荒快速指南.md`. Generated configuration containing environment-specific proxy values stays in the user's home directory rather than the repository.

Existing user files are backed up before a replacement or structural merge. If a managed merge cannot be performed safely, the original remains unchanged and the installer exits with a precise diagnostic. Optional status probes may warn, but failure to establish a required installation or configuration causes a nonzero exit.

## Testing and Acceptance

Automated tests will cover:

- shell syntax for every changed script;
- proxy discovery precedence, URL parsing, credential-safe logging, and the port `7890` fallback;
- idempotent managed blocks for Bash and Zsh;
- Codex TOML creation, incremental updates, preservation of unrelated tables, and rejection of ambiguous input;
- Docker's existing, sudo/system, and no-sudo/Rootless branches through command fixtures or mocks;
- Miniforge and monitoring-tool installed-versus-missing branches;
- a second installer run producing no duplicate configuration.

Final acceptance checks confirm:

- global Git name and email match the requested values;
- `docker version` and `docker compose version` work, or a Rootless prerequisite diagnostic identifies the exact external administrator action;
- `conda`, `nvitop`, `btop`, and `htop` report versions;
- `proxyon` uses the detected address and `proxyoff` cleans up all managed variables;
- Codex retains pre-existing unrelated configuration while exposing the requested settings, plugins, and `pretty-mermaid` skill;
- no Tabby path or configuration was installed or modified by the expanded bootstrap.

README and quick-start documentation will describe the automatic behavior, branch decisions, security notes, and manual verification commands without including private values.
