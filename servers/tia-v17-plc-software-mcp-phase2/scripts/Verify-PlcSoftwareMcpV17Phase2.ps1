param(
    [string]$WorkspaceRoot = $(if ($env:TIA_MCP_WORKSPACE_ROOT) { $env:TIA_MCP_WORKSPACE_ROOT } else { 'A:\project\TIA_V17_MCP_workspace_20260605_211635' }),
    [int]$Port = $(if ($env:TIA_MCP_HTTP_PORT) { [int]$env:TIA_MCP_HTTP_PORT } else { 8770 }),
    [string]$ApiKey = $(if ($env:TIA_MCP_HTTP_API_KEY) { $env:TIA_MCP_HTTP_API_KEY } else { 'codex-test-key' }),
    [int]$ChildTimeoutSec = $(if ($env:TIA_MCP_CHILD_TIMEOUT_SEC) { [int]$env:TIA_MCP_CHILD_TIMEOUT_SEC } else { 1800 }),
    [int]$MaxPortalProcesses = $(if ($env:TIA_MCP_MAX_PORTAL_PROCESSES) { [int]$env:TIA_MCP_MAX_PORTAL_PROCESSES } else { 12 }),
    [switch]$AllowHighPortalLoad,
    [switch]$ToolSurfaceOnly,
    [switch]$ReuseExistingTechnologyObjectFixture
)

[Console]::InputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)
chcp 65001 > $null
$ErrorActionPreference = 'Stop'

$ProductRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$SourceRoot = Join-Path $ProductRoot 'tools\tiaportal-mcp\src\TiaMcpServer'
$ProjectFile = Join-Path $SourceRoot 'TiaMcpServer.V17.csproj'
$BuildOutput = Join-Path $SourceRoot 'bin-v17\Release\net48'
$RuntimeDir = Join-Path $ProductRoot 'runtime'
$RuntimeExe = Join-Path $RuntimeDir 'TiaMcpServer.exe'
$ReportsDir = Join-Path $ProductRoot 'reports\latest'
$ChildLogDir = Join-Path $ReportsDir 'child-logs'
$ManifestPath = Join-Path $ProductRoot 'manifest\tools-list.phase2.json'
$SummaryJson = Join-Path $ReportsDir 'summary.json'
$SummaryMd = Join-Path $ReportsDir 'summary.md'
$ToolSurfaceJson = Join-Path $ReportsDir 'tool-surface.json'
$E2EResultsJson = Join-Path $ReportsDir 'e2e-results.json'
$ProgressJsonl = Join-Path $ReportsDir 'phase2-progress.jsonl'
$HttpStdoutLog = Join-Path $ReportsDir 'tia-http.phase2.stdout.log'
$HttpStderrLog = Join-Path $ReportsDir 'tia-http.phase2.stderr.log'
$HttpPidFile = Join-Path $ReportsDir 'tia-http.phase2.pid'
$BaseUrl = "http://127.0.0.1:$Port/mcp"
$ProtocolVersion = '2025-03-26'

New-Item -ItemType Directory -Force -Path $ReportsDir | Out-Null
New-Item -ItemType Directory -Force -Path $ChildLogDir | Out-Null
New-Item -ItemType Directory -Force -Path $RuntimeDir | Out-Null
foreach ($staleReport in @($SummaryJson, $SummaryMd, $E2EResultsJson, $ProgressJsonl)) {
    if (Test-Path -LiteralPath $staleReport) {
        Remove-Item -LiteralPath $staleReport -Force
    }
}

function Write-Step {
    param([string]$Message)
    Write-Host "[二期验证] $Message"
}

function Write-Phase2Progress {
    param(
        [Parameter(Mandatory = $true)][string]$Stage,
        [Parameter(Mandatory = $true)][string]$Status,
        [string]$Detail = '',
        [object]$Data = $null
    )

    $item = [ordered]@{
        timestamp = (Get-Date).ToString('o')
        stage = $Stage
        status = $Status
        detail = $Detail
    }
    if ($null -ne $Data) {
        $item.data = $Data
    }

    $item | ConvertTo-Json -Depth 30 -Compress | Add-Content -LiteralPath $ProgressJsonl -Encoding UTF8
}

