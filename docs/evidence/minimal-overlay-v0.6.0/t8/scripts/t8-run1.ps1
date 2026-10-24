param(
  [string]$Exe = 'D:\DSH_Workspace\Prog2_app\app\build\windows\x64\runner\Release\loop.exe',
  [string]$Mock = 'D:\DSH_Workspace\Prog2_app\docs\streaming-evidence\tools\mock_llm.py',
  [string]$Root = (Join-Path $env:TEMP 'loop-t8-evidence\run1')
)
$ErrorActionPreference = 'Stop'
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
. "$env:TEMP\loop-t8-evidence\ui.ps1"

if (Test-Path $Root) { Remove-Item $Root -Recurse -Force }
New-Item -ItemType Directory -Force $Root | Out-Null
$logPath = Join-Path $Root 'run1.log'
$jsonPath = Join-Path $Root 'run1-results.jsonl'
$script:fail = 0
$script:checks = New-Object System.Collections.ArrayList
$script:appProc = $null
$script:mockProc = $null
trap {
  Log "FATAL: $_"
  try { if ($script:appProc -and -not $script:appProc.HasExited) { Stop-Process -Id $script:appProc.Id -Force -ErrorAction SilentlyContinue } } catch {}
  try { if ($script:mockProc) { Stop-Process -Id $script:mockProc.Id -Force -ErrorAction SilentlyContinue } } catch {}
  try { [FgSampler]::Stop() } catch {}
  try { [RectSampler]::Stop() } catch {}
  exit 3
}
function Log([string]$msg) {
  $line = "$(Get-Date -Format 'HH:mm:ss.fff') $msg"
  $line | Tee-Object -FilePath $logPath -Append | Out-Host
}
function Rec([string]$id, [string]$status, [string]$detail, $data = $null) {
  $obj = [ordered]@{ id=$id; status=$status; detail=$detail; at=(Get-Date -Format 'HH:mm:ss.fff') }
  if ($null -ne $data) { $obj.data = $data }
  ($obj | ConvertTo-Json -Compress -Depth 8) | Add-Content $jsonPath
  [void]$script:checks.Add($obj)
  if ($status -eq 'FAIL') { $script:fail++ }
  Log ("[{0}] {1} {2}" -f $status, $id, $detail)
}
function Check([string]$id, [bool]$cond, [string]$detail, $data = $null) {
  if ($cond) { Rec $id 'PASS' $detail $data } else { Rec $id 'FAIL' $detail $data }
  return $cond
}
function Wait-Until([scriptblock]$cond, [int]$timeoutMs = 6000, [int]$intervalMs = 50) {
  $deadline = [DateTime]::Now.AddMilliseconds($timeoutMs)
  while ([DateTime]::Now -lt $deadline) {
    try { $v = & $cond } catch { $v = $null }
    if ($v) { return $v }
    Start-Sleep -Milliseconds $intervalMs
  }
  return $null
}
function Get-AppPid { (Get-Process loop -ErrorAction SilentlyContinue | Select-Object -First 1).Id }
function Wait-Answer([int]$processId, [int]$timeoutMs = 20000, [bool]$requireVisible = $false) {
  $deadline = [DateTime]::Now.AddMilliseconds($timeoutMs)
  while ([DateTime]::Now -lt $deadline) {
    $a = @(Get-AnswerWindows $processId)
    if ($a.Count -gt 0 -and (-not $requireVisible -or $a[0].Visible)) { return $a[0] }
    Start-Sleep -Milliseconds 50
  }
  return $null
}
function Is-Topmost($w) { (([Convert]::ToInt64($w.ExStyle,16) -band 0x8) -ne 0) }
function Is-Resizable($w) { (([Convert]::ToInt64($w.Style,16) -band 0x00040000) -ne 0) }
function Get-AnswerList([int]$processId) { @(Get-AnswerWindows $processId) }
function Get-ComposerTopPhysical([string]$shotPath, [int]$relX = 500) {
  Add-Type -AssemblyName System.Drawing
  $img = [System.Drawing.Bitmap]::FromFile($shotPath)
  $start = [Math]::Max(0, $img.Height - 220)
  $prev = $null
  $found = -1
  for ($y = $start; $y -lt $img.Height; $y++) {
    $c = $img.GetPixel($relX, $y)
    $v = [int](($c.R + $c.G + $c.B) / 3)
    if ($null -ne $prev -and [Math]::Abs($v - $prev) -gt 7) { $found = $y; break }
    $prev = $v
  }
  $img.Dispose()
  return $found
}
function Clear-InputFor([string]$kind = 'main') {
  $app = Get-Process loop | Select-Object -First 1
  $w = Get-MainWindow $app.Id
  Activate-Hwnd ([IntPtr]$w.HwndInt)
  if ($kind -eq 'minimal') {
    Click-At ([int]($w.Left + $w.Width/2)) ([int]($w.Top + $w.Height/2))
  } else {
    $dpr = $w.Dpi / 96.0
    $clickX = [int]($w.Left + 1200 * $dpr)
    $clickY = [int]($w.Bottom - 55 * $dpr)
    Click-At $clickX $clickY
  }
  Start-Sleep -Milliseconds 250
  [void][W32T]::PressVk(0x23); Start-Sleep -Milliseconds 60
  for ($i = 0; $i -lt 90; $i++) { [void][W32T]::PressVk(0x08); Start-Sleep -Milliseconds 8 }
  Start-Sleep -Milliseconds 200
}
function Submit-Question([string]$text, [string]$kind = 'main', [int]$settleMs = 250) {
  Clear-InputFor $kind
  $n = Send-Text $text 45
  Start-Sleep -Milliseconds $settleMs
  Send-Enter
  Log "submit kind=$kind text=$text events=$n"
}
function Find-RedButton([string]$shotPath) {
  Add-Type -AssemblyName System.Drawing
  $img = [System.Drawing.Bitmap]::FromFile($shotPath)
  $sx = [int]($img.Width * 0.75); $sy = [int]($img.Height * 0.85)
  $sumX = 0.0; $sumY = 0.0; $count = 0
  for ($y = $sy; $y -lt $img.Height; $y += 2) {
    for ($x = $sx; $x -lt $img.Width; $x += 2) {
      $c = $img.GetPixel($x, $y)
      if ($c.R -gt 140 -and $c.G -lt 100 -and $c.B -lt 110) { $sumX += $x; $sumY += $y; $count++ }
    }
  }
  $img.Dispose()
  if ($count -lt 10) { return $null }
  return [pscustomobject]@{ X = [int]($sumX / $count); Y = [int]($sumY / $count); Count = $count }
}
function Analyze-Geometry([string]$path, [double]$dpr) {
  $rows = Get-Content $path | ForEach-Object {
    $p = $_ -split "`t"
    if ($p.Count -ge 6) { [pscustomobject]@{ T=[int]$p[0]; L=[int]$p[1]; Top=[int]$p[2]; W=[int]$p[3]; H=[int]$p[4]; Vis=$p[5] } }
  }
  $changes = New-Object System.Collections.ArrayList
  $prev = $null
  foreach ($r in $rows) {
    if ($null -eq $prev -or $r.H -ne $prev.H -or $r.W -ne $prev.W -or $r.Top -ne $prev.Top -or $r.L -ne $prev.L) {
      [void]$changes.Add($r)
    }
    $prev = $r
  }
  $intervals = @()
  for ($i = 1; $i -lt $changes.Count; $i++) { $intervals += ($changes[$i].T - $changes[$i-1].T) }
  return [pscustomobject]@{
    Samples = $rows.Count
    Changes = $changes
    DistinctHeightsPhysical = @($changes | Select-Object -ExpandProperty H -Unique)
    DistinctWidthsPhysical = @($changes | Select-Object -ExpandProperty W -Unique)
    MinHeightPhysical = ($changes | Measure-Object -Property H -Minimum).Minimum
    MaxHeightPhysical = ($changes | Measure-Object -Property H -Maximum).Maximum
    MinIntervalMs = if ($intervals.Count) { ($intervals | Measure-Object -Minimum).Minimum } else { $null }
    MaxIntervalMs = if ($intervals.Count) { ($intervals | Measure-Object -Maximum).Maximum } else { $null }
    Intervals = $intervals
    MaxHeightLogical = [Math]::Round((($changes | Measure-Object -Property H -Maximum).Maximum) / $dpr, 1)
    WidthLogical = [Math]::Round((($changes | Select-Object -First 1).W) / $dpr, 1)
  }
}

