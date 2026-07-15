# Cross-platform terminal dotfiles

这一套仓库把当前使用的 `tmux`、`zsh`、`oh-my-zsh`、`powerlevel10k`、`LazyVim`、`lazygit`、`yazi`、`WezTerm` 配置整理成可迁移的 dotfiles，并提供三套安装入口。

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
- `config/wezterm/wezterm.lua`: WezTerm 跨平台配置
- `bootstrap/plugins.lock.sh`: 第三方主题 / 插件固定版本
- `bootstrap/common.sh`: 公共安装函数
- `bootstrap/github_release_asset.py`: GitHub Release 资产解析工具

## 设计约定

- 仓库只跟踪你自己的配置，不直接 vendoring 整个 `oh-my-zsh`、`powerlevel10k`、tmux TPM 插件目录。
- 第三方依赖在安装阶段按 `bootstrap/plugins.lock.sh` 里的固定 commit 拉取。
- `lazygit` 只迁移用户配置 `config.yml`，不迁移运行态 `state.yml`。
- Windows 方案以 MSYS2 为 Unix 工具栈，WezTerm 和 Lazygit 通过 `winget` 安装。
- 安装默认在 Unix 上使用软链接，在 Windows / MSYS2 上默认复制文件；可通过 `DOTFILES_LINK_MODE=symlink|copy` 覆盖。

## 快速开始

### 1. macOS

```bash
cd /path/to/this/repo
./install/macos.sh
```

安装内容：

- Homebrew: `tmux` `neovim` `lazygit` `yazi` `wezterm` `direnv` `eza` `bat` `fzf` `ripgrep` `fd`
- 可选 Nerd Font: `font-jetbrains-mono-nerd-font`
- 固定版本的 `oh-my-zsh` / `powerlevel10k` / zsh 插件 / tmux 插件
- 当前 dotfiles 到 `~/.zshrc` `~/.p10k.zsh` `~/.tmux.conf` `~/.wezterm.lua` `~/.config/*`

### 2. Ubuntu

```bash
cd /path/to/this/repo
./install/ubuntu.sh
```

安装内容：

- `apt`: 基础构建工具、`git`、`curl`、`zsh`、`tmux`、`fzf`、`fd-find`、`ripgrep`、`jq`、`unzip` 等
- Neovim: 官方最新 release 预编译包，安装到 `~/.local/opt/nvim`
- Lazygit / Yazi: GitHub Release 最新官方二进制
- WezTerm: 通过官方 apt 仓库安装
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
- `winget`: `WezTerm`、`Lazygit`
- 配置镜像：
  - `~/.zshrc` `~/.p10k.zsh` `~/.tmux.conf` `~/.wezterm.lua`
  - `~/.config/nvim` / `~/.config/yazi` / `~/.config/lazygit`
  - 同时同步到 Windows 原生程序常用位置：`%LOCALAPPDATA%\nvim`、`%APPDATA%\yazi\config`、`%APPDATA%\lazygit`

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

### WezTerm

`config/wezterm/wezterm.lua` 做了这些处理：

- 根据 `wezterm.target_triple` 自动判断 macOS / Windows / Linux
- 保留当前 tab 标题、Catppuccin 配色、透明度、鼠标行为
- macOS 专属项仅在 macOS 启用：`CMD` 快捷键风格、背景模糊、原生全屏
- Windows 下优先把默认 shell 指向 `C:/msys64/usr/bin/zsh.exe`
- Linux / Windows 把主要快捷键切到 `CTRL+SHIFT`

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

如果后续你在本机更新了这些插件，想把新版本固定进仓库，只需要更新对应 commit。

## 建议验证

安装完成后，可以逐项检查：

```bash
zsh -i -c exit
tmux source-file ~/.tmux.conf
nvim --version
yazi --version
lazygit --version
wezterm -V
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