function Invoke-BuildAndSyncRuntime {
    if (-not (Test-Path -LiteralPath $ProjectFile)) {
        throw "未找到 V17 项目文件：$ProjectFile"
    }

    $stopScript = Join-Path $ProductRoot 'scripts\Stop-PlcSoftwareMcpV17Phase2.ps1'
    if (Test-Path -LiteralPath $stopScript) {
        try { & pwsh -NoProfile -ExecutionPolicy Bypass -File $stopScript } catch {}
    }

    $buildStdout = Join-Path $ReportsDir 'dotnet-build.stdout.log'
    $buildStderr = Join-Path $ReportsDir 'dotnet-build.stderr.log'
    Write-Step "构建 V17 服务：$ProjectFile"
    $process = Start-Process -FilePath 'dotnet' `
        -ArgumentList @('build', $ProjectFile, '-c', 'Release') `
        -WindowStyle Hidden `
        -RedirectStandardOutput $buildStdout `
        -RedirectStandardError $buildStderr `
        -PassThru
    $process.WaitForExit()

    if ($process.ExitCode -ne 0) {
        $stderr = if (Test-Path -LiteralPath $buildStderr) { (Get-Content -LiteralPath $buildStderr -Encoding UTF8 -Tail 80) -join [Environment]::NewLine } else { '' }
        $stdout = if (Test-Path -LiteralPath $buildStdout) { (Get-Content -LiteralPath $buildStdout -Encoding UTF8 -Tail 80) -join [Environment]::NewLine } else { '' }
        throw "dotnet build 失败，ExitCode=$($process.ExitCode)。$stderr$([Environment]::NewLine)$stdout"
    }

    if (-not (Test-Path -LiteralPath (Join-Path $BuildOutput 'TiaMcpServer.exe'))) {
        throw "构建成功但未找到输出：$(Join-Path $BuildOutput 'TiaMcpServer.exe')"
    }

    $runtimeFull = [System.IO.Path]::GetFullPath($RuntimeDir)
    $productFull = [System.IO.Path]::GetFullPath($ProductRoot)
    if (-not $runtimeFull.StartsWith($productFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "拒绝清理 runtime，路径不在产品目录内：$runtimeFull"
    }

    Write-Step "同步 runtime：$BuildOutput -> $RuntimeDir"
    Get-ChildItem -Force -LiteralPath $RuntimeDir | Remove-Item -Recurse -Force
    Get-ChildItem -Force -LiteralPath $BuildOutput | Copy-Item -Destination $RuntimeDir -Recurse -Force
}

function Wait-Health {
    param([int]$TimeoutSec = 90)
    $health = "http://127.0.0.1:$Port/mcp/health"
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    Write-Phase2Progress -Stage 'service.health' -Status 'start' -Detail $health -Data @{ timeoutSec = $TimeoutSec }
    do {
        $client = [System.Net.Http.HttpClient]::new()
        try {
            $client.Timeout = [TimeSpan]::FromSeconds(3)
            $resp = $client.GetAsync($health).GetAwaiter().GetResult()
            if ([int]$resp.StatusCode -eq 200) {
                Write-Phase2Progress -Stage 'service.health' -Status 'success' -Detail $health
                return
            }
        }
        catch {
            Write-Phase2Progress -Stage 'service.health' -Status 'retry' -Detail $_.Exception.Message
            Start-Sleep -Seconds 2
        }
        finally {
            $client.Dispose()
        }
    } while ((Get-Date) -lt $deadline)
    Write-Phase2Progress -Stage 'service.health' -Status 'failed' -Detail $health
    throw "二期 MCP 服务健康检查超时：$health"
}

function Stop-Phase2ServiceInline {
    Write-Phase2Progress -Stage 'service.stop' -Status 'start' -Detail $RuntimeExe
    $targets = @(Get-Process -Name 'TiaMcpServer' -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -eq $RuntimeExe })

    foreach ($target in $targets) {
        Write-Step "停止二期 MCP 服务：PID=$($target.Id)"
        Write-Phase2Progress -Stage 'service.stop' -Status 'stopping' -Detail "PID=$($target.Id)"
        try {
            Stop-Process -Id $target.Id -Force
            Wait-Process -Id $target.Id -Timeout 20 -ErrorAction SilentlyContinue
        }
        catch {
            Write-Phase2Progress -Stage 'service.stop' -Status 'warn' -Detail $_.Exception.Message
        }
    }

    if (Test-Path -LiteralPath $HttpPidFile) {
        Remove-Item -LiteralPath $HttpPidFile -Force
    }

    Write-Phase2Progress -Stage 'service.stop' -Status 'success' -Detail "stopped=$($targets.Count)"
}

function Start-Phase2ServiceInline {
    if (-not (Test-Path -LiteralPath $RuntimeExe)) {
        throw "未找到二期 runtime：$RuntimeExe"
    }

    $existing = @(Get-Process -Name 'TiaMcpServer' -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -eq $RuntimeExe })
    if ($existing.Count -gt 0) {
        $existing[0].Id | Set-Content -LiteralPath $HttpPidFile -Encoding UTF8
        Write-Phase2Progress -Stage 'service.start' -Status 'reuse' -Detail "PID=$($existing[0].Id)"
        return
    }

    $tcp = [System.Net.Sockets.TcpClient]::new()
    try {
        $connect = $tcp.ConnectAsync('127.0.0.1', $Port)
        if ($connect.Wait(600) -and $tcp.Connected) {
            throw "端口 $Port 已被其他进程占用，未启动二期服务。"
        }
    }
    finally {
        $tcp.Dispose()
    }

    $prefix = "http://127.0.0.1:$Port/"
    $env:TIA_MCP_TOOL_PROFILE = 'plc-software-v17-phase2'
    $args = @(
        '--transport', 'http',
        '--http-prefix', $prefix,
        '--http-api-key', $ApiKey,
        '--http-response-timeout-seconds', '300',
        '--tool-profile', 'plc-software-v17-phase2',
        '--tia-major-version', '17',
        '--logging', '1'
    )

    Write-Phase2Progress -Stage 'service.start' -Status 'start' -Detail $RuntimeExe -Data @{ port = $Port; profile = 'plc-software-v17-phase2' }
    $process = Start-Process -FilePath $RuntimeExe `
        -ArgumentList $args `
        -WorkingDirectory $RuntimeDir `
        -WindowStyle Hidden `
        -RedirectStandardOutput $HttpStdoutLog `
        -RedirectStandardError $HttpStderrLog `
        -PassThru

    $process.Id | Set-Content -LiteralPath $HttpPidFile -Encoding UTF8
    Write-Step "二期 MCP 服务已启动：PID=$($process.Id)，地址=$prefix，profile=plc-software-v17-phase2"
    Write-Phase2Progress -Stage 'service.start' -Status 'success' -Detail "PID=$($process.Id)"
}

function Restart-Phase2Service {
    Write-Phase2Progress -Stage 'service.restart' -Status 'start' -Detail '停止并重启二期服务'
    Stop-Phase2ServiceInline
    Start-Phase2ServiceInline
    Wait-Health
    Reset-McpSession
    Write-Phase2Progress -Stage 'service.restart' -Status 'success' -Detail '二期服务已可访问'
}

function Get-PortalLoad {
    $processes = @(Get-Process -Name 'Siemens.Automation.Portal' -ErrorAction SilentlyContinue)
    $totalBytes = 0
    if ($processes.Count -gt 0) {
        $totalBytes = ($processes | Measure-Object WorkingSet64 -Sum).Sum
    }

    return [pscustomobject]@{
        count = $processes.Count
        totalWorkingSetGb = [math]::Round($totalBytes / 1GB, 2)
        maxAllowedCount = $MaxPortalProcesses
        allowHighPortalLoad = [bool]$AllowHighPortalLoad
        topProcesses = @($processes |
            Sort-Object WorkingSet64 -Descending |
            Select-Object -First 8 Id, StartTime, @{Name='WorkingSetMb';Expression={[math]::Round($_.WorkingSet64 / 1MB, 1)}})
    }
}

function Test-E2EAllowed {
    if ($ToolSurfaceOnly) {
        return [pscustomobject]@{ allowed = $false; status = 'gated'; reason = '已指定 -ToolSurfaceOnly，本轮只验证工具面。'; portalLoad = Get-PortalLoad }
    }
    if ($Port -ne 8770) {
        return [pscustomobject]@{ allowed = $false; status = 'gated'; reason = '当前工作区历史验证脚本固定访问 8770，非 8770 端口只做工具面验证。'; portalLoad = Get-PortalLoad }
    }
    if ([string]::IsNullOrWhiteSpace($WorkspaceRoot) -or -not (Test-Path -LiteralPath $WorkspaceRoot)) {
        return [pscustomobject]@{ allowed = $false; status = 'gated'; reason = "未找到工作区验证根目录：$WorkspaceRoot"; portalLoad = Get-PortalLoad }
    }

    $load = Get-PortalLoad
    if (-not $AllowHighPortalLoad -and $load.count -gt $MaxPortalProcesses) {
        return [pscustomobject]@{
            allowed = $false
            status = 'gated'
            reason = "当前 TIA Portal 进程数为 $($load.count)，超过保护阈值 $MaxPortalProcesses。为避免内存不足，本轮不继续打开/创建工程。"
            portalLoad = $load
        }
    }

    return [pscustomobject]@{ allowed = $true; status = 'success'; reason = ''; portalLoad = $load }
}

function Get-SafeLogName {
    param([Parameter(Mandatory = $true)][string]$Name)
    return ($Name -replace '[^A-Za-z0-9_.-]', '_')
}

function Get-LogTail {
    param([Parameter(Mandatory = $true)][string]$Path, [int]$Lines = 40)
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    try { return ((Get-Content -LiteralPath $Path -Encoding UTF8 -Tail $Lines) -join [Environment]::NewLine) }
    catch { return "读取日志尾部失败：$($_.Exception.Message)" }
}

function Invoke-PwshScriptWithTimeout {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [int]$TimeoutSec = $ChildTimeoutSec
    )

    $safeName = Get-SafeLogName -Name (Split-Path -Leaf $ScriptPath)
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $stdoutLog = Join-Path $ChildLogDir "$stamp.$safeName.stdout.log"
    $stderrLog = Join-Path $ChildLogDir "$stamp.$safeName.stderr.log"
    $startedAt = Get-Date
    $process = Start-Process -FilePath 'pwsh' `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath) `
        -WindowStyle Hidden `
        -RedirectStandardOutput $stdoutLog `
        -RedirectStandardError $stderrLog `
        -PassThru

    Write-Step "子脚本 PID=$($process.Id)，超时=${TimeoutSec}s，日志=$stdoutLog"
    if (-not $process.WaitForExit($TimeoutSec * 1000)) {
        try { Stop-Process -Id $process.Id -Force } catch {}
        return [pscustomobject]@{
            status = 'failed'
            detail = "子脚本执行超时：$ScriptPath，超时=${TimeoutSec}s"
            timedOut = $true
            exitCode = $null
            stdoutLog = $stdoutLog
            stderrLog = $stderrLog
            stdoutTail = Get-LogTail -Path $stdoutLog
            stderrTail = Get-LogTail -Path $stderrLog
            elapsedSec = [math]::Round(((Get-Date) - $startedAt).TotalSeconds, 1)
        }
    }

    $process.WaitForExit()
    $exitCode = $process.ExitCode
    $status = if ($exitCode -eq 0) { 'success' } else { 'failed' }
    $detail = if ($exitCode -eq 0) { '' } else { "子脚本退出码=$exitCode。$(Get-LogTail -Path $stderrLog)" }
    return [pscustomobject]@{
        status = $status
        detail = $detail
        timedOut = $false
        exitCode = $exitCode
        stdoutLog = $stdoutLog
        stderrLog = $stderrLog
        stdoutTail = Get-LogTail -Path $stdoutLog -Lines 20
        stderrTail = Get-LogTail -Path $stderrLog -Lines 20
        elapsedSec = [math]::Round(((Get-Date) - $startedAt).TotalSeconds, 1)
    }
}

