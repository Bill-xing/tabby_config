# Tabby Config 独立仓库设计

## 状态

- 设计日期：2026-07-15
- 设计状态：已由用户批准
- 源仓库：`${HOME}/code/wezterm_config`
- 目标仓库：`${HOME}/code/tabby_config`
- 目标分支：`main`
- 远程仓库：本次不创建、不配置、不推送

## 背景

源仓库是一套跨平台终端 dotfiles，除 WezTerm 外还包含 Zsh、tmux、LazyVim、Yazi、Lazygit、第三方插件版本锁定和 macOS、Ubuntu、Windows/MSYS2 安装入口。

目标是创建一个具有全新 Git 历史的同级仓库，保留通用 dotfiles，只把 WezTerm 配置、安装和文档集成替换为 Tabby。Tabby 配置以当前机器安装的 Tabby 1.0.234 配置为来源，但只保存明确允许公开和迁移的字段。

## 目标

1. 在 `${HOME}/code/tabby_config` 创建独立 Git 仓库，默认分支为 `main`。
2. 保留源仓库中的 Zsh、tmux、LazyVim、Yazi、Lazygit 和插件锁定配置。
3. 删除 WezTerm 生产配置和生产文档引用，增加 Tabby 配置与安装支持。
4. 在 macOS、Ubuntu 和 Windows/MSYS2 上安装 Tabby，并把公开配置部署到各平台官方位置。
5. 防止 SSH known-host、连接档案、同步配置、vault、缓存和其他机器运行态数据进入仓库。
6. 通过自动化测试证明 Tabby 配置采用复制部署、已有配置会先备份、目标路径计算正确。
7. 保证源仓库的工作区和提交指针不发生变化。

## 非目标

- 不继承源仓库的 Git 提交历史或远程仓库配置。
- 不创建 GitHub 仓库，也不推送任何提交。
- 不把旧 WezTerm 的 Catppuccin、JetBrains Mono、快捷键或自动进入 tmux 行为映射到 Tabby。
- 不迁移 SSH、Telnet、串口或其他连接档案。
- 不迁移 Tabby 插件运行目录、日志、缓存、Cookies 或窗口状态。
- 不增加自动从本机完整 Tabby 配置回写仓库的工具。
- 不删除用户机器上已有的 `~/.wezterm.lua` 或 WezTerm 应用。
- 不重构与终端替换无关的 dotfiles 或安装逻辑。

## 仓库边界与结构

目标仓库只复制源仓库当前 `HEAD` 中受 Git 跟踪的有效内容，不复制源仓库 `.git` 目录或任何运行态文件。预期结构为：

```text
tabby_config/
├── .gitignore
├── README.md
├── bootstrap/
│   ├── common.sh
│   ├── github_release_asset.py
│   └── plugins.lock.sh
├── config/
│   ├── tabby/
│   │   └── config.yaml
│   ├── lazygit/
│   ├── nvim/
│   ├── tmux/
│   ├── yazi/
│   └── zsh/
├── docs/
│   └── superpowers/
│       ├── plans/
│       └── specs/
├── install/
│   ├── macos.sh
│   ├── ubuntu.sh
│   ├── windows-msys2.sh
│   └── windows.ps1
├── tests/
│   └── test_tabby_config_install.sh
├── lazygit操作指南.md
└── 当前环境常用快捷键速查.md
```

迁移时删除 `config/wezterm/wezterm.lua`，新增 `config/tabby/config.yaml`。其他配置以源仓库当前版本为基线，仅在与 Tabby 集成直接相关时修改。

## Tabby 配置设计

### 来源

配置来源是当前机器的 `~/.config/tabby/config.yaml`。实现不能复制整个文件再依赖黑名单删除，而必须按本设计列出的白名单构造仓库快照。

### 允许入库的根字段

- `version: 8`
- `profiles: []`
- `groups: []`
- `hotkeys`
- `terminal`
- `clickableLinks`
- `accessibility`
- `appearance`
- `hacks`
- `providerBlacklist`
- `commandBlacklist`
- `profileBlacklist`
- `enableWelcomeTab`
- `pluginBlacklist`
- `profileDefaults`

### 必须保留的当前设置

