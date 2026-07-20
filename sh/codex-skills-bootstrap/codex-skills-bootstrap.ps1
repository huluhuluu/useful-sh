#Requires -Version 5.1
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $CliArgs
)

$ErrorActionPreference = 'Stop'
$App = 'codex'
$Skill = @()
$Repo = @()
$DefaultSource = ''
$NoInstallCcSwitch = $false
$DryRun = $false
$ListDefaults = $false
$Help = $false
$CcSwitchVersion = 'v5.9.2'
$CcSwitchWindowsX64Sha256 = 'cc3111f2566981debed594de1ce69379739a730fbe088b17e206709c34b7314d'

$DefaultSkills = @(
    'find-skills',
    'karpathy-guidelines',
    'matplotlib',
    'planning-with-files',
    'ralph-loop',
    'readme-generator',
    'ui-ux-pro-max'
)

function Show-Usage {
    @'
Usage:
  .\codex-skills-bootstrap.ps1 [options]

Options:
  --app APP                 Target app, default: codex
                            Allowed: claude, codex, gemini, open-code, open-claw
  --skill NAME              Install only the selected skill set.
                            Repeat this option or use comma-separated values.
  --repo REPO               Add or enable an extra cc-switch skill repo first.
                            Example: owner/name or owner/name@branch
  --source SOURCE           Source repository for custom --skill values not in the built-in map.
                            Example: owner/name or https://github.com/owner/name
  --no-install-cc-switch    Do not auto-install cc-switch when it is missing
  --dry-run                 Print commands without running them
  --list-defaults           Print default skills and exit
  -h, --help                Show this help

Examples:
  .\codex-skills-bootstrap.ps1
  .\codex-skills-bootstrap.ps1 --app claude
  .\codex-skills-bootstrap.ps1 --skill matplotlib --skill readme-generator
'@
}

function Read-OptionValue {
    param(
        [string[]] $Tokens,
        [int] $Index,
        [string] $Option
    )

    if ($Index + 1 -ge $Tokens.Count) {
        throw "missing value for $Option"
    }

    $Value = $Tokens[$Index + 1]
    if ($Value -like '-*') {
        throw "missing value for $Option"
    }

    $Value
}

for ($Index = 0; $Index -lt $CliArgs.Count; $Index++) {
    $Arg = $CliArgs[$Index]

    switch ($Arg) {
        '--app' {
            $App = Read-OptionValue -Tokens $CliArgs -Index $Index -Option $Arg
            $Index++
        }
        '--skill' {
            $Skill += Read-OptionValue -Tokens $CliArgs -Index $Index -Option $Arg
            $Index++
        }
        '--repo' {
            $Repo += Read-OptionValue -Tokens $CliArgs -Index $Index -Option $Arg
            $Index++
        }
        '--source' {
            $DefaultSource = Read-OptionValue -Tokens $CliArgs -Index $Index -Option $Arg
            $Index++
        }
        '--no-install-cc-switch' {
            $NoInstallCcSwitch = $true
        }
        '--dry-run' {
            $DryRun = $true
        }
        '--list-defaults' {
            $ListDefaults = $true
        }
        { $_ -in @('-h', '--help') } {
            $Help = $true
        }
        default {
            throw "unknown argument: $Arg"
        }
    }
}

if ($App -notin @('claude', 'codex', 'gemini', 'open-code', 'open-claw')) {
    throw "--app must be one of: claude, codex, gemini, open-code, open-claw"
}

function Expand-Values {
    param([string[]] $Values)

    foreach ($Value in $Values) {
        foreach ($Part in ($Value -split ',')) {
            $Trimmed = $Part.Trim()
            if ($Trimmed) {
                $Trimmed
            }
        }
    }
}

function Invoke-Step {
    param(
        [Parameter(Mandatory = $true)]
        [string[]] $Command
    )

    Write-Host ('+ ' + ($Command -join ' '))
    if ($DryRun) {
        return
    }

    & $Command[0] @($Command[1..($Command.Length - 1)])
    if ($LASTEXITCODE -ne 0) {
        throw "command failed: $($Command -join ' ')"
    }
}