$script:SessionId = $null
$script:RequestId = 0

function Reset-McpSession {
    $script:SessionId = $null
    $script:RequestId = 0
}

function Invoke-McpRequest {
    param(
        [Parameter(Mandatory = $true)][string]$Method,
        [object]$Params = $null,
        [switch]$Notification,
        [int]$TimeoutSec = 180
    )

    $headers = @{
        'X-API-Key' = $ApiKey
        'Accept' = 'application/json'
        'Content-Type' = 'application/json'
        'MCP-Protocol-Version' = $ProtocolVersion
    }
    if ($script:SessionId) { $headers['Mcp-Session-Id'] = $script:SessionId }

    $payload = @{ jsonrpc = '2.0'; method = $Method }
    if (-not $Notification) {
        $script:RequestId++
        $payload.id = $script:RequestId
    }
    if ($null -ne $Params) { $payload.params = $Params }

    $json = $payload | ConvertTo-Json -Depth 100 -Compress
    $client = [System.Net.Http.HttpClient]::new()
    $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Post, $BaseUrl)
    $started = Get-Date
    Write-Phase2Progress -Stage 'mcp.request' -Status 'start' -Detail $Method -Data @{ timeoutSec = $TimeoutSec; requestId = $payload.id }
    try {
        $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSec)
        foreach ($key in $headers.Keys) {
            if ($key -ne 'Content-Type') {
                $null = $request.Headers.TryAddWithoutValidation($key, [string]$headers[$key])
            }
        }
        $request.Content = [System.Net.Http.StringContent]::new($json, [System.Text.Encoding]::UTF8, 'application/json')
        $resp = $client.SendAsync($request).GetAwaiter().GetResult()
        $content = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        if ($resp.Headers.Contains('Mcp-Session-Id')) {
            $script:SessionId = [string](@($resp.Headers.GetValues('Mcp-Session-Id'))[0])
        }
        $elapsedSec = [math]::Round(((Get-Date) - $started).TotalSeconds, 1)
        Write-Phase2Progress -Stage 'mcp.request' -Status 'finish' -Detail $Method -Data @{ statusCode = [int]$resp.StatusCode; elapsedSec = $elapsedSec; requestId = $payload.id }
        if (-not $resp.IsSuccessStatusCode) {
            throw "MCP HTTP 请求失败：method=$Method status=$([int]$resp.StatusCode) body=$content"
        }
        if ([string]::IsNullOrWhiteSpace($content)) { return $null }
        return $content | ConvertFrom-Json -Depth 100
    }
    catch {
        Write-Phase2Progress -Stage 'mcp.request' -Status 'failed' -Detail $Method -Data @{ error = $_.Exception.Message; requestId = $payload.id }
        throw
    }
    finally {
        $request.Dispose()
        $client.Dispose()
    }
}

