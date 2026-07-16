<#
.SYNOPSIS
    Agent Win Remote Agent - HTTP agent
.DESCRIPTION
    Stage 2 implementation. Listen on 127.0.0.1:<local_agent_port>; protect management APIs with Bearer token.
    No persistence, no service install, no registry writes, no public listening.
#>
param(
    [int]$Port = 18888,
    [string]$ConfigPath = "",
    [string]$WorkDir = "",
    [string]$LogDir = ""
)

$ErrorActionPreference = "Continue"
$script:StartTime = Get-Date
$script:StopRequested = $false
$script:Listener = $null

function Get-DefaultWorkDir {
    return (Join-Path $env:TEMP "hermes-win-agent")
}

function Get-Config {
    param([string]$Path)

    $defaultWorkDir = Get-DefaultWorkDir
    if ([string]::IsNullOrWhiteSpace($Path)) {
        $Path = Join-Path $defaultWorkDir "relay-settings.json"
    }

    $cfg = [ordered]@{
        server_url = ""
        chisel_auth = ""
        agent_token = ""
        server_port = 9000
        remote_port = 19101
        local_agent_port = 18888
        max_output_bytes = 1048576
        max_stdin_run_bytes = 1048576
        stdin_run_default_timeout = 120
        stdin_run_max_timeout = 300
        max_text_upload_bytes = 5242880
        max_download_bytes = 5242880
        default_timeout = 30
        log_dir = (Join-Path $defaultWorkDir "logs")
    }

    if (Test-Path $Path) {
        try {
            $json = Get-Content $Path -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in $json.PSObject.Properties) {
                $cfg[$p.Name] = $p.Value
            }
        } catch {
            # logging is not initialized yet; return defaults and log later
            $cfg.config_error = $_.Exception.Message
        }
    } else {
        $cfg.config_error = "relay-settings.json not found: $Path"
    }

    $cfg.config_path = $Path
    return [pscustomobject]$cfg
}

$script:Config = Get-Config -Path $ConfigPath
if ($Port -eq 18888 -and $script:Config.local_agent_port) { $Port = [int]$script:Config.local_agent_port }
if ([string]::IsNullOrWhiteSpace($WorkDir)) { $WorkDir = Split-Path -Parent $script:Config.config_path }
if ([string]::IsNullOrWhiteSpace($WorkDir)) { $WorkDir = Get-DefaultWorkDir }
if ([string]::IsNullOrWhiteSpace($LogDir)) {
    $LogDir = [Environment]::ExpandEnvironmentVariables([string]$script:Config.log_dir)
}
if ([string]::IsNullOrWhiteSpace($LogDir)) { $LogDir = Join-Path $WorkDir "logs" }

New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$script:WorkDir = $WorkDir
$script:LogDir = $LogDir
$script:LogFile = Join-Path $LogDir "agent.log"
$script:ChiselLogFile = Join-Path $LogDir "chisel-client.log"
$script:StartLogFile = Join-Path $LogDir "start.log"

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )
    $line = "{0} [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"), $Level, $Message
    try { Add-Content -Path $script:LogFile -Value $line -Encoding UTF8 } catch {}
    try { Write-Host $line } catch {}
}

function ConvertTo-JsonText {
    param($Object, [int]$Depth = 8)
    return ($Object | ConvertTo-Json -Depth $Depth -Compress)
}

function Send-Json {
    param(
        [System.Net.HttpListenerContext]$Context,
        $Object,
        [int]$StatusCode = 200
    )
    $json = ConvertTo-JsonText -Object $Object -Depth 10
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $resp = $Context.Response
    $resp.StatusCode = $StatusCode
    $resp.ContentType = "application/json; charset=utf-8"
    $resp.ContentEncoding = [System.Text.Encoding]::UTF8
    $resp.ContentLength64 = $bytes.Length
    $resp.OutputStream.Write($bytes, 0, $bytes.Length)
    $resp.OutputStream.Close()
}

