# nvim-clangd-setup.sh

通过脚本 [nvim-clangd-setup.sh](./nvim-clangd-setup.sh)，为多个项目生成 clangd 原生识别的 `.clangd` 配置。📱

## 依赖检查

脚本需要 Python 3.9+：

```bash
python3 -c 'import sys; assert sys.version_info >= (3, 9); print(sys.version)'
```

Ubuntu / Debian 可安装这些基础依赖：

```bash
sudo apt install python3
```

macOS 的 Python 可使用 `brew install python` 安装。

Python 缺失或版本过低时，脚本会在退出前打印安装提示。生成配置不依赖本机已安装 NDK 或 clangd；实际编辑代码时，clangd 客户端仍需能够找到对应工具链。

## 1. 🔧 参数说明

| 参数 | 说明 | 默认值 |
| --- | --- | --- |
| `--path DIR` | 目标项目目录；脚本会在此目录创建或更新 `.clangd` | 当前目录 |
| `--compdb-dir DIR` | `compile_commands.json` 所在目录，支持相对项目根目录的路径或绝对路径 | `build` |
| `--compile-commands-dir DIR` | `--compdb-dir` 的兼容别名 | - |
| `-h, --help` | 显示帮助信息并退出 | - |

```bash
./sh/nvim-clangd-setup/nvim-clangd-setup.sh --help
./sh/nvim-clangd-setup/nvim-clangd-setup.sh --path /path/to/project
./sh/nvim-clangd-setup/nvim-clangd-setup.sh --compdb-dir out/clangdb
./sh/nvim-clangd-setup/nvim-clangd-setup.sh --compdb-dir /tmp/clangdb
```

## 2. 🧭 脚本会做这些事

- 在 `--path` 指定的项目目录创建或更新 clangd 原生识别的 `.clangd`
- 项目配置写入 `CompileFlags.CompilationDatabase`，Neovim、VS Code 和其它 clangd 客户端均可直接读取
- 相对 `--compdb-dir` 由 clangd 按项目根目录解析；绝对路径会原样写入
- 多次运行可为不同项目生成不同的 `.clangd`，项目之间不会互相覆盖

## 3. 🚀 常用命令

```bash
./sh/nvim-clangd-setup/nvim-clangd-setup.sh \
  --path /path/to/project \
  --compdb-dir project/android/build_64
```
