param(
  [string]$Exe = 'D:\DSH_Workspace\Prog2_app\app\build\windows\x64\runner\Release\loop.exe',
  [string]$Mock = 'D:\DSH_Workspace\Prog2_app\docs\streaming-evidence\tools\mock_llm.py',
  [string]$Root = (Join-Path $env:TEMP 'loop-t13-evidence\run2')
)
$ErrorActionPreference = 'Stop'
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
. "$env:TEMP\loop-t13-evidence\ui.ps1"
if (Test-Path $Root) { Remove-Item $Root -Recurse -Force }
New-Item -ItemType Directory -Force $Root | Out-Null
$logPath = Join-Path $Root 'run2.log'
$jsonPath = Join-Path $Root 'run2-results.jsonl'
$script:fail = 0
$script:appProc = $null
$script:mockProc = $null
$script:mockId = $null
function Log([string]$msg) { $line = "$(Get-Date -Format 'HH:mm:ss.fff') $msg"; $line | Tee-Object -FilePath $logPath -Append | Out-Host }
function Rec([string]$id, [string]$status, [string]$detail, $data = $null) {
  $obj = [ordered]@{ id=$id; status=$status; detail=$detail; at=(Get-Date -Format 'HH:mm:ss.fff') }
  if ($null -ne $data) { $obj.data = $data }
  ($obj | ConvertTo-Json -Compress -Depth 8) | Add-Content $jsonPath
  if ($status -eq 'FAIL') { $script:fail++ }
  Log ("[{0}] {1} {2}" -f $status, $id, $detail)
}
function Check([string]$id, [bool]$cond, [string]$detail, $data = $null) { if ($cond) { Rec $id 'PASS' $detail $data } else { Rec $id 'FAIL' $detail $data }; return $cond }
function Wait-Until([scriptblock]$cond, [int]$timeoutMs = 15000, [int]$intervalMs = 50) {
  $deadline = [DateTime]::Now.AddMilliseconds($timeoutMs)
  while ([DateTime]::Now -lt $deadline) { try { $v = & $cond } catch { $v = $null }; if ($v) { return $v }; Start-Sleep -Milliseconds $intervalMs }
  return $null
}
function Get-AnswerList([int]$processId) { @(Get-AnswerWindows $processId) }
function Wait-Answer([int]$processId, [int]$timeoutMs = 20000, [bool]$requireVisible = $false) {
  $deadline = [DateTime]::Now.AddMilliseconds($timeoutMs)
  while ([DateTime]::Now -lt $deadline) {
    $a = @(Get-AnswerWindows $processId)
    if ($a.Count -gt 0 -and (-not $requireVisible -or $a[0].Visible)) { return $a[0] }
    Start-Sleep -Milliseconds 50
  }
  return $null
}
trap {
  Log "FATAL: $_"
  try { if ($script:appProc -and -not $script:appProc.HasExited) { Stop-Process -Id $script:appProc.Id -Force -ErrorAction SilentlyContinue } } catch {}
  try { if ($script:mockProc) { Stop-Process -Id $script:mockProc.Id -Force -ErrorAction SilentlyContinue } } catch {}
  try { [FgSampler]::Stop() } catch {}
  exit 3
}
function Clear-Input([int]$processId) {
  $w = Get-MainWindow $processId; Activate-Hwnd ([IntPtr]$w.HwndInt); $dpr = $w.Dpi / 96.0
  Click-At ([int]($w.Left + 1200*$dpr)) ([int]($w.Bottom - 55*$dpr))
  Start-Sleep -Milliseconds 200; [void][W32T]::PressVk(0x23); Start-Sleep -Milliseconds 60
  for ($i = 0; $i -lt 90; $i++) { [void][W32T]::PressVk(0x08); Start-Sleep -Milliseconds 6 }
  Start-Sleep -Milliseconds 150
}
function Submit([int]$processId, [string]$text) {
  Clear-Input $processId; Send-Text $text 45 | Out-Null; Start-Sleep -Milliseconds 250; Send-Enter
  Log "submit text=$text"
}
function Get-ComposerTop([string]$shotPath, [int]$relX) {
  Add-Type -AssemblyName System.Drawing
  $img = [System.Drawing.Bitmap]::FromFile($shotPath); $prev = $null; $found = -1
  for ($y = [Math]::Max(0, $img.Height - 260); $y -lt $img.Height; $y++) {
    $c = $img.GetPixel($relX, $y); $v = [int](($c.R+$c.G+$c.B)/3)
    if ($null -ne $prev -and [Math]::Abs($v-$prev) -gt 7) { $found = $y; break }
    $prev = $v
  }
  $img.Dispose(); return $found
}