function Send-ErrorJson {
    param(
        [System.Net.HttpListenerContext]$Context,
        [string]$Message,
        [int]$StatusCode = 400,
        [string]$Code = "error",
        [string]$Detail = ""
    )
    $obj = [ordered]@{
        ok = $false
        error = $Message
        code = $Code
        time = (Get-Date).ToString("o")
    }
    if (-not [string]::IsNullOrWhiteSpace($Detail)) { $obj["detail"] = $Detail }
    Send-Json -Context $Context -StatusCode $StatusCode -Object $obj
}

function Read-JsonBody {
    param([System.Net.HttpListenerRequest]$Request, [int]$MaxBytes = 1048576)

    if (-not $Request.HasEntityBody) { return $null }
    $ms = New-Object System.IO.MemoryStream
    $buffer = New-Object byte[] 8192
    $total = 0
    while (($read = $Request.InputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
        $total += $read
        if ($total -gt $MaxBytes) { throw "request body too large" }
        $ms.Write($buffer, 0, $read)
    }
    $text = [System.Text.Encoding]::UTF8.GetString($ms.ToArray())
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return ($text | ConvertFrom-Json)
}

function Read-RawBodyLimited {
    param([System.Net.HttpListenerRequest]$Request, [int]$MaxBytes = 1048576)

    if (-not $Request.HasEntityBody) { return $null }
    $ms = New-Object System.IO.MemoryStream
    $buffer = New-Object byte[] 8192
    $total = 0
    while (($read = $Request.InputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
        $total += $read
        if ($total -gt $MaxBytes) { throw "request body too large (max $MaxBytes bytes)" }
        $ms.Write($buffer, 0, $read)
    }
    $text = [System.Text.Encoding]::UTF8.GetString($ms.ToArray())
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return $text
}

function New-RunDirectory {
    $ts = Get-Date -Format "yyyyMMdd-HHmmss"
    $rand = -join ((48..57) + (97..102) | Get-Random -Count 4 | ForEach-Object { [char]$_ })
    $runId = "$ts-$rand"
    $runDir = Join-Path $env:TEMP "hermes-win-agent\runs\$runId"
    New-Item -ItemType Directory -Force -Path $runDir | Out-Null
    return [pscustomobject]@{ run_id = $runId; path = $runDir }
}

function Invoke-PowerShellFileWithTimeout {
    param(
        [string]$FilePath,
        [string]$Cwd,
        [int]$TimeoutSeconds,
        [int]$MaxOutputBytes
    )

    if ($TimeoutSeconds -le 0) { $TimeoutSeconds = 120 }
    if ($TimeoutSeconds -gt 300) { $TimeoutSeconds = 300 }

    $stdoutPath = "$FilePath.stdout.txt"
    $stderrPath = "$FilePath.stderr.txt"
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $timedOut = $false
    $exitCode = $null

    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = "powershell.exe"
        $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$FilePath`""
        $psi.WorkingDirectory = $Cwd
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true

        $proc = [System.Diagnostics.Process]::Start($psi)

        $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
        $stderrTask = $proc.StandardError.ReadToEndAsync()

        $exited = $proc.WaitForExit($TimeoutSeconds * 1000)
        if (-not $exited) {
            $timedOut = $true
            try { $proc.Kill() } catch {}
            try { $proc.WaitForExit(3000) | Out-Null } catch {}
        }
        try { $exitCode = $proc.ExitCode } catch { $exitCode = $null }

        # wait for stream readers with short timeout
        try { $stdoutTask.Wait(5000) | Out-Null } catch {}
        try { $stderrTask.Wait(5000) | Out-Null } catch {}

        $stdout = if ($stdoutTask.IsCompleted) { $stdoutTask.Result } else { "" }
        $stderr = if ($stderrTask.IsCompleted) { $stderrTask.Result } else { "" }
    } finally {
        $sw.Stop()
    }

    $enc = [System.Text.Encoding]::UTF8
    $totalBytes = $enc.GetByteCount($stdout) + $enc.GetByteCount($stderr)
    $truncated = $false
    if ($totalBytes -gt $MaxOutputBytes) {
        $truncated = $true
        $stdoutBytes = $enc.GetByteCount($stdout)
        if ($stdoutBytes -ge $MaxOutputBytes) {
            $stdout = Truncate-Utf8Text -Text $stdout -MaxBytes $MaxOutputBytes
            $stderr = ""
        } else {
            $remaining = $MaxOutputBytes - $stdoutBytes
            $stderr = Truncate-Utf8Text -Text $stderr -MaxBytes $remaining
        }
    }

    return [ordered]@{
        exit_code = $exitCode
        stdout = $stdout
        stderr = $stderr
        duration_ms = [int]$sw.ElapsedMilliseconds
        timeout = $timedOut
        truncated = $truncated
    }
}

function Handle-StdinRun {
    param($Context)
    $runInfo = $null
    try {
        $shell = Get-QueryParam -Request $Context.Request -Name "shell" -Default "powershell"
        if ($shell.ToLowerInvariant() -ne "powershell") {
            Send-ErrorJson -Context $Context -Message "shell cmd is not supported by stdin-run in this version" -StatusCode 400 -Code "unsupported_shell"
            return
        }

        $timeoutRaw = Get-QueryParam -Request $Context.Request -Name "timeout" -Default ""
        $stdinDefault = if ($script:Config.stdin_run_default_timeout) { [int]$script:Config.stdin_run_default_timeout } else { 120 }
        $stdinMax = if ($script:Config.stdin_run_max_timeout) { [int]$script:Config.stdin_run_max_timeout } else { 300 }
        if ([string]::IsNullOrWhiteSpace($timeoutRaw)) {
            $timeout = $stdinDefault
        } else {
            try { $timeout = [int]$timeoutRaw } catch { $timeout = $stdinDefault }
        }
        if ($timeout -le 0) { $timeout = $stdinDefault }
        if ($timeout -gt $stdinMax) { $timeout = $stdinMax }

        $cwd = Get-QueryParam -Request $Context.Request -Name "cwd" -Default ""
        $cleanupRaw = Get-QueryParam -Request $Context.Request -Name "cleanup" -Default "false"
        $cleanup = ($cleanupRaw.ToLowerInvariant() -eq "true")

        $maxBody = if ($script:Config.max_stdin_run_bytes) { [int]$script:Config.max_stdin_run_bytes } else { 1048576 }
        $maxOutput = [int]$script:Config.max_output_bytes

        $body = Read-RawBodyLimited -Request $Context.Request -MaxBytes $maxBody
        if ($null -eq $body) {
            Send-ErrorJson -Context $Context -Message "empty request body" -StatusCode 400 -Code "empty_body"
            return
        }

        $bodySize = [System.Text.Encoding]::UTF8.GetByteCount($body)
        Write-Log "stdin-run start body_size=$bodySize timeout=$timeout cwd=$cwd"

        $runInfo = New-RunDirectory
        $ps1Path = Join-Path $runInfo.path "main.ps1"
        [System.IO.File]::WriteAllText($ps1Path, $body, [System.Text.Encoding]::UTF8)

        $workCwd = $runInfo.path
        if (-not [string]::IsNullOrWhiteSpace($cwd)) {
            if (Test-Path -LiteralPath $cwd -PathType Container) {
                $workCwd = $cwd
            } else {
                Send-ErrorJson -Context $Context -Message "cwd does not exist" -StatusCode 400 -Code "invalid_cwd" -Detail $cwd
                return
            }
        }

        $result = Invoke-PowerShellFileWithTimeout -FilePath $ps1Path -Cwd $workCwd -TimeoutSeconds $timeout -MaxOutputBytes $maxOutput

        Write-Log "stdin-run done run_id=$($runInfo.run_id) exit=$($result.exit_code) timeout=$($result.timeout) duration_ms=$($result.duration_ms)"

        $response = [ordered]@{
            ok = (-not $result.timeout -and ($result.exit_code -eq 0))
            run_id = $runInfo.run_id
            work_dir = $runInfo.path
            entry = "main.ps1"
            exit_code = $result.exit_code
            stdout = $result.stdout
            stderr = $result.stderr
            duration_ms = $result.duration_ms
            timeout = $result.timeout
            truncated = $result.truncated
            cleanup = $cleanup
        }
        Send-Json -Context $Context -Object $response

        if ($cleanup -and $runInfo -and (Test-Path -LiteralPath $runInfo.path)) {
            try {
                Remove-Item -LiteralPath $runInfo.path -Recurse -Force -ErrorAction SilentlyContinue
                Write-Log "stdin-run cleanup run_id=$($runInfo.run_id)"
            } catch {
                Write-Log "stdin-run cleanup failed: $($_.Exception.Message)" "WARN"
            }
        }
    } catch {
        $errMsg = $_.Exception.Message
        Write-Log "stdin-run error: $errMsg" "ERROR"
        if ($runInfo) {
            Send-Json -Context $Context -Object ([ordered]@{
                ok = $false
                run_id = $runInfo.run_id
                work_dir = $runInfo.path
                entry = "main.ps1"
                exit_code = $null
                stdout = ""
                stderr = $errMsg
                duration_ms = 0
                timeout = $false
                truncated = $false
                cleanup = $false
            })
        } else {
            Send-ErrorJson -Context $Context -Message $errMsg -StatusCode 400 -Code "stdin_run_error"
        }
    }
}

function Test-Auth {
    param([System.Net.HttpListenerRequest]$Request)
    $expected = [string]$script:Config.agent_token
    if ([string]::IsNullOrWhiteSpace($expected)) { return $false }
    $auth = $Request.Headers["Authorization"]
    if ([string]::IsNullOrWhiteSpace($auth)) { return $false }
    return ($auth -eq "Bearer $expected")
}

function Get-QueryParam {
    param(
        [System.Net.HttpListenerRequest]$Request,
        [string]$Name,
        [string]$Default = ""
    )
    $v = $Request.QueryString[$Name]
    if ($null -eq $v) { return $Default }
    return [string]$v
}

function Get-UptimeSeconds {
    return [int][Math]::Floor(((Get-Date) - $script:StartTime).TotalSeconds)
}

function Get-IsAdmin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $p = New-Object Security.Principal.WindowsPrincipal($id)
        return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $null }
}

function Get-SafeCimValue {
    param([scriptblock]$Script)
    try { return (& $Script) } catch { return $null }
}

function Get-AgentInfo {
    $os = Get-SafeCimValue { Get-CimInstance Win32_OperatingSystem }
    $cs = Get-SafeCimValue { Get-CimInstance Win32_ComputerSystem }
    return [ordered]@{
        hostname = $env:COMPUTERNAME
        username = [Environment]::UserName
        domain = $env:USERDOMAIN
        os_caption = if ($os) { $os.Caption } else { $null }
        os_version = if ($os) { $os.Version } else { $null }
        os_architecture = if ($os) { $os.OSArchitecture } else { $null }
        computer_manufacturer = if ($cs) { $cs.Manufacturer } else { $null }
        computer_model = if ($cs) { $cs.Model } else { $null }
        powershell_version = $PSVersionTable.PSVersion.ToString()
        is_admin = Get-IsAdmin
        current_directory = (Get-Location).Path
        system_drive = $env:SystemDrive
        temp_dir = $env:TEMP
        process_id = $PID
        agent_port = $Port
        time = (Get-Date).ToString("o")
    }
}

function Truncate-Utf8Text {
    param([string]$Text, [int]$MaxBytes)
    if ($null -eq $Text) { return "" }
    $enc = [System.Text.Encoding]::UTF8
    $bytes = $enc.GetBytes($Text)
    if ($bytes.Length -le $MaxBytes) { return $Text }
    if ($MaxBytes -le 0) { return "" }
    $cut = New-Object byte[] $MaxBytes
    [Array]::Copy($bytes, 0, $cut, 0, $MaxBytes)
    $s = $enc.GetString($cut)
    # avoid ending with broken UTF-8 replacement char
    return $s.TrimEnd([char]0xFFFD)
}

function Read-TextFileSafe {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return "" }
    try { return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) } catch {
        try { return Get-Content $Path -Raw } catch { return "" }
    }
}

function Invoke-CommandWithTimeout {
    param(
        [string]$Shell,
        [string]$Cmd,
        [string]$Cwd,
        [int]$TimeoutSeconds,
        [int]$MaxOutputBytes
    )

    if ([string]::IsNullOrWhiteSpace($Cmd)) { throw "cmd is required" }
    if ($TimeoutSeconds -le 0) { $TimeoutSeconds = [int]$script:Config.default_timeout }
    if ($TimeoutSeconds -le 0) { $TimeoutSeconds = 30 }
    if ($TimeoutSeconds -gt 3600) { $TimeoutSeconds = 3600 }

    $shellNorm = $Shell.ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($shellNorm)) { $shellNorm = "powershell" }

    if ($shellNorm -eq "powershell") {
        $exe = "powershell.exe"
        $args = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", $Cmd)
    } elseif ($shellNorm -eq "cmd") {
        $exe = "cmd.exe"
        $args = @("/c", $Cmd)
    } else {
        throw "unsupported shell: $Shell"
    }

    if ([string]::IsNullOrWhiteSpace($Cwd)) { $Cwd = $script:WorkDir }
    if (-not (Test-Path -LiteralPath $Cwd -PathType Container)) { throw "cwd not found: $Cwd" }

    $runId = [Guid]::NewGuid().ToString("N")
    $stdoutPath = Join-Path $script:LogDir "run-$runId.stdout.txt"
    $stderrPath = Join-Path $script:LogDir "run-$runId.stderr.txt"
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $timedOut = $false
    $exitCode = $null

    try {
        $p = Start-Process -FilePath $exe -ArgumentList $args -WorkingDirectory $Cwd -NoNewWindow -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
        $exited = $p.WaitForExit($TimeoutSeconds * 1000)
        if (-not $exited) {
            $timedOut = $true
            try { $p.Kill() } catch {}
            try { $p.WaitForExit(3000) | Out-Null } catch {}
        }
        try { $exitCode = $p.ExitCode } catch { $exitCode = $null }
    } finally {
        $sw.Stop()
    }

    $stdout = Read-TextFileSafe -Path $stdoutPath
    $stderr = Read-TextFileSafe -Path $stderrPath
    try { Remove-Item -LiteralPath $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue } catch {}

    $enc = [System.Text.Encoding]::UTF8
    $totalBytes = $enc.GetByteCount($stdout) + $enc.GetByteCount($stderr)
    $truncated = $false
    if ($totalBytes -gt $MaxOutputBytes) {
        $truncated = $true
        $stdoutBytes = $enc.GetByteCount($stdout)
        if ($stdoutBytes -ge $MaxOutputBytes) {
            $stdout = Truncate-Utf8Text -Text $stdout -MaxBytes $MaxOutputBytes
            $stderr = ""
        } else {
            $remaining = $MaxOutputBytes - $stdoutBytes
            $stderr = Truncate-Utf8Text -Text $stderr -MaxBytes $remaining
        }
    }

    return [ordered]@{
        ok = (-not $timedOut -and ($exitCode -eq 0))
        exit_code = $exitCode
        stdout = $stdout
        stderr = $stderr
        duration_ms = [int]$sw.ElapsedMilliseconds
        timeout = $timedOut
        truncated = $truncated
    }
}

function Handle-Health {
    param($Context)
    Send-Json -Context $Context -Object ([ordered]@{
        ok = $true
        name = "hermes-win-agent"
        time = (Get-Date).ToString("o")
        pid = $PID
        uptime_seconds = Get-UptimeSeconds
    })
}

function Handle-Status {
    param($Context)
    Send-Json -Context $Context -Object ([ordered]@{
        ok = $true
        hostname = $env:COMPUTERNAME
        username = [Environment]::UserName
        pid = $PID
        agent_port = $Port
        uptime_seconds = Get-UptimeSeconds
        work_dir = $script:WorkDir
        temp_dir = $env:TEMP
        log_file = $script:LogFile
        chisel_log_file = $script:ChiselLogFile
        time = (Get-Date).ToString("o")
    })
}

function Handle-Info {
    param($Context)
    $info = Get-AgentInfo
    $info["ok"] = $true
    Send-Json -Context $Context -Object $info
}

function Handle-Run {
    param($Context)
    try {
        $body = Read-JsonBody -Request $Context.Request -MaxBytes 65536
        if ($null -eq $body) { throw "JSON body is required" }
        $shell = if ($body.shell) { [string]$body.shell } else { "powershell" }
        $cmd = [string]$body.cmd
        $cwd = if ($body.cwd) { [string]$body.cwd } else { $script:WorkDir }
        $timeout = if ($body.timeout) { [int]$body.timeout } else { [int]$script:Config.default_timeout }
        $max = [int]$script:Config.max_output_bytes
        Write-Log "run shell=$shell timeout=$timeout cwd=$cwd cmd=$cmd"
        $result = Invoke-CommandWithTimeout -Shell $shell -Cmd $cmd -Cwd $cwd -TimeoutSeconds $timeout -MaxOutputBytes $max
        Write-Log "run done exit=$($result.exit_code) timeout=$($result.timeout) duration_ms=$($result.duration_ms)"
        Send-Json -Context $Context -Object $result
    } catch {
        Write-Log "run error: $($_.Exception.Message)" "ERROR"
        Send-ErrorJson -Context $Context -Message $_.Exception.Message -StatusCode 400 -Code "run_error"
    }
}

function Handle-Logs {
    param($Context)
    $type = (Get-QueryParam -Request $Context.Request -Name "type" -Default "agent").ToLowerInvariant()
    $linesRaw = Get-QueryParam -Request $Context.Request -Name "lines" -Default "100"
    try { $lines = [int]$linesRaw } catch { $lines = 100 }
    if ($lines -le 0) { $lines = 100 }
    if ($lines -gt 500) { $lines = 500 }

    $map = @{
        agent = $script:LogFile
        chisel = $script:ChiselLogFile
        start = $script:StartLogFile
    }
    if (-not $map.ContainsKey($type)) {
        Send-ErrorJson -Context $Context -Message "invalid log type" -StatusCode 400 -Code "invalid_log_type"
        return
    }
    $path = $map[$type]
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Send-ErrorJson -Context $Context -Message "log not found: $type" -StatusCode 404 -Code "log_not_found"
        return
    }
    try {
        $content = (Get-Content -LiteralPath $path -Tail $lines -Encoding UTF8) -join "`n"
        Send-Json -Context $Context -Object ([ordered]@{ ok=$true; type=$type; path=$path; lines=$lines; content=$content })
    } catch {
        Send-ErrorJson -Context $Context -Message $_.Exception.Message -StatusCode 500 -Code "log_read_error"
    }
}

function Handle-UploadText {
    param($Context)
    try {
        $body = Read-JsonBody -Request $Context.Request -MaxBytes ([int]$script:Config.max_text_upload_bytes + 65536)
        if ($null -eq $body) { throw "JSON body is required" }
        $path = [string]$body.path
        $content = [string]$body.content
        $encoding = if ($body.encoding) { [string]$body.encoding } else { "utf8" }
        $createDirs = if ($null -ne $body.create_dirs) { [bool]$body.create_dirs } else { $false }
        $overwrite = if ($null -ne $body.overwrite) { [bool]$body.overwrite } else { $false }

        if ([string]::IsNullOrWhiteSpace($path)) { throw "path is required" }
        if ($encoding.ToLowerInvariant() -ne "utf8") { throw "only utf8 encoding is supported" }
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($content)
        if ($bytes.Length -gt [int]$script:Config.max_text_upload_bytes) { throw "content too large" }
        if ((Test-Path -LiteralPath $path) -and -not $overwrite) { throw "file exists and overwrite=false" }
        $parent = Split-Path -Parent $path
        if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
            if ($createDirs) { New-Item -ItemType Directory -Force -Path $parent | Out-Null } else { throw "parent directory not found" }
        }
        [System.IO.File]::WriteAllBytes($path, $bytes)
        Write-Log "upload-text path=$path bytes=$($bytes.Length)"
        Send-Json -Context $Context -Object ([ordered]@{ ok=$true; path=$path; bytes_written=$bytes.Length })
    } catch {
        Write-Log "upload-text error: $($_.Exception.Message)" "ERROR"
        Send-ErrorJson -Context $Context -Message $_.Exception.Message -StatusCode 400 -Code "upload_error"
    }
}