# ---------------------------------------------------------------- environment
Log "ROOT=$Root"
$existing = @(Get-Process loop -ErrorAction SilentlyContinue)
if ($existing.Count -gt 0) { throw "LOOP_INSTANCE_RUNNING pid=$($existing[0].Id) - refuse to stop user instance" }
$ports = Get-NetTCPConnection -State Listen -LocalPort 8765,9999 -ErrorAction SilentlyContinue
if ($ports) { throw "PORT_IN_USE $($ports | Out-String)" }
$dataDir = Join-Path $Root 'data'
New-Item -ItemType Directory -Force $dataDir | Out-Null
New-Item -ItemType File -Force (Join-Path $dataDir 'loop.db') | Out-Null
$env:LOOP_DATA_DIR = $dataDir
Remove-Item Env:LOOP_THEME -ErrorAction SilentlyContinue
$mockOut = Join-Path $Root 'mock-out.log'; $mockErr = Join-Path $Root 'mock-err.log'
$mockProc = Start-Process python -ArgumentList @($Mock) -PassThru -WindowStyle Hidden -RedirectStandardOutput $mockOut -RedirectStandardError $mockErr
$script:mockProc = $mockProc
Start-Sleep -Milliseconds 900
$appOut = Join-Path $Root 'app-out.log'; $appErr = Join-Path $Root 'app-err.log'
$app = Start-Process -FilePath $Exe -PassThru -RedirectStandardOutput $appOut -RedirectStandardError $appErr
$script:appProc = $app
Log "mock pid=$($mockProc.Id) app pid=$($app.Id) data=$dataDir exe=$Exe"
$health = $null
for ($i = 0; $i -lt 80; $i++) {
  try { $health = Invoke-RestMethod 'http://127.0.0.1:8765/api/health' -TimeoutSec 1; break } catch { Start-Sleep -Milliseconds 300 }
}
if ($null -eq $health) { throw 'backend health failed' }
Check 'E-ENV-01' ($health.ok -eq $true) "backend health ok version=$($health.version)" $health
Invoke-RestMethod -Method Put -Uri 'http://127.0.0.1:8765/api/settings' -ContentType 'application/json' -Body '{"api_key":"test-key","base_url":"http://127.0.0.1:9999","model":"mock"}' | Out-Null
Invoke-RestMethod -Method Put -Uri 'http://127.0.0.1:8765/api/settings' -ContentType 'application/json' -Body '{"stream_output":true}' | Out-Null
$main = $null
for ($i = 0; $i -lt 60; $i++) { $main = Get-MainWindow $app.Id; if ($main) { break }; Start-Sleep -Milliseconds 250 }
if (-not $main) { throw 'main window not found' }
Start-Sleep -Milliseconds 1200
$dpr = $main.Dpi / 96.0
Log "main hwnd=$($main.HwndInt) rect=$($main.Left),$($main.Top),$($main.Width),$($main.Height) dpr=$dpr"
Check 'E-ENV-02' ($dpr -eq 1.25) "primary display dpr=1.25" @{ dpr=$dpr; dpi=$main.Dpi }
Check 'E-ENV-03' ((Get-AnswerList $app.Id).Count -eq 0) '启动时不创建回答窗'
$fgPath = Join-Path $Root 'foreground.tsv'
[FgSampler]::Start($fgPath)

# ------------------------------------------------------------ normal window
$mm = Get-MinMaxTrack ([IntPtr]$main.HwndInt)
Check 'N-01-01' ($main.Width -eq 1800 -and $main.Height -eq 1125) "normal 1440x900@1.25 ($($main.Width)x$($main.Height))" $main
Check 'N-01-02' ($mm.MinW -eq 1125 -and $mm.MinH -eq 750) "normal WM_GETMINMAXINFO min=900x600 logical ($($mm.MinW)x$($mm.MinH) phys)" $mm
Check 'N-01-03' (-not (Is-Topmost $main)) "normal 窗口非置顶 ex=$($main.ExStyle)"
Save-WindowShot ([IntPtr]$main.HwndInt) (Join-Path $Root '01-normal.png') | Out-Null
# Empty submit must not create an answer window.
Activate-Hwnd ([IntPtr]$main.HwndInt)
$cx = [int]($main.Left + $main.Width/2); $cy = [int]($main.Bottom - 55*$dpr)
Click-At $cx $cy; Start-Sleep -Milliseconds 200; Send-Enter; Start-Sleep -Milliseconds 900
Check 'N-01-04' ((Get-AnswerList $app.Id).Count -eq 0) '空提交不创建回答窗'
# Hotkey conflict tooltip (real registration conflict=1409 observed from probe).
$hkx = [int]($main.Right - 158*$dpr); $hky = [int]($main.Top + 22*$dpr)
[void][W32T]::SetCursorPos($hkx, $hky); Start-Sleep -Milliseconds 1200
Save-WindowShot ([IntPtr]$main.HwndInt) (Join-Path $Root '02-hotkey-tooltip.png') | Out-Null
Rec 'N-01-05' 'INFO' 'Alt+Q/Alt+A system-wide conflict (RegisterHotKey error=1409); tooltip screenshot saved'
# Maximize / restore regression.
$maxX = [int]($main.Right - 69*$dpr); $maxY = [int]($main.Top + 22*$dpr)
Click-At $maxX $maxY; Start-Sleep -Milliseconds 900
$maxw = Get-MainWindow $app.Id
Check 'N-02-01' ($maxw.Width -ge 2500 -and $maxw.Height -ge 1400) "maximize -> work area ($($maxw.Width)x$($maxw.Height))" $maxw
Save-WindowShot ([IntPtr]$maxw.HwndInt) (Join-Path $Root '03-maximized.png') | Out-Null
Click-At ([int]($maxw.Right - 69*$dpr)) ([int]($maxw.Top + 22*$dpr)); Start-Sleep -Milliseconds 900
$restored = Get-MainWindow $app.Id
Check 'N-02-02' ($restored.Width -eq 1800 -and $restored.Height -eq 1125) "restore -> 1440x900 ($($restored.Width)x$($restored.Height))" $restored
Check 'N-02-03' (-not (Is-Topmost $restored)) 'normal restore 非置顶'

