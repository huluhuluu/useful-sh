# adb-relay-guard.sh

使用脚本 [adb-relay-guard.sh](./adb-relay-guard.sh) 守护 USB ADB进程、并且做`adb forward` 和到远端 SSH 主机的反向端口转发。

> 适用场景：手机通过有线 USB 接在一台 Linux 主机上，远端机器通过 SSH reverse tunnel 访问手机上的 ADB 网络调试端口。

默认端口如下：

| 端口 | 说明 |
| --- | --- |
| `47954` | 手机 `adbd` 的 TCP 端口，同时映射为 USB 主机和远端 SSH 主机上的 ADB 访问端口 |
| `45058` | 额外中转端口，同样通过 `adb forward` 和 `ssh -R` 暴露 |

## 1. 参数说明

| 参数 | 说明 | 默认值 |
| --- | --- | --- |
| `--config FILE` | 多设备配置文件。启用后不能同时使用 `--device`、`--adb-port`、`--relay-port`、`--relay-ports` | - |
| `--adb-port PORT` | 执行 `adb tcpip` 使用的端口，同时创建 `adb forward tcp:PORT tcp:PORT` | `47954` |
| `--relay-port PORT` | 额外创建的中转端口，执行 `adb forward tcp:PORT tcp:PORT`。可以重复传入 | `45058` |
| `--relay-ports PORTS` | 逗号分隔的多个中转端口，例如 `45058,45059,45060` | - |
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

单设备但需要多个中转端口：

```bash
./adb-relay-guard.sh \
  --ssh-host <ssh-host> \
  --device <usb-serial> \
  --adb-port 47954 \
  --relay-ports 45058,45059,45060
```

也可以重复传 `--relay-port`：

```bash
./adb-relay-guard.sh \
  --ssh-host <ssh-host> \
  --device <usb-serial> \
  --adb-port 47954 \
  --relay-port 45058 \
  --relay-port 45059
```

放到 `tmux` 里运行：

```bash
tmux new -s adb-relay './adb-relay-guard.sh --ssh-host <ssh-host>'
```

## 3. 多设备配置文件

先用下面命令确认两台手机的 USB 序列号：

```bash
adb devices -l
```

配置文件示例。顶层块名只是给人看的标签，可以用 `device 1`，也可以用手机型号或用途名：

```yaml
Realme-gp7-pro-speed-8elite:
  serial: <first-usb-serial>
  adb: 47954
  relay: 45058,45059,45060

Redmi-k70-pro-8gen3:
  serial: <second-usb-serial>
  adb: 47964
  relay: 45158,45159,45160
```

启动：

```bash
./adb-relay-guard.sh --ssh-host <ssh-host> --config devices.conf
```

如果更想每台设备一个守护实例，也可以开两个 `tmux` 窗口或 session，分别指定不同设备和端口：

```bash
./adb-relay-guard.sh --ssh-host <ssh-host> --device <first-usb-serial> --adb-port 47954 --relay-ports 45058,45059,45060
./adb-relay-guard.sh --ssh-host <ssh-host> --device <second-usb-serial> --adb-port 47964 --relay-ports 45158,45159,45160
```

多设备模式下，所有 `adb` 端口和 `relay` 端口都必须全局唯一。

## 4. 脚本会做这些事

- 单设备模式下，不指定 `--device` 时从 `adb devices -l` 里选择第一个 `usb:` 设备
- 配置文件模式下，逐个处理每个 `serial`
- 检查 `service.adb.tcp.port`，必要时执行对应设备的 `adb tcpip <adb-port>`
- 确保每个设备都存在对应的 `adb` 端口映射和所有 `relay` 端口映射
- 默认只打印启动配置、修复动作、SSH 启停和错误；加 `-v` 后打印每轮健康检查细节
- 如果端口被脏的 `adb` server 占住，执行 `adb kill-server` 和 `adb start-server` 后重试
- 如果端口被非 `adb` 进程占住，只打印占用信息，不自动杀进程
- 使用一个 SSH 进程同时转发所有配置端口。默认单设备等价于：

```bash
ssh -NT \
  -o ExitOnForwardFailure=yes \
  -o ServerAliveInterval=15 \
  -o ServerAliveCountMax=2 \
  -R 0.0.0.0:47954:127.0.0.1:47954 \
  -R 0.0.0.0:45058:127.0.0.1:45058 \
  <ssh-host>
```

## 5. 注意

- 脚本把 USB ADB 当作控制面，网络 ADB 只作为被转发的目标端口
- `ssh` 断开时会自动重连；`adb forward` 丢失时，主循环会重新建立映射
- `ssh` 进程即使还活着，也可能因为本地 `adb forward` 丢失而输出 `connect_to localhost port ... failed`，所以脚本不会只依赖 SSH 进程状态
- 远端 SSH 主机需要允许远端监听 `0.0.0.0`，通常要确认 SSH server 的 `GatewayPorts` 配置，如果没有设置端口会转发到目标机器的`127.0.0.1`上，开以通过开发防火墙规则+socat转发，来吧目标机器的`localhost`端口映射到局域网IP上，例如
```bash
# 添加防火墙规则
sudo ufw allow in on eno2 from 192.168.124.0/24 to any port 47954 proto tcp
sudo ufw allow in on eno2 from 192.168.124.0/24 to any port 47964 proto tcp
sudo ufw allow in on eno2 from 192.168.124.0/24 to any port 45058 proto tcp
sudo ufw allow in on eno2 from 192.168.124.0/24 to any port 45158 proto tcp

# 转发端口
#!/usr/bin/env bash
set -euo pipefail

BIND_IP="192.168.124.101"
PORTS=(47954 47964 45058 45158)
LOG_DIR="/tmp"

for p in "${PORTS[@]}"; do
  if ss -ltn | grep -qE "(${BIND_IP}:$p|0\.0\.0\.0:$p|\\*:$p)\\b"; then
    echo "skip $p: already listening"
    continue
  fi

  echo "start socat: ${BIND_IP}:${p} -> 127.0.0.1:${p}"
  nohup socat \
    TCP-LISTEN:"$p",bind="$BIND_IP",reuseaddr,fork \
    TCP:127.0.0.1:"$p" \
    >"${LOG_DIR}/socat-${p}.log" 2>&1 &
done

echo "current listeners:"
ss -ltnp | grep -E ':(47954|47964|45058|45158)\b' || true

# 杀掉转发进程
pkill -f 'socat.*TCP-LISTEN:\(47954\|47964\|45058\|45158\)'
```
- 配置文件里的顶层块名只是人类可读标签，真正用于选择手机的是 `serial`