# ---- environment
$existing = @(Get-Process loop -ErrorAction SilentlyContinue)
if ($existing.Count -gt 0) { throw "LOOP_INSTANCE_RUNNING pid=$($existing[0].Id)" }
if (Get-NetTCPConnection -State Listen -LocalPort 8765,9999 -ErrorAction SilentlyContinue) { throw 'PORT_IN_USE' }
$dataDir = Join-Path $Root 'data'; New-Item -ItemType Directory -Force $dataDir | Out-Null
New-Item -ItemType File -Force (Join-Path $dataDir 'loop.db') | Out-Null
$env:LOOP_DATA_DIR = $dataDir
Remove-Item Env:LOOP_THEME -ErrorAction SilentlyContinue
$mock = Start-Process python -ArgumentList @($Mock) -PassThru -WindowStyle Hidden -RedirectStandardOutput (Join-Path $Root 'mock-out.log') -RedirectStandardError (Join-Path $Root 'mock-err.log')
$script:mockProc = $mock; $script:mockId = $mock.Id; Start-Sleep -Milliseconds 900
$app = Start-Process -FilePath $Exe -PassThru -RedirectStandardOutput (Join-Path $Root 'app-out.log') -RedirectStandardError (Join-Path $Root 'app-err.log')
$script:appProc = $app
$health = $null
for ($i = 0; $i -lt 80; $i++) { try { $health = Invoke-RestMethod 'http://127.0.0.1:8765/api/health' -TimeoutSec 1; break } catch { Start-Sleep -Milliseconds 300 } }
if ($null -eq $health) { throw 'health failed' }
Invoke-RestMethod -Method Put -Uri 'http://127.0.0.1:8765/api/settings' -ContentType 'application/json' -Body '{"api_key":"test-key","base_url":"http://127.0.0.1:9999","model":"mock"}' | Out-Null
Invoke-RestMethod -Method Put -Uri 'http://127.0.0.1:8765/api/settings' -ContentType 'application/json' -Body '{"stream_output":true}' | Out-Null
for ($i = 0; $i -lt 60; $i++) { $main = Get-MainWindow $app.Id; if ($main) { break }; Start-Sleep -Milliseconds 250 }
if (-not $main) { throw 'main window missing' }
Start-Sleep -Milliseconds 1200
$fgPath = Join-Path $Root 'foreground.tsv'; [FgSampler]::Start($fgPath)
Rec 'E-02-01' 'INFO' "startup main=$($main.Left),$($main.Top),$($main.Width),$($main.Height) dpi=$($main.Dpi)" $main

# ---- monitors (queried independently with DPI-aware P/Invoke before this run)
$secondary = @{ Left = -2560; Top = -58; Width = 2560; Height = 1600; Dpi = 144 }
$primary = @{ Left = 0; Top = 0; Width = 2560; Height = 1440; Dpi = 120 }
Rec 'E-02-02' 'INFO' 'monitors: primary 2560x1440@125% (work=monitor, taskbar auto-hidden); secondary 2560x1600@150% at (-2560,-58)' @{ primary=$primary; secondary=$secondary }

# ---- move main to secondary, 150% DPI
$hwnd = [IntPtr]$main.HwndInt
[void][W32T]::SetWindowPos($hwnd, [IntPtr]::Zero, -2500, 100, 0, 0, 0x0001 -bor 0x0004 -bor 0x0010)
Start-Sleep -Milliseconds 1800
$mainSec = Get-MainWindow $app.Id
$dprSec = $mainSec.Dpi / 96.0
Check 'D-02-01' ([Math]::Abs($dprSec - 1.5) -lt 0.01) "主窗移到副屏 -> DPR 1.5 (dpi=$($mainSec.Dpi))" $mainSec
[void][W32T]::SetWindowPos($hwnd, [IntPtr]::Zero, -2500, 100, 2160, 1350, 0x0004 -bor 0x0010)
Start-Sleep -Milliseconds 1200
$mainSec = Get-MainWindow $app.Id
Check 'D-02-02' ([Math]::Abs($mainSec.Width - 2160) -le 4 -and [Math]::Abs($mainSec.Height - 1350) -le 4) "副屏主窗 1440x900 逻辑 ($($mainSec.Width)x$($mainSec.Height) phys)" $mainSec
Check 'D-02-03' ($mainSec.Left -ge $secondary.Left -and $mainSec.Top -ge $secondary.Top -and $mainSec.Right -le 0) '主窗中心位于副屏工作区'
Save-WindowShot ([IntPtr]$mainSec.HwndInt) (Join-Path $Root '01-main-secondary.png') | Out-Null

