# ubuntu-config.sh

这是一个 Ubuntu 开发机初始化脚本。🐧

它覆盖的范围按你给的那份备忘补齐了，不再只是装几个包，而是把下面几类动作一起串起来：

- 常用包安装
- `tmux` 鼠标模式
- `zsh + oh-my-zsh`
- `zsh-syntax-highlighting` 和 `zsh-autosuggestions`
- `fzf` 和 `zoxide`
- `Miniforge`
- 可选的 `CUDA` 环境变量

## 1. 🔧 参数说明

| 参数 | 说明 | 默认值 |
| --- | --- | --- |
| `--install-base` | 安装基础工具组 | 关闭 |
| `--install-dev` | 安装开发工具组 | 关闭 |
| `--install-shell` | 安装 shell 工具，并配置 `tmux`、`zsh`、`oh-my-zsh`、`fzf`、`zoxide` 和 `zsh` 插件 | 关闭 |
| `--install-miniforge` | 安装 `Miniforge`，执行 `conda init zsh`，并追加清华源 channels | 关闭 |
| `--skip-shell-config` | 安装 shell 相关包，但跳过 `~/.tmux.conf`、`~/.zshrc`、`~/.bash_profile` 的配置写入 | 关闭 |
| `--skip-update` | 跳过 `apt-get update` | 关闭 |
| `--cuda-home DIR` | 往 `~/.zshrc` 追加 `CUDA` 的 `PATH` 和 `LD_LIBRARY_PATH` | 不配置 |
| `--miniforge-prefix DIR` | 自定义 `Miniforge` 安装目录 | `~/miniforge3` |
| `--miniforge-url URL` | 自定义 `Miniforge` 安装脚本地址 | 按架构自动推断 |
| `--all` | 同时执行 `base`、`dev`、`shell`、`miniforge` 四类初始化 | 关闭 |
| `--check` | 只打印计划动作，不实际执行 | 关闭 |
| `-h, --help` | 显示帮助信息并退出 | - |

## 2. 📦 默认安装内容

### 2.1 base

`base` 组目前会安装这些包：

```bash
ca-certificates curl wget gzip netcat-openbsd pv tmux nvtop htop lsof aria2 pigz \
git-lfs git vim tree unzip zip net-tools ripgrep fd-find jq
```

这部分对应你备忘里的常用工具安装，额外保留了仓库原来脚本里常用的开发机基础命令。

### 2.2 dev

`dev` 组目前会安装这些包：

```bash
build-essential cmake ninja-build pkg-config gdb clang clangd python3-pip python3-venv
```

### 2.3 shell

`shell` 组目前会安装这些包：

```bash
zsh fzf bat zoxide git
```

`--install-shell` 不只是装包，还会继续做下面这些配置：

- 给 `~/.tmux.conf` 追加 `set -g mouse on`
- 克隆 `~/.oh-my-zsh`
- 克隆 `zsh-syntax-highlighting` 和 `zsh-autosuggestions`
- 克隆 `~/.fzf` 并执行 `~/.fzf/install --all`
- 如果 `~/.zshrc` 不存在，使用 `oh-my-zsh` 模板生成
- 设置 `plugins=(git sudo zsh-syntax-highlighting zsh-autosuggestions fzf)`
- 追加 `autoload -U compinit && compinit`
- 追加 `eval "$(zoxide init zsh)"`
- 追加 `fzf` 的 key-bindings / completion
- 给 `~/.bash_profile` 追加 `exec "$(command -v zsh)" -l`

## 3. 🚀 常用命令

```bash
# 查看帮助
./sh/ubuntu-config/ubuntu-config.sh --help

# 只看计划，不实际执行
./sh/ubuntu-config/ubuntu-config.sh --check --all

# 安装基础工具、开发工具和 shell 环境
./sh/ubuntu-config/ubuntu-config.sh --install-base --install-dev --install-shell

# 安装 shell 环境，并补上 CUDA 环境变量
./sh/ubuntu-config/ubuntu-config.sh --install-shell --cuda-home /usr/local/cuda

# 只安装 Miniforge
./sh/ubuntu-config/ubuntu-config.sh --install-miniforge

# 一次性做完整初始化
./sh/ubuntu-config/ubuntu-config.sh --all --cuda-home /usr/local/cuda
```

## 4. 🧭 和原始备忘的对应关系

你贴的备忘里有三块核心内容，这个脚本现在分别这样处理：

### 4.1 常用包 + shell 配置

这部分已经落进脚本：

- 常用包安装
- `tmux` 鼠标模式
- `oh-my-zsh`
- `zsh-syntax-highlighting`
- `zsh-autosuggestions`
- `fzf`
- `zoxide`
- 自动切到 `zsh`

和原文不同的地方只有一处：

- `netcat` 在 Ubuntu 里用 `netcat-openbsd`，这样包名更稳

### 4.2 Miniforge

这部分也已经落进脚本：

- 下载并执行 `Miniforge` 安装脚本
- 默认安装到 `~/miniforge3`
- 给 `~/.zshrc` 追加 `source ~/miniforge3/etc/profile.d/conda.sh`
- 执行 `conda init zsh`
- 追加清华源 channels

如果机器不是 `x86_64`，脚本会按架构自动推导安装包 URL；如果你想手动指定，也可以直接用 `--miniforge-url`。

### 4.3 CUDA 环境变量

这部分改成了显式参数，不会盲目写死：

```bash
./sh/ubuntu-config/ubuntu-config.sh --install-shell --cuda-home /usr/local/cuda
```

脚本会往 `~/.zshrc` 追加：

```bash
export PATH="/usr/local/cuda/bin:$PATH"
export LD_LIBRARY_PATH="/usr/local/cuda/lib64:$LD_LIBRARY_PATH"
```

## 5. ⚠️ 注意

- 这个脚本会改 `~/.tmux.conf`、`~/.zshrc`、`~/.bash_profile`
- `--install-shell` 需要能访问 `gitee.com` 和 `github.com`，因为要克隆 `oh-my-zsh`、插件和 `fzf`
- `--install-miniforge` 需要能访问 `mirror.nju.edu.cn`
- 如果你只想装包，不想改 shell 配置，直接加 `--skip-shell-config`
- `CUDA` 配置只在你明确传 `--cuda-home` 时才会写入