function Get-SkillSource {
    param([string] $SkillName)

    switch ($SkillName) {
        'find-skills' { 'https://github.com/vercel-labs/skills' }
        'karpathy-guidelines' { 'https://github.com/forrestchang/andrej-karpathy-skills' }
        'matplotlib' { 'https://github.com/davila7/claude-code-templates' }
        'planning-with-files' { 'https://github.com/davila7/claude-code-templates' }
        'ui-ux-pro-max' { 'https://github.com/davila7/claude-code-templates' }
        'ralph-loop' { 'https://github.com/andrelandgraf/fullstackrecipes' }
        'readme-generator' { 'https://github.com/patricio0312rev/skills' }
        default {
            if ($DefaultSource) {
                $DefaultSource
            } else {
                throw "no source configured for skill: $SkillName. pass --source owner/repo or use a built-in skill"
            }
        }
    }
}

function Install-CcSwitch {
    if ($NoInstallCcSwitch) {
        throw 'cc-switch is required but not found'
    }

    Write-Host 'cc-switch: not found'
    Write-Host 'installing cc-switch for Windows PowerShell...'
    Write-Host 'if GitHub is not reachable, set HTTPS_PROXY/HTTP_PROXY and rerun this script.'

    $asset = "cc-switch-cli-$CcSwitchVersion-windows-x64.zip"
    $downloadUrl = "https://github.com/SaladDay/cc-switch-cli/releases/download/$CcSwitchVersion/$asset"
    $binPath = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps'

    if ($DryRun) {
        Write-Host "+ download $downloadUrl"
        Write-Host "+ verify sha256 $CcSwitchWindowsX64Sha256"
        Write-Host "+ install cc-switch.exe $binPath"
        return
    }

    $tempPath = Join-Path ([IO.Path]::GetTempPath()) ("cc-switch-install-" + [Guid]::NewGuid().ToString('N'))
    $zipPath = Join-Path $tempPath $asset
    $extractPath = Join-Path $tempPath 'extract'
    $stagedPath = $null
    New-Item -ItemType Directory -Path $tempPath -Force | Out-Null

    try {
        Invoke-WebRequest -Uri $downloadUrl -OutFile $zipPath
        $actualSha256 = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actualSha256 -ne $CcSwitchWindowsX64Sha256) {
            throw "cc-switch archive checksum mismatch. expected=$CcSwitchWindowsX64Sha256 actual=$actualSha256"
        }

        Expand-Archive -LiteralPath $zipPath -DestinationPath $extractPath -Force
        $sourcePath = Join-Path $extractPath 'cc-switch.exe'
        if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
            throw 'cc-switch.exe not found in verified archive'
        }

        if (-not (Test-Path -LiteralPath $binPath)) {
            New-Item -ItemType Directory -Path $binPath -Force | Out-Null
        }

        $targetPath = Join-Path $binPath 'cc-switch.exe'
        $stagedPath = "$targetPath.new.$PID"
        Copy-Item -LiteralPath $sourcePath -Destination $stagedPath -Force
        Move-Item -LiteralPath $stagedPath -Destination $targetPath -Force
    } finally {
        if ($stagedPath) {
            Remove-Item -LiteralPath $stagedPath -Force -ErrorAction SilentlyContinue
        }
        Remove-Item -LiteralPath $tempPath -Recurse -Force -ErrorAction SilentlyContinue
    }

    $env:PATH = "$binPath;$env:PATH"
}

function Ensure-CcSwitch {
    Write-Host 'detected environment: windows-powershell'

    $Command = Get-Command cc-switch -ErrorAction SilentlyContinue
    if ($Command) {
        Write-Host 'cc-switch: found'
        return
    }

    Install-CcSwitch

    if ($DryRun) {
        Write-Host 'dry-run: assuming cc-switch would be available after installation'
        return
    }

    $Command = Get-Command cc-switch -ErrorAction SilentlyContinue
    if (-not $Command) {
        throw 'cc-switch is still not available after installation. Open a new PowerShell or add it to PATH, then rerun this script.'
    }
}

