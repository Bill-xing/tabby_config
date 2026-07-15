# lazygit 操作指南

这份文档整理当前讨论过的 lazygit 用法，重点覆盖日常最常用的 Git 工作流：看状态、看提交、查看文件 diff、提交、推送、忽略文件，以及 delta 左右分栏 diff。

## 1. 基本概念

### 1.1 Status

`Status` 表示当前仓库状态，对应命令：

```bash
git status
```

它主要告诉你：

- 当前在哪个分支
- 哪些文件被修改了
- 哪些文件已经 staged
- 哪些文件还没有 staged
- 哪些文件是 untracked
- 有没有冲突
- 本地分支相对远程是 ahead 还是 behind

常见状态：

| 状态 | 含义 |
| --- | --- |
| `modified` | 文件被修改 |
| `staged` | 已加入暂存区，会进入下一次 commit |
| `unstaged` | 改了但还没加入暂存区 |
| `untracked` | 新文件，Git 还没跟踪 |
| `deleted` | 文件被删除 |
| `conflicted` | 合并或 rebase 时有冲突 |
| `clean` | 当前没有未提交改动 |

一句话：`Status` 是当前工作区体检报告。

### 1.2 Commits

`Commits` 看的是项目提交历史，对应：

```bash
git log
```

适合用来：

- 查看项目历史
- 查看某个 commit 改了什么
- 对 commit 做 checkout、reset、revert、cherry-pick、rebase 等操作
- 理解分支之间的提交关系

### 1.3 Reflog

`Reflog` 看的是本地 Git 指针移动历史，对应：

```bash
git reflog
```

它记录的是本地 `HEAD` 或分支指针曾经到过哪里，比如：

```text
commit: add feature
checkout: moving from main to dev
reset: moving to HEAD~1
rebase finished
merge branch dev
```

适合用来：

- 找回误 `reset --hard` 丢掉的 commit
- 找回 rebase 前的位置
- 查看本地刚才切分支、reset、merge、commit 的操作轨迹

核心区别：

| 界面 | 看什么 | 类似命令 | 是否本地专属 | 主要用途 |
| --- | --- | --- | --- | --- |
| `Commits` | 项目的 commit 历史 | `git log` | 不是 | 查看和操作提交 |
| `Reflog` | 本地 HEAD/分支移动记录 | `git reflog` | 是 | 恢复误操作 |

一句话：`Commits` 是项目历史，`Reflog` 是本地 Git 操作轨迹。

## 2. 常用按键

| 操作 | 快捷键 |
| --- | --- |
| 上下移动 | `j` / `k` 或方向键 |
| 进入当前项 | `Enter` |
| 返回上一层 | `Esc` / `h` / 左方向键 |
| 在面板间切换 | `Tab` |
| 聚焦右侧主视图 | `0` |
| 放大当前面板 | `+` |
| 缩小或恢复面板 | `_` |
| 搜索 | `/` |
| 打开快捷键帮助 | `?` |
| 退出 lazygit | `q` |

## 3. 像 VSCode 一样查看某个 commit 的文件改动

你在 VSCode Git Graph 里的习惯是：

```text
点开一个 commit -> 点开一个改动文件 -> 看文件改动
```

在 lazygit 中对应流程是：

```text
Commits 面板 -> 选中 commit -> Enter -> 进入该 commit 的文件列表 -> 选中文件 -> 看右侧 diff
```

注意：选中文件后，右侧会自动显示 diff。  
如果只是看改动，停在文件列表即可，不要再对文件按 `Enter`。

常用流程：

```text
1. 打开 lazygit
2. 切到 Commits 面板
3. 选中某个 commit
4. 按 Enter 进入这个 commit 的文件列表
5. 选中某个文件
6. 右侧 Diff 面板查看这个文件改了什么
```

返回上一层：

```text
Esc
```

如果 `Esc` 没反应，试：

```text
h
```

或左方向键。

## 4. Patch 和 Custom Patch

当你在 commit 的文件列表中，选中文件后再按一次 `Enter`，可能会进入 `Patch / Custom Patch` 界面。

这个界面不是普通查看 diff 的地方，而是用来从某个 commit 中精细挑选一部分改动。

| 区域 | 含义 |
| --- | --- |
| `Patch` | 当前文件或当前 commit 的完整改动 |
| `Custom Patch` | 你从 `Patch` 中手动选出来的部分改动 |

简单理解：

```text
Patch = 完整 diff
Custom Patch = 你选中的那部分 diff
```

例子：

某个 commit 里同时做了两件事：

```text
1. 修改 login 逻辑
2. 顺手改了一个注释
```

如果你只想把“改注释”这几行拿出来，就可以在 `Patch` 里选择那几行，加入 `Custom Patch`。

然后可以对这部分改动单独操作，比如：

- 从当前 commit 里移除
- 拆成新的 commit
- 移动到暂存区
- 复制 patch
- 反向应用 patch

关系可以这样记：

```text
只选中几行 -> Custom Patch 是那几行
选中一个 hunk -> Custom Patch 是那个 hunk
选中整个文件 -> Custom Patch 等于这个文件的完整 patch
选中整个 commit 的所有改动 -> Custom Patch 等于这个 commit 的完整 patch
```