# ---- long answer on secondary (maxH uses secondary work height)
$t0 = Get-Date
Submit $app.Id '长回复'
$ansSec = Wait-Answer $app.Id 20000 $true
$createMs = if ($ansSec) { [int]((Get-Date)-$t0).TotalMilliseconds } else { -1 }
Check 'D-03-01' ($null -ne $ansSec) "副屏创建回答窗 firstVisible=${createMs}ms" @{ latencyMs=$createMs }
Start-Sleep -Milliseconds 3200
$ansSec = @(Get-AnswerList $app.Id)[0]
$ansDpr = $ansSec.Dpi / 96.0
Check 'D-03-02' ([Math]::Abs($ansDpr - 1.5) -lt 0.01) "回答窗 DPR 1.5 (dpi=$($ansSec.Dpi))" $ansSec
Check 'D-03-03' ($ansSec.Left -ge $secondary.Left -and $ansSec.Top -ge $secondary.Top -and $ansSec.Right -le 0 -and $ansSec.Bottom -le ($secondary.Top + $secondary.Height)) '回答窗完全位于副屏工作区' $ansSec
Check 'D-03-04' ([Math]::Abs($ansSec.Width - 896) -le 2) "副屏宽度 896 phys = 597.3 逻辑（35% of 1706.7）" @{ width=$ansSec.Width; logical=[Math]::Round($ansSec.Width/$ansDpr,1) }
Check 'D-03-05' ([Math]::Abs($ansSec.Height - 1120) -le 2) "副屏 maxH = min(1066.7*0.7, 760)=746.7 逻辑 -> 1120 phys" @{ height=$ansSec.Height; logical=[Math]::Round($ansSec.Height/$ansDpr,1) }
$shotMainSec = Join-Path $Root '02-main-secondary-with-answer.png'
Save-WindowShot ([IntPtr]$mainSec.HwndInt) $shotMainSec | Out-Null
$composerTopRel = Get-ComposerTop $shotMainSec 500
$composerTopAbs = $mainSec.Top + $composerTopRel
$gapSec = $composerTopAbs - $ansSec.Bottom
Check 'D-03-06' ($composerTopRel -gt 0 -and $gapSec -ge (8*$ansDpr - 1)) "副屏回答窗不遮挡输入条 gap=$gapSec phys (期望 12)" @{ composerTopRel=$composerTopRel; answerBottom=$ansSec.Bottom; gap=$gapSec }
Check 'D-03-07' ([W32T]::GetForegroundWindow() -eq [IntPtr]$mainSec.HwndInt) '副屏创建/流式期间前台仍为主窗'
Save-WindowShot ([IntPtr]$ansSec.HwndInt) (Join-Path $Root '03-answer-secondary.png') | Out-Null

# ---- auto mode: programmatic main -> primary; Shell 500ms sync / geometryEpoch should re-anchor
$ansAutoBefore = @(Get-AnswerList $app.Id)[0]
[void][W32T]::SetWindowPos([IntPtr]$mainSec.HwndInt, [IntPtr]::Zero, 380, 157, 0, 0, 0x0001 -bor 0x0004 -bor 0x0010)
Start-Sleep -Milliseconds 1200
$mainPrim = Get-MainWindow $app.Id
[void][W32T]::SetWindowPos([IntPtr]$mainPrim.HwndInt, [IntPtr]::Zero, 380, 157, 1800, 1125, 0x0004 -bor 0x0010)
Start-Sleep -Milliseconds 3200
$mainPrim = Get-MainWindow $app.Id
Check 'D-05-01' ([Math]::Abs(($mainPrim.Dpi/96.0) - 1.25) -lt 0.01) "主窗回主屏 -> DPR 1.25 (dpi=$($mainPrim.Dpi))" $mainPrim
$ansPrim = @(Get-AnswerList $app.Id)
Check 'D-05-02' ($ansPrim.Count -eq 1 -and $ansPrim[0].Visible) '自动模式跨屏后回答窗仍可见' $ansPrim
if ($ansPrim.Count -eq 1) {
  $a = $ansPrim[0]
  Check 'D-05-03' ($a.Left -ge -2 -and $a.Top -ge -2 -and $a.Right -le 2562 -and $a.Bottom -le 1442 -and [Math]::Abs(($a.Dpi/96.0) - 1.25) -lt 0.01) "自动模式回答窗跟随回主屏/DPI 1.25 rect=$($a.Left),$($a.Top),$($a.Width),$($a.Height) dpi=$($a.Dpi)" $a
  Check 'D-05-04' ([Math]::Abs($a.Width - 747) -le 4) "宽度逻辑固定 597.3（主屏 747 phys）" @{ width=$a.Width; logical=[Math]::Round($a.Width/($a.Dpi/96.0),1) }
  Check 'D-05-05' ([Math]::Abs($a.Height - 950) -le 4) "主屏 maxH 760 逻辑 -> 950 phys" @{ height=$a.Height; logical=[Math]::Round($a.Height/($a.Dpi/96.0),1) }
  Save-WindowShot ([IntPtr]$a.HwndInt) (Join-Path $Root '05-answer-back-primary.png') | Out-Null
}
$shotPrim = Join-Path $Root '06-main-primary-with-answer.png'
Save-WindowShot ([IntPtr]$mainPrim.HwndInt) $shotPrim | Out-Null
$composerTopRel2 = Get-ComposerTop $shotPrim 500
$composerTopAbs2 = $mainPrim.Top + $composerTopRel2
$gapPrim = $composerTopAbs2 - (@(Get-AnswerList $app.Id)[0]).Bottom
Check 'D-05-06' ($composerTopRel2 -gt 0 -and $gapPrim -ge 8) "跨屏/跨 DPI 后回答窗仍不遮挡输入条 gap=$gapPrim phys" @{ composerTopRel=$composerTopRel2; gap=$gapPrim }

