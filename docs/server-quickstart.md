# SSH 服务器快速环境配置指南

本文面向通过 SSH 使用的 Ubuntu 服务器，目标是在不安装 Tabby、不依赖 `sudo`、不修改系统默认 shell 的前提下，快速部署本仓库的 Zsh、tmux、Neovim、Lazygit、Yazi 和常用 CLI 工具。

对应分支为 `server`，推荐入口为：

```bash
./install/ubuntu-user.sh
```

## 快速结论

已经克隆本仓库时，只需要执行：

```bash
cd /path/to/tabby_config
git switch server
time ./install/ubuntu-user.sh
exit
```

然后重新连接 SSH。交互终端会自动进入用户目录中的 Zsh；`scp`、`rsync` 和 `ssh host command` 等非交互连接仍使用 Bash。

在当前服务器上，完整环境已经存在时，安装器重复执行的实测耗时为 `0.11` 秒。全新服务器的耗时主要取决于 GitHub 下载速度和 Rust 首次安装速度，通常是数分钟而不是现场排查所需的几十分钟。

## 为什么现在不需要再排查 40 分钟

之前耗时的部分已经固化到安装器中：

- 不再反复尝试 `sudo`；无管理员权限时直接使用纯用户目录安装。
- 固定跳过 Tabby 软件和 Tabby 配置。
- Linux CLI 优先选择 `musl` 构建，避免 Ubuntu 22.04 上的新版 GLIBC 依赖错误。
- Tree-sitter CLI 直接在服务器本机编译，并关闭不需要的 QuickJS 默认特性，因此不需要额外安装 `libclang`。
- Yazi 配置已经升级到当前配置格式，不需要安装后逐项修复旧字段。
- 第三方 Zsh/tmux 插件按锁定 commit 做浅拉取，不下载无关历史。
- 已安装且能正常输出版本的工具会直接复用。
- 已经位于锁定 commit 的插件仓库不会再次访问网络。
- SSH 的 Bash → 用户级 Zsh 切换由安装器自动写入 `~/.bashrc`，并带 TTY 与 SSH 检查。
- 下载带连接超时和三次重试；GitHub API 支持 `GITHUB_TOKEN` 或 `GH_TOKEN`。

## 适用范围

推荐环境：

- Ubuntu 22.04 或更新版本。
- `x86_64` 或 `aarch64/arm64`。
- 通过 SSH 登录，服务器不需要 GUI 终端。
- 账号没有 `sudo` 权限，或者不希望修改系统软件包。
- 系统已经提供基础编译和下载命令。

安装器开始前会检查以下命令：

```text
apt-get  cc  curl  dpkg-deb  file  git
python3  tar  tmux  unzip
```

可以一次完成预检：

```bash
(
  missing=0
  for cmd in apt-get cc curl dpkg-deb file git python3 tar tmux unzip; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      echo "missing: $cmd"
      missing=1
    fi
  done
  exit "$missing"
)
```

如果缺少 `cc` 或 `tmux`，纯用户脚本无法可靠补齐它们，应请管理员先安装 `build-essential` 和 `tmux`。不要反复尝试一个不在 sudoers 中的账号密码。

## 全新服务器：推荐流程

### 1. 获取 `server` 分支

已经有仓库：

```bash
cd /path/to/tabby_config
git fetch origin
git switch server
```

全新克隆，已经配置 GitHub SSH key：

```bash
git clone --branch server --single-branch \
  git@github.com:Bill-xing/tabby_config.git
cd tabby_config
```

没有配置 GitHub SSH key：

```bash
git clone --branch server --single-branch \
  https://github.com/Bill-xing/tabby_config.git
cd tabby_config
```

### 2. 用十秒钟检查网络

```bash
curl -fsS --connect-timeout 5 https://api.github.com/rate_limit >/dev/null
git ls-remote https://github.com/ohmyzsh/ohmyzsh.git HEAD >/dev/null
echo "network ok"
```

如果服务器只能通过代理访问 GitHub，先在当前 shell 中设置代理，再执行安装器：

```bash
export http_proxy=http://127.0.0.1:PORT
export https_proxy="$http_proxy"
export all_proxy="$http_proxy"
```

不要把带用户名、密码或 token 的代理地址写入仓库。机器专属设置应放在 `~/.zshrc.local`。

GitHub 匿名 API 达到限额时，可以临时提供 token：

```bash
export GITHUB_TOKEN='your-temporary-token'
```

安装完成后可执行 `unset GITHUB_TOKEN`。安装器不会把 token 写入配置文件。

### 3. 执行一次安装

```bash
time ./install/ubuntu-user.sh 2>&1 | tee /tmp/server-bootstrap.log
```

