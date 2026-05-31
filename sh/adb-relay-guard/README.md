# adb-relay-guard.sh

使用脚本 [adb-relay-guard.sh](./adb-relay-guard.sh) 守护 USB ADB、`adb forward` 和到远端 SSH 主机的反向端口转发。这个场景里手机通过有线 USB 接在一台 Linux 主机上，远端机器通过 SSH reverse tunnel 访问手机上的 ADB 网络调试端口。

默认端口如下：

| 端口 | 说明 |
| --- | --- |
| `47954` | 手机 `adbd` 的 TCP 端口，同时映射为 USB 主机和远端 SSH 主机上的 ADB 访问端口 |
| `45058` | 额外中转端口，同样通过 `adb forward` 和 `ssh -R` 暴露 |

## 1. 参数说明

| 参数 | 说明 | 默认值 |
| --- | --- | --- |
| `--adb-port PORT` | 执行 `adb tcpip` 使用的端口，同时创建 `adb forward tcp:PORT tcp:PORT` | `47954` |
| `--relay-port PORT` | 额外创建的中转端口，执行 `adb forward tcp:PORT tcp:PORT` | `45058` |
| `--ssh-host HOST` | SSH 反向转发的目标主机。启用 SSH 时必须指定 | - |
| `--ssh-bind ADDR` | `ssh -R` 在远端监听的地址 | `0.0.0.0` |
| `--device SERIAL` | 指定 USB ADB 设备序列号。不指定时自动选择第一个带 `usb:` 的设备 | 自动探测 |
| `--interval SEC` | 守护循环检查间隔 | `5` |
| `--once` | 只修复一次 ADB 和端口映射 | 关闭 |
| `--no-ssh` | 不启动 SSH 反向转发，只处理本机 ADB | 关闭 |
| `-v, --verbose` | 打印健康轮询的详细日志 | 关闭 |
| `-h, --help` | 显示帮助信息并退出 | - |

## 2. 常用命令

先在连接手机 USB 的 Linux 主机上做一次本机检查：

```bash
./adb-relay-guard.sh --once --no-ssh
adb forward --list
```

确认 `47954` 和 `45058` 都出现在 `adb forward --list` 之后，再启动完整守护：

```bash
./adb-relay-guard.sh --ssh-host <ssh-host>
./adb-relay-guard.sh --ssh-host <ssh-host> -v
```

放到 `tmux` 里运行：

```bash
tmux new -s adb-relay './adb-relay-guard.sh --ssh-host <ssh-host>'
```

## 3. 脚本会做这些事

- 从 `adb devices -l` 里选择第一个 `usb:` 设备
- 检查 `service.adb.tcp.port`，必要时执行 `adb tcpip 47954`
- 确保存在两条映射：`adb forward tcp:47954 tcp:47954` 和 `adb forward tcp:45058 tcp:45058`
- 默认只打印启动配置、修复动作、SSH 启停和错误；加 `-v` 后打印每轮健康检查细节
- 如果端口被脏的 `adb` server 占住，执行 `adb kill-server` 和 `adb start-server` 后重试
- 如果端口被非 `adb` 进程占住，只打印占用信息，不自动杀进程
- 使用一个 SSH 进程同时转发两个端口：

```bash
ssh -NT \
  -o ExitOnForwardFailure=yes \
  -o ServerAliveInterval=15 \
  -o ServerAliveCountMax=2 \
  -R 0.0.0.0:47954:127.0.0.1:47954 \
  -R 0.0.0.0:45058:127.0.0.1:45058 \
  <ssh-host>
```

## 4. 注意

- 脚本把 USB ADB 当作控制面，网络 ADB 只作为被转发的目标端口
- `ssh` 断开时会自动重连；`adb forward` 丢失时，主循环会重新建立映射
- `ssh` 进程即使还活着，也可能因为本地 `adb forward` 丢失而输出 `connect_to localhost port ... failed`，所以脚本不会只依赖 SSH 进程状态
- 远端 SSH 主机需要允许远端监听 `0.0.0.0`，通常要确认 SSH server 的 `GatewayPorts` 配置