# ---- back to 150% secondary: auto answer follows again
[void][W32T]::SetWindowPos([IntPtr]$mainPrim.HwndInt, [IntPtr]::Zero, -2500, 100, 0, 0, 0x0001 -bor 0x0004 -bor 0x0010)
Start-Sleep -Milliseconds 1200
$mainSec2 = Get-MainWindow $app.Id
[void][W32T]::SetWindowPos([IntPtr]$mainSec2.HwndInt, [IntPtr]::Zero, -2500, 100, 2160, 1350, 0x0004 -bor 0x0010)
Start-Sleep -Milliseconds 3200
$mainSec2 = Get-MainWindow $app.Id
$ansBack = @(Get-AnswerList $app.Id)
Check 'D-06-01' ([Math]::Abs(($mainSec2.Dpi/96.0) - 1.5) -lt 0.01 -and $ansBack.Count -eq 1 -and [Math]::Abs(($ansBack[0].Dpi/96.0) - 1.5) -lt 0.01 -and $ansBack[0].Left -ge $secondary.Left - 2 -and $ansBack[0].Top -ge $secondary.Top - 2 -and $ansBack[0].Right -le 2) "自动模式回 150% 副屏：主/答案 DPI 1.5 且在工作区" $ansBack
if ($ansBack.Count -eq 1) {
  Check 'D-06-02' ([Math]::Abs($ansBack[0].Width - 896) -le 4 -and [Math]::Abs($ansBack[0].Height - 1120) -le 5) "回副屏 width/height=896×1120 phys" $ansBack[0]
}

# ---- user-moved answer on secondary; main moves on primary must NOT clamp it back (T5-06)
$ansMove = @(Get-AnswerList $app.Id)[0]
$ax = [int]($ansMove.Left + 200); $ay = [int]($ansMove.Top + 22)
Drag-At $ax $ay ($ax - 1200) ($ay - 400) 18 120
Start-Sleep -Milliseconds 900
$ansMoved = @(Get-AnswerList $app.Id)[0]
Check 'D-07-01' ($ansMoved.Left -ge $secondary.Left - 2 -and $ansMoved.Top -ge $secondary.Top - 2 -and $ansMoved.Right -le 2) "拖动越界后仍钳制在副屏工作区 rect=$($ansMoved.Left),$($ansMoved.Top),$($ansMoved.Width),$($ansMoved.Height)" $ansMoved
Save-WindowShot ([IntPtr]$ansMoved.HwndInt) (Join-Path $Root '04-answer-secondary-moved.png') | Out-Null
$movedRect = [pscustomobject]@{ Left=$ansMoved.Left; Top=$ansMoved.Top; Width=$ansMoved.Width; Height=$ansMoved.Height; Dpi=$ansMoved.Dpi }
[void][W32T]::SetWindowPos([IntPtr]$mainSec2.HwndInt, [IntPtr]::Zero, 380, 157, 0, 0, 0x0001 -bor 0x0004 -bor 0x0010)
Start-Sleep -Milliseconds 1200
$mainPrim3 = Get-MainWindow $app.Id
[void][W32T]::SetWindowPos([IntPtr]$mainPrim3.HwndInt, [IntPtr]::Zero, 380, 157, 1800, 1125, 0x0004 -bor 0x0010)
Start-Sleep -Milliseconds 3200
$mainPrim3 = Get-MainWindow $app.Id
$ansStay = @(Get-AnswerList $app.Id)
Check 'D-07-02' ([Math]::Abs(($mainPrim3.Dpi/96.0) - 1.25) -lt 0.01) "主窗回主屏 DPI 1.25" $mainPrim3
Check 'D-07-03' ($ansStay.Count -eq 1 -and [Math]::Abs(($ansStay[0].Dpi/96.0) - 1.5) -lt 0.01 -and $ansStay[0].Left -ge $secondary.Left - 2 -and $ansStay[0].Right -le 2) "T5-06 用户拖到副屏的回答窗不被主窗移动拉回/改 DPI rect=$($ansStay[0].Left),$($ansStay[0].Top),$($ansStay[0].Width),$($ansStay[0].Height) dpi=$($ansStay[0].Dpi)" $ansStay
Check 'D-07-04' ($ansStay.Count -eq 1 -and [Math]::Abs($ansStay[0].Left - $movedRect.Left) -le 2 -and [Math]::Abs($ansStay[0].Top - $movedRect.Top) -le 2) "T5-06 用户位置保持不变" @{ moved=$movedRect; after=if($ansStay.Count){$ansStay[0]}else{$null} }

