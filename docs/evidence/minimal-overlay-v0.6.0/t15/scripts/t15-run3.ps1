param(
  [string]$Exe = 'D:\DSH_Workspace\Prog2_app\app\build\windows\x64\runner\Release\loop.exe',
  [string]$Mock = 'D:\DSH_Workspace\Prog2_app\docs\streaming-evidence\tools\mock_llm.py',
  [string]$Root = (Join-Path $env:TEMP 'loop-t15-evidence\run3')
)
$ErrorActionPreference = 'Stop'
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
. "$env:TEMP\loop-t15-evidence\ui.ps1"
if (Test-Path $Root) { Remove-Item $Root -Recurse -Force }
New-Item -ItemType Directory -Force $Root | Out-Null
$logPath = Join-Path $Root 'run3.log'
$jsonPath = Join-Path $Root 'run3-results.jsonl'
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
function Wait-Until([scriptblock]$cond, [int]$timeoutMs = 12000, [int]$intervalMs = 50) {
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
  try { if ($script:mockProc) { Get-CimInstance Win32_Process -Filter "Name='python.exe'" | Where-Object { $_.CommandLine -match 'mock_llm' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } } } catch {}
  try { [FgSampler]::Stop() } catch {}
  exit 3
}
function Clear-Input([int]$processId) {
  $w = Get-MainWindow $processId; Activate-Hwnd ([IntPtr]$w.HwndInt); $dpr = $w.Dpi / 96.0
  Click-At ([int]($w.Left + 1200*$dpr)) ([int]($w.Bottom - 55*$dpr)); Start-Sleep -Milliseconds 200
  [void][W32T]::PressVk(0x23); Start-Sleep -Milliseconds 60
  for ($i = 0; $i -lt 90; $i++) { [void][W32T]::PressVk(0x08); Start-Sleep -Milliseconds 6 }
  Start-Sleep -Milliseconds 150
}
function Submit([int]$processId, [string]$text) {
  Clear-Input $processId; Send-Text $text 45 | Out-Null; Start-Sleep -Milliseconds 250; Send-Enter; Log "submit text=$text"
}
function AverageBrightness([string]$path) {
  Add-Type -AssemblyName System.Drawing
  $img = [System.Drawing.Bitmap]::FromFile($path); $sum = 0.0; $n = 0
  for ($y = 0; $y -lt $img.Height; $y += 5) { for ($x = 0; $x -lt $img.Width; $x += 5) { $c = $img.GetPixel($x, $y); $sum += ($c.R+$c.G+$c.B)/3.0; $n++ } }
  $img.Dispose(); return [Math]::Round($sum/$n, 1)
}

$existing = @(Get-Process loop -ErrorAction SilentlyContinue)
if ($existing.Count -gt 0) { throw "LOOP_INSTANCE_RUNNING pid=$($existing[0].Id)" }
if (Get-NetTCPConnection -State Listen -LocalPort 8765,9999 -ErrorAction SilentlyContinue) { throw 'PORT_IN_USE' }
$dataDir = Join-Path $Root 'data'; New-Item -ItemType Directory -Force $dataDir | Out-Null
New-Item -ItemType File -Force (Join-Path $dataDir 'loop.db') | Out-Null
$env:LOOP_DATA_DIR = $dataDir
$env:LOOP_THEME = 'light'
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
$dpr = $main.Dpi / 96.0
$fgPath = Join-Path $Root 'foreground.tsv'; [FgSampler]::Start($fgPath)
Rec 'E-03-01' 'INFO' "light launch main rect=$($main.Left),$($main.Top),$($main.Width),$($main.Height) dpr=$dpr"
Save-WindowShot ([IntPtr]$main.HwndInt) (Join-Path $Root '01-light-main.png') | Out-Null
$bright = AverageBrightness (Join-Path $Root '01-light-main.png')
Check 'T-01-01' ($bright -gt 100) "LOOP_THEME=light 主窗口为亮色 (brightness=$bright)" @{ brightness=$bright }