function Invoke-Tool {
    param([Parameter(Mandatory = $true)][string]$Name, [hashtable]$Arguments = @{}, [int]$TimeoutSec = 240)

    Write-Phase2Progress -Stage 'tool.call' -Status 'start' -Detail $Name -Data @{ timeoutSec = $TimeoutSec }
    $started = Get-Date
    $raw = Invoke-McpRequest -Method 'tools/call' -Params @{ name = $Name; arguments = $Arguments } -TimeoutSec $TimeoutSec
    $text = ''
    if ($raw -and $raw.result -and $raw.result.content -and $raw.result.content.Count -gt 0) {
        $text = [string]$raw.result.content[0].text
    }
    $parsed = $null
    if (-not [string]::IsNullOrWhiteSpace($text)) {
        try { $parsed = $text | ConvertFrom-Json -Depth 100 } catch {}
    }
    Write-Phase2Progress -Stage 'tool.call' -Status 'finish' -Detail $Name -Data @{ elapsedSec = [math]::Round(((Get-Date) - $started).TotalSeconds, 1); hasText = -not [string]::IsNullOrWhiteSpace($text) }
    return [pscustomobject]@{ raw = $raw; text = $text; parsed = $parsed }
}

function Initialize-McpSession {
    Reset-McpSession
    $null = Invoke-McpRequest -Method 'initialize' -Params @{
        protocolVersion = $ProtocolVersion
        capabilities = @{}
        clientInfo = @{ name = 'verify-plc-software-mcp-v17-phase2'; version = '2.0-beta' }
    } -TimeoutSec 120
    $null = Invoke-McpRequest -Method 'notifications/initialized' -Notification -TimeoutSec 120
}