安装过程会自动完成：

| 内容 | 安装位置 | 快速重跑行为 |
|---|---|---|
| Zsh | `~/.local/opt/zsh` | 本地二进制可运行时复用 |
| fzf、fd、rg、bat、delta、eza、zoxide、direnv、jq | `~/.local/bin` | `--version` 成功时复用 |
| Tree-sitter CLI | `~/.local/opt/tree-sitter-cli` | 版本不低于 0.26.1 时复用 |
| Neovim | `~/.local/opt/nvim` | 本地 `nvim` 可运行时复用 |
| Lazygit、Yazi | `~/.local/bin` | 本地二进制可运行时复用 |
| Oh My Zsh 与 Zsh 插件 | `~/.oh-my-zsh` | HEAD 等于锁定 commit 时复用 |
| tmux 插件 | `~/.tmux/plugins` | HEAD 等于锁定 commit 时复用 |
| dotfiles | `~/.zshrc`、`~/.tmux.conf`、`~/.config/*` | 正确软链接直接保留 |
| SSH Zsh 入口 | `~/.bashrc` 管理块 | 已存在时不重复追加 |

原有普通文件不会被静默覆盖。公共配置部署前会生成 `.bak.YYYYMMDDHHMMSS` 备份；原有机器专属 `.zshrc` 还会保留为 `~/.zshrc.local`。

### 4. 重新连接 SSH

```bash
exit
ssh your-server
```

登录后检查：

```zsh
echo "$ZSH_VERSION"
echo "$SHELL"
```

预期 `$SHELL` 为 `~/.local/bin/zsh`。由于账号没有权限把用户级 Zsh 写进 `/etc/shells`，系统账户的登录 shell 仍可能显示为 `/bin/bash`；这是设计行为。

### 5. 可选：提前初始化 Neovim

如果希望第一次交互启动 Neovim 时无需等待插件下载，可以提前执行：

```bash
nvim --headless "+Lazy! restore" +qa
```

这里应使用 `restore`，它会遵循仓库的 `config/nvim/lazy-lock.json`。不要为了初始化改用 `Lazy! sync`，后者可能更新锁文件和插件提交。

首次安装 parser 后，可以检查 Tree-sitter：

```bash
nvim --headless \
  "+lua require('lazy').load({plugins={'nvim-treesitter'}})" \
  "+checkhealth nvim-treesitter" \
  "+%print" +qa
```

只需要 shell、tmux、Lazygit 或 Yazi 时，可以跳过本步骤；Neovim 会在第一次使用时自行初始化。

## 已配置服务器：最快修复或同步

拉取分支后直接重跑即可：

```bash
git switch server
git pull --ff-only
time ./install/ubuntu-user.sh
```

安装器默认是幂等的：只检查版本、commit 和软链接，不重复下载正常组件。当前服务器实测完整重跑为 `0.11` 秒。

以下情况才需要强制重装：

- 希望升级 GitHub Release 工具到最新版本。
- 用户目录中的二进制被手工替换。
- 第三方插件目录需要恢复到仓库锁定 commit。
- 普通重跑后仍有可复现故障。

强制重装命令：

```bash
DOTFILES_FORCE_INSTALL=1 ./install/ubuntu-user.sh
```

注意：强制模式会把第三方插件目录 checkout 到锁定 commit。不要在 `~/.oh-my-zsh` 或 `~/.tmux/plugins` 中保存未提交的个人修改。

如果不希望安装器向 `~/.bashrc` 添加 SSH Zsh 切换块：

```bash
DOTFILES_SKIP_SSH_ZSH_HANDOFF=1 ./install/ubuntu-user.sh
```

## 安装后的完整验证

### 工具版本

```bash
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"

zsh --version
tmux -V
nvim --version | sed -n '1p'
lazygit --version
yazi --version
tree-sitter --version
fzf --version
fd --version
rg --version | sed -n '1p'
bat --version
delta --version
eza --version | sed -n '1p'
zoxide --version
direnv version
jq --version
```

### 配置链接

```bash
for path in \
  "$HOME/.zshrc" \
  "$HOME/.p10k.zsh" \
  "$HOME/.tmux.conf" \
  "$HOME/.config/tmux-powerline" \
  "$HOME/.config/nvim" \
  "$HOME/.config/yazi" \
  "$HOME/.config/lazygit"; do
  printf '%s -> %s\n' "$path" "$(readlink "$path")"
done
```

### Yazi 与 tmux

```bash
YAZI_CONFIG_HOME="$PWD/config/yazi" yazi --debug >/dev/null

tmux -L dotfiles-check -f "$HOME/.tmux.conf" new-session -d -s verify
tmux -L dotfiles-check display-message -p 'session=#{session_name}'
tmux -L dotfiles-check kill-server

~/.tmux/plugins/tmux-powerline/powerline.sh left
~/.tmux/plugins/tmux-powerline/powerline.sh right
```

