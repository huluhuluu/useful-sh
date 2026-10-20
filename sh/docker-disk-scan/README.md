# docker-disk-scan.sh

使用脚本 [docker-disk-scan.sh](./docker-disk-scan.sh) 只读扫描 Docker 容器 writable layer，以及容器使用的 bind mount / volume 持久化数据。可写层和持久化数据放在对应容器下展示，统一使用容器内部路径；共享来源只扫描一次，再为各容器复用结果。

脚本默认折叠已经被大目录覆盖的文件。例如模型目录已经超过阈值时，不再逐个列出其中的 `safetensors` 分片；直接放在容器顶层目录中的大文件仍会单独显示。

## 1. 🔧 参数说明

| 参数 | 说明 | 默认值 |
| --- | --- | --- |
| `-s, --min-size GIB` | 目录和文件的最小大小，单位为 GiB | `5` |
| `-d, --depth LEVEL` | 目录的最大显示深度；更深内容仍计入上级大小，文件查找不受此限制 | `4` |
| `--all-files` | 不折叠文件，显示所有超过阈值的大文件 | 关闭 |
| `-h, --help` | 显示帮助信息并退出 | - |
| `container` | 可选的容器名称或 ID；扫描选定容器及其挂载，未指定时扫描全部容器 | 全部容器 |

## 2. 🚀 常用命令

```bash
# 查看帮助
./sh/docker-disk-scan/docker-disk-scan.sh --help

# 扫描全部容器，使用默认的 5 GiB 阈值和 4 层目录深度
./sh/docker-disk-scan/docker-disk-scan.sh

# 扫描指定容器及其持久化挂载
./sh/docker-disk-scan/docker-disk-scan.sh my-container

# 查看指定容器中不小于 1 GiB 的目录和文件，并下钻 5 层
./sh/docker-disk-scan/docker-disk-scan.sh --min-size 1 --depth 5 my-container

# 展开模型分片等已被父目录覆盖的大文件
./sh/docker-disk-scan/docker-disk-scan.sh --all-files my-container
```

脚本会在需要时通过 `sudo -v` 请求权限，也可以显式使用：

```bash
sudo ./sh/docker-disk-scan/docker-disk-scan.sh my-container
```

## 3. 📊 输出说明

每个容器的报告按下面的顺序展示：

- `Writable layer`：容器可写层的大目录、大文件
- `Persistent mount: /workspace [bind]` 等：该容器各个 bind / volume 挂载的大目录、大文件，路径映射为容器内部的 `/workspace/code` 等
- 每部分均包含 `Large directories` 和 `Standalone large files`，使用同一套阈值、深度和文件折叠选项

不再单独展示 shared storage 区域或冗长的容器引用列表。示例（大小仅作演示）：

```text
===== my-container | writable=66GiB =====
  Writable layer:
    Large directories:
         59GiB  /root
    ...
  Persistent mount: /workspace [bind]
    Large directories:
        120GiB  /workspace
         80GiB  /workspace/code
    ...
```

共享来源会规范化路径并按设备号/inode 去重。同一文件系统中的父子来源合并扫描，缓存结果；不同文件系统的子来源保留独立扫描。比如 A 的 `/workspace` 与 B 的 `/data` 指向同一来源，只扫描一次，但分别显示在 A、B 的报告下，并映射为各自的容器路径。子目录挂载只显示自己的子树。

`--depth` 对可写层从容器根目录起算，对持久化数据从各自挂载根目录起算。即使共享父目录合并扫描，也会保留子挂载所需的显示深度，不会因合并而漏掉本应显示的目录。

标题中的 `writable=` 只代表可写层大小，不包含持久化数据。共享结果可能出现在多个容器下，因此不能将不同容器的挂载大小直接相加。`Scanned persistent sources` 统计实际扫描的去重来源数量。

挂载源不可访问或扫描失败会在对应容器下标明，并以非零状态退出；socket、设备等非普通文件/目录的挂载会注明跳过。可写层不可用时仍会展示可访问的持久化挂载。指定单个容器时，只展示该容器及其挂载。

目录统计存在父子包含关系，不能直接把每一行相加。例如 `/data/models` 已经包含其下模型目录的空间。

使用 `--all-files` 后，`Standalone large files` 会显示所有达到阈值的文件，适合核对模型分片或数据分片。

## 4. 🔍 扫描范围

脚本扫描 Docker GraphDriver 提供的 `UpperDir`，即容器实际新增或修改的 writable layer 数据，同时读取 `docker inspect .Mounts` 中 bind / volume 的宿主机来源，扫描其持久化数据（包括普通文件挂载）。

扫描使用 `du -x` / `find -xdev`，不跨越文件系统。来源目录内部的其他文件系统只有在它本身也是选定容器的挂载来源时才会单独扫描；不是完整的宿主机磁盘审计。

以下内容不在本脚本的统计范围内：

- Docker 镜像只读层
- tmpfs 等非 bind / volume 挂载
- 未被选定容器引用的 volume
- `/var/lib/docker/containers/*-json.log` 容器日志
- Docker build cache

## 5. ⚠️ 依赖和注意事项

- 需要 Linux、Bash 4+、Docker CLI 和 GNU `du` / `find` / `sort` / `awk` / `numfmt` / `realpath` / `stat`
- 必须在 Docker daemon 所在宿主机运行，并能访问其 UpperDir 和挂载来源；只有 Docker CLI 或远程 Docker context 不够
- root 用户可直接运行；其它用户需要能够通过 `sudo` 访问 Docker daemon 和 `/var/lib/docker`
- 脚本只执行 `docker inspect`、`du` 和 `find` 等读取操作，不包含删除、截断或 `prune`
- 扫描大 writable layer 和持久化目录会产生磁盘读取负载，建议避开 I/O 敏感任务高峰

可在运行前检查：

```bash
for cmd in bash docker du find sort awk numfmt mktemp realpath stat; do
  command -v "$cmd" >/dev/null || echo "missing: $cmd"
done
```

Ubuntu / Debian 可安装：

```bash
sudo apt install docker.io coreutils findutils gawk
```

如果缺少的正是 `sudo`，需要先以 root 身份执行 `apt-get install sudo`。

必需命令缺失时，脚本会在退出前打印对应的 `apt install` 命令。
