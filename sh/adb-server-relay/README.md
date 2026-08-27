# adb-server-relay.sh

使用脚本 [adb-server-relay.sh](./adb-server-relay.sh) 把本机的 ADB **server** socket 通过 SSH 反向隧道暴露给远端，让远端用 `adb -H` 直连本机 server，从而获得高速 `push`。

> 适用场景：手机通过有线 USB 接在一台 Linux 主机上，远端机器跨广域网做 `adb push`，但速率远低于链路带宽。

和 [adb-relay-guard.sh](../adb-relay-guard/) **互补，不是替代**。两个一起跑：这条链路专门用于 `push`，`pull` / `shell` / `adb forward` 继续走 adb-relay-guard 的 `adb connect` 链路。

默认端口如下：

| 端口 | 说明 |
| --- | --- |
| `5037` | 本机 ADB server 监听端口，被转发的源 |
| `47964` | 远端绑定端口，`adb -H` 的目标。选这个端口的原因见第 5 节 |

## 1. 为什么要单独做这条链路

`adb` 有两种协议，性能特性差一个数量级：

| 协议 | 位置 | 帧格式 | 受限于 |
| --- | --- | --- | --- |
| ① | client ↔ server | 十六进制长度前缀请求，之后是裸字节流 | TCP 窗口 ÷ RTT，即**链路带宽** |
| ② | server ↔ adbd | 分组（`A_WRTE` / `A_OKAY` / `A_CLSE`） | **停等**：每个 `A_WRTE` 等一个 `A_OKAY`，即 RTT |

协议②每写一次就要等一次确认，吞吐由延迟决定，和带宽几乎无关。能放宽这个限制的 `delayed_ack` feature **不在本设备协商出的 feature 集里**，所以升级客户端修不好。

`adb-relay-guard` 转发的是设备自己的 adbd 端口，等于把**协议②放到广域网上**，push 就固定在 1.1 MB/s，给多少带宽都没用。

这个脚本转发的是 **server 端口**，把**协议①放到广域网上**，协议②退回 USB，RTT 是微秒级，停等的代价可以忽略。

## 2. 实测速率

Realme gp7 pro（8elite），210.2 MB 真实构建产物 `libMNNConvertDeps.so`（zlib 压缩率 2.56x），用 [bench-push.sh](./bench-push.sh) 测：

| 模式 | push | verify | total | 有效速率 | 相对基线 |
| --- | --- | --- | --- | --- | --- |
| `connect` 不压（基线） | 178.52s | 0.54s | 179.06s | 1.17 MB/s | 1x |
| `connect` + `-z zstd` | 71.91s | 0.56s | 72.47s | 2.90 MB/s | **2.5x** |
| `-H` 不压 | 24.11s | 6.72s | 30.83s | 6.82 MB/s | **5.8x** |
| `-H` + `-z zstd` | 24.55s | 0.59s | 25.15s | 8.36 MB/s | **7.1x** |

四组全部 md5 校验通过。参考值：本机 USB 直连 push 上限 38.7 MB/s。

**只看 total。** `-H` 不压那一行 verify 花了 6.72s，其余三行只要 0.5s——push 返回时缓冲区里还压着数据，是在 verify 期间排空的。单看 push 时长会高估。

**`-H` 下压缩收益有限（只有 1.23x），远低于文件的 2.56x 压缩率。** 两次 push 耗时几乎相同（24.11s vs 24.55s），说明瓶颈已经不在广域网链路上了：210 MB 压到 82 MB，若仍是链路受限应该快 2.5x。24s 传 210 MB 约 8.7 MB/s，而本机 USB 上限 38.7 MB/s，也不是 USB。推断是客户端 zstd 压缩成了 CPU 瓶颈——省下的传输时间被压缩本身吃掉。这是推断，未做 CPU profile。

结论：**结构改动（`-H`）是主要收益，压缩是次要的。** 反过来在 `connect` 路径上压缩收益显著（2.5x），因为那里瓶颈确实在链路。

