# useful-sh

## 1. 📁 仓库结构

整理一些 `shell` 脚本，统一放在 `sh/<name>/` 目录下，每个目录包含：

- 可直接执行的脚本文件
- 对应的 `README.md`

当前仓库里的脚本如下：

| 脚本 | 说明 | 文档 |
| --- | --- | --- |
| [`android-clangd-setup.sh`](./sh/android-clangd-setup/android-clangd-setup.sh) | 自动探测 Android NDK，并给目标项目补齐 VS Code `clangd` 和 `.clangd` 配置 | [README](./sh/android-clangd-setup/README.md) |
| [`codex-zsh-history-isolation.sh`](./sh/codex-zsh-history-isolation/codex-zsh-history-isolation.sh) | 隔离 Codex 使用时的 `zsh` 历史，并控制 Codex 的 `history.jsonl` 保留模式 | [README](./sh/codex-zsh-history-isolation/README.md) |
| [`netcat-transfer.sh`](./sh/netcat-transfer/netcat-transfer.sh) | 使用 `netcat` 压缩传输文件或目录，接收端自动解压 | [README](./sh/netcat-transfer/README.md) |
| [`ubuntu-config.sh`](./sh/ubuntu-config/ubuntu-config.sh) | 批量执行 Ubuntu 常用初始化，包含基础工具和开发工具安装 | [README](./sh/ubuntu-config/README.md) |
| [`zsh-history-prune.sh`](./sh/zsh-history-prune/zsh-history-prune.sh) | 按完整命令行出现次数和最近历史筛选 `~/.zsh_history` | [README](./sh/zsh-history-prune/README.md) |

## 2. 🚀 使用方式

先看脚本说明，再执行具体命令。每个脚本都提供 `--help`。

```bash
# 查看脚本说明
./sh/android-clangd-setup/android-clangd-setup.sh --help
./sh/codex-zsh-history-isolation/codex-zsh-history-isolation.sh --help
./sh/netcat-transfer/netcat-transfer.sh --help
./sh/ubuntu-config/ubuntu-config.sh --help
./sh/zsh-history-prune/zsh-history-prune.sh --help
```
