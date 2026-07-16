<#
.SYNOPSIS
    Agent Win Remote - status view
.DESCRIPTION
    Read-only operation; do not modify anything.
#>
$ErrorActionPreference = "Continue"
$WorkDir = Join-Path $env:TEMP "hermes-win-agent"
$LogDir  = Join-Path $WorkDir "logs"

Write-Host ""
Write-Host "========================================="
Write-Host "  Agent Win Remote - 状态查看"
Write-Host "========================================="
Write-Host ""

function Mask-Secret([string]$s) {
    if ([string]::IsNullOrEmpty($s)) { return "" }
    if ($s.Length -le 10) { return "***" }
    return $s.Substring(0,4) + "..." + $s.Substring($s.Length-4)
}

function Get-AgentProcess {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like "*hermes-win-agent*agent.ps1*" }
}

function Get-ChiselProcess {
    Get-CimInstance Win32_Process -Filter "Name='chisel.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like "*hermes-win-agent*" }
}

function Test-LocalPort([int]$Port) {
    return [bool](Get-NetTCPConnection -LocalAddress 127.0.0.1 -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
}

function Test-RemoteHealth([string]$Url) {
    try {
        $r = Invoke-WebRequest -UseBasicParsing -Uri $Url -TimeoutSec 5 -ErrorAction Stop
        return ($r.StatusCode -eq 200)
    } catch {
        return $false
    }
}

$cfgPath = Join-Path $WorkDir "relay-settings.json"
$cfg = $null
$agentPort = 18888
$remotePort = 19101
$serverUrl = ""
$publicUrl = ""
if (Test-Path $cfgPath) {
    try {
        $cfg = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $agentPort = [int]$cfg.local_agent_port
        $remotePort = [int]$cfg.remote_port
        $serverUrl = [string]$cfg.server_url
        if ($serverUrl -match '^https?://([^/:]+)') {
            $publicUrl = "http://$($Matches[1]):$remotePort"
        }
    } catch {
        Write-Host "[警告] relay-settings.json 解析失败：$_" -ForegroundColor Yellow
    }
} else {
    Write-Host "[警告] 未找到 relay-settings.json：$cfgPath" -ForegroundColor Yellow
}

$agentProcs = @(Get-AgentProcess)
$chiselProcs = @(Get-ChiselProcess)
$agentListening = Test-LocalPort $agentPort
$healthOk = $false
if ($agentListening) { $healthOk = Test-RemoteHealth "http://127.0.0.1:$agentPort/health" }

$agentState = if ($agentProcs.Count -gt 0 -and $agentListening -and $healthOk) { "运行中" } else { "已停止/异常" }
$chiselState = if ($chiselProcs.Count -gt 0) { "运行中" } else { "已停止" }
$portState = if ($agentListening) { "监听中" } else { "未监听" }
$healthState = if ($healthOk) { "正常" } else { "不可用" }

Write-Host "状态摘要："
Write-Host "  Agent：       $agentState"
Write-Host "  Chisel：      $chiselState"
Write-Host "  本地端口：    127.0.0.1:$agentPort $portState"
Write-Host "  本地健康：    $healthState"
if ($publicUrl) { Write-Host "  Hermes访问：  $publicUrl" }
Write-Host "  工作目录：    $WorkDir"
Write-Host "  日志目录：    $LogDir"
Write-Host ""

if ($cfg) {
    Write-Host "配置摘要："
    Write-Host "  server_url：       $serverUrl"
    Write-Host "  chisel_auth：      $(Mask-Secret ([string]$cfg.chisel_auth))"
    Write-Host "  agent_token：      $(Mask-Secret ([string]$cfg.agent_token))"
    Write-Host "  remote_port：      $remotePort"
    Write-Host "  local_agent_port： $agentPort"
    Write-Host ""
}

Write-Host "文件检查："
$files = @("agent.ps1", "chisel.exe", "relay-settings.json", "stop.ps1", "status.ps1", "menu.bat")
foreach ($f in $files) {
    $fp = Join-Path $WorkDir $f
    if (Test-Path $fp) {
        $sz = (Get-Item $fp).Length
        Write-Host "  [存在] $f ($sz bytes)"
    } else {
        Write-Host "  [缺失] $f"
    }
}
Write-Host ""

Write-Host "Agent 进程："
if ($agentProcs.Count -gt 0) {
    foreach ($p in $agentProcs) { Write-Host "  PID=$($p.ProcessId) $($p.Name)" }
} else {
    Write-Host "  无"
}
Write-Host ""

Write-Host "Chisel 进程："
if ($chiselProcs.Count -gt 0) {
    foreach ($p in $chiselProcs) { Write-Host "  PID=$($p.ProcessId) $($p.Name)" }
} else {
    Write-Host "  无"
}
Write-Host ""

Write-Host "端口检查："
Write-Host "  127.0.0.1:$agentPort -> $portState"
Write-Host "  远程端口：$remotePort（在中继服务器 上监听，只有 chisel 连接成功后才会出现）"
Write-Host ""

Write-Host "最近日志："
$agentLog = Join-Path $LogDir "agent.log"
$chiselErr = Join-Path $LogDir "chisel-client.err.log"
if (Test-Path $chiselErr) {
    Write-Host "-------- chisel-client.err.log 最近 30 行 --------"
    Get-Content $chiselErr -Tail 30 -Encoding UTF8
} else {
    Write-Host "未找到 chisel-client.err.log"
}
if (Test-Path $agentLog) {
    Write-Host "-------- agent.log 最近 30 行 --------"
    Get-Content $agentLog -Tail 30 -Encoding UTF8
} else {
    Write-Host "未找到 agent.log"
}

Write-Host ""
Write-Host "[完成] 状态查看结束（只读，不会修改系统）" -ForegroundColor Green
