<#
.SYNOPSIS
    Agent Win Remote - stop agent and chisel
.DESCRIPTION
    Call local POST /stop with Bearer token, then stop chisel processes under hermes-win-agent. Do not delete files.
#>
$ErrorActionPreference = "Continue"
$WorkDir = Join-Path $env:TEMP "hermes-win-agent"
$LogDir = Join-Path $WorkDir "logs"

Write-Host ""
Write-Host "========================================="
Write-Host "  Agent Win Remote - stop"
Write-Host "========================================="
Write-Host ""

function Read-LocalConfig {
    $cfgPath = Join-Path $WorkDir "relay-settings.json"
    if (Test-Path $cfgPath) {
        try { return Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { Write-Host "[WARN] relay-settings.json parse failed: $_" -ForegroundColor Yellow }
    } else {
        Write-Host "[WARN] relay-settings.json not found: $cfgPath" -ForegroundColor Yellow
    }
    return [pscustomobject]@{ local_agent_port = 18888; agent_token = "" }
}

function Get-AgentProcess {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like "*hermes-win-agent*agent.ps1*" }
}

function Get-ChiselProcess {
    Get-CimInstance Win32_Process -Filter "Name='chisel.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like "*hermes-win-agent*" }
}

$cfg = Read-LocalConfig
$agentPort = [int]$cfg.local_agent_port
$token = [string]$cfg.agent_token

# gracefully stop agent
try {
    $headers = @{}
    if (-not [string]::IsNullOrWhiteSpace($token)) { $headers["Authorization"] = "Bearer $token" }
    $resp = Invoke-WebRequest -Uri "http://127.0.0.1:${agentPort}/stop" -Method POST -Headers $headers -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
    Write-Host "  agent /stop response: $($resp.StatusCode)"
    Start-Sleep -Seconds 1
} catch {
    Write-Host "  agent /stop unavailable or failed: $($_.Exception.Message)"
}

# if agent still runs, stop only processes matching this directory
$agentProcs = Get-AgentProcess
if ($agentProcs) {
    foreach ($p in $agentProcs) {
        try {
            Stop-Process -Id $p.ProcessId -Force
            Write-Host "  stopped agent powershell PID=$($p.ProcessId)"
        } catch {
            Write-Host "  stop agent PID=$($p.ProcessId) failed: $_" -ForegroundColor Yellow
        }
    }
} else {
    Write-Host "  not found hermes-win-agent related agent process"
}

# stop chisel processes from this directory only
$chiselProcs = Get-ChiselProcess
if ($chiselProcs) {
    foreach ($p in $chiselProcs) {
        try {
            Stop-Process -Id $p.ProcessId -Force
            Write-Host "  stopped chisel PID=$($p.ProcessId)"
        } catch {
            Write-Host "  stop chisel PID=$($p.ProcessId) failed: $_" -ForegroundColor Yellow
        }
    }
} else {
    Write-Host "  not found hermes-win-agent related chisel process"
}

Write-Host ""
Write-Host "LogDir: $LogDir"
Write-Host "[done] stop action finished" -ForegroundColor Green