# ---- light answer window
$t0 = Get-Date; Submit $app.Id '长回复'
$ans = Wait-Answer $app.Id 20000 $true
$lat = if ($ans) { [int]((Get-Date)-$t0).TotalMilliseconds } else { -1 }
Check 'T-01-02' ($null -ne $ans) "亮色主题下创建回答窗 firstVisible=${lat}ms"
Start-Sleep -Milliseconds 2500
$ans = @(Get-AnswerList $app.Id)[0]
Save-WindowShot ([IntPtr]$ans.HwndInt) (Join-Path $Root '02-light-answer.png') | Out-Null
$ansBright = AverageBrightness (Join-Path $Root '02-light-answer.png')
Check 'T-01-03' ($ansBright -gt 100) "回答窗首帧亮色 (brightness=$ansBright)" @{ brightness=$ansBright }

# ---- collapse answer, switch main to dark, check answer sync (spec 2.7)
Click-At ([int]($ans.Right - 57)) ([int]($ans.Top + 22))
$collapsed = Wait-Until { $a = @(Get-AnswerList $app.Id); if ($a.Count -eq 1 -and $a[0].Height -eq 45) { $a[0] } } 4000
$ansCollapsed = @(Get-AnswerList $app.Id)[0]
Save-WindowShot ([IntPtr]$ansCollapsed.HwndInt) (Join-Path $Root '03-answer-collapsed-light.png') | Out-Null
$cBright = AverageBrightness (Join-Path $Root '03-answer-collapsed-light.png')
Check 'T-01-04' ($null -ne $collapsed -and $cBright -gt 100) "收起回答窗仍为亮色 (height=$($ansCollapsed.Height), brightness=$cBright)" @{ brightness=$cBright; height=$ansCollapsed.Height }
# settings page and dark toggle
$main = Get-MainWindow $app.Id
Activate-Hwnd ([IntPtr]$main.HwndInt)
Click-At ([int]($main.Left + 75*$dpr)) ([int]($main.Top + 848*$dpr))
Start-Sleep -Milliseconds 900
Save-WindowShot ([IntPtr]$main.HwndInt) (Join-Path $Root '04-settings-light.png') | Out-Null
Click-At ([int]($main.Left + 1352*$dpr)) ([int]($main.Top + 226*$dpr))
Start-Sleep -Milliseconds 1000
Save-WindowShot ([IntPtr]$main.HwndInt) (Join-Path $Root '05-settings-dark.png') | Out-Null
$mainDarkBright = AverageBrightness (Join-Path $Root '05-settings-dark.png')
Check 'T-02-01' ($mainDarkBright -lt 100) "主窗口切到深色 (brightness=$mainDarkBright)" @{ brightness=$mainDarkBright }
$ansNow = @(Get-AnswerList $app.Id)[0]
Save-WindowShot ([IntPtr]$ansNow.HwndInt) (Join-Path $Root '06-answer-collapsed-after-dark-switch.png') | Out-Null
$cBright2 = AverageBrightness (Join-Path $Root '06-answer-collapsed-after-dark-switch.png')
Check 'T-02-02' ($cBright2 -lt 100) "主窗切深色后回答窗跟随变暗 (brightness=$cBright2)" @{ before=$cBright; after=$cBright2 }
# close answer under dark, recreate -> launch payload dark
Click-At ([int]($ansNow.Right - 23)) ([int]($ansNow.Top + 22))
Wait-Until { @(Get-AnswerList $app.Id).Count -eq 0 } 4000 | Out-Null
Click-At ([int]($main.Left + 75*$dpr)) ([int]($main.Top + 170*$dpr))
Start-Sleep -Milliseconds 900
$t1 = Get-Date; Submit $app.Id '普通问题'
$ansDark = Wait-Answer $app.Id 20000 $true
Check 'T-02-03' ($null -ne $ansDark) "深色主题下重建回答窗"
Start-Sleep -Milliseconds 1500
$ansDark = @(Get-AnswerList $app.Id)[0]
Save-WindowShot ([IntPtr]$ansDark.HwndInt) (Join-Path $Root '07-answer-dark-launch.png') | Out-Null
$dBright = AverageBrightness (Join-Path $Root '07-answer-dark-launch.png')
Check 'T-02-04' ($dBright -lt 100) "重建回答窗使用深色首帧 (brightness=$dBright)" @{ brightness=$dBright }

