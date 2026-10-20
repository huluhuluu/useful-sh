# docker-disk-scan.sh

使用脚本 [docker-disk-scan.sh](./docker-disk-scan.sh) 只读扫描 Docker 容器 writable layer，以及容器使用的 bind mount / volume 持久化数据。可写层和持久化数据放在对应容器下展示，统一使用容器内部路径；根据实际挂载来源识别共享，不按目录名猜测；同一来源只扫描一次，共享来源的其他挂载使用简短引用。

脚本默认折叠已经被大目录覆盖的文件。例如模型目录已经超过阈值时，不再逐个列出其中的 `safetensors` 分片；直接放在容器顶层目录中的大文件仍会单独显示。

## 1. 🔧 参数说明

| 参数 | 说明 | 默认值 |
| --- | --- | --- |
| `-s, --min-size GIB` | 目录和文件的最小大小，单位为 GiB | `5` |
| `-d, --depth LEVEL` | 从容器根目录 / 起算的目录显示深度；更深内容仍计入上级大小，文件查找不受此限制 | `4` |
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

共享判断来自 `docker inspect .Mounts` 的实际来源：规范化宿主机来源路径并按设备号/inode 去重，然后统计引用它的不同容器数量。被本次选定的两个及以上容器引用才标记为 `shared #N`；同一容器的重复挂载不会被误判为跨容器共享。没有任何固定的共享目录名单。

例如两个容器的 `/data` 指向同一来源，会识别为共享；两个容器都有 `/workspace`，但分别指向不同来源，则各自独立展开。同一来源即使挂载到不同名字的容器目录，也会识别为共享。符号链接和硬链接等同源别名不会重复扫描。

共享来源选择挂载路径最浅、能显示完整目录层级的位置展开详情（相同深度时选择元数据中先出现的挂载）。其余位置只显示大小及 `Details: shared #N at container:/mount` 引用，不重复列出目录、文件或长引用列表。引用可能指向后面的容器报告。`--all-files` 控制详情中的文件折叠，共享引用仍保持简短。

父子来源属于范围重叠，不直接视为同一共享来源。它们分别扫描、缓存并标记 `Overlapping source ranges; sizes are not additive.`，避免父来源的扫描错误影响独立的子来源。重叠子树可能被遍历多次，这是保留各自扫描范围和错误状态的代价；来源完全相同时始终只扫描一次。

`--depth` 对可写层和持久化数据统一从容器根目录 `/` 起算：`/` 是第 0 层，`/data` 是第 1 层，`/data/models` 是第 2 层。例如 `--depth 4` 时，`/data` 下最多再显示 3 层目录。共享来源会按所有挂载所需的最大深度扫描，在选定的详情位置按容器内路径过滤；其他位置通过简短引用访问详情。文件查找不受目录深度限制。

标题中的 `writable=` 只代表可写层大小，不包含持久化数据。共享结果可能出现在多个容器下，因此不能将不同容器的挂载大小直接相加。`Scanned persistent sources` 统计成功扫描的精确去重来源数量；`Shared persistent sources` 统计被多个选定容器引用的来源数量。这些计数不是磁盘大小合计，父子重叠来源的大小也不能直接相加。

挂载源不可访问或扫描失败会在对应容器下标明，并以非零状态退出。扫描失败时保留已获取的目录和文件结果，并标记统计不完整、大小可能偏低；不会把空的失败结果当作“没有大文件”。`du` 与 `find` 独立执行，错误会打印失败阶段、扫描来源及最多 5 行具体原因。共享来源的失败也会缓存，避免重复扫描。socket、设备等非普通文件/目录的挂载会注明跳过。可写层不可用时仍会展示可访问的持久化挂载。指定单个容器时，只扫描和展示该容器及其挂载，共享判断也仅针对本次选定的容器。

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
