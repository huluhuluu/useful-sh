# adb-server-relay.sh

使用脚本 [adb-server-relay.sh](./adb-server-relay.sh) 把本机的 ADB **server** 端口通过 SSH 反向隧道暴露给远端，让远端客户端直接使用本机 USB 设备执行 `adb push`。

> 适用场景：手机通过 USB 接在一台 Linux 主机上，远端机器需要跨网络向手机推送构建产物。

这个脚本和 [adb-relay-guard.sh](../adb-relay-guard/) **互补，不是替代**：

- `adb-server-relay.sh`：转发 ADB server，主要用于高速 `push`
- `adb-relay-guard.sh`：转发设备的 `adbd` 端口，用于 `pull`、`shell` 和 `adb forward`

## 依赖检查

主脚本依赖：`adb`、`ssh`、`awk`、`date`、`sleep`。Ubuntu / Debian 可安装：

```bash
sudo apt install adb openssh-client gawk coreutils
```

配套的 [bench-push.sh](./bench-push.sh) 还依赖 `stat`、`md5sum`、`cut` 和 `tail`，这些通常由 `coreutils` 提供。

运行主脚本前，需要满足：

- 手机已通过 USB 连接，并且 `adb devices -l` 显示为 `device`
- 启用 SSH 隧道时，当前主机可以免交互登录 `--ssh-host`
- 远端已经有端口转发或 `socat`，能把局域网地址转到 SSH 反向转发监听的环回地址

默认端口如下：

| 端口 | 说明 |
| --- | --- |
| `5037` | 本机 ADB server 监听端口，作为 SSH 隧道源端口 |
| `47964` | 远端 SSH 反向隧道端口，远端 `adb -H` 连接此端口 |

## 1. 为什么需要这条链路

一次 `adb push` 包含两段通信：

1. ADB client 与 ADB server 之间传输文件
2. ADB server 与手机 `adbd` 之间写入文件

`adb-relay-guard.sh` 把设备的 `adbd` 端口放到远端网络上，第二段通信会受到网络 RTT 影响，跨网络 `push` 的吞吐明显下降。

本脚本把 ADB server 的端口放到 SSH 隧道上，让第一段通信跨网络传输，而第二段通信留在 USB 主机本地。这样可以显著提高跨网络 `push` 速度。

## 2. 参数说明

| 参数 | 说明 | 默认值 |
| --- | --- | --- |
| `--ssh-host HOST` | SSH 反向转发的目标主机。启用 SSH 时必须指定 | - |
| `--remote-port PORT` | 远端绑定的端口，也是远端 `adb -H -P` 的目标端口 | `47964` |
| `--server-port PORT` | 本机 ADB server 监听端口 | `5037` |
| `--ssh-bind ADDR` | `ssh -R` 在远端绑定的地址 | `127.0.0.1` |
| `--device SERIAL` | 健康检查使用的 USB 设备序列号。不指定时选择第一个 USB 设备 | 自动探测 |
| `--guard-config FILE` | 检查 `--remote-port` 是否被 `adb-relay-guard` 配置占用 | - |
| `--interval SEC` | 守护循环检查间隔 | `5` |
| `--once` | 检查一次；启用 SSH 时启动隧道并等待隧道退出 | 关闭 |
| `--no-ssh` | 只检查 ADB server 和 USB 设备，不启动 SSH | 关闭 |
| `-v, --verbose` | 打印每轮健康检查的详细日志 | 关闭 |
| `-h, --help` | 显示帮助信息并退出 | - |

端口必须是 `1` 到 `65535` 的正整数。`--ssh-bind` 默认使用远端环回地址，是因为远端 SSH server 通常关闭了 `GatewayPorts`。

## 3. 常用命令

先在连接手机的 Linux 主机上做一次本机检查：

```bash
./adb-server-relay.sh --no-ssh --once
```

指定 USB 序列号进行检查：

```bash
adb devices -l
./adb-server-relay.sh --device <usb-serial> --no-ssh --once
```

启动完整守护：

```bash
./adb-server-relay.sh --ssh-host <ssh-host>
```

指定端口并打印详细日志：

```bash
./adb-server-relay.sh \
  --ssh-host <ssh-host> \
  --remote-port 47964 \
  --server-port 5037 \
  --device <usb-serial> \
  --verbose
```

建议放在 `tmux` 中运行：

```bash
tmux new -s adb-server-relay './adb-server-relay.sh --ssh-host <ssh-host>'
```

远端直接指定 ADB server：

```bash
adb -H <relay-ip> -P 47964 devices
adb -H <relay-ip> -P 47964 -s <usb-serial> push -z zstd --sync build/libMNN.so /data/local/tmp/
```

也可以使用环境变量，避免每条命令重复 `-H -P`：

```bash
export ADB_SERVER_SOCKET=tcp:<relay-ip>:47964
adb -s <usb-serial> push -z zstd --sync build/libMNN.so /data/local/tmp/
```

## 4. 脚本会做什么

脚本启动后会按以下顺序工作：

- 检查本机 ADB server 是否响应；没有响应时执行 `adb start-server`
- 检查指定的 USB 设备是否在线；未指定序列号时自动选择第一个 USB 设备
- 启动一个 SSH 反向隧道，将远端端口转发到本机 ADB server：

