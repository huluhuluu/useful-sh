# useful-sh

## 1. 📁 仓库结构

整理一些 `shell` / `PowerShell` 脚本，统一放在 `sh/<name>/` 目录下，每个目录包含：

- 可直接执行的脚本文件
- 对应的 `README.md`

当前仓库里的脚本如下：

| 脚本 | 说明 | 文档 |
| --- | --- | --- |
| [`adb-relay-guard.sh`](./sh/adb-relay-guard/adb-relay-guard.sh) | 守护 USB ADB、`adb forward` 和到远端 SSH 主机的反向端口转发 | [README](./sh/adb-relay-guard/README.md) |
| [`android-clangd-setup.sh`](./sh/android-clangd-setup/android-clangd-setup.sh) | 自动探测 Android NDK，并给目标项目补齐 VS Code `clangd` 和 `.clangd` 配置 | [README](./sh/android-clangd-setup/README.md) |
| [`codex-zsh-history-isolation.sh`](./sh/codex-zsh-history-isolation/codex-zsh-history-isolation.sh) | 隔离 Codex 使用时的 `zsh` 历史，并控制 Codex 的 `history.jsonl` 保留模式 | [README](./sh/codex-zsh-history-isolation/README.md) |
| [`codex-skills-bootstrap`](./sh/codex-skills-bootstrap/) | 通过 `cc-switch` 给 Codex 或其它 agent 批量安装常用 skills | [README](./sh/codex-skills-bootstrap/README.md) |
| [`file-integrity.sh`](./sh/file-integrity/file-integrity.sh) | 快速计算大文件的 `sha256`、`md5`、`blake3` 等完整性 hash，并支持期望值校验 | [README](./sh/file-integrity/README.md) |
| [`netcat-transfer.sh`](./sh/netcat-transfer/netcat-transfer.sh) | 使用 `netcat` 压缩传输文件或目录，接收端自动解压 | [README](./sh/netcat-transfer/README.md) |
| [`ubuntu-config.sh`](./sh/ubuntu-config/ubuntu-config.sh) | 批量执行 Ubuntu 常用初始化，包含基础工具和开发工具安装 | [README](./sh/ubuntu-config/README.md) |
| [`windows-sntp-sync.ps1`](./sh/windows-sntp-sync/windows-sntp-sync.ps1) | 绕过 `w32time`，使用独立 SNTP 请求校准 Windows 系统时间 | [README](./sh/windows-sntp-sync/README.md) |
| [`zsh-history-prune.sh`](./sh/zsh-history-prune/zsh-history-prune.sh) | 按完整命令行出现次数和最近历史筛选 `~/.zsh_history` | [README](./sh/zsh-history-prune/README.md) |

## 2. 🚀 使用方式

先看脚本说明，再执行具体命令。每个脚本都提供 `--help`。

Linux / Git Bash：

```bash
./sh/adb-relay-guard/adb-relay-guard.sh --help
./sh/android-clangd-setup/android-clangd-setup.sh --help
./sh/codex-skills-bootstrap/codex-skills-bootstrap.sh --help
./sh/codex-zsh-history-isolation/codex-zsh-history-isolation.sh --help
./sh/file-integrity/file-integrity.sh --help
./sh/netcat-transfer/netcat-transfer.sh --help
./sh/ubuntu-config/ubuntu-config.sh --help
pwsh -NoProfile -ExecutionPolicy Bypass -File ./sh/windows-sntp-sync/windows-sntp-sync.ps1 --help
./sh/zsh-history-prune/zsh-history-prune.sh --help
```

Windows PowerShell：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\sh\codex-skills-bootstrap\codex-skills-bootstrap.ps1 --help
powershell -NoProfile -ExecutionPolicy Bypass -File .\sh\windows-sntp-sync\windows-sntp-sync.ps1 --help
```
