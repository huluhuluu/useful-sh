# codex-skills-bootstrap.sh

使用脚本 [codex-skills-bootstrap.sh](./codex-skills-bootstrap.sh)，通过 `cc-switch` 给 `Codex` 批量安装并启用常用 skills。默认目标是 `codex`，也可以切换到其它 agent。🧩

## 1. 🔧 参数说明

| 参数 | 说明 | 默认值 |
| --- | --- | --- |
| `--app APP` | 目标 agent，可选 `claude`、`codex`、`gemini`、`open-code`、`open-claw` | `codex` |
| `--skill NAME` | 只安装指定 skill，不安装默认列表。可以重复传入，也可以使用逗号分隔 | 默认列表 |
| `--repo REPO` | 先添加或启用额外的 `cc-switch` skill repo，例如 `owner/name` 或 `owner/name@branch` | - |
| `--source SOURCE` | 给非内置 skill 指定 `skills.sh` 对应的 GitHub source | - |
| `--no-install-cc-switch` | 缺少 `cc-switch` 时直接报错，不自动安装 | 关闭 |
| `--dry-run` | 只打印将要执行的命令，不实际安装 | 关闭 |
| `--list-defaults` | 输出默认 skill 列表并退出 | - |
| `-h, --help` | 显示帮助信息并退出 | - |

默认安装下面这些 skills，不包含 `huluhuluu-blog-style`。这些 skill 会先通过 `npx skills add` 从 `skills.sh` 对应的 GitHub source 下载，再导入 `cc-switch` 管理。

| Skill | Source |
| --- | --- |
| `find-skills` | `https://github.com/vercel-labs/skills` |
| `karpathy-guidelines` | `https://github.com/forrestchang/andrej-karpathy-skills` |
| `matplotlib` | `https://github.com/davila7/claude-code-templates` |
| `planning-with-files` | `https://github.com/davila7/claude-code-templates` |
| `ralph-loop` | `https://github.com/andrelandgraf/fullstackrecipes` |
| `readme-generator` | `https://github.com/patricio0312rev/skills` |
| `ui-ux-pro-max` | `https://github.com/davila7/claude-code-templates` |

## 2. 🚀 常用命令

先进入 `useful-sh` 仓库根目录：

```powershell
Set-Location C:\path\to\useful-sh
```

### 2.1 Windows PowerShell

PowerShell 不能直接执行 `.sh`。Windows 原生环境使用 `codex-skills-bootstrap.ps1`：

```powershell
# 默认给 Codex 安装并启用默认列表
powershell -NoProfile -ExecutionPolicy Bypass -File .\sh\codex-skills-bootstrap\codex-skills-bootstrap.ps1

# 切换到其它 agent
powershell -NoProfile -ExecutionPolicy Bypass -File .\sh\codex-skills-bootstrap\codex-skills-bootstrap.ps1 --app claude

# 只安装指定 skills
powershell -NoProfile -ExecutionPolicy Bypass -File .\sh\codex-skills-bootstrap\codex-skills-bootstrap.ps1 --skill matplotlib --skill readme-generator

# 安装非内置 skill 时指定 source
powershell -NoProfile -ExecutionPolicy Bypass -File .\sh\codex-skills-bootstrap\codex-skills-bootstrap.ps1 --skill ralph-setup --source https://github.com/andrelandgraf/fullstackrecipes

# 先看会执行哪些命令
powershell -NoProfile -ExecutionPolicy Bypass -File .\sh\codex-skills-bootstrap\codex-skills-bootstrap.ps1 --dry-run
```

### 2.2 Linux / Git Bash

```bash
# 默认给 Codex 安装并启用默认列表
./sh/codex-skills-bootstrap/codex-skills-bootstrap.sh

# 切换到其它 agent
./sh/codex-skills-bootstrap/codex-skills-bootstrap.sh --app claude

# 只安装指定 skills
./sh/codex-skills-bootstrap/codex-skills-bootstrap.sh --skill matplotlib --skill readme-generator

# 先看会执行哪些命令
./sh/codex-skills-bootstrap/codex-skills-bootstrap.sh --dry-run

# 输出 skill 列表
cc-switch skills list
```

## 3. 🧭 `cc-switch` 安装

脚本会先检测本机是否有 `cc-switch`。

Linux 下如果没有 `cc-switch`，脚本会执行：

```bash
curl -fsSL https://github.com/SaladDay/cc-switch-cli/releases/latest/download/install.sh | bash
```

如果 GitHub 无法直连，需要先手动开启代理，再运行脚本，例如：

```bash
export HTTPS_PROXY=http://127.0.0.1:7890
export HTTP_PROXY=http://127.0.0.1:7890
```

Windows 原生 PowerShell 会通过 `codex-skills-bootstrap.ps1` 自动安装 `cc-switch.exe`。也可以手动安装：

```powershell
$downloadUrl = "https://github.com/SaladDay/cc-switch-cli/releases/latest/download/cc-switch-cli-windows-x64.zip"
$zipPath = "$env:TEMP\cc-switch-cli.zip"
$extractPath = "$env:TEMP\cc-switch-extract"
Invoke-WebRequest -Uri $downloadUrl -OutFile $zipPath
Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force
$binPath = "$env:LOCALAPPDATA\Microsoft\WindowsApps"
if (!(Test-Path $binPath)) { New-Item -ItemType Directory -Path $binPath -Force }
Copy-Item "$extractPath\cc-switch.exe" -Destination $binPath -Force
cc-switch --version
```

PowerShell 访问 GitHub 失败时，先设置代理：

```powershell
$env:HTTPS_PROXY = "http://127.0.0.1:7890"
$env:HTTP_PROXY = "http://127.0.0.1:7890"
```

## 4. ⚙️ 脚本会做这些事

执行顺序如下：

1. 检测当前运行环境：Linux、Windows shell 或 unknown。
2. 检查 `cc-switch` 是否可用。
3. 检查 `npx` 是否可用。
4. 缺少 `cc-switch` 时按环境处理：
   - Linux：执行 `curl -fsSL .../install.sh | bash`
   - Windows PowerShell：下载 release zip 并复制 `cc-switch.exe`
   - Windows shell：提示改用 PowerShell 入口
5. 可选添加或启用额外 skill repo。
6. 对每个 skill 执行 `npx skills add <source> --global --copy --agent <app> --skill <skill> -y`。
7. 执行 `cc-switch skills scan-unmanaged --app <app>` 和 `cc-switch skills import-from-apps <skill>`。
8. 执行 `cc-switch skills enable --app <app> <skill>`。
9. 最后执行 `cc-switch skills sync --app <app>` 并输出 `cc-switch skills list`。

## 5. ⚠️ 注意

- `npx skills add` 需要能访问对应的 GitHub source。网络不通时先开代理，再重跑脚本。
- 传入 `--skill` 会跳过默认列表，只处理手动指定的 skills。
- 脚本会跳过 `huluhuluu-blog-style`，避免覆盖本地写作 skill 的软链接或本地修改。
