param(
  [Parameter(Mandatory = $true)][int]$ParentPid,
  [Parameter(Mandatory = $true)][string]$InstallDir,
  [Parameter(Mandatory = $true)][string]$StagingDir,
  [Parameter(Mandatory = $true)][string]$ExeName,
  [Parameter(Mandatory = $true)][string]$BackupDir,
  [Parameter(Mandatory = $true)][string]$LogPath
)

$ErrorActionPreference = 'Stop'

function Write-Log([string]$message) {
  try {
    Add-Content -Path $LogPath -Encoding UTF8 -Value ("[{0}] {1}" -f (Get-Date -Format 's'), $message)
  } catch {}
}

function Start-Loop {
  $exe = Join-Path $InstallDir $ExeName
  if (Test-Path $exe) {
    Start-Process -FilePath $exe -WorkingDirectory $InstallDir
  }
}

Write-Log "updater start parent=$ParentPid install=$InstallDir staging=$StagingDir"

try {
  $waited = 0
  while ($waited -lt 30) {
    $process = Get-Process -Id $ParentPid -ErrorAction SilentlyContinue
    if (-not $process) { break }
    Start-Sleep -Milliseconds 500
    $waited += 0.5
  }
  if (Get-Process -Id $ParentPid -ErrorAction SilentlyContinue) {
    Write-Log "parent still running, abort"
    exit 2
  }
  Start-Sleep -Milliseconds 800

  if (Test-Path $BackupDir) {
    Remove-Item -Path $BackupDir -Recurse -Force -ErrorAction SilentlyContinue
  }
  New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
  Write-Log "backup to $BackupDir"
  Copy-Item -Path (Join-Path $InstallDir '*') -Destination $BackupDir -Recurse -Force

  Write-Log "copy staging to install"
  Copy-Item -Path (Join-Path $StagingDir '*') -Destination $InstallDir -Recurse -Force

  Write-Log "restart new version"
  Start-Loop
  Write-Log "update done"
  exit 0
}
catch {
  Write-Log "ERROR: $($_.Exception.Message)"
  try {
    if (Test-Path $BackupDir) {
      Write-Log "rollback from backup"
      Copy-Item -Path (Join-Path $BackupDir '*') -Destination $InstallDir -Recurse -Force
    }
    Start-Loop
  } catch {
    Write-Log "ROLLBACK ERROR: $($_.Exception.Message)"
  }
  exit 1
}