# --------------------------------------------------------- floating + minimal
$cur = Get-MainWindow $app.Id
Activate-Hwnd ([IntPtr]$cur.HwndInt)
Click-At ([int]($cur.Right - 158*$dpr)) ([int]($cur.Top + 22*$dpr))
$fl = Wait-Until { $w = Get-MainWindow $app.Id; if ($w -and $w.Width -lt 700) { $w } } 4000
Check 'M-01-01' ($null -ne $fl) '点击浮窗按钮进入浮窗'
$fl = Get-MainWindow $app.Id
$mmf = Get-MinMaxTrack ([IntPtr]$fl.HwndInt)
Check 'M-01-02' ($fl.Width -eq 575 -and $fl.Height -eq 750) "floating 460x600 ($($fl.Width)x$($fl.Height))" $fl
Check 'M-01-03' ($mmf.MinW -eq 450 -and $mmf.MinH -eq 525) "floating min 360x420 ($($mmf.MinW)x$($mmf.MinH) phys)" $mmf
Check 'M-01-04' (Is-Topmost $fl) "floating 置顶 ex=$($fl.ExStyle)"
Save-WindowShot ([IntPtr]$fl.HwndInt) (Join-Path $Root '04-floating.png') | Out-Null
# Pin toggle regression.
$pinX = [int]($fl.Right - 139*$dpr); $pinY = [int]($fl.Top + 22*$dpr)
Click-At $pinX $pinY; Start-Sleep -Milliseconds 500
$pinOff = Get-MainWindow $app.Id
Check 'M-01-05' (-not (Is-Topmost $pinOff)) "unpin -> 非置顶 ex=$($pinOff.ExStyle)"
Click-At $pinX $pinY; Start-Sleep -Milliseconds 500
$pinOn = Get-MainWindow $app.Id
Check 'M-01-06' (Is-Topmost $pinOn) "re-pin -> 置顶 ex=$($pinOn.ExStyle)"
# Alt+Q should be a no-op in this environment (global conflict) and must not corrupt state.
[void][W32T]::PressVk(0x12); Start-Sleep -Milliseconds 50; [void][W32T]::PressVk(0x51); Start-Sleep -Milliseconds 800
$afterAltQ = Get-MainWindow $app.Id
Check 'M-01-07' ($afterAltQ.Width -eq 575) "Alt+Q 被系统占用时为 no-op（浮窗仍 460 宽）"
# Type draft and minimize.
$fl = Get-MainWindow $app.Id
Activate-Hwnd ([IntPtr]$fl.HwndInt)
Click-At ([int]($fl.Left + $fl.Width/2)) ([int]($fl.Bottom - 55*$dpr))
Send-Text '极简草稿保留' 55 | Out-Null
Start-Sleep -Milliseconds 300
Click-At ([int]($fl.Right - 101*$dpr)) ([int]($fl.Top + 22*$dpr))
$minimal = Wait-Until { $w = Get-MainWindow $app.Id; if ($w -and $w.Height -lt 80) { $w } } 4000
Check 'M-02-01' ($null -ne $minimal) '最小化按钮进入极简'
$minimal = Get-MainWindow $app.Id
$mmm = Get-MinMaxTrack ([IntPtr]$minimal.HwndInt)
Check 'M-02-02' ($minimal.Width -eq 575 -and $minimal.Height -eq 65) "minimal 460x52 ($($minimal.Width)x$($minimal.Height) phys)" $minimal
Check 'M-02-03' ($mmm.MinW -eq 450 -and $mmm.MinH -eq 65) "minimal minSize 360x52 ($($mmm.MinW)x$($mmm.MinH) phys)" $mmm
Check 'M-02-04' (Is-Topmost $minimal) "minimal 恒置顶 ex=$($minimal.ExStyle)"
Check 'M-02-05' (-not (Is-Resizable $minimal)) "minimal 禁用缩放 style=$($minimal.Style)"
Save-WindowShot ([IntPtr]$minimal.HwndInt) (Join-Path $Root '05-minimal-bar.png') | Out-Null
$colors = Count-Colors (Join-Path $Root '05-minimal-bar.png') 2
Rec 'M-02-06' 'INFO' "minimal bar pixel colors=$colors, size=575x65 (52 logical), no message area" @{ colors=$colors }
# Drag the bar by its drag handle.
$mx1 = [int]($minimal.Left + 12*$dpr); $my1 = [int]($minimal.Top + 26*$dpr)
Drag-At $mx1 $my1 ($mx1-260) ($my1-220) 16 120
Start-Sleep -Milliseconds 500
$moved = Get-MainWindow $app.Id
Check 'M-02-07' ([Math]::Abs($moved.Width - $minimal.Width) -le 2 -and [Math]::Abs($moved.Height - $minimal.Height) -le 2 -and ($moved.Left -ne $minimal.Left -or $moved.Top -ne $minimal.Top)) "极简条可拖动且保持 460x52 delta=($($moved.Left-$minimal.Left),$($moved.Top-$minimal.Top))" $moved
Save-WindowShot ([IntPtr]$moved.HwndInt) (Join-Path $Root '06-minimal-moved.png') | Out-Null
# Submit from minimal: draft preserved + answer window.
Activate-Hwnd ([IntPtr]$moved.HwndInt)
Click-At ([int]($moved.Left + $moved.Width/2)) ([int]($moved.Top + $moved.Height/2))
Start-Sleep -Milliseconds 250
Send-Vk 0x23; Send-Enter
$m3t0 = Get-Date
$ans1 = Wait-Answer $app.Id 20000 $true
$m3createMs = if ($ans1) { [int]((Get-Date) - $m3t0).TotalMilliseconds } else { -1 }
Check 'M-03-01' ($null -ne $ans1) "极简条非空提交创建回答窗（firstVisible ${m3createMs}ms）" @{ latencyMs=$m3createMs }
Start-Sleep -Milliseconds 1000
$ans1 = @(Get-AnswerList $app.Id)[0]
$minimal2 = Get-MainWindow $app.Id
$inter = [System.Drawing.Rectangle]::Intersect(
  [System.Drawing.Rectangle]::new($ans1.Left, $ans1.Top, $ans1.Width, $ans1.Height),
  [System.Drawing.Rectangle]::new($minimal2.Left, $minimal2.Top, $minimal2.Width, $minimal2.Height))
