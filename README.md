# Cross-platform terminal dotfiles

这一套仓库把当前使用的 `tmux`、`zsh`、`oh-my-zsh`、`powerlevel10k`、`LazyVim`、`lazygit`、`yazi`、`Tabby` 配置整理成可迁移的 dotfiles，并提供三套安装入口。

当前这版额外统一了一套面向终端工作流的方向键习惯：

- `i / k / j / l = 上 / 下 / 左 / 右`
- `tmux` 采用这套方向逻辑管理 `pane`
- `yazi` 采用同样的方向逻辑管理文件浏览
- `tmux` 还借鉴了 theniceboy 风格的 `session / window / pane` 常用操作，但保留 `Ctrl-b` 作为前缀键

安装入口：

- macOS: `./install/macos.sh`
- Ubuntu: `./install/ubuntu.sh`
- Windows 原生 + MSYS2: `./install/windows-msys2.sh`
- Windows PowerShell 引导: `./install/windows.ps1`

## 目录结构

- `config/zsh/.zshrc` + `config/zsh/.p10k.zsh`: zsh / oh-my-zsh / powerlevel10k
- `config/tmux/.tmux.conf`: tmux 主配置，包含 `ikjl` pane 导航、session/window 快捷键、增强状态栏
- `config/nvim/`: LazyVim 配置目录，保留 `lazy-lock.json`
- `config/lazygit/config.yml`: lazygit 用户配置，当前迁移 `delta` pager
- `config/yazi/yazi.toml`: yazi 功能配置
- `config/yazi/keymap.toml`: yazi 自定义键位，采用 `ikjl` 导航
- `config/tabby/config.yaml`: 经过隐私清理的 Tabby 配置快照
- `bootstrap/plugins.lock.sh`: 第三方主题 / 插件固定版本
- `bootstrap/common.sh`: 公共安装函数
- `bootstrap/github_release_asset.py`: GitHub Release 资产解析工具

## 设计约定

- 仓库只跟踪你自己的配置，不直接 vendoring 整个 `oh-my-zsh`、`powerlevel10k`、tmux TPM 插件目录。
- 第三方依赖在安装阶段按 `bootstrap/plugins.lock.sh` 里的固定 commit，或固定版本和校验和安装。
- `lazygit` 只迁移用户配置 `config.yml`，不迁移运行态 `state.yml`。
- Windows 方案以 MSYS2 为 Unix 工具栈，Tabby 和 Lazygit 通过 `winget` 安装。
- 普通 dotfiles 默认在 Unix 上使用软链接，在 Windows / MSYS2 上默认复制文件；可通过 `DOTFILES_LINK_MODE=symlink|copy` 覆盖。
- Tabby 是特例：无论 `DOTFILES_LINK_MODE` 如何设置，都强制复制为普通文件，绝不创建符号链接。如果目标已存在，安装器会先在同目录备份为 `config.yaml.bak.YYYYMMDDHHMMSS`；同一秒内发生命名冲突时依次追加 `.1`、`.2` 等后缀。

## 快速开始

### 1. macOS

```bash
cd /path/to/this/repo
./install/macos.sh
```

安装内容：

- Homebrew: `tmux` `neovim` `lazygit` `yazi` `direnv` `eza` `bat` `fzf` `ripgrep` `fd`
- Tabby cask: `brew install --cask tabby`；标准桌面安装脚本会自动安装 `tabby-osc-notify@1.0.0`
- 可选 Nerd Font: `font-jetbrains-mono-nerd-font`
- 固定版本的 `oh-my-zsh` / `powerlevel10k` / zsh 插件 / tmux 插件
- 当前 dotfiles 到 `~/.zshrc` `~/.p10k.zsh` `~/.tmux.conf` `~/.config/*`；Tabby 配置复制到 `$HOME/Library/Application Support/tabby/config.yaml`

### 2. Ubuntu

```bash
cd /path/to/this/repo
./install/ubuntu.sh
```

安装内容：