# ---- IME / focus during streaming
Log '--- IME + focus'
Add-Type -TypeDefinition @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class ImeX {
  [DllImport("imm32.dll")] public static extern IntPtr ImmGetContext(IntPtr hwnd);
  [DllImport("imm32.dll")] public static extern bool ImmReleaseContext(IntPtr hwnd, IntPtr himc);
  [DllImport("imm32.dll")] public static extern bool ImmSetOpenStatus(IntPtr himc, bool open);
  [DllImport("imm32.dll")] public static extern bool ImmSetConversionStatus(IntPtr himc, uint conv, uint sentence);
  [DllImport("imm32.dll", CharSet = CharSet.Unicode)] public static extern int ImmGetCompositionStringW(IntPtr himc, int index, byte[] buf, int len);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr LoadKeyboardLayout(string klid, uint flags);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hwnd, uint msg, IntPtr w, IntPtr l);
  public static string Comp(IntPtr himc) {
    int len = ImmGetCompositionStringW(himc, 8, null, 0);
    if (len <= 0) return "";
    var buf = new byte[len];
    int n = ImmGetCompositionStringW(himc, 8, buf, len);
    if (n <= 0) return "";
    return Encoding.Unicode.GetString(buf, 0, n);
  }
}
"@
$main = Get-MainWindow $app.Id
Activate-Hwnd ([IntPtr]$main.HwndInt)
# send a slow question, then focus composer and start IME composition while streaming
Clear-Input $app.Id
Send-Text '慢速' 45 | Out-Null; Start-Sleep -Milliseconds 200; Send-Enter
Start-Sleep -Milliseconds 250
Click-At ([int]($main.Left + 1200*$dpr)) ([int]($main.Bottom - 55*$dpr))
Start-Sleep -Milliseconds 300
$fi = [W32T]::FocusedInfo().Split('|')
$fgHwnd = $fi[0]; $focusHwnd = $fi[2]
$himc = [ImeX]::ImmGetContext([IntPtr][long]$focusHwnd)
if ($himc -eq [IntPtr]::Zero) { $himc = [ImeX]::ImmGetContext([IntPtr]$main.HwndInt) }
$hkl = [ImeX]::LoadKeyboardLayout('00000804', 1)
[void][ImeX]::PostMessage([IntPtr]$main.HwndInt, 0x0050, [IntPtr]::Zero, $hkl)
Start-Sleep -Milliseconds 400
$openOk = $false; $convOk = $false
if ($himc -ne [IntPtr]::Zero) {
  $openOk = [ImeX]::ImmSetOpenStatus($himc, $true)
  $convOk = [ImeX]::ImmSetConversionStatus($himc, 1, 0)
}
foreach ($vk in @(0x4E,0x49,0x48,0x41,0x4F)) { [void][W32T]::PressVk([uint16]$vk); Start-Sleep -Milliseconds 90 }
Start-Sleep -Milliseconds 500
$comp = if ($himc -ne [IntPtr]::Zero) { [ImeX]::Comp($himc) } else { '' }
Rec 'IME-01-00' 'INFO' "IME context: hwnd=$($main.HwndInt) focus=$focusHwnd himc=$($himc.ToInt64()) openOk=$openOk convOk=$convOk comp='$comp'"
$imeWorked = ($comp.Length -gt 0)
if ($imeWorked) {
  Rec 'IME-01-01' 'PASS' "真实输入法组合已启动 comp='$comp'" @{ comp=$comp }
  $hBefore = (@(Get-AnswerList $app.Id)[0]).Height
  Start-Sleep -Milliseconds 500
  $compDuring = [ImeX]::Comp($himc)
  $hAfter = (@(Get-AnswerList $app.Id)[0]).Height
  Check 'IME-01-02' ($compDuring.Length -gt 0) "流式改高期间组合串保持 comp='$compDuring' height=$hBefore->$hAfter" @{ comp=$compDuring; heightBefore=$hBefore; heightAfter=$hAfter }
  # click answer window body while composing
  $ansNow = @(Get-AnswerList $app.Id)[0]
  Click-At ([int]($ansNow.Left + 100)) ([int]($ansNow.Top + 100))
  Start-Sleep -Milliseconds 400
  $compAfter = [ImeX]::Comp($himc)
  $fgAfter = [W32T]::GetForegroundWindow()
  Check 'IME-01-03' ($fgAfter -eq [IntPtr]$main.HwndInt) '组合中点击回答窗后前台仍为主窗'
  Check 'IME-01-04' ($compAfter.Length -gt 0) "组合中点击回答窗后 IME 组合未丢 comp='$compAfter'" @{ comp=$compAfter }
  [void][W32T]::PressVk(0x1B); Start-Sleep -Milliseconds 200
} else {
  Rec 'IME-01-01' 'INFO' '自动化未能启动真实中文 IME 组合（Microsoft Pinyin 已安装但仅一个键盘布局、TSF 未响应合成）；改为验证焦点/前台不被回答窗抢走，真实 IME 组合列为人工限制'
  Send-Text '焦点测试' 45 | Out-Null
  Start-Sleep -Milliseconds 400
  $fiBefore = [W32T]::FocusedInfo().Split('|')
  $ansNow = @(Get-AnswerList $app.Id)[0]
  Click-At ([int]($ansNow.Left + 100)) ([int]($ansNow.Top + 100))
  Start-Sleep -Milliseconds 1500
  $fiAfter = [W32T]::FocusedInfo().Split('|')
  Check 'IME-01-02' ($fiAfter[0] -eq $fiBefore[0] -and $fiAfter[0] -eq [string]$main.HwndInt) "点击回答窗后前台仍为主窗 (before=$($fiBefore[0]) after=$($fiAfter[0]))"
  Check 'IME-01-03' ($fiAfter[2] -eq $fiBefore[2]) "点击回答窗后文本输入焦点未变 (before=$($fiBefore[2]) after=$($fiAfter[2]))" @{ before=$fiBefore[2]; after=$fiAfter[2] }
  Rec 'IME-01-04' 'INFO' "点击回答窗正文 1.5s 后焦点快照 fg=$($fiAfter[0]) class=$(($fiAfter[1])) textFocus=$($fiAfter[2])"
}
# close answer with real mouse; foreground must return main
$ansNow = @(Get-AnswerList $app.Id)
if ($ansNow.Count -eq 1) {
  Click-At ([int]($ansNow[0].Right - 23)) ([int]($ansNow[0].Top + 22))
  Start-Sleep -Milliseconds 800
}
Check 'IME-02-01' ([W32T]::GetForegroundWindow() -eq [IntPtr]$main.HwndInt) '关闭回答窗后前台为主窗'
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
$maxEp = if ($episodes.Count) { ($episodes | Measure-Object -Property DurationMs -Maximum).Maximum } else { 0 }
Check 'F-03-01' ($over100.Count -eq 0) "全流程回答窗前台停留 <=100ms（episodes=$($episodes.Count) max=${maxEp}ms）" @{ episodes=$episodes }
# quit
$startQuit = Get-Date
[void][W32T]::PostMessage([IntPtr]$main.HwndInt, 0x0111, [IntPtr]1027, [IntPtr]::Zero)
$exited = Wait-Until { $app.HasExited } 10000 100
Check 'X-03-01' ($exited) 'tray 退出进程'
Get-CimInstance Win32_Process -Filter "Name='python.exe'" | Where-Object { $_.CommandLine -match 'mock_llm' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
if (-not $app.HasExited) { Stop-Process -Id $app.Id -Force -ErrorAction SilentlyContinue }
Log "DONE failures=$($script:fail)"
[ordered]@{ failures=$script:fail; completedAt=(Get-Date -Format o); imeWorked=$imeWorked; maxAnswerForegroundMs=$maxEp } | ConvertTo-Json | Set-Content (Join-Path $Root 'summary.json') -Encoding UTF8
if ($script:fail -gt 0) { exit 2 } else { exit 0 }
