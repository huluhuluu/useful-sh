# useful-sh

一些偏实用的 shell 脚本，当前包含：

- `codex-zsh-history-isolation.sh`：隔离 Codex 执行命令带来的 shell 历史污染，并控制 Codex 自己的 `history.jsonl`
- `zsh-history-prune.sh`：按常用命令和最近历史筛选 `~/.zsh_history`

目标仓库：
[https://github.com/huluhuluu/useful-sh](https://github.com/huluhuluu/useful-sh)

## 脚本总览

| 脚本 | 作用 | 常用命令 | 详细说明 |
| --- | --- | --- | --- |
| [`codex-zsh-history-isolation.sh`](#codex-zsh-history-isolationsh) | 隔离 Codex shell 历史，单独指定 `HISTFILE` / `ZDOTDIR`，并设置 Codex 自己的历史保留模式 | `./codex-zsh-history-isolation.sh --check` | [查看用法](#codex-zsh-history-isolationsh) |
| [`zsh-history-prune.sh`](#zsh-history-prunesh) | 按完整命令行出现次数和最近历史筛选 `~/.zsh_history` | `./zsh-history-prune.sh --apply` | [查看用法](#zsh-history-prunesh) |

## `codex-zsh-history-isolation.sh`

这个脚本会处理 4 件事：

1. 把 `allow_login_shell` 设为 `false`
2. 把 `shell_environment_policy.experimental_use_profile` 设为 `false`
3. 把 `shell_environment_policy.set.HISTFILE` 和 `shell_environment_policy.set.ZDOTDIR` 指向隔离目录
4. 设置 Codex 自己的 `[history].persistence`，也就是 `~/.codex/history.jsonl` 的保留模式

### 查看帮助

```bash
./codex-zsh-history-isolation.sh --help
```

### 只检测，不写入

```bash
./codex-zsh-history-isolation.sh --check
```

这个模式会输出这些文件路径：

- Codex 配置文件
- Codex 自己的 `history.jsonl`
- 隔离后的 shell history 文件
- 隔离后的 `ZDOTDIR`
- 隔离后的 `.zshenv`

同时它会返回：

- 已经符合要求时退出码为 `0`
- 还没配置好时退出码为 `1`

### 直接应用默认配置

```bash
./codex-zsh-history-isolation.sh
```

### 指定 Codex 的 shell history 文件

```bash
./codex-zsh-history-isolation.sh --codex-shell-histfile /tmp/codex-shell-history
```

也可以用旧参数名：

```bash
./codex-zsh-history-isolation.sh --histfile /tmp/codex-shell-history
```

### 指定 Codex 自己的历史保留模式

默认会写成：

```toml
[history]
persistence = "none"
```

如果你想保留 Codex 自己的 `history.jsonl`，可以这样：

```bash
./codex-zsh-history-isolation.sh --codex-history-persistence save-all
```

### 只 sparse clone 这个脚本并执行

```bash
git clone --filter=blob:none --sparse https://github.com/huluhuluu/useful-sh.git
cd useful-sh
git sparse-checkout set codex-zsh-history-isolation.sh README.md
chmod +x codex-zsh-history-isolation.sh
./codex-zsh-history-isolation.sh --help
```

## `zsh-history-prune.sh`

这个脚本会读取 zsh 历史，按“完整命令行”统计出现次数，然后：

1. 保留最近一段历史
2. 保留出现次数达到阈值的完整命令行
3. 在 `--apply` 时先备份，再重写 history 文件

### 查看帮助

```bash
./zsh-history-prune.sh --help
```

### 只预览，不改文件

```bash
./zsh-history-prune.sh
```

### 按默认规则执行清理

```bash
./zsh-history-prune.sh --apply
```

默认规则是：

- 完整命令行出现次数至少 `5`
- 不额外保留 top N
- 永远保留最近 `500` 条

### 调整筛选阈值

```bash
./zsh-history-prune.sh --min-count 8 --top 20 --keep-recent 1000
```

### 只 sparse clone 这个脚本并执行

```bash
git clone --filter=blob:none --sparse https://github.com/huluhuluu/useful-sh.git
cd useful-sh
git sparse-checkout set zsh-history-prune.sh README.md
chmod +x zsh-history-prune.sh
./zsh-history-prune.sh --help
```

## 说明

- `zsh-history-prune.sh` 默认是预览模式，不会直接改写历史文件
- `zsh-history-prune.sh --apply` 如果筛选结果和原文件完全一样，会直接退出，不重复备份和改写
- `codex-zsh-history-isolation.sh` 已经是幂等的，重复执行时如果配置已匹配，会直接提示并退出