```bash
ssh -NT \
  -o ExitOnForwardFailure=yes \
  -o ServerAliveInterval=15 \
  -o ServerAliveCountMax=2 \
  -R 127.0.0.1:47964:127.0.0.1:5037 \
  <ssh-host>
```

- ADB server 或 USB 设备异常时停止隧道
- 设备恢复或 SSH 断开后，在下一轮检查中重新建立隧道
- **不会调用 `adb kill-server`**，避免影响同一 ADB server 上的其它转发规则

## 5. 与 adb-relay-guard 配合

两条链路的用途不同，推荐按操作类型选择：

| 操作 | 使用方式 |
| --- | --- |
| `push` | 本脚本的 `adb -H <relay-ip> -P 47964` |
| `pull` | `adb-relay-guard.sh` 的 `adb connect` 链路 |
| `shell` | `adb-relay-guard.sh` 的 `adb connect` 链路 |
| `adb forward` | `adb-relay-guard.sh` 的 `adb connect` 链路 |

典型拓扑如下：

```text
push（本脚本）:
  远端 adb client
      | adb -H <relay-ip> -P 47964
      v
  中转机局域网端口
      | socat 或已有端口转发
      v
  中转机 127.0.0.1:47964
      | SSH -R
      v
  USB 主机 127.0.0.1:5037
      | ADB server
      v
  手机 USB

pull / shell / forward（adb-relay-guard）:
  远端 adb connect
      |
      v
  中转机局域网端口
      | socat 或已有端口转发
      v
  USB 主机 adb forward
      |
      v
  手机 USB
```

注意：`adb -H` 看到的是 USB 设备序列号，而 `adb connect` 看到的是网络地址，两条链路中的 `serial` 不是同一个值。

### 端口冲突检查

如果 `adb-relay-guard` 也在使用同一个远端端口，两个 SSH 隧道会互相冲突。可以传入 guard 配置，让脚本启动前检查：

```bash
./adb-server-relay.sh \
  --ssh-host <ssh-host> \
  --remote-port 47964 \
  --guard-config ../adb-relay-guard/devices.conf
```

`--guard-config` 只检查配置中的 `adb`、`relay` 和 `relays` 端口，不会修改配置文件，也不会终止其它进程。

## 6. 性能参考

以下数据来自 Realme gp7 pro（8elite）向手机推送 210.2 MB 构建产物的实测，使用 [bench-push.sh](./bench-push.sh)：

| 模式 | push | verify | total | 有效速率 | 相对基线 |
| --- | --- | --- | --- | --- | --- |
| `connect` 不压缩 | 178.52s | 0.54s | 179.06s | 1.17 MB/s | 1x |
| `connect` + `-z zstd` | 71.91s | 0.56s | 72.47s | 2.90 MB/s | 2.5x |
| `-H` 不压缩 | 24.11s | 6.72s | 30.83s | 6.82 MB/s | 5.8x |
| `-H` + `-z zstd` | 24.55s | 0.59s | 25.15s | 8.36 MB/s | 7.1x |

四组传输都通过了 md5 校验。本表是特定设备、网络和文件的参考，不能视为固定性能保证。

测量时应看 `total`，不要只看 `push`：`push` 返回时数据可能仍在 SSH 或内核缓冲区中，后续的校验阶段才会等待传输完全排空。

运行基准脚本：

```bash
./bench-push.sh <file> [connect-serial] [relay-host:port] [usb-serial]
```

例如：

```bash
./bench-push.sh build/libMNN.so \
  192.168.124.101:47954 \
  192.168.124.101:47964 \
  <usb-serial>
```

脚本会依次测试 `connect` 和 `-H` 两条链路，并分别测试不压缩和 `zstd` 压缩。任意一次 push 失败或 md5 校验失败时，脚本最终返回非零状态。

## 7. 注意事项

- 本脚本主要用于 `push`。`pull`、`shell` 和 `adb forward` 继续使用 `adb-relay-guard.sh` 的链路。
- `--ssh-bind 127.0.0.1` 只允许 SSH 目标主机本机访问。需要让局域网其它机器访问时，必须显式使用 `--ssh-bind 0.0.0.0`，并同时检查 SSH server 的 `GatewayPorts`、防火墙和端口白名单。
- 远端客户端可以通过 ADB 协议发送 `host:kill`，从而杀掉共享的本机 ADB server。能访问该端口的用户也能枚举设备、执行 shell 和写入文件。不要把 ADB server 端口暴露给不可信网络；安全要求较高时，优先让每个客户端使用自己的 SSH 本地转发。
- `adb forward` 规则存在于 USB 主机的 ADB server 中。远端执行 `adb -H ... forward` 后，监听端口仍在 USB 主机上，不会出现在远端客户端的 `localhost`。
- `-z zstd` 是否生效取决于客户端、server 和设备协商出的 feature。不要只用 `adb host-features` 判断压缩是否启用。
- ADB server 重启后 SSH 隧道通常仍然指向正确的端口，但重启瞬间进行中的传输会失败，需要重新执行。
