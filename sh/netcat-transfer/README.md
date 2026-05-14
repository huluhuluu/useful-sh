# netcat-transfer.sh

使用脚本 [netcat-transfer.sh](./netcat-transfer.sh) 通过 `netcat` 一键压缩传输文件或目录，并在接收端自动解压。📦

## 1. 🧭 模式说明

| 模式 | 说明 |
| --- | --- |
| `send` | 把 `--path` 指向的文件或目录打包、压缩后发送出去 |
| `recv` | 监听 `--port`，接收流并解包到 `--path` 指定目录 |

## 2. 🔧 参数说明

| 参数 | 适用模式 | 说明 | 默认值 |
| --- | --- | --- | --- |
| `--host HOST` | `send` | 接收端主机地址。发送时必须指定 | - |
| `--port PORT` | `send` / `recv` | 传输端口。两端都必须一致 | - |
| `--path PATH` | `send` / `recv` | `send` 时表示要发送的文件或目录；`recv` 时表示解包目标目录 | - |
| `--compression MODE` | `send` / `recv` | 压缩模式，可选 `auto`、`zstd`、`gzip`、`none`。`auto` 会优先选 `zstd` | `auto` |
| `-h, --help` | `send` / `recv` | 显示帮助信息并退出 | - |

## 3. 🚀 常用命令

```bash
./sh/netcat-transfer/netcat-transfer.sh --help
./sh/netcat-transfer/netcat-transfer.sh recv --port 9000 --path /tmp/recv
./sh/netcat-transfer/netcat-transfer.sh send --host 192.168.1.10 --port 9000 --path ./my-dir
./sh/netcat-transfer/netcat-transfer.sh send --host 192.168.1.10 --port 9000 --path ./my-dir --compression zstd
```

## 4. ⚙️ 脚本会做这些事

- 发送端自动把文件或目录打成 `tar` 流
- 支持 `gzip`、`zstd` 和 `none` 三种压缩模式
- 接收端自动监听端口、解压并解包到目标目录
- 默认优先使用 `zstd`，如果本机没有则回退到 `gzip`
- 自动兼容常见 `nc`/`netcat` 的监听参数差异

## 5. ⚠️ 注意

- 传输内容未加密，适合局域网或受信任环境
- 接收前请先在目标机器启动 `recv`，并用 `--path` 指定目标目录
- 如果目标目录不存在，脚本会自动创建