function Handle-Download {
    param($Context)
    try {
        $path = Get-QueryParam -Request $Context.Request -Name "path" -Default ""
        if ([string]::IsNullOrWhiteSpace($path)) { throw "path is required" }
        if ($path -match '[*?]') { throw "wildcards are not allowed" }
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "file not found" }
        $item = Get-Item -LiteralPath $path
        if ($item.Length -gt [int]$script:Config.max_download_bytes) { throw "file too large" }
        $bytes = [System.IO.File]::ReadAllBytes($item.FullName)
        $b64 = [Convert]::ToBase64String($bytes)
        Write-Log "download path=$($item.FullName) bytes=$($bytes.Length)"
        Send-Json -Context $Context -Object ([ordered]@{ ok=$true; path=$item.FullName; content_base64=$b64; bytes=$bytes.Length; encoding="base64" })
    } catch {
        Write-Log "download error: $($_.Exception.Message)" "ERROR"
        Send-ErrorJson -Context $Context -Message $_.Exception.Message -StatusCode 400 -Code "download_error"
    }
}

function Handle-List {
    param($Context)
    try {
        $path = Get-QueryParam -Request $Context.Request -Name "path" -Default $script:WorkDir
        $limitRaw = Get-QueryParam -Request $Context.Request -Name "limit" -Default "200"
        try { $limit = [int]$limitRaw } catch { $limit = 200 }
        if ($limit -le 0) { $limit = 200 }
        if ($limit -gt 500) { $limit = 500 }
        if ([string]::IsNullOrWhiteSpace($path)) { throw "path is required" }
        if (-not (Test-Path -LiteralPath $path -PathType Container)) { throw "directory not found" }
        $items = @()
        foreach ($i in (Get-ChildItem -LiteralPath $path -Force | Select-Object -First $limit)) {
            $items += [ordered]@{
                name = $i.Name
                path = $i.FullName
                type = if ($i.PSIsContainer) { "directory" } else { "file" }
                size = if ($i.PSIsContainer) { $null } else { $i.Length }
                last_write_time = $i.LastWriteTime.ToString("o")
            }
        }
        Send-Json -Context $Context -Object ([ordered]@{ ok=$true; path=(Resolve-Path -LiteralPath $path).Path; items=$items })
    } catch {
        Send-ErrorJson -Context $Context -Message $_.Exception.Message -StatusCode 400 -Code "list_error"
    }
}

