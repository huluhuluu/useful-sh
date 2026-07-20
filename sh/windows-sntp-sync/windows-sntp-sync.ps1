#Requires -Version 5.1
param(
    [string[]] $Servers = @('ntp1.aliyun.com', 'ntp2.aliyun.com', 'ntp.aliyun.com'),
    [int] $TimeoutMilliseconds = 3000,
    [double] $MaxCorrectionSeconds = 300,
    [string] $LogPath = "$env:ProgramData\LocalSntpSync\sntp-sync.log",
    [string] $TaskName = 'Local SNTP Time Sync',
    [string] $StartupTaskName = 'Local SNTP Time Sync Startup',
    [int] $IntervalMinutes = 30,
    [switch] $InstallTask,
    [switch] $UninstallTask,
    [Alias('h')]
    [switch] $Help
)

$ErrorActionPreference = 'Stop'

function Show-Usage {
    @'
Usage:
  .\windows-sntp-sync.ps1 [options]
  .\windows-sntp-sync.ps1 -InstallTask
  .\windows-sntp-sync.ps1 -UninstallTask

What it does:
  1. Queries SNTP/NTP servers from a temporary UDP port
  2. Parses the NTP transmit timestamp
  3. Sets Windows system time through SetSystemTime
  4. Can install scheduled tasks to run at startup and every 30 minutes

Options:
  -Servers HOST[,HOST...]          NTP servers, default: ntp1.aliyun.com, ntp2.aliyun.com, ntp.aliyun.com
  -TimeoutMilliseconds N           UDP receive timeout, default: 3000
  -MaxCorrectionSeconds N          Refuse large corrections, default: 300
  -LogPath PATH                    Sync log path, default: C:\ProgramData\LocalSntpSync\sntp-sync.log
  -InstallTask                     Install scheduled tasks as SYSTEM
  -UninstallTask                   Remove scheduled tasks
  -TaskName NAME                   Interval task name
  -StartupTaskName NAME            Startup task name
  -IntervalMinutes N               Interval task period, default: 30
  -h, --help                       Show this help

Examples:
  .\windows-sntp-sync.ps1 --help
  .\windows-sntp-sync.ps1
  .\windows-sntp-sync.ps1 -Servers ntp1.aliyun.com,ntp2.aliyun.com
  .\windows-sntp-sync.ps1 -InstallTask
  .\windows-sntp-sync.ps1 -UninstallTask
'@
}

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal] $identity
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-SyncLog {
    param([string] $Message)

    $directory = Split-Path -Parent $LogPath
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff zzz'
    Add-Content -LiteralPath $LogPath -Value "[$timestamp] $Message"
}

function ConvertTo-PowerShellLiteral {
    param([string] $Value)

    "'" + $Value.Replace("'", "''") + "'"
}

function Remove-SyncTask {
    param(
        [string] $Name,
        [switch] $Quiet
    )

    & schtasks.exe /Query /TN $Name 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        return $false
    }

    & schtasks.exe /Delete /TN $Name /F 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to remove task: $Name"
    }

    if (-not $Quiet) {
        Write-Host "Removed task: $Name"
    }
    return $true
}

function Get-PowerShellPath {
    $pwsh = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if ($pwsh) {
        return $pwsh.Source
    }

    $powershell = Get-Command powershell.exe -ErrorAction SilentlyContinue
    if ($powershell) {
        return $powershell.Source
    }

    throw 'Unable to find pwsh.exe or powershell.exe'
}

