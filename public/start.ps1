<#
.SYNOPSIS
    Agent Win Remote - start/stop/status manager
.DESCRIPTION
    Manage agent.ps1 and chisel.exe. No service install, registry changes, or persistence.
#>
param(
    [Parameter(Position=0)]
    [string]$HostIdOrAction = "",
    [ValidateSet("start","stop","restart","status","check")]
    [string]$Action = "start",
    [string]$BaseUrl = "",
    [string]$ConfigUrl = "",
    [string]$HostId = ""
)

$ErrorActionPreference = "Stop"
if ($HostIdOrAction) {
    $validActions = @("start", "stop", "restart", "status", "check")
    if ($validActions -contains $HostIdOrAction.ToLower()) {
        $Action = $HostIdOrAction.ToLower()
    } else {
        $HostId = $HostIdOrAction
    }
}
$WorkDir = Join-Path $env:TEMP "hermes-win-agent"
$LogDir  = Join-Path $WorkDir "logs"

function Write-Banner($title) {
    Write-Host ""
    Write-Host "=========================================" -ForegroundColor Cyan
    Write-Host "  Agent Win Remote - $title" -ForegroundColor Cyan
    Write-Host "=========================================" -ForegroundColor Cyan
    Write-Host ""
}

function Ensure-Dirs {
    New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
    New-Item -ItemType Directory -Force -Path $LogDir  | Out-Null
}

function Download-File($url, $dest) {
    $name = [IO.Path]::GetFileName($dest)
    if ((Test-Path $dest) -and $name -eq "chisel.exe") {
        $existing = Get-Item $dest -ErrorAction SilentlyContinue
        if ($existing -and $existing.Length -gt 1000000) {
            Write-Host "  skip existing: $dest ($($existing.Length) bytes)"
            return
        }
    }

    Write-Host "  download: $url -> $dest"
    $tmp = "$dest.tmp"
    if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }

    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($curl) {
        & curl.exe -L --fail --connect-timeout 15 --max-time 600 --retry 3 --retry-delay 2 -o $tmp $url
        if ($LASTEXITCODE -ne 0) { throw "curl.exe download failed: exit $LASTEXITCODE" }
    } else {
        Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing -TimeoutSec 600 -ErrorAction Stop
    }

    if (-not (Test-Path $tmp)) { throw "download failed: tmp file not found: $tmp" }
    $sz = (Get-Item $tmp).Length
    if ($sz -le 0) { throw "download failed: empty file: $url" }
    Move-Item -Force $tmp $dest
    Write-Host "  OK: $dest ($sz bytes)"
}

function Get-FileHash16 {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return "" }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $stream = [System.IO.File]::OpenRead($Path)
    try {
        $hash = $sha.ComputeHash($stream)
        return ([BitConverter]::ToString($hash) -replace "-","").Substring(0,16).ToLower()
    } finally {
        $stream.Close()
    }
}

function Sync-Files {
    Ensure-Dirs
    if ($ConfigUrl) {
        Download-File $ConfigUrl (Join-Path $WorkDir "relay-settings.json")
    }
    if ($BaseUrl) {
        $baseUrlNorm = $BaseUrl.TrimEnd("/")
        $manifestUrl = "$baseUrlNorm/manifest.json"
        $manifestPath = Join-Path $WorkDir "manifest.json"
        $remoteManifest = $null

        # Try to download manifest for hash comparison
        try {
            Download-File $manifestUrl $manifestPath
            $remoteManifest = Get-Content $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
            Write-Host "  manifest loaded, checking hashes..."
        } catch {
            Write-Host "  manifest not available, downloading all files"
        }

        $files = @("agent.ps1", "chisel.exe", "relay-settings.json", "stop.ps1", "status.ps1", "start.ps1")
        $skipped = 0
        $downloaded = 0
        foreach ($f in $files) {
            if ($f -eq "relay-settings.json" -and $ConfigUrl) { continue }
            $dest = Join-Path $WorkDir $f

            # Check hash if manifest available
            if ($remoteManifest -and $remoteManifest.$f) {
                $localHash = Get-FileHash16 -Path $dest
                if ($localHash -eq $remoteManifest.$f) {
                    $skipped++
                    continue
                }
            }

            Download-File "$baseUrlNorm/$f" $dest
            $downloaded++
        }
        Write-Host "  sync done: $downloaded downloaded, $skipped skipped"
    }
}