Check 'M-03-02' ($ans1.Width -eq 896) "回答窗宽度 896 phys = 716.8 逻辑（35% of 2048）" @{ width=$ans1.Width; logical=[Math]::Round($ans1.Width/$dpr,1) }
Check 'M-03-03' ($ans1.Height -ge 223 -and $ans1.Height -le 227) "短回答高度 225 phys = 180 逻辑 (minH)" @{ height=$ans1.Height; logical=[Math]::Round($ans1.Height/$dpr,1) }
Check 'M-03-04' ($inter.Width -eq 0 -and $inter.Height -eq 0) '回答窗与极简条零交集'
Check 'M-03-05' ([W32T]::GetForegroundWindow() -eq [IntPtr]$minimal2.HwndInt) '创建回答窗后前台仍为主窗'
Save-WindowShot ([IntPtr]$ans1.HwndInt) (Join-Path $Root '07-answer-draft.png') | Out-Null
Save-WindowShot ([IntPtr]$minimal2.HwndInt) (Join-Path $Root '08-minimal-with-answer.png') | Out-Null
# Close answer via header X.
Click-At ([int]($ans1.Right - 23)) ([int]($ans1.Top + 22))
$closed = Wait-Until { @(Get-AnswerList $app.Id).Count -eq 0 } 4000
Check 'M-03-06' ($closed) '标题栏关闭按钮销毁回答窗'
# Double-click drag handle -> expand back to floating.
$minimal2 = Get-MainWindow $app.Id
DoubleClick-At ([int]($minimal2.Left + 12*$dpr)) ([int]($minimal2.Top + 26*$dpr))
$expanded = Wait-Until { $w = Get-MainWindow $app.Id; if ($w -and $w.Width -eq 575 -and $w.Height -eq 750) { $w } } 4000
Check 'M-04-01' ($null -ne $expanded) '双击拖动区恢复展开浮窗 460x600'
# Re-enter minimal then back to normal.
$expanded = Get-MainWindow $app.Id
Click-At ([int]($expanded.Right - 101*$dpr)) ([int]($expanded.Top + 22*$dpr))
$minimal3 = Wait-Until { $w = Get-MainWindow $app.Id; if ($w -and $w.Height -lt 80) { $w } } 4000
$m3 = Get-MainWindow $app.Id
Click-At ([int]($m3.Right - 21*$dpr)) ([int]($m3.Top + 26*$dpr))
$normal2 = Wait-Until { $w = Get-MainWindow $app.Id; if ($w -and $w.Width -eq 1800 -and $w.Height -eq 1125) { $w } } 5000
Check 'M-04-02' ($null -ne $normal2) '极简条返回恢复 1440x900 主窗口'
$normal2 = Get-MainWindow $app.Id
$mm2 = Get-MinMaxTrack ([IntPtr]$normal2.HwndInt)
Check 'M-04-03' ($mm2.MinW -eq 1125 -and $mm2.MinH -eq 750 -and -not (Is-Topmost $normal2)) '返回后 minSize/置顶恢复' $mm2

# ------------------------------------------------------------ long answer
Log '--- long answer phase'
Submit-Question '长回复' 'main' 300
$ansLong = Wait-Answer $app.Id 20000 $true
if (-not $ansLong) { throw 'long answer window not created' }
$initialVisibleHeight = $ansLong.Height
$geomPath = Join-Path $Root 'long-geometry.tsv'
[RectSampler]::Start($geomPath, $ansLong.HwndInt, 5)
Start-Sleep -Milliseconds 3600
[RectSampler]::Stop()
$geom = Analyze-Geometry $geomPath $dpr
Check 'A-01-01' ($geom.MaxHeightPhysical -eq 950) "长回答高度达 maxH 950 phys = 760 逻辑" $geom
Check 'A-01-02' ($geom.MinHeightPhysical -le 415 -and $initialVisibleHeight -le 225) "高度从 minH 开始增长（首帧 $initialVisibleHeight phys, 采样最小 $($geom.MinHeightPhysical)）" @{ min=$geom.MinHeightPhysical; initial=$initialVisibleHeight }
Check 'A-01-03' ($geom.DistinctWidthsPhysical.Count -eq 1 -and $geom.DistinctWidthsPhysical[0] -eq 896) '高度变化中宽度固定 896' $geom.DistinctWidthsPhysical
Check 'A-01-04' ($geom.Changes.Count -ge 2) "观测到高度多步增长 ($($geom.Changes.Count) 次)" $geom.Changes
Check 'A-01-05' ($null -ne $geom.MinIntervalMs -and $geom.MinIntervalMs -ge 55) "测高/改高节流下限 >=55ms (min=$($geom.MinIntervalMs)ms)" @{ min=$geom.MinIntervalMs; max=$geom.MaxIntervalMs; intervals=$geom.Intervals }
Check 'A-01-06' (($geom.Changes.Count / 3.6) -le 12.5) "改高频率 <=12.5 次/秒 (observed $([Math]::Round($geom.Changes.Count/3.6,2))/s)"
$ansLong = @(Get-AnswerList $app.Id)[0]
Save-WindowShot ([IntPtr]$ansLong.HwndInt) (Join-Path $Root '09-answer-long.png') | Out-Null
# Internal scroll at maxH.
$before = Join-Path $Root '09-answer-long-before.png'
Copy-Item (Join-Path $Root '09-answer-long.png') $before
# T7 F-04/T11 T5-11: hover wheel over the non-activating answer window should
# now scroll. Record it; also verify the scrollbar path as a fallback.
Wheel-At ([int]($ansLong.Left + $ansLong.Width/2)) ([int]($ansLong.Top + $ansLong.Height/2)) 600
Start-Sleep -Milliseconds 400
$afterWheel = Join-Path $Root '10a-answer-long-realwheel.png'
Save-WindowShot ([IntPtr]$ansLong.HwndInt) $afterWheel | Out-Null
$wheelDiff = Compare-Png $before $afterWheel 4
Rec 'A-01-07a' 'INFO' "未激活回答窗悬停滚轮像素差 $($wheelDiff.Ratio)" @{ diff=$wheelDiff }
Drag-At ([int]($ansLong.Right - 5)) ([int]($ansLong.Bottom - 40)) ([int]($ansLong.Right - 5)) ([int]($ansLong.Top + 120)) 14 120
Start-Sleep -Milliseconds 400
$after = Join-Path $Root '10-answer-long-scrolled.png'
Save-WindowShot ([IntPtr]$ansLong.HwndInt) $after | Out-Null
$diff = Compare-Png $before $after 4
$ansAfterScroll = @(Get-AnswerList $app.Id)[0]
Check 'A-01-07' (($diff.Ratio -gt 0.05 -or $wheelDiff.Ratio -gt 0.05) -and $ansAfterScroll.Height -eq $ansLong.Height) "maxH 下内部滚动（滚轮差 $($wheelDiff.Ratio) / 滚动条差 $($diff.Ratio)）height 不变=$($ansAfterScroll.Height -eq $ansLong.Height)" @{ wheelDiff=$wheelDiff; scrollbarDiff=$diff; heightBefore=$ansLong.Height; heightAfter=$ansAfterScroll.Height }
Drag-At ([int]($ansLong.Right - 5)) ([int]($ansLong.Top + 120)) ([int]($ansLong.Right - 5)) ([int]($ansLong.Bottom - 40)) 14 120
# Composer overlap by detecting the input bar top edge in main screenshot.
$mainShot = Join-Path $Root '11-main-with-answer.png'
Save-WindowShot ([IntPtr]$normal2.HwndInt) $mainShot | Out-Null
$composerTopRel = Get-ComposerTopPhysical $mainShot 500
$composerTopAbs = $normal2.Top + $composerTopRel
$gapPhysical = $composerTopAbs - $ansLong.Bottom
Check 'A-01-08' ($composerTopRel -gt 0 -and $gapPhysical -ge (8*$dpr - 2)) "回答窗不与输入条重叠 gap=$gapPhysical phys (>= $([Math]::Round(8*$dpr,1)))" @{ composerTopRel=$composerTopRel; composerTopAbs=$composerTopAbs; answerBottom=$ansLong.Bottom; gap=$gapPhysical }