function Assert-ToolSurface {
    if (-not (Test-Path -LiteralPath $ManifestPath)) {
        throw "未找到二期工具 manifest：$ManifestPath"
    }
    $manifest = Get-Content -Raw -Encoding UTF8 -LiteralPath $ManifestPath | ConvertFrom-Json -Depth 100
    $allowed = @($manifest.tools | ForEach-Object { [string]$_.name })
    if ($allowed.Count -eq 0) { throw '二期工具 manifest 为空。' }

    Initialize-McpSession
    $listed = Invoke-McpRequest -Method 'tools/list' -TimeoutSec 120
    $actual = @($listed.result.tools | ForEach-Object { [string]$_.name } | Sort-Object -Unique)
    $expected = @($allowed | Sort-Object -Unique)

    $missing = @($expected | Where-Object { $actual -notcontains $_ })
    $extra = @($actual | Where-Object { $expected -notcontains $_ })
    $bannedPatterns = @('HMI', 'Unified', 'Online', 'Reflection', 'Report')
    $bannedNames = @('SetWatchTableModifyValue', 'DownloadToPlc', 'GoOnline', 'GoOffline', 'DescribeObject', 'GetTechnologyObjectProperties')
    $bannedActual = @($actual | Where-Object {
        $name = $_
        ($bannedNames -contains $name) -or (@($bannedPatterns | Where-Object { $name -match $_ }).Count -gt 0)
    })

    $surface = [pscustomobject]@{
        status = if ($missing.Count -eq 0 -and $extra.Count -eq 0 -and $bannedActual.Count -eq 0) { 'success' } else { 'failed' }
        profile = 'plc-software-v17-phase2'
        expectedCount = $expected.Count
        actualCount = $actual.Count
        missing = $missing
        extra = $extra
        bannedActual = $bannedActual
        actualTools = $actual
    }
    $surface | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $ToolSurfaceJson -Encoding UTF8

    if ($surface.status -ne 'success') {
        throw "工具面验证失败。missing=$($missing -join ', ') extra=$($extra -join ', ') banned=$($bannedActual -join ', ')"
    }
    return $surface
}