- `apt`: 基础构建工具、`git`、`curl`、`zsh`、`tmux`、`fzf`、`fd-find`、`ripgrep`、`jq`、`unzip` 等
- Neovim: 官方最新 release 预编译包，安装到 `~/.local/opt/nvim`
- Lazygit / Yazi: GitHub Release 最新官方二进制
- Tabby: 从 `Eugeny/tabby` 最新 GitHub Release 中按 `x86_64` / `arm64` 架构选择 `.deb` 安装包；标准桌面安装脚本会自动安装 `tabby-osc-notify@1.0.0`
- Tabby 配置复制到 `${XDG_CONFIG_HOME:-$HOME/.config}/tabby/config.yaml`
- Ubuntu 兼容补丁：如果系统只提供 `batcat` / `fdfind`，会自动补 `~/.local/bin/bat` 和 `~/.local/bin/fd`

执行完成后建议：

```bash
chsh -s "$(command -v zsh)"
exec zsh
```

### 3. Windows + MSYS2

先确保仓库位于 Windows 可访问路径，例如：

```powershell
cd C:\path\to\repo
powershell -ExecutionPolicy Bypass -File .\install\windows.ps1
```

或者已经在 MSYS2 中时：

```bash
cd /c/path/to/repo
./install/windows-msys2.sh
```

安装内容：

- MSYS2 包：`zsh` `tmux` `git` `curl` `file` `neovim` `ripgrep` `fd` `fzf` `yazi`
- 可选包（若仓库中存在）：`bat` `eza` `direnv` `jq` `python`
- `winget`: `Eugeny.Tabby`、`JesseDuffield.lazygit`；标准桌面安装脚本会自动安装 `tabby-osc-notify@1.0.0`
- 配置镜像：
  - `~/.zshrc` `~/.p10k.zsh` `~/.tmux.conf`
  - `~/.config/nvim` / `~/.config/yazi` / `~/.config/lazygit`
  - 同时同步到 Windows 原生程序常用位置：`%LOCALAPPDATA%\nvim`、`%APPDATA%\yazi\config`、`%APPDATA%\lazygit`
  - Tabby 配置复制到 `%APPDATA%\Tabby\config.yaml`

## 平台兼容处理

### zsh

`config/zsh/.zshrc` 已做这些跨平台处理：

- 自动识别 `macOS` / `Linux` / `Windows(MSYS2)`
- 按平台追加 PATH：Homebrew、`~/.local/bin`、Cargo、Go、pnpm、MSYS2 路径
- 保留原有 alias、history、`direnv`、`nvm`、`pyenv`、`nodenv`、`conda`、`fzf`、`eza`、`bat`
- 在 Windows/MSYS2 下为 `yazi` 设置 `YAZI_FILE_ONE`（如果检测到 `file.exe`）

### tmux

- 保留 `Ctrl-b` 作为前缀键，避免 `Ctrl-s` 流控冲突
- pane 导航改为 `prefix + i/k/j/l = 上/下/左/右`
- pane 调整大小改为 `prefix + I/K/J/L = 上/下/左/右`
- 复制模式同样采用 `i/k/j/l` 方向
- 借鉴 theniceboy 风格加入了高频 `session / window / pane` 快捷键：
  - `prefix + C-c`: 新建或切换 session
  - `Ctrl-1..0`: 直接切到编号 session，不存在时自动创建
  - `prefix + 1..0`: 把当前 window 移到目标 session 并切过去
  - `Alt-o`: 新建 window
  - `Alt-1..0`: 直接切到编号 window
  - `Alt-f`: 当前 pane 最大化 / 还原
- 状态栏增强为：
  - 左侧显示 session 名和 window 数
  - 中间显示 window 列表
  - 右侧显示 `PREFIX` / `COPY` / `ZOOM` 状态、主机名和时间
- pane 顶部边框显示 pane 编号、当前命令和当前目录名
- 插件统一由 `bootstrap/plugins.lock.sh` 固定版本安装

### yazi

- `config/yazi/yazi.toml` 不再只保留预览参数，补充了：
  - 文件管理布局、排序、标题格式
  - opener / open rules
  - 任务并发参数
  - 代码、图片、视频、PDF、压缩包等预览器
- `config/yazi/keymap.toml` 采用与 tmux 一致的方向逻辑：
  - `i / k / j / l = 上 / 下 / 左 / 右`
  - `I / K = 快速上下移动`
  - `J / L = 后退 / 前进目录历史`