# ------------------------------------------------ replacement / move / collapse
Log '--- replacement / user move / collapse'
$hwndBefore = $ansLong.HwndInt
$listBeforeReplace = @(Get-AnswerList $app.Id)
Submit-Question '长回复' 'main' 250
Start-Sleep -Milliseconds 1800
$listAfterReplace = @(Get-AnswerList $app.Id)
$ansReplace = if ($listAfterReplace.Count -gt 0) { $listAfterReplace[0] } else { $null }
Check 'A-02-01' ($null -ne $ansReplace -and $ansReplace.HwndInt -eq $hwndBefore -and $listAfterReplace.Count -eq 1) '再次提交复用同一回答窗（单实例替换语义）' @{ before=@($listBeforeReplace | ForEach-Object { $_.HwndInt }); after=@($listAfterReplace | ForEach-Object { $_.HwndInt }); expected=$hwndBefore }
if ($null -eq $ansReplace) { throw 'replacement window missing' }
Check 'A-02-02' ($ansReplace.Height -eq 950) '替换后重新增长到 maxH'
Save-WindowShot ([IntPtr]$ansReplace.HwndInt) (Join-Path $Root '12-answer-replaced.png') | Out-Null
# Drag window by header; moved to user position.
$dragX = [int]($ansReplace.Left + 220); $dragY = [int]($ansReplace.Top + 22)
Drag-At $dragX $dragY ($dragX-260) ($dragY-140) 16 120
Start-Sleep -Milliseconds 800
$ansMoved = @(Get-AnswerList $app.Id)[0]
Check 'A-02-03' ([Math]::Abs($ansMoved.Left - $ansReplace.Left) -gt 100 -or [Math]::Abs($ansMoved.Top - $ansReplace.Top) -gt 60) "标题栏拖动改变位置 delta=($($ansMoved.Left-$ansReplace.Left),$($ansMoved.Top-$ansReplace.Top))" $ansMoved
Save-WindowShot ([IntPtr]$ansMoved.HwndInt) (Join-Path $Root '13-answer-moved.png') | Out-Null
# User moved: top edge anchoring on next short answer (shrink then grow).
$topBefore = $ansMoved.Top
Submit-Question '普通问题' 'main' 250
Start-Sleep -Milliseconds 1500
$ansShort = @(Get-AnswerList $app.Id)[0]
Check 'A-02-04' ($ansShort.Height -eq 225) "替换为短回答后缩回 minH 225" @{ height=$ansShort.Height }
$topAfterShort = $ansShort.Top
Submit-Question '长回复' 'main' 250
Start-Sleep -Milliseconds 2200
$ansGrow = @(Get-AnswerList $app.Id)[0]
Check 'A-02-05' ($ansGrow.Height -eq 950 -and [Math]::Abs($ansGrow.Top - $topAfterShort) -le 2) "user-moved 模式高度增长时顶边固定 (top $topAfterShort -> $($ansGrow.Top), height $($ansGrow.Height))"
# Collapse 36 logical / expand.
Click-At ([int]($ansGrow.Right - 57)) ([int]($ansGrow.Top + 22))
$collapsed = Wait-Until { $a = @(Get-AnswerList $app.Id); if ($a.Count -eq 1 -and $a[0].Height -eq 45) { $a[0] } } 3000
Check 'A-02-06' ($null -ne $collapsed) '收起为 36 逻辑高标题条（45 phys）'
Save-WindowShot ([IntPtr]$collapsed.HwndInt) (Join-Path $Root '14-answer-collapsed.png') | Out-Null
$collapsed = @(Get-AnswerList $app.Id)[0]
Click-At ([int]($collapsed.Right - 57)) ([int]($collapsed.Top + 22))
$expanded = Wait-Until { $a = @(Get-AnswerList $app.Id); if ($a.Count -eq 1 -and $a[0].Height -eq 950) { $a[0] } } 4000
Check 'A-02-07' ($null -ne $expanded) '展开恢复高度 950'
$expanded = @(Get-AnswerList $app.Id)[0]
Check 'A-02-08' ([W32T]::GetForegroundWindow() -eq [IntPtr]$normal2.HwndInt) '收起/展开后前台仍为主窗'