第一条 powerline 命令应显示 session/window/pane 格式及主题颜色；第二条应不输出内容。

### 确认 Tabby 未部署

```bash
if command -v tabby >/dev/null 2>&1 || [ -e "$HOME/.config/tabby" ]; then
  echo "unexpected Tabby installation or config" >&2
  exit 1
fi
echo "Tabby skipped"
```

### 确认非交互 SSH 未被 Zsh 接管

从本机执行：

```bash
ssh your-server 'printf "non-interactive shell: %s\n" "$BASH_VERSION"'
```

它应输出 Bash 版本。交互式 `ssh your-server` 则应进入 Zsh，因此不会破坏自动化任务、SCP 或 rsync。

## 常见问题

### `user is not in the sudoers file`

不要继续尝试密码，直接使用：

```bash
./install/ubuntu-user.sh
```

该入口只写入用户目录，不执行 `sudo`，也不修改 `/etc/shells`。

### GitHub API 返回 403 或 rate limit

先确认是不是反复强制重装。正常重跑不会请求已安装工具的 Release API。

需要全新安装时，可设置临时 `GITHUB_TOKEN` 或等待匿名额度恢复：

```bash
export GITHUB_TOKEN='your-temporary-token'
./install/ubuntu-user.sh
unset GITHUB_TOKEN
```

### 出现 `GLIBC_2.39 not found`

重新执行普通安装器。损坏的本地二进制无法通过 `--version` 检查时会被自动替换：

```bash
./install/ubuntu-user.sh
```

Yazi 与常用 Rust CLI 使用 `musl` Release；Tree-sitter CLI 在本机编译，因此不应依赖高于服务器版本的 GLIBC。

### Tree-sitter 提示缺少 `libclang`

确认使用的是本分支脚本，而不是手工执行默认特性的 `cargo install`：

```bash
git branch --show-current
rg -- '--no-default-features' install/ubuntu-user.sh
```

本脚本的 Tree-sitter 构建不启用 QuickJS 特性，不需要 `libclang`。当前服务器实测该精简构建约 24 秒。

### Yazi 能启动但配置报错

确认链接指向当前分支，并运行调试检查：

```bash
readlink "$HOME/.config/yazi"
YAZI_CONFIG_HOME="$PWD/config/yazi" yazi --debug
```

不要把旧版 `yazi.toml` 或 `keymap.toml` 从其他服务器覆盖回来。

### SSH 登录后仍是 Bash

检查管理块和用户级 Zsh：

```bash
test -x "$HOME/.local/bin/zsh" && echo "zsh wrapper ok"
rg -n 'tabby_config user-local zsh' "$HOME/.bashrc"
```

管理块只在同时满足“SSH 环境、输入输出为 TTY、用户级 Zsh 可执行”时切换。修改后应退出并重新连接，不要只运行 `source ~/.bashrc` 判断。

### 插件目录存在但不是 Git 仓库

安装器会停止，以免覆盖未知内容。先把冲突目录改名保存，再重跑。例如：

```bash
mv "$HOME/.oh-my-zsh" "$HOME/.oh-my-zsh.before-server-setup"
./install/ubuntu-user.sh
```

确认新环境正常后，再手工比较旧目录中的个人内容。

## 回滚

此方案不修改系统包和 `/etc/shells`。需要回滚时：

1. 从 `~/.bashrc` 删除 `tabby_config user-local zsh` 起止标记之间的管理块。
2. 将需要的 `.bak.YYYYMMDDHHMMSS` 文件恢复为原文件名。
3. 配置中的机器专属 alias、代理和环境变量仍可从 `~/.zshrc.local` 找回。
4. `~/.local/bin`、`~/.local/opt`、`~/.oh-my-zsh` 和 `~/.tmux/plugins` 都是用户目录内容，可在确认无用后自行归档或清理。

## 维护建议

- 日常同步只运行普通安装，不使用 `DOTFILES_FORCE_INSTALL=1`。
- 插件版本只在 `bootstrap/plugins.lock.sh` 中升级并提交。
- Neovim 初始化使用 `Lazy! restore`，保持 `lazy-lock.json` 不变。
- 机器专属配置只写入 `~/.zshrc.local`。
- 不要提交 token、密码、代理凭据、SSH host 或私钥路径。
- 修改安装器后至少执行：

```bash
bash -n bootstrap/*.sh bootstrap/user-local-zsh install/*.sh
git diff --check
./install/ubuntu-user.sh
```