- 同时加入 theniceboy 风格的高频文件管理能力：
  - `Ctrl-p`: fzf 跳文件或目录
  - `F`: ripgrep 内容搜索
  - `f`: 过滤文件
  - `z h`: 切换隐藏文件
  - `yy / dd / pp`: 复制 / 剪切 / 粘贴
  - `g` 系列：快速跳常用目录
  - `w`: 任务面板

### lazygit

- `config/lazygit/config.yml` 来自当前机器配置。
- 当前配置把 git pager 设为 `delta --dark --paging=never`，优先使用 side-by-side + line numbers，兼容项保留普通 line numbers。
- 安装脚本会部署到 `~/.config/lazygit`；Windows / MSYS2 下也会同步到 `%APPDATA%\lazygit`。

### Tabby

`config/tabby/config.yaml` 来源于当前 Tabby `1.0.234` 配置，但仓库 YAML 是按字段白名单重建的公开快照，不是将完整本机文件复制后再依赖黑名单清理。

快照保留了深色 AdventureTime、浅色 Tabby Default Light、20px 字体、0.84 透明度和 `vibrancy`，并保持欢迎页关闭、SSH profile 默认关闭动态标题以及当前快捷键。

白名单明确排除设备和账户数据、根级 `ssh`、SSH known-host、连接 `profile`、同步信息 `configSync`、`vault`、令牌、密码、密钥路径以及 Electron 运行态数据。因此，这个文件不是本机 Tabby 全部数据的原样备份。

macOS、Ubuntu 和 Windows/MSYS2 的标准桌面安装脚本会从锁定的 tarball URL 下载 `tabby-osc-notify@1.0.0`，按固定 SHA-256 校验和验证后直接解包到 Tabby 的运行态 `plugins/` 目录；这个流程不要求系统预装 Node.js 或 npm。

安装期间必须保持 Tabby 完全关闭；安装完成后重启 Tabby，插件才会被加载。操作系统的通知权限必须允许 Tabby 发送通知；安装器不会申请或修改通知权限。

> **安全警告：** 本机完整的 Tabby `config.yaml` 和运行态 `plugins/` 目录都不提交到仓库。不要把本机完整的 Tabby `config.yaml` 直接复制回仓库；更新快照时，必须重新执行字段白名单筛选，只写入允许公开的字段。

由于 Tabby 退出时可能重写配置，部署前请关闭 Tabby。部署始终是“备份旧文件、再复制公开快照”，不会把应用正在写入的配置直接链接回 Git 工作树。

## 固定版本依赖

当前锁定的关键三方版本都在 `bootstrap/plugins.lock.sh`：

- `oh-my-zsh`
- `powerlevel10k`
- `zsh-autosuggestions`
- `zsh-syntax-highlighting`
- `tmux-plugins/tpm`
- `tmux-sensible`
- `tmux-yank`
- `tmux-resurrect`
- `tmux-continuum`
- `erikw/tmux-powerline`
- `tabby-osc-notify@1.0.0`

如果后续你在本机更新了这些插件，想把新版本固定进仓库，需要更新对应 commit；对于 Tabby 插件，还要同步更新版本、tarball URL 和 SHA-256 校验和。

## 建议验证

安装完成后，可以逐项检查：

```bash
zsh -i -c exit
tmux source-file ~/.tmux.conf
nvim --version
yazi --version
lazygit --version
tabby --version
```

如果你已经在当前机器上更新过仓库配置，也可以重点检查这两项：

```bash
tmux source-file ~/.tmux.conf
python3 - <<'PY'
import tomllib
for path in ['config/yazi/yazi.toml', 'config/yazi/keymap.toml']:
    with open(path, 'rb') as f:
        tomllib.load(f)
print('yazi config ok')
PY
```

## 已知说明

- `LazyVim` 首次启动会自动拉取 `lazy.nvim` 和插件，需要联网。
- Ubuntu / Windows 上字体不会强制自动安装；如果希望图标完整，建议安装 `JetBrainsMono Nerd Font`。
- `lazygit` 的 `state.yml` 是本机运行态数据，仓库只迁移 `config.yml`。
- Tabby 配置只会复制；每次目标已存在时都会先在同目录生成带时间戳的备份。运行任何安装入口前，请先关闭 Tabby。