- 当前完整快捷键映射，而不是只保留与默认值不同的快捷键。
- AdventureTime 深色配色及完整 16 色调色板。
- Tabby Default Light 浅色配色。
- 空的自定义配色列表和当前搜索选项。
- `terminal.fontSize: 20`。
- `appearance.opacity: 0.84`。
- `appearance.vibrancy: true`。
- `enableWelcomeTab: false`。
- `profileDefaults.ssh.disableDynamicTitle: true`。
- 当前为空的 accessibility、clickableLinks、hacks 和 blacklist 值。

### 禁止入库的内容

- 根级 `ssh` 配置，包括 known-host 地址、端口、算法和指纹。
- 根级 `configSync` 配置。
- `vault`、令牌、密码、私钥路径和插件凭据。
- 非空的 SSH、Telnet、串口或其他连接 profile。
- `config.yaml.backup`。
- `ssh-profiles-cache.json`。
- `window.json` 和 `log.txt`。
- Cookies、Local Storage、Session Storage、GPU Cache 和其他 Electron 数据。
- Tabby 的 `plugins/` 运行目录。

### 配置生命周期与隐私边界

Tabby 把普通界面设置和 SSH known-host 等运行态数据保存在同一个 `config.yaml`。因此，Tabby 配置不得采用源仓库在 Unix 上默认使用的软链接部署方式。

数据流固定为：

```text
仓库中的公开白名单快照
        │
        │ 安装时复制
        ▼
平台的 Tabby config.yaml
        │
        │ Tabby 在本机自由更新
        ▼
含私有运行态数据的本机副本
```

所有平台均强制复制 Tabby 配置。Tabby 后续写入本机配置时不能修改受 Git 跟踪的仓库快照。README 必须警告用户不要把本机完整配置直接复制回仓库。

## 公共安装组件

`bootstrap/common.sh` 增加两个职责明确的单元：

1. 路径计算函数：根据明确的平台值返回 Tabby `config.yaml` 目标路径，便于独立测试。
2. `install_tabby_config`：创建父目录、备份已有目标、把仓库快照复制为普通文件。

`install_config_payload` 不再部署 `~/.wezterm.lua`，而是调用 `install_tabby_config`。Zsh、tmux、Neovim、Yazi 和 Lazygit 继续沿用现有链接或复制策略。

每次部署 Tabby 配置前，安装流程都无条件打印关闭应用的明确警告，不做跨平台进程检测。文档要求在安装前退出 Tabby，避免应用退出时用内存中的旧配置覆盖新文件。

目标已经存在时，复用现有时间戳备份语义：

```text
config.yaml.bak.YYYYMMDDHHMMSS
```

备份完成后再复制仓库配置。Tabby 配置不能读取 `DOTFILES_LINK_MODE` 来改变为软链接。

## 平台安装设计

### macOS

- 普通 Homebrew 包列表删除 `wezterm`。
- 使用 `brew install --cask tabby` 安装 Tabby。
- 其他 Homebrew 包、字体、Zsh 和 tmux 插件安装保持不变。
- 配置目标为 `$HOME/Library/Application Support/tabby/config.yaml`。
- 所有包含空格的路径均正确引用。

### Ubuntu

- 删除 WezTerm Fury APT 仓库和 `ensure_wezterm_apt_repo`。
- 保留基础 APT 软件包、Neovim、Lazygit、Yazi、Zsh 和 tmux 流程。
- 复用 `bootstrap/github_release_asset.py`，从 `Eugeny/tabby` 最新正式 GitHub Release 选择 `.deb`：
  - `x86_64` 选择 `linux-x64.deb`。
  - `arm64` 选择 `linux-arm64.deb`。
- 使用 APT 安装本地 `.deb`，由 APT 处理依赖。
- 不永久添加 Tabby APT 源或密钥。
- 配置目标为 `${XDG_CONFIG_HOME:-$HOME/.config}/tabby/config.yaml`。

### Windows 与 MSYS2

- `install/windows.ps1` 和 `install/windows-msys2.sh` 把 WinGet 标识 `Wez.WezTerm` 替换为 `Eugeny.Tabby`。
- PowerShell 继续准备 MSYS2、Tabby 和 Lazygit。
- MSYS2 脚本继续安装 Unix 工具栈、插件和 dotfiles。
- 使用 `cygpath` 把 `%APPDATA%` 转换为 MSYS2 可写路径。
- 配置目标为 `%APPDATA%\Tabby\config.yaml`。
- 不把 Windows 原生 Tabby 配置部署到 MSYS2 的 `~/.config/tabby`。
- 直接运行 PowerShell 或直接运行 MSYS2 安装入口都保持可用。