# --------------------------------------------------------------- stop / error
Log '--- stop / error / stream off'
$ansBeforeStop = @(Get-AnswerList $app.Id)[0]
Submit-Question '慢速' 'main' 250
Start-Sleep -Milliseconds 700
$mainNow = Get-MainWindow $app.Id
$shotNow = Join-Path $Root '15-main-streaming.png'
Save-WindowShot ([IntPtr]$mainNow.HwndInt) $shotNow | Out-Null
$red = Find-RedButton $shotNow
if ($null -eq $red) {
  Save-WindowShot ([IntPtr]$mainNow.HwndInt) (Join-Path $Root '15b-main-streaming.png') | Out-Null
  $red = Find-RedButton (Join-Path $Root '15b-main-streaming.png')
}
Check 'A-03-01' ($null -ne $red) "流式中发送按钮变红（stop 可定位 count=$($red.Count)）" $red
if ($null -ne $red) {
  Click-At ([int]($mainNow.Left + $red.X)) ([int]($mainNow.Top + $red.Y))
  Start-Sleep -Milliseconds 1200
}
$ansStopped = @(Get-AnswerList $app.Id)
Check 'A-03-02' ($ansStopped.Count -eq 1) '停止后回答窗保留'
Save-WindowShot ([IntPtr]$ansStopped[0].HwndInt) (Join-Path $Root '16-answer-stopped.png') | Out-Null
Check 'A-03-03' ($ansStopped[0].HwndInt -eq $ansBeforeStop.HwndInt) '停止复用同一回答窗'
# Error response.
Submit-Question '空回复' 'main' 250
Start-Sleep -Milliseconds 2000
$ansErr = @(Get-AnswerList $app.Id)
Check 'A-04-01' ($ansErr.Count -eq 1) '错误回答保留窗口（不静默降级）'
Save-WindowShot ([IntPtr]$ansErr[0].HwndInt) (Join-Path $Root '17-answer-error.png') | Out-Null
# stream off -> one-shot content.
Invoke-RestMethod -Method Put -Uri 'http://127.0.0.1:8765/api/settings' -ContentType 'application/json' -Body '{"stream_output":false}' | Out-Null
$ansErrBefore = $ansErr[0]
$geomOffPath = Join-Path $Root 'streamoff-geometry.tsv'
[RectSampler]::Start($geomOffPath, $ansErrBefore.HwndInt, 10)
Submit-Question '长回复' 'main' 250
Start-Sleep -Milliseconds 2500
[RectSampler]::Stop()
$geomOff = Analyze-Geometry $geomOffPath $dpr
Check 'A-05-01' ($geomOff.MaxHeightPhysical -eq 950) "stream_output=false 仍自适应到 maxH 950" $geomOff
Check 'A-05-02' ($geomOff.Changes.Count -le 5) "stream_output=false 高度变化少（$($geomOff.Changes.Count) 次）"
$ansOff = @(Get-AnswerList $app.Id)[0]
Save-WindowShot ([IntPtr]$ansOff.HwndInt) (Join-Path $Root '18-answer-streamoff.png') | Out-Null
Invoke-RestMethod -Method Put -Uri 'http://127.0.0.1:8765/api/settings' -ContentType 'application/json' -Body '{"stream_output":true}' | Out-Null
# External close (simulates crash/user DWM close) then recreate.
[void][W32T]::PostMessage([IntPtr]$ansOff.HwndInt, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
$extClosed = Wait-Until { @(Get-AnswerList $app.Id).Count -eq 0 } 4000
Check 'A-06-01' ($extClosed) '回答窗被外部关闭后主窗检测 absent, 不崩溃'
Start-Sleep -Milliseconds 500
Submit-Question '普通问题' 'main' 250
$newAns = Wait-Answer $app.Id 20000 $false
Check 'A-06-02' ($null -ne $newAns -and $newAns.HwndInt -ne $ansOff.HwndInt) "外部关闭后下一次提交创建新窗口 hwnd=$($newAns.HwndInt)"
Start-Sleep -Milliseconds 1200

# --------------------------------------------------------------- screenshot
Log '--- screenshot closed loop'
$cur = Get-MainWindow $app.Id
# close any answer window so the title-bar button is reachable
$ansOpenNow = @(Get-AnswerList $app.Id)
if ($ansOpenNow.Count -eq 1) { Click-At ([int]($ansOpenNow[0].Right - 23)) ([int]($ansOpenNow[0].Top + 22)); Start-Sleep -Milliseconds 800 }
# ensure floating
$cur = Get-MainWindow $app.Id
if ($cur.Width -ne 575) {
  Activate-Hwnd ([IntPtr]$cur.HwndInt)
  Click-At ([int]($cur.Right - 158*$dpr)) ([int]($cur.Top + 22*$dpr))
  $cur = Wait-Until { $w = Get-MainWindow $app.Id; if ($w -and $w.Width -eq 575) { $w } } 4000
}
# enter minimal
$cur = Get-MainWindow $app.Id
Activate-Hwnd ([IntPtr]$cur.HwndInt)
Click-At ([int]($cur.Right - 101*$dpr)) ([int]($cur.Top + 22*$dpr))
$min = Wait-Until { $w = Get-MainWindow $app.Id; if ($w -and $w.Height -lt 80) { $w } } 4000
$min = Get-MainWindow $app.Id
# create an answer window from minimal first, so screenshot can prove it is hidden/restored
Submit-Question '截图前问题' 'minimal' 250
$ansBeforeShot = Wait-Answer $app.Id 20000 $true
Start-Sleep -Milliseconds 900
$min = Get-MainWindow $app.Id
$ansVisibleBefore = @(Get-AnswerList $app.Id)
$ansWasOpen = ($ansVisibleBefore.Count -eq 1 -and $ansVisibleBefore[0].Visible)
$ansHwndBeforeShot = if ($ansWasOpen) { $ansVisibleBefore[0].HwndInt } else { 0 }
Check 'S-00-01' ($ansWasOpen) '极简条提交问题后回答窗可见（为截图隐藏/恢复做准备）'
# click screenshot in minimal bar (right-54 logical from right edge)
Click-At ([int]($min.Right - 54*$dpr)) ([int]($min.Top + 26*$dpr))
$overlay = Wait-Until { $w = Get-MainWindow $app.Id; if ($w -and $w.Width -ge 2500) { $w } } 12000 100
Check 'S-01-01' ($null -ne $overlay) '极简条截图进入全屏覆盖层（work area 2560x1440）'
$answerHiddenDuring = $true
if ($ansWasOpen) {
  $visSamples = @()
  for ($i = 0; $i -lt 8; $i++) {
    $a = @(Get-AnswerList $app.Id)
    if ($a.Count -eq 1) { $visSamples += $a[0].Visible } else { $visSamples += $false }
    Start-Sleep -Milliseconds 60
  }
  $answerHiddenDuring = -not ($visSamples -contains $true)
}
Check 'S-01-02' ($answerHiddenDuring) '截图期间回答窗隐藏（若此前可见）' @{ ansWasOpen=$ansWasOpen }
$ov = Get-MainWindow $app.Id
Check 'S-01-03' ($ov.Left -eq 0 -and $ov.Top -eq 0 -and $ov.Width -eq 2560 -and $ov.Height -eq 1440) '截图覆盖层铺满工作区'
# click 全屏 then 完成 (primary display coordinates)
Click-At 1242 1385
Start-Sleep -Milliseconds 500
$ovShot = Join-Path $Root '19-overlay-toolbar.png'
Save-DesktopShot $ovShot 1000 1320 700 120
Click-At 1374 1385
$restoredShot = Wait-Until { $w = Get-MainWindow $app.Id; if ($w -and $w.Width -eq 575 -and $w.Height -eq 65) { $w } } 12000 100
Check 'S-01-04' ($null -ne $restoredShot) '截图完成恢复极简条 460x52'
Start-Sleep -Milliseconds 1500
$restoredShot = Get-MainWindow $app.Id
$ansAfterShot = @(Get-AnswerList $app.Id)
Check 'S-01-05' (($ansAfterShot.Count -eq 1 -and $ansAfterShot[0].Visible) -eq $ansWasOpen) '截图结束回答窗可见性恢复'
Save-WindowShot ([IntPtr]$restoredShot.HwndInt) (Join-Path $Root '20-minimal-after-screenshot.png') | Out-Null
# screenshot attachment was uploaded; wait for snackbar/attachment then submit non-empty question.
Start-Sleep -Milliseconds 800
Click-At ([int]($restoredShot.Left + $restoredShot.Width/2)) ([int]($restoredShot.Top + $restoredShot.Height/2))
Send-Text '截图提问闭环' 55 | Out-Null
Start-Sleep -Milliseconds 400
Send-Enter
$ansShot = Wait-Answer $app.Id 20000 $false
Check 'S-01-06' ($null -ne $ansShot) '截图附件 + 非空问题 -> 回答窗（闭环）'
Start-Sleep -Milliseconds 1200
$ansShot = @(Get-AnswerList $app.Id)[0]
Save-WindowShot ([IntPtr]$ansShot.HwndInt) (Join-Path $Root '21-answer-after-screenshot.png') | Out-Null
# cancel path: screenshot then Esc.
$min = Get-MainWindow $app.Id
Activate-Hwnd ([IntPtr]$min.HwndInt)
# close answer first so minimal input reachable
$ansShot = @(Get-AnswerList $app.Id)
if ($ansShot.Count -eq 1) { Click-At ([int]($ansShot[0].Right - 23)) ([int]($ansShot[0].Top + 22)); Start-Sleep -Milliseconds 800 }
$min = Get-MainWindow $app.Id
Click-At ([int]($min.Right - 54*$dpr)) ([int]($min.Top + 26*$dpr))
$overlay2 = Wait-Until { $w = Get-MainWindow $app.Id; if ($w -and $w.Width -ge 2500) { $w } } 12000 100
if ($overlay2) { Send-Vk 0x1B; Start-Sleep -Milliseconds 1500 }
$afterCancel = Get-MainWindow $app.Id
Check 'S-02-01' ($afterCancel.Width -eq 575 -and $afterCancel.Height -eq 65) 'Esc 取消截图恢复极简条'
# return to normal
$m = Get-MainWindow $app.Id
Click-At ([int]($m.Right - 21*$dpr)) ([int]($m.Top + 26*$dpr))
$norm = Wait-Until { $w = Get-MainWindow $app.Id; if ($w -and $w.Width -eq 1800 -and $w.Height -eq 1125) { $w } } 5000
Check 'S-02-02' ($null -ne $norm) '截图/极简后返回主窗口 1440x900'

# --------------------------------------------------------- minimize / exit
Log '--- minimize / exit cleanup'
$norm = Get-MainWindow $app.Id
Submit-Question '长回复' 'main' 250
$ansExit = Wait-Answer $app.Id 20000 $false
Start-Sleep -Milliseconds 1200
$ansExit = @(Get-AnswerList $app.Id)[0]
Check 'X-01-01' ($null -ne $ansExit) '退出前回答窗存在'
[void][W32T]::PostMessage([IntPtr]$norm.HwndInt, 0x0112, [IntPtr]0xF020, [IntPtr]::Zero)
Start-Sleep -Milliseconds 900
$ansMin = @(Get-AnswerList $app.Id)
Check 'X-01-02' ($ansMin.Count -eq 1 -and -not $ansMin[0].Visible) '主窗最小化时回答窗隐藏' $ansMin
[void][W32T]::ShowWindow([IntPtr]$norm.HwndInt, 9)
Start-Sleep -Milliseconds 1000
$ansRestored = @(Get-AnswerList $app.Id)
Check 'X-01-03' ($ansRestored.Count -eq 1 -and $ansRestored[0].Visible) '主窗恢复时回答窗无激活恢复显示' $ansRestored
# WM_CLOSE with tray active -> hide to tray; answer window hides with it.
$norm = Get-MainWindow $app.Id
[void][W32T]::PostMessage([IntPtr]$norm.HwndInt, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
Start-Sleep -Milliseconds 1200
$hiddenMain = Get-MainWindow $app.Id
$ansHidden = @(Get-AnswerList $app.Id)
Check 'X-02-01' ($hiddenMain -and -not $hiddenMain.Visible -and -not $app.HasExited) 'tray 激活时关闭主窗 -> 隐藏到托盘（进程存活）' @{ main=$hiddenMain; exited=$app.HasExited }
Check 'X-02-02' ($ansHidden.Count -eq 1 -and -not $ansHidden[0].Visible) '托盘隐藏时回答窗一并隐藏（保留引擎/状态）' $ansHidden
# Tray quit: answer window must be destroyed before process exit.
$startQuit = Get-Date
[void][W32T]::PostMessage([IntPtr]$norm.HwndInt, 0x0111, [IntPtr]1027, [IntPtr]::Zero)
$answerGoneAt = $null; $exitedAt = $null
for ($i = 0; $i -lt 160; $i++) {
  if ($null -eq $answerGoneAt -and @(Get-AnswerList $app.Id).Count -eq 0) { $answerGoneAt = (Get-Date) }
  if ($app.HasExited) { $exitedAt = (Get-Date); break }
  Start-Sleep -Milliseconds 50
}
$exited = $app.HasExited
$leftWins = @(Get-LoopWindows $app.Id)
$leftPort = @(Get-NetTCPConnection -State Listen -LocalPort 8765 -ErrorAction SilentlyContinue)
$answerGoneMs = if ($answerGoneAt) { [int]($answerGoneAt - $startQuit).TotalMilliseconds } else { -1 }
$exitMs = if ($exitedAt) { [int]($exitedAt - $startQuit).TotalMilliseconds } else { -1 }
Check 'X-02-03' ($exited) "tray 退出 -> 进程退出 (answerGoneMs=$answerGoneMs exitMs=$exitMs)"
Check 'X-02-04' ($null -ne $answerGoneAt -and $null -ne $exitedAt -and $answerGoneAt -le $exitedAt) '回答窗先关闭、后进程退出（无孤儿）' @{ answerGoneMs=$answerGoneMs; exitMs=$exitMs }
Check 'X-02-05' ($leftWins.Count -eq 0) "退出后无残留窗口 windowsLeft=$($leftWins.Count)"
Check 'X-02-06' ($leftPort.Count -eq 0) "退出后 8765 无监听 portLeft=$($leftPort.Count)"
[FgSampler]::Stop()
# Focus analysis.
$fgLines = @(Get-Content $fgPath | ForEach-Object {
  $p = $_ -split "`t"
  if ($p.Count -ge 2) {
    $f = $p[1] -split '\|'
    if ($f.Count -ge 3) { [pscustomobject]@{ T=[int]$p[0]; Hwnd=$f[0]; Class=$f[1]; Focus=$f[2] } }
  }
})
$answerEpisodes = New-Object System.Collections.ArrayList
for ($i = 0; $i -lt $fgLines.Count; $i++) {
  if ($fgLines[$i].Class -eq 'FLUTTER_MULTI_WINDOW_WIN32_WINDOW') {
    $startT = $fgLines[$i].T
    $endT = if ($i + 1 -lt $fgLines.Count) { $fgLines[$i+1].T } else { $startT }
    [void]$answerEpisodes.Add([pscustomobject]@{ StartMs=$startT; DurationMs=($endT-$startT); Hwnd=$fgLines[$i].Hwnd })
  }
}
$mainFgCount = @($fgLines | Where-Object { $_.Class -eq 'FLUTTER_RUNNER_WIN32_WINDOW' }).Count
$answerFgCount = @($fgLines | Where-Object { $_.Class -eq 'FLUTTER_MULTI_WINDOW_WIN32_WINDOW' }).Count
$over100 = @($answerEpisodes | Where-Object { $_.DurationMs -gt 100 })
$maxEpisode = if ($answerEpisodes.Count) { ($answerEpisodes | Measure-Object -Property DurationMs -Maximum).Maximum } else { 0 }
Check 'F-01-01' ($over100.Count -eq 0) "回答窗前台停留均不超过 100ms 补偿上限（episodes=$($answerEpisodes.Count) max=${maxEpisode}ms）" @{ episodes=$answerEpisodes; over100=$over100; mainForegroundTransitions=$mainFgCount; answerTransitions=$answerFgCount }
Rec 'F-01-02' 'INFO' "foreground sampler: transitions main=$mainFgCount answer=$answerFgCount maxAnswerEpisode=${maxEpisode}ms; log=$fgPath"
# T5-04 / T5-08 / F-06: parse app stdout after the full run.
$appOutText = Get-Content $appOut -Raw -ErrorAction SilentlyContinue
$resyncCount = ([regex]::Matches($appOutText, 'resync_requested')).Count
$chromeFailCount = ([regex]::Matches($appOutText, 'applyAnswerWindowChrome failed')).Count
$anchorUpdateCount = ([regex]::Matches($appOutText, 'answer anchors updated')).Count
$timingMatches = [regex]::Matches($appOutText, 'answer create timing: ready=(\d+)ms visible=(\d+)ms')
$timings = @()
foreach ($m in $timingMatches) {
  $timings += [pscustomobject]@{ readyMs=[int]$m.Groups[1].Value; visibleMs=[int]$m.Groups[2].Value }
}
$firstThree = @($timings | Select-Object -First 3)
$timingSummary = @($firstThree | ForEach-Object { "ready=$($_.readyMs)/visible=$($_.visibleMs)" }) -join ', '
if ($firstThree.Count -eq 0) {
  Rec 'T5-08' 'INFO' 'EXCEPTION/UNMEASURED：app stdout 中无 answer create timing 记录'
} elseif (@($firstThree | Where-Object { $_.visibleMs -gt 400 }).Count -gt 0) {
  Rec 'T5-08' 'EXCEPTION' "首次可见未达 spec 400ms 目标（EXCEPTION，非 PASS）：$timingSummary；待 t9 决定是否接受（第二引擎冷启动，未预热）" @{ timings=$firstThree }
} else {
  Rec 'T5-08' 'PASS' "首次可见 ≤400ms：$timingSummary" @{ timings=$firstThree }
}
Check 'T5-04' ($resyncCount -eq 0) "长回答/改高/形态切换后 resync_requested=$resyncCount（无全量风暴）"
Check 'F-06' ($chromeFailCount -eq 0) "applyAnswerWindowChrome failed=$chromeFailCount"
Rec 'T5-05' 'INFO' "geometry/answer anchors updated=$anchorUpdateCount 次；answer overlaps input bar=$( ([regex]::Matches($appOutText,'answer overlaps input bar')).Count )"
# Screenshot upload evidence from DB.
$dbDump = @'
import sqlite3, os, json
p = os.path.join(os.environ['TEMP'], 'loop-t8-evidence', 'run1', 'data', 'loop.db')
c = sqlite3.connect(p); cur = c.cursor()
cols = [r[1] for r in cur.execute('pragma table_info(uploads)')]
rows = [dict(zip(cols, r)) for r in cur.execute('select * from uploads order by rowid desc limit 5')]
for r in rows:
    for k in list(r):
        if isinstance(r[k], bytes): r[k] = f'<{len(r[k])} bytes>'
print(json.dumps(rows, ensure_ascii=True))
c.close()
'@
$dbPy = Join-Path $Root 'uploads.py'
Set-Content -Path $dbPy -Value $dbDump -Encoding UTF8
$uploads = (python $dbPy) | ConvertFrom-Json
Check 'S-01-07' (@($uploads).Count -ge 1) "截图上传落库 uploads=$(@($uploads).Count)" $uploads
# Cleanup.
Stop-Process -Id $mockProc.Id -Force -ErrorAction SilentlyContinue
if (-not $app.HasExited) { Stop-Process -Id $app.Id -Force -ErrorAction SilentlyContinue }
Log "DONE failures=$($script:fail) checks=$($script:checks.Count)"
$summary = [ordered]@{ failures=$script:fail; checks=$script:checks.Count; completedAt=(Get-Date -Format o); log=$logPath }
$summary | ConvertTo-Json | Set-Content (Join-Path $Root 'summary.json') -Encoding UTF8
if ($script:fail -gt 0) { exit 2 } else { exit 0 }