function Invoke-WorkspaceScript {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptName,
        [int]$TimeoutSec = $ChildTimeoutSec
    )

    $scriptPath = Join-Path (Join-Path $WorkspaceRoot 'temp') $ScriptName
    if (-not (Test-Path -LiteralPath $scriptPath)) {
        throw "未找到工作区验证脚本：$scriptPath"
    }

    $start = Get-Date
    Write-Step "执行 $ScriptName"
    Write-Phase2Progress -Stage 'workspace.script' -Status 'start' -Detail $ScriptName -Data @{ timeoutSec = $TimeoutSec; scriptPath = $scriptPath }
    $execution = Invoke-PwshScriptWithTimeout -ScriptPath $scriptPath -TimeoutSec $TimeoutSec
    $item = [pscustomobject]@{
        script = $scriptPath
        status = $execution.status
        detail = $execution.detail
        timedOut = $execution.timedOut
        exitCode = $execution.exitCode
        timeoutSec = $TimeoutSec
        elapsedSec = $execution.elapsedSec
        stdoutLog = $execution.stdoutLog
        stderrLog = $execution.stderrLog
        startedAt = $start.ToString('s')
        finishedAt = (Get-Date).ToString('s')
    }
    if ($item.status -ne 'success') {
        Write-Phase2Progress -Stage 'workspace.script' -Status 'failed' -Detail $ScriptName -Data @{ elapsedSec = $item.elapsedSec; exitCode = $item.exitCode; timedOut = $item.timedOut; stdoutLog = $item.stdoutLog; stderrLog = $item.stderrLog }
        throw "工作区验证脚本失败：$scriptPath。$($item.detail)"
    }
    Write-Phase2Progress -Stage 'workspace.script' -Status 'success' -Detail $ScriptName -Data @{ elapsedSec = $item.elapsedSec; stdoutLog = $item.stdoutLog; stderrLog = $item.stderrLog }
    return $item
}

function CloseCurrentProjectBestEffort {
    try {
        Initialize-McpSession
        $state = Invoke-Tool -Name 'GetState' -TimeoutSec 60
        $parsed = $state.parsed
        $isConnected = $false
        if ($parsed -and $parsed.PSObject.Properties.Name -contains 'isConnected') {
            $isConnected = [bool]$parsed.isConnected
        }
        elseif ($parsed -and $parsed.PSObject.Properties.Name -contains 'IsConnected') {
            $isConnected = [bool]$parsed.IsConnected
        }

        if (-not $isConnected) {
            Write-Phase2Progress -Stage 'cleanup.project' -Status 'skip' -Detail '当前 MCP 会话未连接，不主动 Connect。'
            return
        }

        $project = if ($parsed.PSObject.Properties.Name -contains 'project') { [string]$parsed.project } elseif ($parsed.PSObject.Properties.Name -contains 'Project') { [string]$parsed.Project } else { '' }
        $session = if ($parsed.PSObject.Properties.Name -contains 'session') { [string]$parsed.session } elseif ($parsed.PSObject.Properties.Name -contains 'Session') { [string]$parsed.Session } else { '' }
        $hasProject = -not [string]::IsNullOrWhiteSpace($project) -and $project -ne '-'
        $hasSession = -not [string]::IsNullOrWhiteSpace($session) -and $session -ne '-'

        if ($hasProject -or $hasSession) {
            $null = Invoke-Tool -Name 'SaveProject' -TimeoutSec 240
            $null = Invoke-Tool -Name 'CloseProject' -TimeoutSec 240
        }
        else {
            Write-Phase2Progress -Stage 'cleanup.project' -Status 'skip' -Detail '已连接但没有打开工程，仅断开连接。'
        }

        $null = Invoke-Tool -Name 'Disconnect' -TimeoutSec 120
    }
    catch {
        Write-Step "工程清理失败但继续：$($_.Exception.Message)"
    }
    Reset-McpSession
}

function Get-FirstArray {
    param([object]$Object, [string[]]$Names)
    if ($null -eq $Object) { return @() }
    foreach ($name in $Names) {
        if ($Object.PSObject.Properties.Name -contains $name) {
            $value = $Object.$name
            if ($null -eq $value) { return @() }
            return @($value)
        }
    }
    return @()
}

