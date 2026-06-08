param(
    [string]$WorkspaceRoot = $(if ($env:TIA_MCP_WORKSPACE_ROOT) { $env:TIA_MCP_WORKSPACE_ROOT } else { '' }),
    [int]$Port = $(if ($env:TIA_MCP_HTTP_PORT) { [int]$env:TIA_MCP_HTTP_PORT } else { 8770 }),
    [string]$ApiKey = $(if ($env:TIA_MCP_HTTP_API_KEY) { $env:TIA_MCP_HTTP_API_KEY } else { 'codex-test-key' }),
    [int]$ChildTimeoutSec = $(if ($env:TIA_MCP_CHILD_TIMEOUT_SEC) { [int]$env:TIA_MCP_CHILD_TIMEOUT_SEC } else { 1200 }),
    [int]$MaxPortalProcesses = $(if ($env:TIA_MCP_MAX_PORTAL_PROCESSES) { [int]$env:TIA_MCP_MAX_PORTAL_PROCESSES } else { 12 }),
    [switch]$AllowHighPortalLoad
)

[Console]::InputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)
chcp 65001 > $null
$ErrorActionPreference = 'Stop'

$ProductRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$ReportsDir = Join-Path $ProductRoot 'reports\latest'
$ManifestPath = Join-Path $ProductRoot 'manifest\tools-list.json'
$SummaryJson = Join-Path $ReportsDir 'summary.json'
$SummaryMd = Join-Path $ReportsDir 'summary.md'
$ChildLogDir = Join-Path $ReportsDir 'child-logs'
$BaseUrl = "http://127.0.0.1:$Port/mcp"
$ProtocolVersion = '2025-03-26'

New-Item -ItemType Directory -Force -Path $ReportsDir | Out-Null
New-Item -ItemType Directory -Force -Path $ChildLogDir | Out-Null

if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
    throw '未设置验证工作区路径。请传入 -WorkspaceRoot，或设置环境变量 TIA_MCP_WORKSPACE_ROOT。'
}

function Write-Step {
    param([string]$Message)
    Write-Host "[一期验证] $Message"
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

function Test-WorkspaceValidationAllowed {
    $load = Get-PortalLoad
    if (-not $AllowHighPortalLoad -and $load.count -gt $MaxPortalProcesses) {
        return [pscustomobject]@{
            allowed = $false
            status = 'gated'
            reason = "当前 TIA Portal 进程数为 $($load.count)，超过保护阈值 $MaxPortalProcesses。为避免内存不足，本轮不再继续打开/创建工程。可关闭多余博途后重跑，或显式加 -AllowHighPortalLoad 强制执行。"
            portalLoad = $load
        }
    }

    return [pscustomobject]@{
        allowed = $true
        status = 'success'
        reason = ''
        portalLoad = $load
    }
}

function Wait-Health {
    param([int]$TimeoutSec = 90)
    $health = "http://127.0.0.1:$Port/mcp/health"
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    do {
        try {
            $resp = Invoke-WebRequest -UseBasicParsing -Uri $health -TimeoutSec 3
            if ($resp.StatusCode -eq 200) { return }
        }
        catch {
            Start-Sleep -Seconds 2
        }
    } while ((Get-Date) -lt $deadline)
    throw "一期 MCP 服务健康检查超时：$health"
}

function Get-SafeLogName {
    param([Parameter(Mandatory = $true)][string]$Name)
    return ($Name -replace '[^A-Za-z0-9_.-]', '_')
}

function Get-LogTail {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$Lines = 40
    )

    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    try {
        return ((Get-Content -LiteralPath $Path -Encoding UTF8 -Tail $Lines) -join [Environment]::NewLine)
    }
    catch {
        return "读取日志尾部失败：$($_.Exception.Message)"
    }
}

