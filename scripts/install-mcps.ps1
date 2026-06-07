param(
  [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
  [string]$CodexConfig = (Join-Path $env:USERPROFILE '.codex\config.toml'),
  [string]$ProfilePath = (Join-Path $RepoRoot 'profiles\current.toml'),
  [string[]]$Names = @('tia_portal_v17', 'openai-developer-docs', 'deepwiki', 'context7', 'github', 'office-document'),
  [switch]$DryRun,
  [switch]$Apply
)

$ErrorActionPreference = 'Stop'
[Console]::InputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)

function Get-Placeholders {
  param([string]$Path)

  $map = @{}
  $defaultCodexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
  $map['CODEX_HOME'] = $defaultCodexHome

  if (-not (Test-Path -LiteralPath $Path)) {
    return $map
  }

  $inPlaceholders = $false
  foreach ($line in Get-Content -Encoding UTF8 -LiteralPath $Path) {
    if ($line -match '^\s*\[placeholders\]\s*$') {
      $inPlaceholders = $true
      continue
    }
    if ($line -match '^\s*\[') {
      $inPlaceholders = $false
    }
    if ($inPlaceholders -and $line -match '^\s*([A-Za-z0-9_]+)\s*=\s*''(.*)''\s*$') {
      $map[$Matches[1]] = $Matches[2]
    }
  }
  return $map
}

function Resolve-Template {
  param(
    [string]$Text,
    [hashtable]$Placeholders
  )

  $resolved = $Text
  foreach ($key in $Placeholders.Keys) {
    $resolved = $resolved.Replace("{{$key}}", [string]$Placeholders[$key])
  }

  if ($resolved -match '\{\{[A-Za-z0-9_]+\}\}') {
    throw "Unresolved placeholder remains in MCP snippet: $($Matches[0])"
  }

  return $resolved
}

function Get-ServerName {
  param([string]$Snippet)
  if ($Snippet -notmatch '\[mcp_servers\.([A-Za-z0-9_]+)\]') {
    throw "Could not find [mcp_servers.*] section in snippet."
  }
  return $Matches[1]
}

$registry = Join-Path $RepoRoot 'registry'
if (-not (Test-Path -LiteralPath $registry)) {
  throw "Missing registry directory: $registry"
}

$placeholders = Get-Placeholders -Path $ProfilePath
$snippets = @()

foreach ($name in $Names) {
  $path = Join-Path $registry "$name.toml"
  if (-not (Test-Path -LiteralPath $path)) {
    throw "Missing registry snippet: $path"
  }
  $raw = Get-Content -Raw -Encoding UTF8 -LiteralPath $path
  $resolved = Resolve-Template -Text $raw -Placeholders $placeholders
  $snippets += [pscustomobject]@{
    Name = Get-ServerName -Snippet $resolved
    Text = $resolved.Trim()
  }
}

Write-Output "MCP snippets selected:"
foreach ($snippet in $snippets) {
  Write-Output "- $($snippet.Name)"
}

if ($DryRun -or -not $Apply) {
  Write-Output ""
  Write-Output "Dry-run preview of MCP snippets only:"
  Write-Output (($snippets | ForEach-Object { $_.Text }) -join "`r`n`r`n")
  if (-not $DryRun) {
    Write-Warning "No file was changed. Re-run with -Apply to write config.toml."
  }
  return
}

if (-not (Test-Path -LiteralPath $CodexConfig)) {
  throw "Codex config not found: $CodexConfig"
}

$current = Get-Content -Raw -Encoding UTF8 -LiteralPath $CodexConfig

foreach ($snippet in $snippets) {
  $escaped = [regex]::Escape($snippet.Name)
  $pattern = "(?ms)^\[mcp_servers\.$escaped\]\r?\n.*?(?=^\[|\z)"
  $current = [regex]::Replace($current, $pattern, '')
}

$merged = $current.TrimEnd() + "`r`n`r`n# MCP snippets from central registry`r`n" + (($snippets | ForEach-Object { $_.Text }) -join "`r`n`r`n") + "`r`n"

$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$backup = "$CodexConfig.bak_$stamp_mcp_registry"
Copy-Item -LiteralPath $CodexConfig -Destination $backup
Set-Content -Encoding UTF8 -LiteralPath $CodexConfig -Value $merged

Write-Output "Updated $CodexConfig"
Write-Output "Backup: $backup"