function Read-Config {
    $cfgPath = Join-Path $WorkDir "relay-settings.json"
    if (-not (Test-Path $cfgPath)) {
        throw "relay-settings.json not found: $cfgPath"
    }
    $cfg = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($HostId) {
        $hostMap = $cfg.hosts.$HostId
        if (-not $hostMap) { throw "HostId not found in config.hosts: $HostId" }
        if ($hostMap.remote_port) { $cfg.remote_port = [int]$hostMap.remote_port }
        if ($hostMap.local_agent_port) { $cfg.local_agent_port = [int]$hostMap.local_agent_port }
        $cfg | Add-Member -NotePropertyName selected_host_id -NotePropertyValue $HostId -Force
        if ($hostMap.name) { $cfg | Add-Member -NotePropertyName selected_host_name -NotePropertyValue ([string]$hostMap.name) -Force }
    }
    return $cfg
}

function Mask-Secret([string]$s) {
    if ([string]::IsNullOrEmpty($s)) { return "" }
    if ($s.Length -le 10) { return "***" }
    return $s.Substring(0,4) + "..." + $s.Substring($s.Length-4)
}

function Get-AgentProcess {
    $needle = (Join-Path $WorkDir "agent.ps1").Replace("\", "\\")
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like "*hermes-win-agent*agent.ps1*" -or $_.CommandLine -like "*$needle*" }
}

function Get-ChiselProcess {
    Get-CimInstance Win32_Process -Filter "Name='chisel.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like "*hermes-win-agent*" }
}

function Do-Start {
    Write-Banner "start"
    Ensure-Dirs
    Sync-Files

    $cfg = Read-Config
    $agentPort = [int]$cfg.local_agent_port
    $remotePort = [int]$cfg.remote_port
    $serverUrl  = [string]$cfg.server_url
    $chiselAuth = [string]$cfg.chisel_auth
    $cfgPath = Join-Path $WorkDir "relay-settings.json"

    Write-Host "Action:      start"
    if ($cfg.selected_host_id) { Write-Host "HostId:      $($cfg.selected_host_id)" }
    if ($cfg.selected_host_name) { Write-Host "HostName:    $($cfg.selected_host_name)" }
    Write-Host "WorkDir:     $WorkDir"
    Write-Host "AgentPort:   $agentPort"
    Write-Host "RemotePort:  $remotePort"
    Write-Host "ServerUrl:   $serverUrl"
    Write-Host "Auth:        $(Mask-Secret $chiselAuth)"
    Write-Host "Logs:        $LogDir"
    Write-Host ""

    if ($serverUrl -match "PORTAL") {
        Write-Host "[WARN] server_url is placeholder; agent can start; chisel client will be skipped." -ForegroundColor Yellow
    }

    $agentScript = Join-Path $WorkDir "agent.ps1"
    if (-not (Test-Path $agentScript)) { throw "agent.ps1 not found: $agentScript" }

    $existingAgent = Get-AgentProcess
    if ($existingAgent) {
        Write-Host "agent.ps1 already running: $($existingAgent.ProcessId -join ', ')"
    } else {
        Write-Host "start agent.ps1, listening 127.0.0.1:$agentPort ..."
        $agentOut = Join-Path $LogDir "agent.stdout.log"
        $agentErr = Join-Path $LogDir "agent.stderr.log"
        $agentArgs = @(
            "-NoProfile", "-ExecutionPolicy", "Bypass",
            "-File", "`"$agentScript`"",
            "-ConfigPath", "`"$cfgPath`"",
            "-WorkDir", "`"$WorkDir`"",
            "-LogDir", "`"$LogDir`"",
            "-Port", $agentPort
        ) -join " "
        Start-Process -FilePath "powershell.exe" -ArgumentList $agentArgs -WindowStyle Hidden -RedirectStandardOutput $agentOut -RedirectStandardError $agentErr
        Start-Sleep -Seconds 1
        Write-Host "  agent.ps1 start command sent"
    }

    $chiselExe = Join-Path $WorkDir "chisel.exe"
    if (-not (Test-Path $chiselExe)) { throw "chisel.exe not found: $chiselExe" }

    if ($serverUrl -match "PORTAL") {
        Write-Host "[WARN] server_url is placeholder; skip chisel client start" -ForegroundColor Yellow
    } else {
        $existingChisel = Get-ChiselProcess
        if ($existingChisel) {
            Write-Host "chisel.exe already running: $($existingChisel.ProcessId -join ', ')"
        } else {
            Write-Host "start chisel.exe client..."
            $chiselLog = Join-Path $LogDir "chisel-client.log"
            $chiselErr = Join-Path $LogDir "chisel-client.err.log"
            $chiselArgs = "client --auth `"$chiselAuth`" `"$serverUrl`" R:0.0.0.0:${remotePort}:127.0.0.1:${agentPort}"
            Start-Process -FilePath $chiselExe -ArgumentList $chiselArgs -WorkingDirectory $WorkDir -WindowStyle Hidden -RedirectStandardOutput $chiselLog -RedirectStandardError $chiselErr
            Write-Host "  chisel.exe client start command sent"
        }
    }

    Write-Host ""
    Write-Host "[done] start action finished" -ForegroundColor Green
}