function Stop-PwshProcessesStartedAfter {
    param([Parameter(Mandatory = $true)][datetime]$StartedAt)

    $targets = @(Get-Process -Name 'pwsh' -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Id -ne $PID -and
            $_.StartTime -ge $StartedAt.AddSeconds(-2)
        })

    foreach ($target in $targets) {
        try {
            Write-Step "停止超时验证残留 pwsh：PID=$($target.Id)"
            Stop-Process -Id $target.Id -Force
        }
        catch {
            Write-Step "停止残留 pwsh 失败但继续：PID=$($target.Id)，$($_.Exception.Message)"
        }
    }
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
    $process = $null

    try {
        $process = Start-Process -FilePath 'pwsh' `
            -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath) `
            -WindowStyle Hidden `
            -RedirectStandardOutput $stdoutLog `
            -RedirectStandardError $stderrLog `
            -PassThru

        Write-Step "子脚本 PID=$($process.Id)，超时=${TimeoutSec}s，日志=$stdoutLog"

        if (-not $process.WaitForExit($TimeoutSec * 1000)) {
            try { Stop-Process -Id $process.Id -Force } catch {}
            Stop-PwshProcessesStartedAfter -StartedAt $startedAt
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
        $detail = if ($exitCode -eq 0) {
            ''
        }
        else {
            $stderrTail = Get-LogTail -Path $stderrLog
            if ([string]::IsNullOrWhiteSpace($stderrTail)) {
                $stderrTail = Get-LogTail -Path $stdoutLog
            }
            "子脚本退出码=$exitCode。$stderrTail"
        }

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
    catch {
        return [pscustomobject]@{
            status = 'failed'
            detail = "启动或等待子脚本失败：$($_.Exception.Message)"
            timedOut = $false
            exitCode = $null
            stdoutLog = $stdoutLog
            stderrLog = $stderrLog
            stdoutTail = Get-LogTail -Path $stdoutLog
            stderrTail = Get-LogTail -Path $stderrLog
            elapsedSec = [math]::Round(((Get-Date) - $startedAt).TotalSeconds, 1)
        }
    }
}

$script:SessionId = $null
$script:RequestId = 0

function Invoke-McpRequest {
    param(
        [Parameter(Mandatory = $true)][string]$Method,
        [object]$Params = $null,
        [switch]$Notification,
        [int]$TimeoutSec = 120
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
    $resp = Invoke-WebRequest -UseBasicParsing -Method Post -Uri $BaseUrl -Headers $headers -Body $json -TimeoutSec $TimeoutSec
    if ($resp.Headers['Mcp-Session-Id']) { $script:SessionId = $resp.Headers['Mcp-Session-Id'] }
    if ([string]::IsNullOrWhiteSpace($resp.Content)) { return $null }
    return $resp.Content | ConvertFrom-Json -Depth 100
}

function Invoke-ToolBestEffort {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [hashtable]$Arguments = @{},
        [int]$TimeoutSec = 120
    )

    try {
        return Invoke-McpRequest -Method 'tools/call' -Params @{
            name = $Name
            arguments = $Arguments
        } -TimeoutSec $TimeoutSec
    }
    catch {
        Write-Step "清理工具 $Name 执行失败但继续：$($_.Exception.Message)"
        return $null
    }
}

function Reset-McpSession {
    $script:SessionId = $null
    $script:RequestId = 0
}

function Assert-ToolSurface {
    if (-not (Test-Path -LiteralPath $ManifestPath)) {
        throw "未找到工具 manifest：$ManifestPath"
    }
    $manifest = Get-Content -Raw -Encoding UTF8 -LiteralPath $ManifestPath | ConvertFrom-Json -Depth 100
    $allowed = @($manifest.tools | ForEach-Object { [string]$_.name })
    if ($allowed.Count -eq 0) { throw '工具 manifest 为空。' }

    $null = Invoke-McpRequest -Method 'initialize' -Params @{
        protocolVersion = $ProtocolVersion
        capabilities = @{}
        clientInfo = @{ name = 'verify-plc-software-mcp-v17'; version = '1.0' }
    }
    $null = Invoke-McpRequest -Method 'notifications/initialized' -Notification

    $listed = Invoke-McpRequest -Method 'tools/list' -TimeoutSec 120
    $actual = @($listed.result.tools | ForEach-Object { [string]$_.name } | Sort-Object -Unique)
    $expected = @($allowed | Sort-Object -Unique)

    $missing = @($expected | Where-Object { $actual -notcontains $_ })
    $extra = @($actual | Where-Object { $expected -notcontains $_ })
    $bannedPatterns = @('HMI', 'Unified', 'Online', 'Reflection', 'Report')
    $bannedNames = @('SetWatchTableModifyValue', 'CreateTechnologyObject', 'ExportTechnologyObjectsToDirectory')
    $bannedActual = @($actual | Where-Object {
        $name = $_
        ($bannedNames -contains $name) -or (@($bannedPatterns | Where-Object { $name -match $_ }).Count -gt 0)
    })

    $surface = [pscustomobject]@{
        status = if ($missing.Count -eq 0 -and $extra.Count -eq 0 -and $bannedActual.Count -eq 0) { 'success' } else { 'failed' }
        expectedCount = $expected.Count
        actualCount = $actual.Count
        missing = $missing
        extra = $extra
        bannedActual = $bannedActual
        actualTools = $actual
    }
    $surface | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath (Join-Path $ReportsDir 'tool-surface.json') -Encoding UTF8

    if ($surface.status -ne 'success') {
        throw "工具面验证失败。missing=$($missing -join ', ') extra=$($extra -join ', ') banned=$($bannedActual -join ', ')"
    }
    return $surface
}

function Restart-Phase1Service {
    param([switch]$SkipStop)

    if (-not $SkipStop) {
        & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $ProductRoot 'scripts\Stop-PlcSoftwareMcpV17.ps1')
    }
    & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $ProductRoot 'scripts\Start-PlcSoftwareMcpV17.ps1') -Port $Port -ApiKey $ApiKey
    Wait-Health
    Reset-McpSession
}

function CloseCurrentProjectBestEffort {
    Reset-McpSession
    try {
        $null = Invoke-McpRequest -Method 'initialize' -Params @{
            protocolVersion = $ProtocolVersion
            capabilities = @{}
            clientInfo = @{ name = 'phase1-cleanup'; version = '1.0' }
        } -TimeoutSec 60
        $null = Invoke-McpRequest -Method 'notifications/initialized' -Notification -TimeoutSec 60
        $null = Invoke-ToolBestEffort -Name 'Connect' -TimeoutSec 180
        $null = Invoke-ToolBestEffort -Name 'SaveProject' -TimeoutSec 180
        $null = Invoke-ToolBestEffort -Name 'CloseProject' -TimeoutSec 180
        $null = Invoke-ToolBestEffort -Name 'Disconnect' -TimeoutSec 60
    }
    catch {
        Write-Step "工程清理失败但继续：$($_.Exception.Message)"
    }
    Reset-McpSession
}

function Invoke-WorkspaceScript {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptName,
        [switch]$RestartBefore,
        [switch]$CloseAfter,
        [int]$TimeoutSec = $ChildTimeoutSec
    )

    if ($RestartBefore) {
        Write-Step "重启一期服务，准备执行 $ScriptName"
        Restart-Phase1Service
    }

    $scriptPath = Join-Path (Join-Path $WorkspaceRoot 'temp') $ScriptName
    if (-not (Test-Path -LiteralPath $scriptPath)) {
        throw "未找到工作区验证脚本：$scriptPath"
    }

    $start = Get-Date
    Write-Step "执行 $ScriptName"
    $execution = Invoke-PwshScriptWithTimeout -ScriptPath $scriptPath -TimeoutSec $TimeoutSec
    $status = $execution.status
    $detail = $execution.detail

    if ($CloseAfter) {
        Write-Step "执行工程清理：SaveProject -> CloseProject -> Disconnect"
        CloseCurrentProjectBestEffort
        Write-Step "重启一期服务释放 MCP 侧工程句柄"
        Restart-Phase1Service
    }

    $item = [pscustomobject]@{
        script = $scriptPath
        status = $status
        detail = $detail
        timedOut = $execution.timedOut
        exitCode = $execution.exitCode
        timeoutSec = $TimeoutSec
        elapsedSec = $execution.elapsedSec
        stdoutLog = $execution.stdoutLog
        stderrLog = $execution.stderrLog
        startedAt = $start.ToString('s')
        finishedAt = (Get-Date).ToString('s')
    }
    if ($status -ne 'success') {
        throw "工作区验证脚本失败：$scriptPath。$detail"
    }
    return $item
}

function Invoke-WorkspaceValidationControlled {
    $results = [System.Collections.Generic.List[object]]::new()

    # OpenProject 回归组需要保留同一个前台工程，验证“同路径已打开时优先附着”。
    $results.Add((Invoke-WorkspaceScript -ScriptName 'http-mcp-verify-v17-globaldb-min.ps1' -TimeoutSec 1200)) | Out-Null
    $results.Add((Invoke-WorkspaceScript -ScriptName 'reopen-globaldb-project-fixed.ps1' -TimeoutSec 600)) | Out-Null
    $results.Add((Invoke-WorkspaceScript -ScriptName 'inspect-openproject-ready.ps1' -TimeoutSec 600)) | Out-Null
    $results.Add((Invoke-WorkspaceScript -ScriptName 'verify-openproject-tree-to-export.ps1' -CloseAfter -TimeoutSec 900)) | Out-Null

    # 后续每个大场景独立开闭工程，避免多个项目常驻导致内存吃紧。
    $results.Add((Invoke-WorkspaceScript -ScriptName 'http-mcp-verify-plc-software-a-class-v17.ps1' -RestartBefore -CloseAfter -TimeoutSec 2400)) | Out-Null
    $results.Add((Invoke-WorkspaceScript -ScriptName 'verify-1211c-technology-object-export.ps1' -RestartBefore -CloseAfter -TimeoutSec 1200)) | Out-Null
    $results.Add((Invoke-WorkspaceScript -ScriptName 'verify-plc-software-doc-gates-v17.ps1' -RestartBefore -CloseAfter -TimeoutSec 600)) | Out-Null

    $outDir = Join-Path (Join-Path $WorkspaceRoot 'temp') 'plc-software-full-validation-v17'
    New-Item -ItemType Directory -Force -Path $outDir | Out-Null
    $workspaceSummary = Join-Path $outDir 'summary.json'
    $workspaceSummaryMd = Join-Path $outDir 'summary.md'
    $summary = [pscustomobject]@{
        startedAt = ($results | Select-Object -First 1).startedAt
        finishedAt = (Get-Date).ToString('s')
        mode = 'controlled-single-project'
        results = $results
    }
    $summary | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $workspaceSummary -Encoding UTF8
    @(
        '# PLC-Software 全量验证汇总'
        ''
        '模式：受控串行，子脚本之间主动 CloseProject/Disconnect，减少 TIA 常驻工程数量。'
        ''
        '| Script | Status |'
        '|---|---|'
        ($results | ForEach-Object { "| $($_.script) | $($_.status) |" })
    ) -join [Environment]::NewLine | Set-Content -LiteralPath $workspaceSummaryMd -Encoding UTF8

    return [pscustomobject]@{
        status = 'success'
        summaryPath = $workspaceSummary
        summaryMdPath = $workspaceSummaryMd
        mode = 'controlled-single-project'
        results = $results
    }
}

$startedAt = Get-Date
$toolSurface = $null
$workspaceValidation = $null
$finalStatus = 'success'
$failure = ''
$projectSessionTouched = $false

try {
    Write-Step '启动独立一期服务'
    Restart-Phase1Service

    Write-Step '验证 tools/list 只暴露一期 allowlist'
    $toolSurface = Assert-ToolSurface

    $portalGate = Test-WorkspaceValidationAllowed
    if (-not $portalGate.allowed) {
        Write-Step $portalGate.reason
        $finalStatus = 'gated'
        $workspaceValidation = [pscustomobject]@{
            status = 'gated'
            reason = $portalGate.reason
            mode = 'portal-load-guard'
            portalLoad = $portalGate.portalLoad
            results = @()
        }
    }
    else {
        Write-Step "Portal 负载通过保护检查：count=$($portalGate.portalLoad.count)，totalWorkingSetGb=$($portalGate.portalLoad.totalWorkingSetGb)"
        Write-Step '受控串行执行 PLC-Software 全量端到端验证'
        $projectSessionTouched = $true
        $workspaceValidation = Invoke-WorkspaceValidationControlled
    }
}
catch {
    $finalStatus = 'failed'
    $failure = $_.Exception.Message
}
finally {
    Write-Step '最终清理独立一期服务'
    if ($projectSessionTouched) {
        Write-Step '本轮已执行工程验证，尝试 SaveProject -> CloseProject -> Disconnect'
        try { CloseCurrentProjectBestEffort } catch {}
    }
    try { & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $ProductRoot 'scripts\Stop-PlcSoftwareMcpV17.ps1') } catch {}
}

$summaryObject = [pscustomobject]@{
    productRoot = $ProductRoot
    workspaceRoot = $WorkspaceRoot
    startedAt = $startedAt.ToString('s')
    finishedAt = (Get-Date).ToString('s')
    status = $finalStatus
    profile = 'plc-software-v17'
    baseUrl = $BaseUrl
    toolSurface = $toolSurface
    workspaceValidation = $workspaceValidation
    failure = $failure
}

$summaryObject | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $SummaryJson -Encoding UTF8

$workspaceStatus = if ($workspaceValidation) { $workspaceValidation.status } else { '' }
$workspaceSummaryPath = if ($workspaceValidation -and $workspaceValidation.PSObject.Properties.Name -contains 'summaryPath') { $workspaceValidation.summaryPath } else { '' }
$workspaceReason = if ($workspaceValidation -and $workspaceValidation.PSObject.Properties.Name -contains 'reason') { $workspaceValidation.reason } else { '' }
$portalLoadLine = ''
if ($workspaceValidation -and $workspaceValidation.PSObject.Properties.Name -contains 'portalLoad' -and $workspaceValidation.portalLoad) {
    $portalLoadLine = "- Portal 负载：count=$($workspaceValidation.portalLoad.count)，totalWorkingSetGb=$($workspaceValidation.portalLoad.totalWorkingSetGb)，maxAllowedCount=$($workspaceValidation.portalLoad.maxAllowedCount)"
}

@(
    '# TIA Portal V17 PLC-Software MCP 一期验证报告'
    ''
    "- 最终状态：$finalStatus"
    "- 服务地址：$BaseUrl"
    "- 工具 profile：plc-software-v17"
    "- 工具面状态：$($toolSurface.status)"
    "- 工作区全量验证：$workspaceStatus"
    "- 失败信息：$failure"
    "- 门禁原因：$workspaceReason"
    $portalLoadLine
    ''
    '## 证据'
    ''
    "- summary.json：$SummaryJson"
    "- tool-surface.json：$(Join-Path $ReportsDir 'tool-surface.json')"
    "- 工作区全量验证：$workspaceSummaryPath"
) -join [Environment]::NewLine | Set-Content -LiteralPath $SummaryMd -Encoding UTF8

Write-Host "summary json: $SummaryJson"
Write-Host "summary md: $SummaryMd"

if ($finalStatus -ne 'success') {
    if ($finalStatus -eq 'gated') {
        Write-Host "一期验证进入 gated：$($workspaceValidation.reason)"
        exit 0
    }

    throw "一期验证失败：$failure"
}
