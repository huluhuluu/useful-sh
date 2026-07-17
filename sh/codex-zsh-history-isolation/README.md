# codex-zsh-history-isolation.sh

使用脚本 [codex-zsh-history-isolation.sh](./codex-zsh-history-isolation.sh) 隔离 Codex shell 历史，避免污染 `zsh` 的命令历史，并设置 Codex 自己的 `history.jsonl` 保留模式。🧠

## 依赖检查

脚本需要 Python 3.11+ 及其标准库 `tomllib`，配置生效时需要 `zsh`：

```bash
python3 -c 'import sys, tomllib; assert sys.version_info >= (3, 11); print(sys.version)'
command -v zsh >/dev/null || echo "missing: zsh"
```

Ubuntu 24.04 及更新版本可安装：

```bash
sudo apt install python3 zsh
```

macOS 可使用 `brew install python zsh` 安装。

较旧发行版的 `python3` 可能低于 3.11，安装后仍应执行上面的检查命令确认。
缺少 Python 或 `tomllib` 时，脚本也会在退出前打印对应的安装和版本提示。

## 1. 🔧 参数说明

| 参数 | 说明 | 默认值 |
| --- | --- | --- |
| `--codex-dir DIR` | Codex 主目录。脚本会在这里读取和写入 `config.toml`、`history.jsonl` 和备份文件 | `~/.codex` |
| `--histfile FILE` | 隔离后的 shell 历史文件路径。脚本会把 `HISTFILE` 指到这里 | `~/.codex/shell_history` |
| `--codex-shell-histfile FILE` | `--histfile` 的别名，行为完全一致 | 同上 |
| `--zdotdir DIR` | 隔离后的 `zsh` 配置目录。脚本会写入这个目录下的 `.zshenv` | `~/.codex/zsh` |
| `--codex-history-persistence MODE` | 设置 `[history].persistence`，控制 Codex 自己的历史保存方式 | `none` |
| `--check` | 只检查当前状态，不写文件。适合先确认配置是否已经就绪 | 关闭 |
| `-h, --help` | 显示帮助信息并退出 | - |

`--codex-history-persistence` 目前只接受 `none` 和 `save-all`。

```bash
./sh/codex-zsh-history-isolation/codex-zsh-history-isolation.sh --help
./sh/codex-zsh-history-isolation/codex-zsh-history-isolation.sh --check
./sh/codex-zsh-history-isolation/codex-zsh-history-isolation.sh
./sh/codex-zsh-history-isolation/codex-zsh-history-isolation.sh --codex-history-persistence save-all
```

## 2. 🧭 作用

- 设置 `allow_login_shell = false`
- 设置 `shell_environment_policy.experimental_use_profile = false`
- 设置隔离的 `HISTFILE` 和 `ZDOTDIR`
- 控制 `[history].persistence`
- 自动备份已有的 `config.toml`
- 先做校验，再决定是只检查还是写入文件

## 3. ⚠️ 注意

- `--codex-dir`、`--histfile` 和 `--zdotdir` 都要求绝对路径
- 脚本会在 `--codex-dir/backups` 下保存备份
- 如果只想确认当前状态，直接用 `--check`
