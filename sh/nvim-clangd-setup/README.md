# nvim-clangd-setup.sh

通过脚本 [nvim-clangd-setup.sh](./nvim-clangd-setup.sh)，自动探测 Android NDK，并为多个项目生成交叉编译场景下的 `.clangd` 配置。📱

## 依赖检查

脚本需要 Python 3.9+ 和基础文件查找命令：

```bash
python3 -c 'import sys; assert sys.version_info >= (3, 9); print(sys.version)'
for cmd in find sort; do
  command -v "$cmd" >/dev/null || echo "missing: $cmd"
done
```

Ubuntu / Debian 可安装这些基础依赖：

```bash
sudo apt install python3 findutils coreutils
```

还必须提前准备好 Android NDK，且 NDK 中应存在可执行的 `toolchains/llvm/prebuilt/*/bin/clang` 和 `clangd`。可通过环境变量让脚本探测，或使用 `--ndk-path DIR` 指定；本文档不提供 Android NDK 安装步骤。

## 1. 🔧 参数说明

| 参数 | 说明 | 默认值 |
| --- | --- | --- |
| `--path DIR` | 目标项目目录；脚本会在此目录创建或更新 `.clangd` | 当前目录 |
| `--ndk-path DIR` | 手动指定 Android NDK 根目录。指定后会跳过自动探测 | 自动探测 |
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

- 自动从 `ANDROID_NDK`、`ANDROID_NDK_ROOT`、`ANDROID_NDK_HOME`、`NDK_ROOT`、`NDK_HOME`、`ANDROID_SDK_ROOT`、`ANDROID_HOME` 等环境变量中探测 NDK
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
