param(
  [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
)

$ErrorActionPreference = 'Stop'
[Console]::InputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)

$registry = Join-Path $RepoRoot 'registry'
if (-not (Test-Path -LiteralPath $registry)) {
  throw "Missing registry directory: $registry"
}

$files = Get-ChildItem -File -LiteralPath $registry -Filter '*.toml'
if (-not $files) {
  throw "No registry TOML files found."
}

$secretPattern = 'sk-[A-Za-z0-9_-]{32,}|github_pat_[A-Za-z0-9_]{40,}|ghp_[A-Za-z0-9_]{36,}|AKIA[0-9A-Z]{16}|-----BEGIN (RSA |OPENSSH |EC |DSA )?PRIVATE KEY-----|Bearer\s+[A-Za-z0-9._-]{20,}'

foreach ($file in $files) {
  $text = Get-Content -Raw -Encoding UTF8 -LiteralPath $file.FullName
  if ($text -notmatch '\[mcp_servers\.') {
    throw "Missing [mcp_servers.*] section in $($file.FullName)"
  }
  if ($text -match $secretPattern) {
    throw "Possible secret found in $($file.FullName)"
  }
}

Write-Output "Validated $($files.Count) MCP registry files."