function Install-SyncTasks {
    if (-not (Test-IsAdmin)) {
        throw 'Installing scheduled tasks requires Administrator.'
    }

    $scriptPath = $PSCommandPath
    if (-not $scriptPath) {
        throw 'Unable to resolve current script path.'
    }

    $shellPath = Get-PowerShellPath
    $serverLiterals = @($Servers | ForEach-Object { ConvertTo-PowerShellLiteral $_ })
    $scriptLiteral = ConvertTo-PowerShellLiteral $scriptPath
    $logLiteral = ConvertTo-PowerShellLiteral $LogPath
    $maxCorrection = $MaxCorrectionSeconds.ToString([Globalization.CultureInfo]::InvariantCulture)
    $invocation = "& $scriptLiteral -Servers @($($serverLiterals -join ', ')) " +
        "-TimeoutMilliseconds $TimeoutMilliseconds -MaxCorrectionSeconds $maxCorrection -LogPath $logLiteral"
    $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($invocation))
    $taskCommand = "`"$shellPath`" -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encodedCommand"

    [void] (Remove-SyncTask -Name $TaskName -Quiet)
    [void] (Remove-SyncTask -Name $StartupTaskName -Quiet)

    $createdTasks = @()
    try {
        & schtasks.exe /Create /TN $TaskName /SC MINUTE /MO $IntervalMinutes /RU SYSTEM /RL HIGHEST /TR $taskCommand /F
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to create task: $TaskName"
        }
        $createdTasks += $TaskName

        & schtasks.exe /Create /TN $StartupTaskName /SC ONSTART /RU SYSTEM /RL HIGHEST /DELAY 0000:45 /TR $taskCommand /F
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to create task: $StartupTaskName"
        }
        $createdTasks += $StartupTaskName

        & schtasks.exe /Run /TN $TaskName
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to start task: $TaskName"
        }
    } catch {
        foreach ($CreatedTask in $createdTasks) {
            try {
                [void] (Remove-SyncTask -Name $CreatedTask -Quiet)
            } catch {
                Write-Warning $_.Exception.Message
            }
        }
        throw
    }

    Write-Host "Installed task: $TaskName"
    Write-Host "Installed task: $StartupTaskName"
    Write-Host "Log: $LogPath"
}

function Uninstall-SyncTasks {
    if (-not (Test-IsAdmin)) {
        throw 'Uninstalling scheduled tasks requires Administrator.'
    }

    foreach ($Name in @($TaskName, $StartupTaskName)) {
        if (-not (Remove-SyncTask -Name $Name)) {
            Write-Host "Task not present: $Name"
        }
    }
}

function Get-NtpTime {
    param(
        [string] $Server,
        [int] $Timeout
    )

    $request = [byte[]]::new(48)
    $request[0] = 0x1B

    $udp = [System.Net.Sockets.UdpClient]::new()
    try {
        $udp.Client.ReceiveTimeout = $Timeout
        $udp.Client.SendTimeout = $Timeout

        $addresses = [System.Net.Dns]::GetHostAddresses($Server) |
            Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork }

        if (-not $addresses -or $addresses.Count -eq 0) {
            throw "No IPv4 address resolved for $Server"
        }

        $sendTimeUtc = [DateTime]::UtcNow
        $ntpEpoch = [DateTime]::new(1900, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)
        $sendSecondsTotal = ($sendTimeUtc - $ntpEpoch).TotalSeconds
        $sendWholeSeconds = [math]::Floor($sendSecondsTotal)
        $sendSeconds = [uint32]($sendWholeSeconds % 4294967296.0)
        $sendFraction = [uint32][math]::Floor(($sendSecondsTotal - $sendWholeSeconds) * 4294967296.0)
        $sendSecondsBytes = [BitConverter]::GetBytes($sendSeconds)
        $sendFractionBytes = [BitConverter]::GetBytes($sendFraction)
        [Array]::Reverse($sendSecondsBytes)
        [Array]::Reverse($sendFractionBytes)
        [Array]::Copy($sendSecondsBytes, 0, $request, 40, 4)
        [Array]::Copy($sendFractionBytes, 0, $request, 44, 4)

        $endpoint = [System.Net.IPEndPoint]::new($addresses[0], 123)
        $udp.Connect($endpoint)
        [void] $udp.Send($request, $request.Length)

        $remote = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)
        $response = $udp.Receive([ref] $remote)
        $receiveTimeUtc = [DateTime]::UtcNow

        if ($response.Length -lt 48) {
            throw "Short NTP response from $Server ($($response.Length) bytes)"
        }

        if (-not $remote.Address.Equals($endpoint.Address) -or $remote.Port -ne 123) {
            throw "NTP response came from unexpected endpoint $remote"
        }

        $leap = ($response[0] -shr 6) -band 0x03
        $version = ($response[0] -shr 3) -band 0x07
        $mode = $response[0] -band 0x07
        $stratum = [int] $response[1]
        if ($leap -eq 3) {
            throw "NTP server $Server reports an unsynchronized clock"
        }
        if ($version -lt 3 -or $version -gt 4) {
            throw "Unsupported NTP version from $Server`: $version"
        }
        if ($mode -ne 4) {
            throw "Invalid NTP response mode from $Server`: $mode"
        }
        if ($stratum -lt 1 -or $stratum -gt 15) {
            throw "Invalid NTP stratum from $Server`: $stratum"
        }

        for ($Index = 0; $Index -lt 8; $Index++) {
            if ($response[24 + $Index] -ne $request[40 + $Index]) {
                throw "NTP originate timestamp mismatch from $Server"
            }
        }

        $transmitTimestampNonzero = $false
        for ($Index = 40; $Index -lt 48; $Index++) {
            if ($response[$Index] -ne 0) {
                $transmitTimestampNonzero = $true
                break
            }
        }
        if (-not $transmitTimestampNonzero) {
            throw "NTP response from $Server has an empty transmit timestamp"
        }

        $secondsBytes = $response[40..43]
        $fractionBytes = $response[44..47]
        [Array]::Reverse($secondsBytes)
        [Array]::Reverse($fractionBytes)

        $seconds = [BitConverter]::ToUInt32($secondsBytes, 0)
        $fraction = [BitConverter]::ToUInt32($fractionBytes, 0)
        $milliseconds = ($fraction * 1000.0) / 0x100000000L

        $eraSeconds = 4294967296.0
        $receiveSeconds = ($receiveTimeUtc - $ntpEpoch).TotalSeconds
        $era = [math]::Round(($receiveSeconds - [double]$seconds) / $eraSeconds)
        $fullSeconds = [double]$seconds + ($era * $eraSeconds)
        $serverTimeUtc = $ntpEpoch.AddSeconds($fullSeconds).AddMilliseconds($milliseconds)

        $roundTrip = $receiveTimeUtc - $sendTimeUtc
        if ($roundTrip.TotalMilliseconds -lt 0) {
            throw 'System clock changed while collecting the NTP sample'
        }
        $correctedUtc = $serverTimeUtc.AddTicks([int64]($roundTrip.Ticks / 2))

        [pscustomobject]@{
            Server = $Server
            Address = $remote.Address.ToString()
            UtcTime = $correctedUtc
            ReceiveTimeUtc = $receiveTimeUtc
            RoundTripMilliseconds = [math]::Round($roundTrip.TotalMilliseconds, 3)
        }
    }
    finally {
        $udp.Dispose()
    }
}

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class NativeTime {
    [StructLayout(LayoutKind.Sequential)]
    public struct SYSTEMTIME {
        public ushort Year;
        public ushort Month;
        public ushort DayOfWeek;
        public ushort Day;
        public ushort Hour;
        public ushort Minute;
        public ushort Second;
        public ushort Milliseconds;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool SetSystemTime(ref SYSTEMTIME st);
}
'@

function Set-SystemTimeUtc {
    param([DateTime] $UtcTime)

    $utc = $UtcTime.ToUniversalTime()
    $systemTime = [NativeTime+SYSTEMTIME]::new()
    $systemTime.Year = [ushort] $utc.Year
    $systemTime.Month = [ushort] $utc.Month
    $systemTime.Day = [ushort] $utc.Day
    $systemTime.Hour = [ushort] $utc.Hour
    $systemTime.Minute = [ushort] $utc.Minute
    $systemTime.Second = [ushort] $utc.Second
    $systemTime.Milliseconds = [ushort] $utc.Millisecond

    if (-not [NativeTime]::SetSystemTime([ref] $systemTime)) {
        $errorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw "SetSystemTime failed with Win32 error $errorCode"
    }
}

function Sync-TimeViaSntp {
    if (-not (Test-IsAdmin)) {
        Write-SyncLog 'ERROR: script must run elevated to set system time.'
        throw 'This script must run as Administrator or SYSTEM.'
    }

    $lastError = $null
    foreach ($server in $Servers) {
        try {
            $sample = Get-NtpTime -Server $server -Timeout $TimeoutMilliseconds
            $nowUtc = [DateTime]::UtcNow
            $targetUtc = $sample.UtcTime.AddTicks(($nowUtc - $sample.ReceiveTimeUtc).Ticks)
            $offsetSeconds = ($targetUtc - $nowUtc).TotalSeconds

            if ([math]::Abs($offsetSeconds) -gt $MaxCorrectionSeconds) {
                throw "Refusing correction of $([math]::Round($offsetSeconds, 3))s; limit is $MaxCorrectionSeconds seconds."
            }

            Set-SystemTimeUtc -UtcTime $targetUtc
            Write-SyncLog ("OK server={0} address={1} rtt_ms={2} offset_s={3}" -f `
                $sample.Server, $sample.Address, $sample.RoundTripMilliseconds, [math]::Round($offsetSeconds, 6))
            Write-Host ("Synced via {0} ({1}), offset_s={2}" -f `
                $sample.Server, $sample.Address, [math]::Round($offsetSeconds, 6))
            return
        }
        catch {
            $lastError = $_
            Write-SyncLog ("WARN server={0} error={1}" -f $server, $_.Exception.Message)
        }
    }

    Write-SyncLog ("ERROR all servers failed; last_error={0}" -f $lastError.Exception.Message)
    throw "All servers failed. Last error: $($lastError.Exception.Message)"
}

if ($Help) {
    Show-Usage
    exit 0
}

if ($InstallTask -and $UninstallTask) {
    throw '-InstallTask and -UninstallTask cannot be used together.'
}
if (-not $Servers -or @($Servers | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count -ne $Servers.Count) {
    throw '-Servers must contain at least one non-empty server name.'
}
if ($TimeoutMilliseconds -le 0) {
    throw '-TimeoutMilliseconds must be a positive integer.'
}
if ($MaxCorrectionSeconds -le 0) {
    throw '-MaxCorrectionSeconds must be positive.'
}
if ($IntervalMinutes -lt 1 -or $IntervalMinutes -gt 1439) {
    throw '-IntervalMinutes must be between 1 and 1439.'
}
if ([string]::IsNullOrWhiteSpace($LogPath)) {
    throw '-LogPath must not be empty.'
}
if ([string]::IsNullOrWhiteSpace($TaskName) -or [string]::IsNullOrWhiteSpace($StartupTaskName)) {
    throw 'Scheduled task names must not be empty.'
}

if ($InstallTask) {
    Install-SyncTasks
    exit 0
}

if ($UninstallTask) {
    Uninstall-SyncTasks
    exit 0
}

Sync-TimeViaSntp
