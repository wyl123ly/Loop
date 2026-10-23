# 构建纯 Flutter Windows 版（后端在进程内，无 Python、无 sidecar）
# 用法：powershell -ExecutionPolicy Bypass -File packaging\build_native.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

Write-Host '[1/3] 构建原生 Flutter Windows...'
$flutterCmd = Get-Command flutter -ErrorAction SilentlyContinue
$flutter = if ($flutterCmd) { $flutterCmd.Source } else { Join-Path $root '.tools\flutter\bin\flutter.bat' }
if (-not (Test-Path $flutter)) { throw '找不到 flutter，先安装 Flutter SDK 并加入 PATH' }
Push-Location app
& $flutter build windows --release
$code = $LASTEXITCODE
Pop-Location
if ($code -ne 0) { throw "flutter build windows 失败：$code" }

Write-Host '[2/3] 组装 release\Loop-Desktop ...'
$src = Join-Path $root 'app\build\windows\x64\runner\Release'
$out = Join-Path $root 'release\Loop-Desktop'
if (Test-Path $out) { Remove-Item $out -Recurse -Force }
New-Item -ItemType Directory -Force -Path $out | Out-Null
Copy-Item (Join-Path $src '*') $out -Recurse -Force
if (Test-Path (Join-Path $out 'loop.exe')) {
    Rename-Item (Join-Path $out 'loop.exe') 'Loop.exe'
}
# 清理旧版遗留的 sidecar（如果存在）
Remove-Item (Join-Path $out 'LoopServer.exe') -Force -ErrorAction SilentlyContinue
if (Test-Path 'packaging\native-readme.txt') {
    Copy-Item 'packaging\native-readme.txt' (Join-Path $out '使用说明.txt') -Force
}

# 写入更新校验用的版本文件（不依赖 tag）
$versionLine = Get-Content (Join-Path $root 'app\pubspec.yaml') | Where-Object { $_ -match '^version:' } | Select-Object -First 1
$appVersion = ($versionLine -replace '^version:\s*', '') -replace '\+.*$', ''
$appVersion = $appVersion.Trim()
$versionJson = (@{ version = $appVersion } | ConvertTo-Json -Compress)
[IO.File]::WriteAllText((Join-Path $out 'version.json'), $versionJson, (New-Object System.Text.UTF8Encoding($false)))

Write-Host '[3/3] 压缩...'
$zip = Join-Path $root 'release\Loop-Desktop-win64.zip'
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path (Join-Path $out '*') -DestinationPath $zip -Force

Write-Host "完成：$out"
Write-Host "压缩包：$zip"
