# zsh-history-prune.sh

使用脚本 [zsh-history-prune.sh](./zsh-history-prune.sh) 按完整命令行出现次数和最近历史筛选 `~/.zsh_history` 并清理。🧹

## 1. 🔧 参数说明

| 参数 | 说明 | 默认值 |
| --- | --- | --- |
| `--histfile FILE` | 要处理的 `zsh` 历史文件。优先使用这个参数，其次才看环境变量 `HISTFILE` | `$HISTFILE` 或 `~/.zsh_history` |
| `--min-count N` | 保留完整命令行出现次数至少为 `N` 的记录。适合清掉只执行过一两次的命令 | `5` |
| `--top N` | 额外保留出现次数最高的前 `N` 条完整命令行。和 `--min-count` 取并集 | `0` |
| `--keep-recent N` | 永远保留最近 `N` 条历史记录，不参与筛选 | `500` |
| `--backup-dir DIR` | `--apply` 时保存备份的目录 | `~/.zsh_history.backups` |
| `--apply` | 真的改写历史文件。默认只预览，不写回 | 关闭 |
| `-h, --help` | 显示帮助信息并退出 | - |

## 2. 🧠 处理规则

- 先按完整命令行统计出现次数
- 再保留 `--top` 和 `--min-count` 命中的命令
- 同时保留最近 `--keep-recent` 条记录
- 预览模式只输出结果，不会修改原文件
- `--apply` 会先写备份，再覆盖历史文件

## 3. 🚀 常用命令

```bash
./sh/zsh-history-prune/zsh-history-prune.sh --help
./sh/zsh-history-prune/zsh-history-prune.sh
./sh/zsh-history-prune/zsh-history-prune.sh --apply
./sh/zsh-history-prune/zsh-history-prune.sh --min-count 5 --top 0
```

## 4. ⚠️ 注意

- 处理对象必须存在且非空
- `--apply` 之前会自动创建备份目录
- `--top` 和 `--min-count` 可以同时使用，脚本会保留两者的并集