function Ensure-Npx {
    $Command = Get-Command npx -ErrorAction SilentlyContinue
    if ($Command) {
        Write-Host 'npx: found'
        return
    }

    if ($DryRun) {
        Write-Host 'dry-run: npx is not installed; commands will still be printed'
        return
    }

    throw 'npx is required to install skills from skills.sh sources. Install Node.js first, then rerun this script.'
}

function Install-Repo {
    param([string] $RepoName)

    try {
        Invoke-Step -Command @('cc-switch', 'skills', 'repos', 'add', $RepoName)
    } catch {
        Write-Warning "repo add failed, trying to enable existing repo: $RepoName"
        Invoke-Step -Command @('cc-switch', 'skills', 'repos', 'enable', $RepoName)
    }
}

function Install-Skill {
    param([string] $SkillName)

    if ($SkillName -eq 'huluhuluu-blog-style') {
        Write-Host "skip local style skill: $SkillName"
        return
    }

    Write-Host ''
    Write-Host "skill: $SkillName"
    $Source = Get-SkillSource -SkillName $SkillName

    Invoke-Step -Command @('npx', 'skills', 'add', $Source, '--global', '--copy', '--agent', $App, '--skill', $SkillName, '-y')
    Invoke-Step -Command @('cc-switch', 'skills', 'scan-unmanaged', '--app', $App)
    Invoke-Step -Command @('cc-switch', 'skills', 'import-from-apps', $SkillName)
    Invoke-Step -Command @('cc-switch', 'skills', 'enable', '--app', $App, $SkillName)
}

if ($Help) {
    Show-Usage
    exit 0
}

if ($ListDefaults) {
    $DefaultSkills
    exit 0
}

Ensure-CcSwitch
Ensure-Npx

$SelectedSkills = @(Expand-Values -Values $Skill)
if ($SelectedSkills.Count -eq 0) {
    $RequestedSkills = $DefaultSkills
} else {
    $RequestedSkills = $SelectedSkills
}

$RequestedRepos = @(Expand-Values -Values $Repo)

Write-Host "target app: $App"
Write-Host ''

$FailedRepos = @()
foreach ($RepoName in $RequestedRepos) {
    try {
        Install-Repo -RepoName $RepoName
    } catch {
        $FailedRepos += $RepoName
    }
}

$FailedSkills = @()
$SeenSkills = @{}
foreach ($SkillName in $RequestedSkills) {
    if ($SeenSkills.ContainsKey($SkillName)) {
        continue
    }
    $SeenSkills[$SkillName] = $true

    try {
        Install-Skill -SkillName $SkillName
    } catch {
        $FailedSkills += $SkillName
    }
}

Write-Host ''
$FinalFailures = @()
try {
    Invoke-Step -Command @('cc-switch', 'skills', 'sync', '--app', $App)
} catch {
    $FinalFailures += 'cc-switch skills sync'
}

Write-Host ''
Write-Host 'current skills:'
try {
    Invoke-Step -Command @('cc-switch', 'skills', 'list')
} catch {
    $FinalFailures += 'cc-switch skills list'
}

if ($FailedRepos.Count -gt 0 -or $FailedSkills.Count -gt 0 -or $FinalFailures.Count -gt 0) {
    if ($FailedRepos.Count -gt 0) {
        Write-Warning "failed repos: $($FailedRepos -join ' ')"
    }
    if ($FailedSkills.Count -gt 0) {
        Write-Warning "failed skills: $($FailedSkills -join ' ')"
    }
    if ($FinalFailures.Count -gt 0) {
        Write-Warning "failed final steps: $($FinalFailures -join '; ')"
    }
    throw 'check network/proxy and enabled skill repositories, then rerun this script'
}

Write-Host ''
Write-Host 'done'