`pull` 方向没有用这套方法重测。旧测量显示 `connect` pull 约 10 MB/s、`-H` pull 约 1–3 MB/s，两种模式是镜像关系，但那批数字用的是小文件，可能同样有缓冲假象，**当作方向性参考而非准确值**。保持 `pull` 走 `adb connect` 的建议不变。

压缩率因文件而异：`.so` 2.27–2.69x，可执行文件 3.36x，但 int4 的 `.mnn.weight` 只有 1.14x——权重文件用 `--sync` 跳过，不要压。

## 3. 参数说明

| 参数 | 说明 | 默认值 |
| --- | --- | --- |
| `--ssh-host HOST` | SSH 反向转发的目标主机。启用 SSH 时必须指定 | - |
| `--remote-port PORT` | `ssh -R` 在远端绑定的端口，`adb -H` 的目标端口 | `47964` |
| `--server-port PORT` | 本机 ADB server 端口，被转发的源 | `5037` |
| `--ssh-bind ADDR` | `ssh -R` 在远端监听的地址 | `127.0.0.1` |
| `--device SERIAL` | 健康检查用的 USB ADB 设备序列号。不指定时自动选择第一个带 `usb:` 的设备 | 自动探测 |
| `--guard-config FILE` | 如果该配置文件里有设备占用 `--remote-port`，拒绝启动 | - |
| `--interval SEC` | 守护循环检查间隔 | `5` |
| `--once` | 检查一次后启动隧道并等待，不进守护循环 | 关闭 |
| `--no-ssh` | 不启动 SSH 反向转发，只做本机检查 | 关闭 |
| `-v, --verbose` | 打印健康轮询的详细日志 | 关闭 |
| `-h, --help` | 显示帮助信息并退出 | - |

`--ssh-bind` 默认是 `127.0.0.1`，和 adb-relay-guard 的默认值 `0.0.0.0` 不同。因为远端 sshd 的 `GatewayPorts` 通常是关的，`ssh -R` 只能绑环回，要靠远端已有的 socat 桥到局域网。

## 4. 常用命令

先做一次本机检查，确认 server 和设备都正常：

```bash
./adb-server-relay.sh --no-ssh --once
```

再启动完整守护：

```bash
./adb-server-relay.sh --ssh-host cpu \
  --remote-port 47964 \
  --guard-config ../adb-relay-guard/devices.conf
```

放到 `tmux` 里运行：

```bash
tmux new -s adb-server-relay './adb-server-relay.sh --ssh-host cpu --remote-port 47964 --guard-config ../adb-relay-guard/devices.conf'
```

远端使用。注意 serial 是 **USB 序列号**，不是 `ip:port`：

```bash
adb -H 192.168.124.101 -P 47964 devices
adb -H 192.168.124.101 -P 47964 -s <usb-serial> push -z zstd --sync build/libMNN.so /data/local/tmp/
```

每条命令都带 `-H -P` 很啰嗦，可以用环境变量：

```bash
export ADB_SERVER_SOCKET=tcp:192.168.124.101:47964
adb -s <usb-serial> push -z zstd --sync build/libMNN.so /data/local/tmp/
```

## 5. 拓扑和端口选择

两条链路并存：

```
push（本脚本）:
  远端[adb -H client] --局域网--> cpu:192.168.124.101:47964
                                    |  socat（已有，无需改动）
                                    v
                                  cpu:127.0.0.1:47964
                                    ^  ssh -R（本脚本建立）
  设备 <--USB-- 本机[adb server :5037] ----+

pull / shell / forward（adb-relay-guard，原样不动）:
  远端[adb connect] --局域网--> cpu:192.168.124.101:47954
                                    |  socat
                                    v
                                  cpu:127.0.0.1:47954
                                    ^  ssh -R
  设备 <--USB-- 本机[adb forward tcp:47954] ----+
```

**为什么是 47964。** 中转机 `cpu` 的 INPUT 链有端口白名单，且没有 sudo，开不了新端口。从远端实测（同二层网段）：

| 目标 | 结果 |
| --- | --- |
| `192.168.124.101:47954` / `:45058` / `:47964` / `:45158` | 通 |
| `192.168.124.101:47955` / `:45059` / `:5037` / `:6037` | 不通 |
| `172.28.7.174:` 任意端口 | 不通 |