## 文档设计

README 必须更新以下内容：

- 仓库定位和目录结构。
- 三个平台的 Tabby 安装方式。
- 三个平台的 Tabby 配置位置。
- Tabby 强制复制、其他 dotfiles 保持原有部署策略的区别。
- 安装前关闭 Tabby、已有配置自动备份的说明。
- 白名单配置包含和排除的内容。
- 当前 AdventureTime、20px 字体、0.84 透明度、vibrancy、快捷键、欢迎页和动态标题设置。
- 用 `tabby --version` 替换 `wezterm -V`。
- 不得把本机完整 `config.yaml` 复制回仓库的隐私警告。

`当前环境常用快捷键速查.md` 与 `lazygit操作指南.md` 只在存在 WezTerm 专属名称、路径或行为时修改，不做无关重排。

## 测试设计

新增 `tests/test_tabby_config_install.sh`。测试使用临时 HOME 和配置目录，不安装应用、不写入真实用户目录。它必须验证：

1. Linux 目标路径正确。
2. macOS 目标路径正确并包含带空格的 Application Support 目录。
3. Windows/MSYS2 目标路径正确指向转换后的 `%APPDATA%/Tabby/config.yaml`。
4. 安装函数创建缺失的父目录。
5. 目标配置是普通文件而不是软链接。
6. 已有目标在覆盖前生成时间戳备份。
7. 备份内容等于原目标内容。
8. 新目标内容等于仓库白名单快照。
9. 测试结束清理临时目录。

实施完成后执行：

```bash
bash -n bootstrap/*.sh install/*.sh tests/*.sh
bash tests/test_tabby_config_install.sh
```

还必须使用当前环境可用的真实 YAML 解析器加载 `config/tabby/config.yaml`，并断言：

- 根级 `ssh`、`configSync` 和 `vault` 不存在。
- `knownHosts`、令牌、密码、私钥和连接地址不存在。
- `profiles` 与 `groups` 为空。
- AdventureTime 调色板完整。
- 字体为 20px，透明度为 0.84，vibrancy 已启用。
- 快捷键快照完整保留。

生产文件残留检查为：

```bash
rg -n -i 'wezterm' README.md bootstrap config install \
  当前环境常用快捷键速查.md lazygit操作指南.md
```

预期无匹配。`docs/superpowers/` 记录迁移历史，可以提及 WezTerm，因此不参与该检查。

## 错误处理

- 不支持的平台导致路径计算函数返回明确错误，而不是猜测路径。
- Windows 缺少 `%APPDATA%` 时停止 Tabby 配置部署并给出错误。
- 下载不到匹配架构的 Ubuntu `.deb` 时由现有 Release 解析逻辑失败并停止安装。
- 目标备份失败时停止部署，不覆盖原配置。
- 配置复制失败时返回非零状态，由安装脚本的 `set -euo pipefail` 停止流程。
- WinGet 不可用时沿用现有提示方式，要求用户手动安装 Tabby。

## 完成标准

迁移只有在以下条件同时满足时完成：

- `${HOME}/code/tabby_config` 是默认分支为 `main` 的独立 Git 仓库。
- 新仓库没有远程仓库。
- 所有通用 dotfiles 已保留。
- WezTerm 生产配置和生产文档引用已删除。
- Tabby 白名单配置已加入且不含机器私有数据。
- macOS、Ubuntu、Windows/MSYS2 安装入口均安装并部署 Tabby。
- Tabby 配置在所有平台均为复制部署。
- Bash 语法、安装测试、YAML 解析、隐私断言和残留检查全部通过。
- 新仓库工作区干净且提交完整。
- 源仓库仍位于原提交，工作区状态未变化。

## 参考资料

- Tabby 配置文件位置：<https://github.com/Eugeny/tabby/wiki/Config-file>
- Tabby 配置服务与默认值合并：<https://raw.githubusercontent.com/Eugeny/tabby/v1.0.234/tabby-core/src/services/config.service.ts>
- Tabby 官方仓库与 Releases：<https://github.com/Eugeny/tabby>
- Homebrew Tabby cask：<https://formulae.brew.sh/cask/tabby>
- WinGet `Eugeny.Tabby` manifest：<https://raw.githubusercontent.com/microsoft/winget-pkgs/master/manifests/e/Eugeny/Tabby/1.0.234/Eugeny.Tabby.yaml>
