# docker-disk-scan.sh

使用脚本 [docker-disk-scan.sh](./docker-disk-scan.sh) 只读扫描 Docker 容器 writable layer，按容器列出超过阈值的大目录和大文件，并使用容器内部路径展示结果。

脚本默认折叠已经被大目录覆盖的文件。例如模型目录已经超过阈值时，不再逐个列出其中的 `safetensors` 分片；直接放在 `/root` 等通用目录下的大文件仍会单独显示。

## 1. 🔧 参数说明

| 参数 | 说明 | 默认值 |
| --- | --- | --- |
| `-s, --min-size GIB` | 目录和文件的最小大小，单位为 GiB | `5` |
| `-d, --depth LEVEL` | `du` 扫描目录时的最大下钻深度 | `4` |
| `--all-files` | 不折叠文件，显示所有超过阈值的大文件 | 关闭 |
| `-h, --help` | 显示帮助信息并退出 | - |
| `container` | 可选的容器名称或 ID；未指定时扫描全部容器 | 全部容器 |

## 2. 🚀 常用命令

```bash
# 查看帮助
./sh/docker-disk-scan/docker-disk-scan.sh --help

# 扫描全部容器，使用默认的 5 GiB 阈值和 4 层目录深度
./sh/docker-disk-scan/docker-disk-scan.sh

# 只扫描 my-container 容器
./sh/docker-disk-scan/docker-disk-scan.sh my-container

# 查看 my-container 中不小于 1 GiB 的目录和文件，并下钻 5 层
./sh/docker-disk-scan/docker-disk-scan.sh --min-size 1 --depth 5 my-container

# 展开模型分片等已被父目录覆盖的大文件
./sh/docker-disk-scan/docker-disk-scan.sh --all-files my-container
```

脚本会在需要时通过 `sudo -v` 请求权限，也可以显式使用：

```bash
sudo ./sh/docker-disk-scan/docker-disk-scan.sh my-container
```

## 3. 📊 输出说明

每个容器包含两部分：

- `Large directories`：writable layer 中达到阈值的目录，大小包含其子目录和文件
- `Standalone large files`：达到阈值、且没有被更具体的大目录覆盖的文件

目录统计存在父子包含关系，不能直接把每一行相加。例如 `$HOME/models` 已经包含其下模型目录的空间。

使用 `--all-files` 后，`Standalone large files` 会显示所有达到阈值的文件，适合核对模型分片或数据分片。

## 4. 🔍 扫描范围

脚本扫描 Docker GraphDriver 提供的 `UpperDir`，即容器实际新增或修改的 writable layer 数据。

以下内容不在本脚本的统计范围内：

- Docker 镜像只读层
- bind mount 和 named volume
- `/var/lib/docker/containers/*-json.log` 容器日志
- Docker build cache

## 5. ⚠️ 依赖和注意事项

- 需要 Linux、Bash 4+、Docker CLI 和 GNU `du` / `find` / `sort` / `awk` / `numfmt`
- 当前用户需要能够通过 `sudo` 访问 Docker daemon 和 `/var/lib/docker`
- 脚本只执行 `docker inspect`、`du` 和 `find` 等读取操作，不包含删除、截断或 `prune`
- 扫描大 writable layer 会产生磁盘读取负载，建议避开 I/O 敏感任务高峰

可在运行前检查：

```bash
for cmd in bash docker sudo du find sort awk numfmt; do
  command -v "$cmd" >/dev/null || echo "missing: $cmd"
done
```

Ubuntu / Debian 可安装：

```bash
sudo apt install docker.io sudo coreutils findutils gawk
```

如果缺少的正是 `sudo`，需要先以 root 身份执行 `apt-get install sudo`。

必需命令缺失时，脚本会在退出前打印对应的 `apt install` 命令。
