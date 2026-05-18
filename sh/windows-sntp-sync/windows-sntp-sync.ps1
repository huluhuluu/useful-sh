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
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff zzz'
    Add-Content -LiteralPath $LogPath -Value "[$timestamp] $Message"
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
    $taskCommand = "`"$shellPath`" -NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`""

    & schtasks.exe /Delete /TN $TaskName /F 2>$null
    & schtasks.exe /Delete /TN $StartupTaskName /F 2>$null

    & schtasks.exe /Create /TN $TaskName /SC MINUTE /MO $IntervalMinutes /RU SYSTEM /RL HIGHEST /TR $taskCommand /F
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to create task: $TaskName"
    }

    & schtasks.exe /Create /TN $StartupTaskName /SC ONSTART /RU SYSTEM /RL HIGHEST /DELAY 0000:45 /TR $taskCommand /F
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to create task: $StartupTaskName"
    }

    & schtasks.exe /Run /TN $TaskName
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to start task: $TaskName"
    }

    Write-Host "Installed task: $TaskName"
    Write-Host "Installed task: $StartupTaskName"
    Write-Host "Log: $LogPath"
}

function Uninstall-SyncTasks {
    if (-not (Test-IsAdmin)) {
        throw 'Uninstalling scheduled tasks requires Administrator.'
    }

    & schtasks.exe /Delete /TN $TaskName /F 2>$null
    & schtasks.exe /Delete /TN $StartupTaskName /F 2>$null
    Write-Host "Removed task if present: $TaskName"
    Write-Host "Removed task if present: $StartupTaskName"
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

        $endpoint = [System.Net.IPEndPoint]::new($addresses[0], 123)
        $sendTimeUtc = [DateTime]::UtcNow
        [void] $udp.Send($request, $request.Length, $endpoint)

        $remote = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)
        $response = $udp.Receive([ref] $remote)
        $receiveTimeUtc = [DateTime]::UtcNow

        if ($response.Length -lt 48) {
            throw "Short NTP response from $Server ($($response.Length) bytes)"
        }

        $secondsBytes = $response[40..43]
        $fractionBytes = $response[44..47]
        [Array]::Reverse($secondsBytes)
        [Array]::Reverse($fractionBytes)

        $seconds = [BitConverter]::ToUInt32($secondsBytes, 0)
        $fraction = [BitConverter]::ToUInt32($fractionBytes, 0)
        $milliseconds = ($fraction * 1000.0) / 0x100000000L

        $ntpEpoch = [DateTime]::new(1900, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)
        $serverTimeUtc = $ntpEpoch.AddSeconds($seconds).AddMilliseconds($milliseconds)

        $roundTrip = $receiveTimeUtc - $sendTimeUtc
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

if ($InstallTask) {
    Install-SyncTasks
    exit 0
}

if ($UninstallTask) {
    Uninstall-SyncTasks
    exit 0
}

Sync-TimeViaSntp