function Do-Stop {
    Write-Banner "stop"
    $stopScript = Join-Path $WorkDir "stop.ps1"
    if (Test-Path $stopScript) { & $stopScript } else { Write-Host "[WARN] stop.ps1 not found: $stopScript" -ForegroundColor Yellow }
}

function Do-Restart {
    Do-Stop
    Start-Sleep -Seconds 2
    Do-Start
}

function Do-Status {
    Write-Banner "status"
    $statusScript = Join-Path $WorkDir "status.ps1"
    if (Test-Path $statusScript) { & $statusScript } else { Write-Host "[WARN] status.ps1 not found: $statusScript" -ForegroundColor Yellow }
}

function Do-Check {
    Write-Banner "check"
    Ensure-Dirs
    if ($BaseUrl -or $ConfigUrl) { Sync-Files }
    $cfgPath     = Join-Path $WorkDir "relay-settings.json"
    $agentScript = Join-Path $WorkDir "agent.ps1"
    $chiselExe   = Join-Path $WorkDir "chisel.exe"

    Write-Host "Check:"
    Write-Host "  PowerShell: $($PSVersionTable.PSVersion)"
    Write-Host "  WorkDir:    $WorkDir"
    Write-Host ""

    if (Test-Path $cfgPath) {
        Write-Host "  [PASS] relay-settings.json exists"
        $cfg = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
        Write-Host "  [PASS] relay-settings.json parse ok"
        if ([string]$cfg.server_url -match "PORTAL") { Write-Host "  [WARN] server_url is placeholder" -ForegroundColor Yellow } else { Write-Host "  [PASS] server_url configured" }
        $port = [int]$cfg.local_agent_port
        $listening = Get-NetTCPConnection -LocalAddress 127.0.0.1 -LocalPort $port -ErrorAction SilentlyContinue
        if ($listening) { Write-Host "  [INFO] agent port ${port} is listening" } else { Write-Host "  [INFO] agent port ${port} is not listening" }
    } else {
        Write-Host "  [FAIL] relay-settings.json not found" -ForegroundColor Red
    }

    if (Test-Path $agentScript) { Write-Host "  [PASS] agent.ps1 exists" } else { Write-Host "  [FAIL] agent.ps1 not found" -ForegroundColor Red }
    if (Test-Path $chiselExe) { Write-Host "  [PASS] chisel.exe exists" } else { Write-Host "  [FAIL] chisel.exe not found" -ForegroundColor Red }

    Write-Host ""
    Write-Host "[done] check action finished" -ForegroundColor Green
}

switch ($Action) {
    "start"   { Do-Start }
    "stop"    { Do-Stop }
    "restart" { Do-Restart }
    "status"  { Do-Status }
    "check"   { Do-Check }
}
