# android-clangd-setup.sh

通过脚本 [android-clangd-setup.sh](./android-clangd-setup.sh)，自动探测 Android NDK 路径，并为目标项目补齐交叉编译场景下的 `clangd` 配置。📱

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

macOS 的 Python 可使用 `brew install python` 安装。

基础命令缺失或 Python 版本过低时，脚本会在退出前打印安装提示。还必须提前准备好 Android NDK，且 NDK 中应存在可执行的 `toolchains/llvm/prebuilt/*/bin/clang` 和 `clangd`。可通过环境变量让脚本探测，或使用 `--ndk-path DIR` 指定；本文档不提供 Android NDK 安装步骤。

## 1. 🔧 参数说明

| 参数 | 说明 | 默认值 |
| --- | --- | --- |
| `--path DIR` | 目标项目目录。脚本会在这个目录里写入或更新 `.vscode/settings.json` 和 `.clangd` | 当前目录 |
| `--ndk-path DIR` | 手动指定 Android NDK 根目录。指定后会跳过自动探测 | 自动探测 |
| `--compdb-dir DIR` | `compile_commands.json` 所在目录，支持相对目标项目的路径或绝对路径 | `build` |
| `--compile-commands-dir DIR` | `--compdb-dir` 的兼容别名 | - |
| `-h, --help` | 显示帮助信息并退出 | - |

```bash
./sh/android-clangd-setup/android-clangd-setup.sh --help
./sh/android-clangd-setup/android-clangd-setup.sh
./sh/android-clangd-setup/android-clangd-setup.sh --path /path/to/project
./sh/android-clangd-setup/android-clangd-setup.sh --ndk-path /path/to/android-ndk
./sh/android-clangd-setup/android-clangd-setup.sh --compdb-dir out/clangdb
./sh/android-clangd-setup/android-clangd-setup.sh --compdb-dir /tmp/clangdb
```

## 2. 🧭 脚本会做这些事

- 自动从 `ANDROID_NDK`、`ANDROID_NDK_ROOT`、`ANDROID_NDK_HOME`、`NDK_ROOT`、`NDK_HOME`、`ANDROID_SDK_ROOT`、`ANDROID_HOME` 等环境变量中探测 NDK
- 在目标目录创建或更新 `.vscode/settings.json` 和 `.clangd`
- 只覆盖和 `clangd` 相关的字段，保留已有的其他配置
- 检查目标目录写权限、NDK 目录结构、`clang`/`clangd` 可执行状态
- 相对 `--compdb-dir` 会写成 VS Code 的 `${workspaceFolder}/<dir>`；绝对路径会原样写入
- 如果目标目录中的 `compile_commands.json` 不存在，会提示但不会直接失败
- 默认作用于当前目录，必要时用 `--path` 指定任意项目目录

## 3. 🚀 常用命令

```bash
./sh/android-clangd-setup/android-clangd-setup.sh --help
```