function Handle-Stop {
    param($Context)
    Write-Log "stop requested"
    Send-Json -Context $Context -Object ([ordered]@{ ok=$true; message="agent stopping" })
    $script:StopRequested = $true
    try { $script:Listener.Stop() } catch {}
}

function Handle-Help {
    param($Context)
    Send-Json -Context $Context -Object ([ordered]@{
        ok = $true
        name = "hermes-win-agent"
        endpoints = @(
            "GET /health",
            "GET /status",
            "GET /info",
            "POST /stdin-run",
            "POST /run",
            "GET /logs",
            "POST /upload-text",
            "GET /download",
            "GET /list",
            "POST /stop",
            "GET /help"
        )
        notes = [ordered]@{
            stdin_run = "recommended main workflow: submit main.ps1 via HTTP body, execute once, return result"
            run = "short debug commands only (whoami, hostname, Get-Date)"
            stdin_run_usage = "POST /stdin-run with raw PS1 script as body (UTF-8). Query: shell, timeout, cwd, cleanup"
        }
        auth = "Bearer token required except /health and /help"
    })
}

function Route-Request {
    param([System.Net.HttpListenerContext]$Context)
    $req = $Context.Request
    $path = $req.Url.AbsolutePath.ToLowerInvariant().TrimEnd("/")
    if ([string]::IsNullOrWhiteSpace($path)) { $path = "/" }
    $method = $req.HttpMethod.ToUpperInvariant()

    Write-Log "$method $path from $($req.RemoteEndPoint)"

    $public = (($method -eq "GET" -and $path -eq "/health") -or ($method -eq "GET" -and $path -eq "/help"))
    if (-not $public -and -not (Test-Auth -Request $req)) {
        Send-ErrorJson -Context $Context -Message "unauthorized" -StatusCode 401 -Code "unauthorized"
        return
    }

    switch ("$method $path") {
        "GET /health" { Handle-Health -Context $Context; return }
        "GET /help" { Handle-Help -Context $Context; return }
        "GET /status" { Handle-Status -Context $Context; return }
        "GET /info" { Handle-Info -Context $Context; return }
        "POST /run" { Handle-Run -Context $Context; return }
        "POST /stdin-run" { Handle-StdinRun -Context $Context; return }
        "GET /logs" { Handle-Logs -Context $Context; return }
        "POST /upload-text" { Handle-UploadText -Context $Context; return }
        "GET /download" { Handle-Download -Context $Context; return }
        "GET /list" { Handle-List -Context $Context; return }
        "POST /stop" { Handle-Stop -Context $Context; return }
        default { Send-ErrorJson -Context $Context -Message "not found" -StatusCode 404 -Code "not_found"; return }
    }
}