function Invoke-Phase2TechnologyObjectBatchExport {
    Write-Phase2Progress -Stage 'phase2.to.batchExport' -Status 'start' -Detail '验证 TO 批量导出'
    $exportDir = Join-Path $ReportsDir 'technology-object-batch-export'
    New-Item -ItemType Directory -Force -Path $exportDir | Out-Null

    Initialize-McpSession
    $null = Invoke-Tool -Name 'Connect' -TimeoutSec 240
    $tos = Invoke-Tool -Name 'GetTechnologyObjects' -Arguments @{ softwarePath = 'PLC_1' } -TimeoutSec 240
    $items = Get-FirstArray -Object $tos.parsed -Names @('items', 'Items')
    $pidCompactItems = @($items | Where-Object {
        ([string]$_.ofSystemLibElement -match 'PID_Compact') -or
        ([string]$_.OfSystemLibElement -match 'PID_Compact') -or
        ([string]$_.name -match 'PID_Compact') -or
        ([string]$_.Name -match 'PID_Compact')
    } | Select-Object -First 1)

    if ($pidCompactItems.Count -eq 0) {
        throw "二期 TO 批量导出验证失败：当前 PLC_1 未读到 PID_Compact。raw=$($tos.text)"
    }

    $batch = Invoke-Tool -Name 'ExportTechnologyObjectsToDirectory' -Arguments @{
        softwarePath = 'PLC_1'
        exportDir = $exportDir
        regexName = 'PID_Compact.*'
    } -TimeoutSec 300

    $imported = Get-FirstArray -Object $batch.parsed -Names @('imported', 'Imported')
    $failed = Get-FirstArray -Object $batch.parsed -Names @('failed', 'Failed')
    $xmlFiles = @(Get-ChildItem -LiteralPath $exportDir -Filter '*.xml' -File -ErrorAction SilentlyContinue)
    if ($failed.Count -gt 0 -or $imported.Count -eq 0 -or $xmlFiles.Count -eq 0) {
        Write-Phase2Progress -Stage 'phase2.to.batchExport' -Status 'failed' -Detail 'TO 批量导出未形成有效 XML' -Data @{ importedCount = $imported.Count; failedCount = $failed.Count; xmlCount = $xmlFiles.Count }
        throw "ExportTechnologyObjectsToDirectory 未形成有效导出。imported=$($imported.Count) failed=$($failed.Count) xml=$($xmlFiles.Count) raw=$($batch.text)"
    }

    Write-Phase2Progress -Stage 'phase2.to.batchExport' -Status 'success' -Detail $exportDir -Data @{ exportedCount = $xmlFiles.Count }
    return [pscustomobject]@{
        tool = 'ExportTechnologyObjectsToDirectory'
        status = 'success'
        exportDir = $exportDir
        exportedCount = $xmlFiles.Count
        exportedFiles = @($xmlFiles | ForEach-Object { $_.FullName })
        getTechnologyObjects = $tos.parsed
        exportTechnologyObjectsToDirectory = $batch.parsed
    }
}

function Invoke-ExistingTechnologyObjectFixtureOpen {
    Write-Phase2Progress -Stage 'phase2.to.fixture' -Status 'start' -Detail '打开既有 PID_Compact fixture'
    $fixtureProjectPathFile = Join-Path (Join-Path (Join-Path $WorkspaceRoot 'temp') 'technology-object-fixture') 'project-path.txt'
    if (-not (Test-Path -LiteralPath $fixtureProjectPathFile)) {
        throw "未找到 PID_Compact fixture 工程路径文件：$fixtureProjectPathFile"
    }

    $projectPath = (Get-Content -Raw -Encoding UTF8 -LiteralPath $fixtureProjectPathFile).Trim()
    if ([string]::IsNullOrWhiteSpace($projectPath) -or -not (Test-Path -LiteralPath $projectPath)) {
        throw "PID_Compact fixture 工程路径无效：$projectPath"
    }

    Initialize-McpSession
    $null = Invoke-Tool -Name 'Connect' -TimeoutSec 240
    $open = Invoke-Tool -Name 'OpenProject' -Arguments @{ path = $projectPath } -TimeoutSec 300
    $tos = Invoke-Tool -Name 'GetTechnologyObjects' -Arguments @{ softwarePath = 'PLC_1' } -TimeoutSec 240
    $items = Get-FirstArray -Object $tos.parsed -Names @('items', 'Items')
    if ($items.Count -eq 0) {
        Write-Phase2Progress -Stage 'phase2.to.fixture' -Status 'failed' -Detail $projectPath
        throw "已打开 PID_Compact fixture 工程，但 GetTechnologyObjects 为空。projectPath=$projectPath raw=$($tos.text)"
    }

    Write-Phase2Progress -Stage 'phase2.to.fixture' -Status 'success' -Detail $projectPath -Data @{ technologyObjectCount = $items.Count }
    return [pscustomobject]@{
        tool = 'OpenProjectExistingPidCompactFixture'
        status = 'success'
        projectPath = $projectPath
        openProject = $open.parsed
        getTechnologyObjects = $tos.parsed
    }
}

