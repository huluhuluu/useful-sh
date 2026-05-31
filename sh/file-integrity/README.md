# file-integrity.sh

使用脚本 [file-integrity.sh](./file-integrity.sh) 快速计算大文件的完整性标识。默认使用 `sha256`，也支持 `md5`、`sha512`、`blake3`、`xxh64` 等算法。

这个脚本适合两个场景：

- 大文件传输前后确认内容是否一致
- 下载模型、数据集、压缩包后保存一个可复查的 hash

## 1. 🔧 参数说明

| 参数 | 说明 | 默认值 |
| --- | --- | --- |
| `-a, --algo NAME` | hash 算法，可选 `auto`、`md5`、`sha1`、`sha256`、`sha512`、`blake3`、`xxh64` | `sha256` |
| `--check HASH` | 计算后和期望 hash 对比，匹配输出 `check: OK`，不匹配退出码为 `2` | - |
| `--list` | 列出当前机器可用算法和对应命令 | - |
| `-h, --help` | 显示帮助信息并退出 | - |

## 2. 🚀 常用命令

```bash
# 查看帮助
./sh/file-integrity/file-integrity.sh --help

# 默认计算 sha256
./sh/file-integrity/file-integrity.sh ./large.bin

# 计算 md5，兼容很多旧系统或旧校验记录
./sh/file-integrity/file-integrity.sh --algo md5 ./large.bin

# 有 b3sum 时可以用 blake3，通常更适合大文件
./sh/file-integrity/file-integrity.sh --algo blake3 ./large.bin

# 校验文件是否匹配已知 sha256
./sh/file-integrity/file-integrity.sh \
  --check 2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824 \
  ./large.bin
```

输出格式固定为：

```bash
sha256  <hash>  ./large.bin
```

这样后续可以直接复制 hash 部分，或者把整行记录到传输日志里。

## 3. 🧠 算法选择

| 算法 | 适用场景 | 依赖命令 |
| --- | --- | --- |
| `sha256` | 默认推荐，通用性和完整性校验都比较稳 | `sha256sum` / `shasum` / `openssl` |
| `md5` | 和历史系统或已有 md5 记录对齐 | `md5sum` / `md5` / `openssl` |
| `sha512` | 需要更长 hash 时使用 | `sha512sum` / `shasum` / `openssl` |
| `blake3` | 大文件快速校验，适合本机装了 `b3sum` 的环境 | `b3sum` |
| `xxh64` | 只做非安全场景的快速误传检测 | `xxhsum` |

`--algo auto` 会优先使用 `blake3`，没有 `b3sum` 时回退到 `sha256`，再回退到 `md5`。

## 4. ⚠️ 注意

- 脚本按文件流式计算，适合大文件，不会把文件整体读进内存
- `md5` 和 `xxh64` 更适合完整性检测，不适合作为安全校验
- `blake3` 和 `xxh64` 需要额外安装工具；只依赖系统常见工具时直接用默认 `sha256`
