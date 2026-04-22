# zsh-history-prune.sh

按完整命令行出现次数和最近历史筛选 `~/.zsh_history`并清理。

脚本位置：
[zsh-history-prune.sh](./zsh-history-prune.sh)

常用命令：

```bash
./sh/zsh-history-prune/zsh-history-prune.sh --help
./sh/zsh-history-prune/zsh-history-prune.sh
./sh/zsh-history-prune/zsh-history-prune.sh --apply
./sh/zsh-history-prune/zsh-history-prune.sh --min-count 5 --top 0
```

默认规则：

- 完整命令行出现次数至少 `5`
- 不额外保留 top N
- 永远保留最近 `500` 条