Write-Log "agent starting work_dir=$script:WorkDir log_dir=$script:LogDir port=$Port config=$($script:Config.config_path)"
if ($script:Config.config_error) { Write-Log "config warning: $($script:Config.config_error)" "WARN" }

$script:Listener = [System.Net.HttpListener]::new()
$prefix = "http://127.0.0.1:${Port}/"
$script:Listener.Prefixes.Add($prefix)

try {
    $script:Listener.Start()
    Write-Log "listening on $prefix"
} catch {
    Write-Log "failed to listen on ${prefix}: $($_.Exception.Message)" "ERROR"
    throw
}

try {
    while ($script:Listener.IsListening -and -not $script:StopRequested) {
        try {
            $ctx = $script:Listener.GetContext()
            Route-Request -Context $ctx
        } catch [System.Net.HttpListenerException] {
            if (-not $script:StopRequested) { Write-Log "listener error: $($_.Exception.Message)" "ERROR" }
        } catch {
            Write-Log "request error: $($_.Exception.Message)" "ERROR"
            try { Send-ErrorJson -Context $ctx -Message "internal server error" -StatusCode 500 -Code "internal_error" } catch {}
        }
    }
} finally {
    try { $script:Listener.Close() } catch {}
    Write-Log "agent stopped"
}