function Invoke-E2EValidation {
    $results = [System.Collections.Generic.List[object]]::new()
    Write-Phase2Progress -Stage 'e2e' -Status 'start' -Detail '开始二期端到端验证'

    if ($ReuseExistingTechnologyObjectFixture) {
        $results.Add((Invoke-ExistingTechnologyObjectFixtureOpen)) | Out-Null
    }
    else {
        $results.Add((Invoke-WorkspaceScript -ScriptName 'create-1211c-pidcompact-fixture-v17.ps1' -TimeoutSec 1800)) | Out-Null
    }
    $results.Add((Invoke-Phase2TechnologyObjectBatchExport)) | Out-Null
    CloseCurrentProjectBestEffort
    Restart-Phase2Service

    $results.Add((Invoke-WorkspaceScript -ScriptName 'http-mcp-verify-v17-globaldb-min.ps1' -TimeoutSec 1200)) | Out-Null
    CloseCurrentProjectBestEffort
    Restart-Phase2Service

    $results.Add((Invoke-WorkspaceScript -ScriptName 'http-mcp-verify-plc-software-a-class-v17.ps1' -TimeoutSec 2400)) | Out-Null
    CloseCurrentProjectBestEffort
    Restart-Phase2Service

    $results.Add((Invoke-WorkspaceScript -ScriptName 'verify-plc-software-doc-gates-v17.ps1' -TimeoutSec 600)) | Out-Null
    CloseCurrentProjectBestEffort

    $e2e = [pscustomobject]@{
        status = 'success'
        mode = 'phase2-controlled-single-project'
        results = $results
    }
    $e2e | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $E2EResultsJson -Encoding UTF8
    Write-Phase2Progress -Stage 'e2e' -Status 'success' -Detail '二期端到端验证完成' -Data @{ resultCount = $results.Count }
    return $e2e
}

$startedAt = Get-Date
$buildStatus = $null
$toolSurface = $null
$e2e = $null
$finalStatus = 'success'
$failure = ''

try {
    Invoke-BuildAndSyncRuntime
    $buildStatus = [pscustomobject]@{ status = 'success'; projectFile = $ProjectFile; runtimeDir = $RuntimeDir; outputDir = $BuildOutput }

    Write-Step '启动独立二期服务'
    Restart-Phase2Service

    Write-Step '验证 tools/list 只暴露二期 allowlist'
    $toolSurface = Assert-ToolSurface

    $gate = Test-E2EAllowed
    if (-not $gate.allowed) {
        $finalStatus = 'gated'
        $e2e = [pscustomobject]@{
            status = 'gated'
            reason = $gate.reason
            mode = 'gate'
            portalLoad = $gate.portalLoad
            results = @()
        }
        $e2e | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $E2EResultsJson -Encoding UTF8
        Write-Step $gate.reason
    }
    else {
        Write-Step "Portal 负载通过保护检查：count=$($gate.portalLoad.count)，totalWorkingSetGb=$($gate.portalLoad.totalWorkingSetGb)"
        Write-Step '开始二期端到端验证'
        $e2e = Invoke-E2EValidation
    }
}
catch {
    $finalStatus = 'failed'
    $failure = $_.Exception.Message
}
finally {
    Write-Step '最终清理独立二期服务'
    try { CloseCurrentProjectBestEffort } catch {}
    try { Stop-Phase2ServiceInline } catch {}
}

$summaryObject = [pscustomobject]@{
    productRoot = $ProductRoot
    workspaceRoot = $WorkspaceRoot
    startedAt = $startedAt.ToString('s')
    finishedAt = (Get-Date).ToString('s')
    status = $finalStatus
    profile = 'plc-software-v17-phase2'
    baseUrl = $BaseUrl
    build = $buildStatus
    toolSurface = $toolSurface
    e2e = $e2e
    failure = $failure
}

$summaryObject | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $SummaryJson -Encoding UTF8

$e2eStatus = if ($e2e) { $e2e.status } else { '' }
$e2eReason = if ($e2e -and $e2e.PSObject.Properties.Name -contains 'reason') { $e2e.reason } else { '' }
$toolStatus = if ($toolSurface) { $toolSurface.status } else { '' }
$toolCount = if ($toolSurface) { "$($toolSurface.actualCount)/$($toolSurface.expectedCount)" } else { '' }

@(
    '# TIA Portal V17 PLC-Software MCP 二期验证报告'
    ''
    "- 最终状态：$finalStatus"
    "- 服务地址：$BaseUrl"
    "- 工具 profile：plc-software-v17-phase2"
    "- 构建状态：$($buildStatus.status)"
    "- 工具面状态：$toolStatus"
    "- 工具数量：$toolCount"
    "- 端到端验证：$e2eStatus"
    "- 门禁原因：$e2eReason"
    "- 失败信息：$failure"
    ''
    '## 证据'
    ''
    "- summary.json：$SummaryJson"
    "- tool-surface.json：$ToolSurfaceJson"
    "- e2e-results.json：$E2EResultsJson"
    "- 构建日志：$(Join-Path $ReportsDir 'dotnet-build.stdout.log')"
) -join [Environment]::NewLine | Set-Content -LiteralPath $SummaryMd -Encoding UTF8

Write-Host "summary json: $SummaryJson"
Write-Host "summary md: $SummaryMd"

if ($finalStatus -eq 'failed') {
    throw "二期验证失败：$failure"
}

if ($finalStatus -eq 'gated') {
    Write-Host "二期验证进入 gated：$e2eReason"
}
