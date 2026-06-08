[Console]::InputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)
chcp 65001 > $null
$ErrorActionPreference = 'Stop'

$ProductRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$RuntimeExe = Join-Path $ProductRoot 'runtime\TiaMcpServer.exe'
$PidFile = Join-Path $ProductRoot 'reports\latest\tia-http.pid'

$targets = @(Get-Process -Name 'TiaMcpServer' -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -eq $RuntimeExe })

if ($targets.Count -eq 0) {
    Write-Host "未发现独立一期 runtime 下的 TiaMcpServer.exe 进程。"
}
else {
    foreach ($target in $targets) {
        Write-Host "停止一期 MCP 服务：PID=$($target.Id)"
        Stop-Process -Id $target.Id -Force
    }
}

if (Test-Path -LiteralPath $PidFile) {
    Remove-Item -LiteralPath $PidFile -Force
}
