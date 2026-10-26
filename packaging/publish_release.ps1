param(
  [Parameter(Mandatory = $true)][string]$Tag,
  [string]$Token = $env:GITHUB_TOKEN,
  [string]$Repo = 'wyl123ly/Loop',
  [string]$Zip = 'release\Loop-Desktop-win64.zip',
  [string]$NotesFile = '',
  [switch]$NoAsset
)

# Publish a GitHub Release and upload the Windows zip in one command.
# IMPORTANT: keep this file ASCII-only (Windows PowerShell 5.1 reads .ps1 as ANSI).
#
# Usage:
#   $env:GITHUB_TOKEN = 'ghp_xxx'   # token needs repo scope
#   powershell -ExecutionPolicy Bypass -File packaging\publish_release.ps1 -Tag v0.8.9
#
# The token is only read from the environment/parameter and never written to disk.

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if ([string]::IsNullOrWhiteSpace($Token)) {
  Write-Host 'Missing GitHub token. Set $env:GITHUB_TOKEN (repo scope required).' -ForegroundColor Red
  exit 2
}
if (-not (Test-Path $Zip)) {
  Write-Host "Update zip not found: $Zip" -ForegroundColor Red
  exit 2
}

$version = $Tag.TrimStart('v', 'V')
$releaseName = "Loop v$version"
if ([string]::IsNullOrWhiteSpace($NotesFile)) {
  $candidate = "docs\release-v$version.md"
  if (Test-Path $candidate) { $NotesFile = $candidate }
}
$body = ''
if (-not [string]::IsNullOrWhiteSpace($NotesFile) -and (Test-Path $NotesFile)) {
  $body = Get-Content $NotesFile -Raw -Encoding UTF8
}

$headers = @{
  Authorization          = "Bearer $Token"
  Accept                 = 'application/vnd.github+json'
  'User-Agent'           = 'Loop-Release-Publisher'
  'X-GitHub-Api-Version' = '2022-11-28'
}

function Invoke-GitHub([string]$Method, [string]$Uri, $Body) {
  if ($null -eq $Body) {
    return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $headers -TimeoutSec 60
  }
  $json = $Body | ConvertTo-Json -Depth 6
  return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $headers -TimeoutSec 60 `
    -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($json))
}

Write-Host "[1/3] Find or create release $Tag ..."
$release = $null
try {
  $release = Invoke-GitHub 'GET' "https://api.github.com/repos/$Repo/releases/tags/$Tag" $null
  Write-Host "      release exists: $($release.html_url)"
} catch {
  $payload = @{
    tag_name   = $Tag
    name       = $releaseName
    body       = $body
    draft      = $false
    prerelease = $false
  }
  $release = Invoke-GitHub 'POST' "https://api.github.com/repos/$Repo/releases" $payload
  Write-Host "      release created: $($release.html_url)"
}

if ($NoAsset) {
  Write-Host '[2/3] asset upload skipped (-NoAsset)'
  Write-Host '[3/3] done'
  exit 0
}

$assetName = [IO.Path]::GetFileName($Zip)
$existing = @($release.assets | Where-Object { $_.name -eq $assetName })
foreach ($asset in $existing) {
  Write-Host "[2/3] delete old asset $assetName ..."
  Invoke-GitHub 'DELETE' "https://api.github.com/repos/$Repo/releases/assets/$($asset.id)" $null | Out-Null
}

Write-Host "[2/3] upload $assetName ($([math]::Round((Get-Item $Zip).Length / 1MB, 1)) MB) ..."
$uploadUrl = "https://uploads.github.com/repos/$Repo/releases/$($release.id)/assets?name=$assetName"
Invoke-RestMethod -Method 'POST' -Uri $uploadUrl -Headers $headers -TimeoutSec 900 `
  -ContentType 'application/zip' -InFile $Zip | Out-Null

Write-Host '[3/3] done. Auto update may take up to 1 hour to see it (GitHub API cache).'