日常只看 diff 时，不需要进入 `Custom Patch`。

## 5. 使用 delta 左右分栏 diff

当前已经配置 lazygit 使用 `git-delta` 显示 diff。

配置文件位置：

```text
/Users/xingjianming/Library/Application Support/lazygit/config.yml
```

当前配置：

```yaml
git:
  pagers:
    - pager: delta --dark --paging=never --side-by-side --line-numbers
    - pager: delta --dark --paging=never --line-numbers
```

含义：

| Pager | 显示方式 | 适合场景 |
| --- | --- | --- |
| 第一个 | 左右分栏 diff | 对比旧内容和新内容 |
| 第二个 | 普通整宽 diff | 新增文件、左边为空、右边内容很多 |

在 diff 视图里按：

```text
|
```

可以在这两个 pager 之间切换。

在 Mac 键盘上，`|` 通常是：

```text
Shift + \
```

注意：要在普通 Diff 面板里按 `|` 才明显。  
如果你已经进入 `Patch / Custom Patch`，那是 lazygit 自己的 patch 编辑视图，custom pager 不一定管它。

正确测试方式：

```text
Commits 面板
选中 commit
Enter 进入文件列表
只选中文件，不要再按 Enter
看右侧 Diff 面板
按 |
```

### 5.1 能不能手动调节左右两栏比例

delta 的 `--side-by-side` 是左右两栏等宽布局，不能像 VSCode 那样拖动分割线，单独放大右侧改动内容。

能做的是：

- 按 `+` 放大 lazygit 当前 diff 面板
- 把终端窗口拉宽
- 按 `|` 切换到普通整宽 diff

对于“原始文件为空，新增内容很多”的情况，建议按 `|` 切到普通整宽 diff。

## 6. 调用 VSCode 左右分栏 diff

如果你想要真正类似 VSCode 的左右分栏，可以让 lazygit 调 Git difftool。

先配置 Git：

```bash
git config --global diff.tool vscode
git config --global difftool.vscode.cmd 'code --wait --diff "$LOCAL" "$REMOTE"'
git config --global difftool.prompt false
```

如果 `code` 命令不存在，在 VSCode 命令面板中执行：

```text
Shell Command: Install 'code' command in PATH
```

之后在 lazygit 里选中文件，按：

```text
Ctrl+t
```

就会用 VSCode 打开左右分栏 diff。

## 7. 提交 commit

常用流程：

```text
Files 面板 -> 选择文件 -> stage -> commit -> 输入提交信息 -> Enter
```

具体操作：

```text
1. 打开 lazygit
2. 进入 Files 面板
3. 选择要提交的文件
4. 按 Space 暂存当前文件
5. 按 c 开始 commit
6. 输入 commit message
7. 按 Enter 确认提交
```

常用快捷键：

| 操作 | 快捷键 |
| --- | --- |
| stage/unstage 当前文件 | `Space` |
| stage/unstage 所有文件 | `a` |
| commit | `c` |
| 用编辑器写 commit message | `C` |
| amend 上一个 commit | `A` |
| 放弃当前文件改动 | `x` |
| push | `P` |
| pull | `p` |

最常用的一套：

```text
Space -> c -> 输入提交信息 -> Enter -> P
```

含义：

```text
暂存文件 -> 提交 -> 推送
```

## 8. 把文件加入 .gitignore

在 lazygit 里：

```text
Files 面板 -> 选中那个文件 -> 按 i
```

`i` 会把该文件路径加入 `.gitignore`。

也可以手动编辑 `.gitignore`：

```gitignore
filename.txt
```

常见写法：

```gitignore
# 忽略某个文件
data.db

# 忽略某个目录
node_modules/

# 忽略某类文件
*.log
```

注意：如果文件已经被 Git 跟踪，加入 `.gitignore` 后不会自动取消跟踪。

这种情况需要执行：

```bash
git rm --cached path/to/file
```

然后提交：

```bash
git add .gitignore
git commit -m "chore: update gitignore"
```

总结：

| 文件状态 | 处理方式 |
| --- | --- |
| 未被 Git 跟踪 | lazygit 选中文件后按 `i` 即可 |
| 已被 Git 跟踪 | 加入 `.gitignore` 后，再执行 `git rm --cached path/to/file` |

## 9. 常见场景速查

| 需求 | 操作 |
| --- | --- |
| 查看当前改动 | `Files` 面板选中文件，看右侧 diff |
| 查看某个 commit 改了什么 | `Commits` -> 选 commit -> `Enter` -> 选文件 |
| 返回上一层 | `Esc` / `h` / 左方向键 |
| 看左右分栏 diff | 使用 delta side-by-side pager |
| 切换整宽 diff | 在普通 Diff 面板按 `|` |
| 进入 custom patch | commit 文件列表中选中文件后再按 `Enter` |
| 提交当前文件 | 选文件 -> `Space` -> `c` |
| 提交所有文件 | `a` -> `c` |
| 推送 | `P` |
| 拉取 | `p` |
| 忽略文件 | 选中文件 -> `i` |
| 出事后找回提交 | 看 `Reflog` |

