param(
    [int]$Port = $(if ($env:TIA_MCP_HTTP_PORT) { [int]$env:TIA_MCP_HTTP_PORT } else { 8770 }),
    [string]$ApiKey = $(if ($env:TIA_MCP_HTTP_API_KEY) { $env:TIA_MCP_HTTP_API_KEY } else { 'codex-test-key' }),
    [int]$HttpResponseTimeoutSeconds = $(if ($env:TIA_MCP_HTTP_RESPONSE_TIMEOUT_SECONDS) { [int]$env:TIA_MCP_HTTP_RESPONSE_TIMEOUT_SECONDS } else { 300 })
)

[Console]::InputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)
chcp 65001 > $null
$ErrorActionPreference = 'Stop'

$ProductRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$RuntimeDir = Join-Path $ProductRoot 'runtime'
$ExePath = Join-Path $RuntimeDir 'TiaMcpServer.exe'
$LogDir = Join-Path $ProductRoot 'reports\latest'
$StdoutLog = Join-Path $LogDir 'tia-http.phase2.stdout.log'
$StderrLog = Join-Path $LogDir 'tia-http.phase2.stderr.log'
$PidFile = Join-Path $LogDir 'tia-http.phase2.pid'

if (-not (Test-Path -LiteralPath $ExePath)) {
    throw "未找到二期 runtime：$ExePath。请先运行 Verify-PlcSoftwareMcpV17Phase2.ps1，或手动构建并同步 runtime。"
}

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

$existing = @(Get-Process -Name 'TiaMcpServer' -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -eq $ExePath })
if ($existing) {
    $pids = @($existing | ForEach-Object { $_.Id })
    Write-Host "二期 MCP 服务已在运行：PID=$($pids -join ', ')"
    $pids[0] | Set-Content -LiteralPath $PidFile -Encoding UTF8
    return
}

$tcp = [System.Net.Sockets.TcpClient]::new()
try {
    $connect = $tcp.ConnectAsync('127.0.0.1', $Port)
    if ($connect.Wait(600) -and $tcp.Connected) {
        throw "端口 $Port 已被其他进程占用，未启动二期服务。请先停止旧 MCP 服务或换用 TIA_MCP_HTTP_PORT。"
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
    '--http-response-timeout-seconds', "$HttpResponseTimeoutSeconds",
    '--tool-profile', 'plc-software-v17-phase2',
    '--tia-major-version', '17',
    '--logging', '1'
)

$process = Start-Process -FilePath $ExePath `
    -ArgumentList $args `
    -WorkingDirectory $RuntimeDir `
    -WindowStyle Hidden `
    -RedirectStandardOutput $StdoutLog `
    -RedirectStandardError $StderrLog `
    -PassThru

$process.Id | Set-Content -LiteralPath $PidFile -Encoding UTF8
Write-Host "二期 MCP 服务已启动：PID=$($process.Id)，地址=$prefix，profile=plc-software-v17-phase2，httpTimeout=${HttpResponseTimeoutSeconds}s"
