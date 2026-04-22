# codex-zsh-history-isolation.sh

隔离 Codex shell 历史，并设置 Codex 自己的 `history.jsonl` 保留模式。

脚本位置：
[codex-zsh-history-isolation.sh](/workspace/zjh/code/shield/sh/codex-zsh-history-isolation/codex-zsh-history-isolation.sh)

常用命令：

```bash
./sh/codex-zsh-history-isolation/codex-zsh-history-isolation.sh --help
./sh/codex-zsh-history-isolation/codex-zsh-history-isolation.sh --check
./sh/codex-zsh-history-isolation/codex-zsh-history-isolation.sh
./sh/codex-zsh-history-isolation/codex-zsh-history-isolation.sh --codex-history-persistence save-all
```

作用：

- 设置 `allow_login_shell = false`
- 设置 `shell_environment_policy.experimental_use_profile = false`
- 设置隔离的 `HISTFILE` 和 `ZDOTDIR`
- 控制 `[history].persistence`