# ---- cleanup via tray quit
$ansNow = @(Get-AnswerList $app.Id)
if ($ansNow.Count -eq 1) { Rec 'X-02-00' 'INFO' 'answer open at quit' $ansNow }
$startQuit = Get-Date
[void][W32T]::PostMessage([IntPtr]$mainPrim3.HwndInt, 0x0111, [IntPtr]1027, [IntPtr]::Zero)
$answerGoneAt = $null; $exitedAt = $null
for ($i = 0; $i -lt 160; $i++) {
  if ($null -eq $answerGoneAt -and @(Get-AnswerList $app.Id).Count -eq 0) { $answerGoneAt = (Get-Date) }
  if ($app.HasExited) { $exitedAt = (Get-Date); break }
  Start-Sleep -Milliseconds 50
}
Check 'D-06-01' ($app.HasExited) 'tray 退出：进程退出'
Check 'D-06-02' ($null -ne $answerGoneAt -and $null -ne $exitedAt -and $answerGoneAt -le $exitedAt) '多屏/回答窗存在时退出无孤儿' @{ answerGoneMs = if($answerGoneAt){[int]($answerGoneAt-$startQuit).TotalMilliseconds}else{-1}; exitMs = if($exitedAt){[int]($exitedAt-$startQuit).TotalMilliseconds}else{-1} }
[FgSampler]::Stop()
$fgLines = @(Get-Content $fgPath | ForEach-Object {
  $p = $_ -split "`t"
  if ($p.Count -ge 2) {
    $f = $p[1] -split '\|'
    if ($f.Count -ge 3) { [pscustomobject]@{ T=[int]$p[0]; Hwnd=$f[0]; Class=$f[1]; Focus=$f[2] } }
  }
})
$episodes = New-Object System.Collections.ArrayList
for ($i = 0; $i -lt $fgLines.Count; $i++) {
  if ($fgLines[$i].Class -eq 'FLUTTER_MULTI_WINDOW_WIN32_WINDOW') {
    $endT = if ($i+1 -lt $fgLines.Count) { $fgLines[$i+1].T } else { $fgLines[$i].T }
    [void]$episodes.Add([pscustomobject]@{ StartMs=$fgLines[$i].T; DurationMs=($endT-$fgLines[$i].T) })
  }
}
$over100 = @($episodes | Where-Object { $_.DurationMs -gt 100 })
$maxEpisode = if ($episodes.Count) { ($episodes | Measure-Object -Property DurationMs -Maximum).Maximum } else { 0 }
Check 'D-09-01' ($over100.Count -eq 0) "多屏/拖动/流式期间回答窗前台停留 <=100ms（max=${maxEpisode}ms）" @{ episodes=$episodes }
Get-CimInstance Win32_Process -Filter "Name='python.exe'" | Where-Object { $_.CommandLine -match 'mock_llm' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
if (-not $app.HasExited) { Stop-Process -Id $app.Id -Force -ErrorAction SilentlyContinue }
Log "DONE failures=$($script:fail)"
[ordered]@{ failures=$script:fail; completedAt=(Get-Date -Format o) } | ConvertTo-Json | Set-Content (Join-Path $Root 'summary.json') -Encoding UTF8
if ($script:fail -gt 0) { exit 2 } else { exit 0 }
