$ErrorActionPreference = 'Stop'
$root = 'D:\DSH_Workspace\Prog2_app'
$tools = Join-Path $root '.tools'
New-Item -ItemType Directory -Force -Path $tools | Out-Null
$log = Join-Path $tools 'vs-install.log'

function Log([string]$message) {
    $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $message
    Write-Host $line
    Add-Content -Path $log -Value $line -Encoding UTF8
}

Log "start"
$isAdmin = (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Log "elevated=$isAdmin"

try {
    $regPath = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock'
    & reg.exe add $regPath /v AllowDevelopmentWithoutDevLicense /t REG_DWORD /d 1 /f | Out-Null
    $code1 = $LASTEXITCODE
    & reg.exe add $regPath /v AllowAllTrustedApps /t REG_DWORD /d 1 /f | Out-Null
    $code2 = $LASTEXITCODE
    Log "devmode exit=$code1/$code2"
} catch {
    Log "devmode failed: $($_.Exception.Message)"
}

$installer = Join-Path $tools 'vs_buildtools.exe'
if (-not (Test-Path $installer) -or (Get-Item $installer).Length -lt 1000000) {
    Log 'downloading bootstrapper'
    & curl.exe -L --max-time 300 -o $installer 'https://aka.ms/vs/17/release/vs_buildtools.exe'
    Log "curl exit=$LASTEXITCODE"
}
Log ("bootstrapper bytes=" + (Get-Item $installer).Length)

$argList = '--quiet --wait --norestart --nocache --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended'
Log 'installing VCTools (20-40 min)...'
$proc = Start-Process -FilePath $installer -ArgumentList $argList -Wait -PassThru
Log ("installer_exit=" + $proc.ExitCode)

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (Test-Path $vswhere) {
    $vsPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    Log ("vs_path=" + $vsPath)
} else {
    Log 'vswhere_missing'
}
Log 'done'
