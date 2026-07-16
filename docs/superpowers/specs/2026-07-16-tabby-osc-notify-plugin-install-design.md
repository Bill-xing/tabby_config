# Tabby OSC Notify 跨平台安装设计

## 背景

仓库的 macOS、Ubuntu 和 Windows/MSYS2 安装入口已经安装 Tabby 并部署公开的
`config/tabby/config.yaml`，但 `tabby-osc-notify` 仍需在 Tabby 设置中手动安装。
`server` 分支已经配置 Codex 通过 tmux 和 SSH 发送 OSC 9 通知，因此本地 Tabby
插件是通知链路中尚未自动化的一环。

目标 npm 包为 `tabby-osc-notify@1.0.0`。Tabby 1.0.234 会扫描用户数据目录下的
`plugins/node_modules`，并在加载用户插件时提供 Angular、RxJS 和 `tabby-terminal`
等内建模块。因此安装器只需安全部署目标插件包本身，不需要为三个平台额外安装
Node.js、npm 或插件声明的运行时依赖。

## 目标

- macOS、Ubuntu 和 Windows/MSYS2 的标准安装入口自动安装
  `tabby-osc-notify@1.0.0`。
- 固定下载地址和 SHA-256，确保不同时间和平台安装同一份内容。
- 重复执行保持幂等，不破坏 `tabby-background` 等已有插件。
- 下载、校验或解压失败时不改变当前可用插件。
- 升级或修复插件时保留旧目录备份，并避免备份被 Tabby 当作插件加载。
- `main` 与 `server` 分支都获得相同的跨平台安装能力。
- `server` 分支的无 root 服务器入口继续跳过 Tabby 配置和桌面插件。
- 完成后在当前 Mac 的 Tabby 1.0.234 上安装并验证 OSC 9 通知。

## 非目标

- 不修改第三方插件源码。
- 不把 npm tarball 或解压后的第三方插件提交进仓库。
- 不自动修改操作系统的通知权限。
- 不启用声音；`server` 分支已有的 `terminal.bell: off` 保持不变。
- 不为服务器安装 Tabby 桌面应用。

## 方案选择

采用“固定 tarball 下载并直接部署”的方案。安装器从 npm registry 下载已锁定的
tarball，校验 SHA-256 后只把包内容放入 Tabby 用户插件目录。

未采用系统 npm，因为现有安装脚本并不要求 Node.js/npm；新增该依赖会扩大安装面，
而且会下载 Tabby 已经内建的 Angular、RxJS 和 `tabby-terminal`。也不把 tarball
提交到仓库，以保持当前通过锁文件记录第三方来源、安装时下载的约定。

## 配置与路径

`bootstrap/plugins.lock.sh` 增加以下锁定信息：

- 包名：`tabby-osc-notify`
- 版本：`1.0.0`
- tarball URL：npm registry 的固定版本地址
- SHA-256：`a48fad95d94768b683f273397d7d818c526de969b3247c430bd309b3b0bb36d8`

插件根目录从现有 `tabby_config_path` 推导，确保配置与插件位于同一个 Tabby 用户
数据目录：

- macOS：`~/Library/Application Support/tabby/plugins`
- Linux：`${XDG_CONFIG_HOME:-$HOME/.config}/tabby/plugins`
- Windows/MSYS2：`%APPDATA%/Tabby/plugins`，通过 `cygpath` 转为 Unix 路径

最终插件目录为：

`<plugins>/node_modules/tabby-osc-notify`

## 安装流程

`bootstrap/common.sh` 增加插件路径、校验和安装函数。标准流程如下：

1. `DOTFILES_SKIP_TABBY` 已启用时，同时跳过 Tabby 配置和插件。
2. 若目标目录中的 `package.json` 声明了正确包名和版本，且 `dist/index.js` 存在，
   记录复用信息并直接成功返回。
3. 在临时目录下载固定 tarball。
4. 使用 `sha256sum` 或 `shasum -a 256` 校验文件；平台均不支持时明确失败。
5. 解压前检查归档成员，拒绝绝对路径、父目录跳转以及 `package/` 之外的内容。
6. 解压到暂存目录，修复上游 tarball 中目录缺少执行位的问题。
7. 验证暂存包的名称、版本和入口文件。
8. 若已有目标目录，将其移到 `<plugins>/backups/` 下的防冲突时间戳目录。
   备份不放在 `node_modules` 中，避免 Tabby 扫描并重复加载。
9. 将验证后的暂存目录移动到最终位置。若最终移动失败，恢复刚创建的备份。

安装不修改或删除其他 `node_modules` 子目录，也不重写 Tabby 生成的
`package-lock.json`。Tabby 的插件发现以插件目录及其 `package.json` 为准，锁文件
并非启动时的插件清单。

`install_config_payload` 在同一个非跳过分支中先部署 Tabby 配置，再安装插件。
这样现有三个桌面平台入口自动获得插件安装能力，而 `server` 分支
`install/ubuntu-user.sh` 设置的 `DOTFILES_SKIP_TABBY=1` 会跳过两者。

## 错误处理

- 网络失败、校验失败、归档结构异常和包元数据不匹配都返回非零状态，并保留原插件。
- 只有下载、校验、解压和元数据验证全部成功后才移动现有插件。
- 备份目录名称处理同一秒内的冲突，不覆盖旧备份。
- 安装器继续提示用户在操作前关闭 Tabby，避免运行中的应用与文件变更竞争。
- 安装成功后提示重启 Tabby，并提醒通知权限仍由操作系统控制。

## 测试

新增离线 shell 测试，运行时生成一个最小插件 tarball，并覆盖下载函数指向该 fixture。
测试覆盖：

- macOS、Linux、Windows/MSYS2 三种插件路径。
- 首次安装的包名、版本和入口文件。
- 重复安装不创建备份且保持目标不变。
- 保留同目录中的其他插件和 `package-lock.json`。
- 旧版或损坏目标被备份到 `plugins/backups` 后替换。
- SHA-256 不匹配、非法归档和错误元数据不会改变已有目标。
- `DOTFILES_SKIP_TABBY=1` 同时跳过配置与插件。
- 锁文件中的真实版本、URL 和 SHA-256 与设计一致。

现有 Tabby 配置隐私测试、Codex 通知测试和安装脚本语法检查继续运行。实现完成后，
在当前 Mac 上确认插件出现在 Tabby 已安装插件列表，并用以下序列验证通知：

```sh
printf '\033]9;Codex 通知测试\007'
```

## 分支交付

由于当前工作区的 `.git` 在执行环境中只读，远端更新通过可写的临时克隆完成，文件
改动同时同步回当前工作区供用户检查。实施顺序为：

1. 基于最新 `origin/main` 完成测试、实现、文档和提交。
2. 基于最新 `origin/server` 应用同一实现，保留该分支已有的 Codex OSC 9、tmux
   passthrough、`terminal.bell: off` 和无 root 安装逻辑。
3. 分别运行各分支的完整相关测试后更新 `origin/main` 与 `origin/server`。

