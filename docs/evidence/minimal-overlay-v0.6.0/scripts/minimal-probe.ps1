$ErrorActionPreference='Stop'
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
$ev = Join-Path $env:TEMP 'loop-t4-probe2'
. "$env:TEMP\loop-t4-evidence\ui.ps1"
function Wait-Until([scriptblock]$cond, [int]$timeoutMs = 6000, [int]$intervalMs = 50) {
  $deadline = [DateTime]::Now.AddMilliseconds($timeoutMs)
  while ([DateTime]::Now -lt $deadline) {
    try { $v = & $cond } catch { $v = $null }
    if ($v) { return $v }
    Start-Sleep -Milliseconds $intervalMs
  }
  return $null
}
$data = Join-Path $ev 'data'; New-Item -ItemType Directory -Force $data | Out-Null
New-Item -ItemType File -Force (Join-Path $data 'loop.db') | Out-Null
$env:LOOP_DATA_DIR = $data
$mock = Start-Process python -ArgumentList 'D:\DSH_Workspace\Prog2_app\docs\streaming-evidence\tools\mock_llm.py' -PassThru -WindowStyle Hidden -RedirectStandardOutput "$ev\mock-out.log" -RedirectStandardError "$ev\mock-err.log"
Start-Sleep -Milliseconds 800
$app = Start-Process 'D:\DSH_Workspace\Prog2_app\app\build\windows\x64\runner\Release\loop.exe' -PassThru -RedirectStandardOutput "$ev\app-out.log" -RedirectStandardError "$ev\app-err.log"
try {
for($i=0;$i -lt 80;$i++){ try { $h=Invoke-RestMethod 'http://127.0.0.1:8765/api/health' -TimeoutSec 1; break } catch { Start-Sleep -Milliseconds 300 } }
Invoke-RestMethod -Method Put -Uri 'http://127.0.0.1:8765/api/settings' -ContentType 'application/json' -Body '{"api_key":"test-key","base_url":"http://127.0.0.1:9999","model":"mock"}' | Out-Null
Invoke-RestMethod -Method Put -Uri 'http://127.0.0.1:8765/api/settings' -ContentType 'application/json' -Body '{"stream_output":true}' | Out-Null
for($i=0;$i -lt 60;$i++){ $main=Get-MainWindow $app.Id; if($main){break}; Start-Sleep -Milliseconds 250 }
Start-Sleep -Milliseconds 1200
$dpr=$main.Dpi/96.0
Activate-Hwnd ([IntPtr]$main.HwndInt)
Click-At ([int]($main.Right - 158*$dpr)) ([int]($main.Top + 22*$dpr))
$fl=Wait-Until { $w=Get-MainWindow $app.Id; if($w -and $w.Width -eq 575){$w} } 5000
"floating=$($fl.Left),$($fl.Top),$($fl.Width),$($fl.Height)"
Activate-Hwnd ([IntPtr]$fl.HwndInt)
Click-At ([int]($fl.Left + $fl.Width/2)) ([int]($fl.Bottom - 55*$dpr))
Send-Text '极简草稿保留' 50 | Out-Null
Click-At ([int]($fl.Right - 101*$dpr)) ([int]($fl.Top + 22*$dpr))
$min=Wait-Until { $w=Get-MainWindow $app.Id; if($w -and $w.Height -lt 80){$w} } 5000
"minimal=$($min.Left),$($min.Top),$($min.Width),$($min.Height)"
$mx1=[int]($min.Left+12*$dpr); $my1=[int]($min.Top+26*$dpr)
Drag-At $mx1 $my1 ($mx1-260) ($my1-220) 16 120
Start-Sleep -Milliseconds 500
$moved=Get-MainWindow $app.Id
"moved=$($moved.Left),$($moved.Top),$($moved.Width),$($moved.Height)"
Activate-Hwnd ([IntPtr]$moved.HwndInt)
Click-At ([int]($moved.Left + $moved.Width/2)) ([int]($moved.Top + $moved.Height/2))
Start-Sleep -Milliseconds 250
[void][W32T]::PressVk(0x23); Start-Sleep -Milliseconds 80
$t0=Get-Date
[void][W32T]::PressVk(0x0D)
$first=$null; $firstVis=$null
for($i=0;$i -lt 1500;$i++){
  $a=@(Get-AnswerWindows $app.Id)
  if($a.Count -gt 0){ if(-not $first){ $first=[int]((Get-Date)-$t0).TotalMilliseconds; "first $first hwnd=$($a[0].HwndInt) vis=$($a[0].Visible) rect=$($a[0].Left),$($a[0].Top),$($a[0].Width),$($a[0].Height)" }; if(-not $firstVis -and $a[0].Visible){ $firstVis=[int]((Get-Date)-$t0).TotalMilliseconds; "firstVisible $firstVis rect=$($a[0].Left),$($a[0].Top),$($a[0].Width),$($a[0].Height)" } }
  Start-Sleep -Milliseconds 10
}
"done first=$first firstVisible=$firstVis"
} finally {
Stop-Process -Id $app.Id -Force -ErrorAction SilentlyContinue
Stop-Process -Id $mock.Id -Force -ErrorAction SilentlyContinue
}