每个失败的用例都在中转机上用 `ss` 确认过监听存在，所以是过滤，不是配置错误。

`47964` 和 `45158` 在白名单里，是因为 `adb-relay-guard/devices.conf` 给**第二台设备**（`Redmi-k70-pro-8gen3`）预留了它们，而当前运行的是 `devices_8elite.conf`，只有一台 Realme，所以这两个端口是空的。中转机上的 socat 已经在做 `192.168.124.101:47964 -> 127.0.0.1:47964`，复用它意味着**中转机零改动**：不改白名单、不重启 socat。

`--guard-config` 就是为这件事准备的：传入 guard 的配置文件，如果那台设备会来抢这个端口，脚本直接拒绝启动。

## 6. 脚本会做这些事

- 不指定 `--device` 时从 `adb devices -l` 里选择第一个 `usb:` 设备
- 检查本机 ADB server 是否响应，不响应才 `adb start-server`
- **绝不调用 `adb kill-server`**，因为 adb-relay-guard 共用同一个 server，杀掉会连带拆掉生产链路的 `adb forward` 规则
- 传了 `--guard-config` 时做启动前冲突检查
- 用一个 SSH 进程做反向转发，等价于：

```bash
ssh -NT \
  -o ExitOnForwardFailure=yes \
  -o ServerAliveInterval=15 \
  -o ServerAliveCountMax=2 \
  -R 127.0.0.1:47964:127.0.0.1:5037 \
  <ssh-host>
```

- 健康检查失败（server 起不来或设备掉了）时主动停掉隧道，恢复后重建
- 默认只打印启动配置、修复动作、SSH 启停和错误；加 `-v` 打印每轮细节

## 7. 注意

**只用于 `push`。** 旧测量显示 `pull` 走这条链路会明显变慢（约 1–3 MB/s，对 `adb connect` 的约 10 MB/s），但那批数字用小文件测的、没排除缓冲假象，只能当方向性参考。`pull` 和 `shell` 留在原链路。真要确认，用 `bench-push.sh` 的同样方法重测。

**插上第二台设备会冲突。** 如果把 guard 切到 `devices.conf` 并接上 `Redmi-k70-pro-8gen3`，它会来抢 `47964`。先停掉本脚本或换一个白名单内的端口。`--guard-config` 把静默冲突变成启动报错。

**远端客户端可以 `adb kill-server` 杀掉共用的 server。** 协议①包含 `host:kill`，而本机这个 server 是 adb-relay-guard 依赖的同一个。任何能连到 `192.168.124.101:47964` 的人都能拆掉生产链路、枚举所有设备、开 root shell、往设备上写文件。脚本自己绝不调用 `kill-server`，但拦不住远端客户端。这是"在局域网上共享 adb server"这件事固有的暴露面——如果这点重要，改成每个客户端自己 `ssh -L`，别对局域网开放。

**`adb forward` 规则开在本机，不在客户端。** forward 规则存在 server 里，所以远端执行 `adb -H ... forward tcp:N` 时，监听端口开在本机（USB 主机）上，客户端的 `localhost:N` 是空的。依赖本机 `adb forward` 访问设备服务的测试脚本，必须继续走 `adb connect` 链路。

**两条链路的 serial 不同。** `-H` 看到的是 USB 序列号，`adb connect` 看到的是 `ip:port`。同时用两条链路的脚本要能按命令分流。

**`-z` 会静默降级。** adb 28.x 和 37.x 的 `ADB_SERVER_VERSION` 都是 41，新客户端不会杀掉旧 server，只会挂上去，然后 `-z zstd` 变成空操作且**不报错**。用 `adb features`（协商结果）确认，**不要用 `adb host-features`**（客户端静态表，升级后一直显示新的，会骗人）。

**server 重启后隧道会自愈，但传输会断。** `ssh -R` 转发的是端口号，新 server 仍然绑 `5037`，所以隧道本身不用重建；但重启瞬间正在进行的 push 会失败，重试即可。
