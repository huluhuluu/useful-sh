# netcat-transfer.sh

使用脚本 [netcat-transfer.sh](./netcat-transfer.sh) 通过 `netcat` 传输一个或多个文件/目录。发送端将路径打包为 `tar` 流，可选择是否压缩；接收端可选择是否解压，并将内容释放到目标目录。📦

## 1. 🧭 执行顺序

必须先在目标机器启动 `recv`，看到 `listening` 提示后，再在源机器执行 `send`：

```text
目标机器：recv 监听端口
                 ↓
源机器：send 连接并发送
```

如果先执行 `send`，目标端口尚未监听，`nc` 通常会立即报连接失败。

## 2. 🔧 参数说明

### 通用参数

| 参数 | 说明 | 默认值 |
| --- | --- | --- |
| `--port PORT` | 传输端口，两端必须一致 | - |
| `--compression MODE` | 兼容旧用法；在 `send` 中等同 `--compress`，在 `recv` 中等同 `--decompress` | 取决于模式 |
| `-h, --help` | 显示帮助信息并退出 | - |

### 发送端

| 参数 | 说明 | 默认值 |
| --- | --- | --- |
| `--host HOST` | 接收端地址 | - |
| `--path PATH...` | 一个或多个文件/目录；可重复，也支持 shell 展开的通配符 | - |
| `--compress MODE` | 压缩方式：`auto`、`zstd`、`gzip`、`none` | `auto` |
| `--no-compress` | 不压缩，只发送 tar 流 | - |

### 接收端

| 参数 | 说明 | 默认值 |
| --- | --- | --- |
| `--path DIR` | 解包目标目录 | - |
| `--decompress MODE` | 期望的压缩方式：`zstd`、`gzip`、`none`；`auto` 按发送端协议头选择 | `none` |
| `--no-decompress` | 期望输入流未压缩，等同 `--decompress none` | 默认行为 |

发送端会在数据流开头写入实际压缩方式。接收端会先读取协议头，再决定是否解压：

- 默认接收端使用 `none`，只接受未压缩流
- 发送端与接收端模式不一致时立即报错，不会解包文件
- `--decompress auto` 会按发送端协议头自动选择解压方式
- 两台机器都必须使用支持该协议头的当前脚本版本

## 3. 🚀 常用命令

### zstd 压缩传输

目标机器先执行：

```bash
./sh/netcat-transfer/netcat-transfer.sh recv \
  --port 9000 \
  --path /tmp/recv \
  --decompress zstd
```

源机器再执行：

```bash
./sh/netcat-transfer/netcat-transfer.sh send \
  --host 192.168.124.1 \
  --port 9000 \
  --path ./large.pkl \
  --compress zstd
```

### 传输多个匹配文件

在 `zsh` 中，通配符会在脚本执行前展开为多个参数，脚本会将它们全部接收：

```bash
./sh/netcat-transfer/netcat-transfer.sh send \
  --host 192.168.124.1 \
  --port 9000 \
  --path ~/**/*.pkl \
  --compress gzip
```

也可以显式列出或重复 `--path`：

```bash
./sh/netcat-transfer/netcat-transfer.sh send \
  --host 192.168.124.1 \
  --port 9000 \
  --path ./a.pkl ./b.pkl \
  --path ./models \
  --compress gzip
```

在 Bash 中递归使用 `**` 前需要启用：

```bash
shopt -s globstar nullglob
```

不要给通配符加引号；`'~/**/*.pkl'` 会作为字面字符串传入，脚本不会自行展开。只匹配 home 顶层时可使用 `~/*.pkl`。

### 不压缩传输

目标机器：

```bash
./sh/netcat-transfer/netcat-transfer.sh recv \
  --port 9000 --path /tmp/recv --no-decompress
```

源机器：

```bash
./sh/netcat-transfer/netcat-transfer.sh send \
  --host 192.168.124.1 --port 9000 --path ./large.bin --no-compress
```

### 自动识别发送端压缩方式

接收端可以明确允许按协议头自动选择：

```bash
./sh/netcat-transfer/netcat-transfer.sh recv \
  --port 9000 --path /tmp/recv --decompress auto
```

如果发送端使用 `gzip`，而接收端保持默认的 `none`，接收端会在解包前停止并输出：

```text
compression mismatch: sender=gzip, receiver=none
nothing was extracted; rerun recv with --decompress gzip or --decompress auto
```

## 4. 📁 多路径打包规则

脚本会计算所有发送路径的共同父目录，并以它为 tar 根目录：

- `$HOME/a.pkl` 和 `$HOME/b.pkl` 会在接收目录中生成 `a.pkl`、`b.pkl`
- `$HOME/a/x.pkl` 和 `$HOME/b/y.pkl` 会保留为 `a/x.pkl`、`b/y.pkl`
- 只发送单个文件或目录时，行为和旧版本一致

这样不会把绝对路径直接写入 tar，也避免所有文件都落到 `root/...` 前缀下。

## 5. ⚠️ 注意

- 接收目录需要当前用户具有写入和进入权限，即目录权限中的 `w+x`
- 传输流没有加密或身份认证，只适合可信局域网或受保护隧道
- 接收端会直接解包发送方提供的 tar 流，只应接收可信发送方的数据
- 发送端的 `auto` 优先使用 `zstd`，没有时回退到 `gzip`
- 接收端默认不解压；使用 `--decompress auto` 时会读取协议头并选择对应工具
- 新协议头与旧脚本的数据流格式不兼容，发送和接收两端应同时更新
- 多个路径可能包含同名相对路径，发送前应检查脚本输出的 `common parent` 和 `source` 列表
