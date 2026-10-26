param(
  [Parameter(Mandatory = $true)][int]$ParentPid,
  [Parameter(Mandatory = $true)][string]$InstallDir,
  [Parameter(Mandatory = $true)][string]$StagingDir,
  [Parameter(Mandatory = $true)][string]$ExeName,
  [Parameter(Mandatory = $true)][string]$BackupDir,
  [Parameter(Mandatory = $true)][string]$LogPath,
  [switch]$NoRestart
)

# IMPORTANT: keep this file ASCII-only. Windows PowerShell 5.1 reads .ps1 as ANSI
# when there is no BOM, and non-ASCII comments can break parsing.

$ErrorActionPreference = 'Stop'

function Write-Log([string]$message) {
  try {
    Add-Content -Path $LogPath -Encoding UTF8 -Value ("[{0}] {1}" -f (Get-Date -Format 's'), $message)
  } catch {}
}

function Start-Loop {
  if ($NoRestart) {
    Write-Log 'restart skipped (NoRestart)'
    return
  }
  $exe = Join-Path $InstallDir $ExeName
  if (Test-Path $exe) {
    Start-Process -FilePath $exe -WorkingDirectory $InstallDir
  }
}

# User data entries: never overwrite them and never copy them into the backup.
$userDataNames = @(
  'loop.db', 'loop.db-wal', 'loop.db-shm',
  'files', 'uploads', 'subjects', 'skills', 'mcp',
  'logs', 'tmp', 'backups', 'trash', 'tray.ico'
)

function Copy-InstallToBackup {
  if (Test-Path $BackupDir) {
    Remove-Item -Path $BackupDir -Recurse -Force -ErrorAction SilentlyContinue
  }
  New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
  foreach ($item in Get-ChildItem -Path $InstallDir -Force) {
    if ($item.Name -eq 'data') {
      $dataBackup = Join-Path $BackupDir 'data'
      New-Item -ItemType Directory -Force -Path $dataBackup | Out-Null
      foreach ($child in Get-ChildItem -Path $item.FullName -Force) {
        if ($userDataNames -contains $child.Name) { continue }
        Copy-Item -Path $child.FullName -Destination $dataBackup -Recurse -Force
      }
    } else {
      Copy-Item -Path $item.FullName -Destination $BackupDir -Recurse -Force
    }
  }
}

Write-Log "updater start parent=$ParentPid install=$InstallDir staging=$StagingDir"

try {
  # Wait up to 120 seconds for the app to exit; abort instead of overwriting a running app.
  $waited = 0
  while ($waited -lt 120) {
    $process = Get-Process -Id $ParentPid -ErrorAction SilentlyContinue
    if (-not $process) { break }
    Start-Sleep -Milliseconds 500
    $waited += 0.5
  }
  if (Get-Process -Id $ParentPid -ErrorAction SilentlyContinue) {
    Write-Log 'parent still running after 120s, abort'
    exit 2
  }
  Start-Sleep -Milliseconds 800

  Write-Log "backup to $BackupDir (user data excluded)"
  Copy-InstallToBackup

  Write-Log 'copy staging to install'
  Copy-Item -Path (Join-Path $StagingDir '*') -Destination $InstallDir -Recurse -Force

  Write-Log 'restart new version'
  Start-Loop
  Write-Log 'update done'
  exit 0
}
catch {
  Write-Log "ERROR: $($_.Exception.Message)"
  try {
    if (Test-Path $BackupDir) {
      Write-Log 'rollback from backup'
      Copy-Item -Path (Join-Path $BackupDir '*') -Destination $InstallDir -Recurse -Force
    }
    Start-Loop
  } catch {
    Write-Log "ROLLBACK ERROR: $($_.Exception.Message)"
  }
  exit 1
}