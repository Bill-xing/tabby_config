# tmux 底部状态栏配置入库设计

## 背景

仓库已经跟踪 `config/tmux/.tmux.conf`，也已经锁定并安装
`erikw/tmux-powerline`。不过，当前机器实际使用的 tmux-powerline 用户配置仍位于
仓库之外：

- `~/.config/tmux-powerline/config.sh`
- `~/.config/tmux-powerline/themes/minimal.sh`

TPM 在 `.tmux.conf` 末尾加载 tmux-powerline 后，会覆盖 `.tmux.conf` 前面设置的
`status-left`、`status-right`、窗口格式、刷新间隔和状态栏样式。因此，仅保存
`.tmux.conf` 中的手写 status 配置不能复现当前屏幕最底部的 bar。

## 当前生效状态

当前 tmux 服务器和用户配置共同产生以下状态栏：

- `TMUX_POWERLINE_THEME="minimal"`
- 左侧仅包含 `tmux_session_info` segment，显示格式为 `#S:#I.#P`
- 中间使用 tmux 的窗口列表
- 右侧没有 segment
- `tmux_session_info` 的前景色为 `colour234`，背景色为 `colour148`
- 状态栏底色为 `colour235`
- 状态栏位于底部、窗口列表居中、刷新间隔为 1 秒
- tmux-powerline 固定版本为 commit
  `d70011158dc389070d6ed7a67b65367206b6ddec`

上述两份用户配置不包含凭据、主机标识或其他运行态隐私数据，可以原样进入仓库。

## 方案比较

### 采用：跟踪并部署 tmux-powerline 用户配置目录

把当前两个文件原样保存为：

- `config/tmux-powerline/config.sh`
- `config/tmux-powerline/themes/minimal.sh`

安装时通过已有 `link_or_copy` 机制，把整个目录部署到
`${XDG_CONFIG_HOME:-$HOME/.config}/tmux-powerline`。这与 tmux-powerline 自身默认的
配置发现路径一致，也保留了当前主题继承上游 `default.sh` 的行为。

### 不采用：把状态栏全部内联进 `.tmux.conf`

这种方式需要重写 tmux-powerline 已有的 segment 和窗口格式逻辑，而且 TPM 仍可能在
末尾覆盖这些设置。它保存的是人工重建结果，不是当前真正使用的配置来源。

### 不采用：只保存当前渲染出的 status 字符串

左侧当前可以渲染成固定的 tmux 格式字符串，但中间窗口列表依赖 tmux 的动态窗口状态，
主题颜色和插件默认值也会丢失。这不能完整复现当前 bar。

## 文件与安装流程

`bootstrap/common.sh` 的 `install_config_payload` 增加一次目录部署：

```text
config/tmux-powerline
        |
        +-- link_or_copy --> ${XDG_CONFIG_HOME:-$HOME/.config}/tmux-powerline
```

该调用沿用仓库现有平台策略：

- macOS 和 Ubuntu 默认创建指向仓库目录的符号链接。
- Windows/MSYS2 默认复制整个目录。
- `DOTFILES_LINK_MODE=symlink|copy` 仍可覆盖默认策略。
- 目标已存在且不是正确的现有符号链接时，由 `link_or_copy` 先创建时间戳备份。

tmux-powerline 插件本身仍由 `install_tmux_plugins` 按锁定 commit 安装，不把第三方插件
源码复制进仓库。

## 文档更新

README 的目录结构、安装内容、tmux 说明和验证命令需要明确：

- 仓库跟踪 tmux-powerline 的 `minimal` 用户主题。
- 最底部 bar 左侧显示 session/window/pane，中间显示窗口列表，右侧为空。
- 安装目标是 `${XDG_CONFIG_HOME:-$HOME/.config}/tmux-powerline`。
- 可直接运行左右两侧的 `powerline.sh` 命令验证渲染结果。

不修改快捷键速查中与本次状态栏无关的章节。

## 测试与验收

自动化测试覆盖以下行为：

1. 两份 tmux-powerline 配置文件存在，并包含当前主题名、用户主题目录、唯一左侧
   segment 和空右侧 segment。
2. `install_config_payload` 使用 `link_or_copy` 部署整个 `config/tmux-powerline`
   目录到 XDG 配置目录。
3. 在隔离的临时 HOME/XDG 目录中执行 copy 模式部署后，目标文件与仓库源文件逐字节
   一致。
4. README 记录配置来源、安装目标和当前可见结构。

在当前机器上另做一次集成验证：让锁定版本的 tmux-powerline 读取仓库配置，并断言：

- `powerline.sh left` 的输出包含 `#S:#I.#P`、`colour148` 和 `colour234`。
- `powerline.sh right` 的输出为空。

验证使用临时 `XDG_CONFIG_HOME` 或显式配置路径，不替换当前
`~/.config/tmux-powerline` 符号链接，也不改变正在运行的 tmux 会话。

## 非目标

- 不更改 bar 的外观、颜色、segment、位置或刷新间隔。
- 不修改当前 tmux session/window/pane。
- 不 vendoring tmux-powerline 第三方源码。
- 不顺带重构 `.tmux.conf` 中会被插件覆盖的旧 status 配置。
