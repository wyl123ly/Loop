$ErrorActionPreference='Stop'
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
. "$env:TEMP\loop-t4-evidence\ui.ps1"
function Wait-Until([scriptblock]$cond,[int]$timeoutMs=20000,[int]$intervalMs=50){$d=[DateTime]::Now.AddMilliseconds($timeoutMs);while([DateTime]::Now -lt $d){try{$v=& $cond}catch{$v=$null};if($v){return $v};Start-Sleep -Milliseconds $intervalMs};return $null}
$ev=Join-Path $env:TEMP 'loop-t4-scroll'; if(Test-Path $ev){Remove-Item $ev -Recurse -Force}; New-Item -ItemType Directory -Force $ev | Out-Null
$data=Join-Path $ev 'data'; New-Item -ItemType Directory -Force $data | Out-Null; New-Item -ItemType File -Force (Join-Path $data 'loop.db') | Out-Null
$env:LOOP_DATA_DIR=$data
$mock=Start-Process python -ArgumentList 'D:\DSH_Workspace\Prog2_app\docs\streaming-evidence\tools\mock_llm.py' -PassThru -WindowStyle Hidden -RedirectStandardOutput "$ev\mock-out.log" -RedirectStandardError "$ev\mock-err.log"
Start-Sleep -Milliseconds 800
$app=Start-Process 'D:\DSH_Workspace\Prog2_app\app\build\windows\x64\runner\Release\loop.exe' -PassThru -RedirectStandardOutput "$ev\app-out.log" -RedirectStandardError "$ev\app-err.log"
try {
for($i=0;$i -lt 80;$i++){try{$h=Invoke-RestMethod 'http://127.0.0.1:8765/api/health' -TimeoutSec 1;break}catch{Start-Sleep -Milliseconds 300}}
Invoke-RestMethod -Method Put -Uri 'http://127.0.0.1:8765/api/settings' -ContentType 'application/json' -Body '{"api_key":"test-key","base_url":"http://127.0.0.1:9999","model":"mock"}' | Out-Null
Invoke-RestMethod -Method Put -Uri 'http://127.0.0.1:8765/api/settings' -ContentType 'application/json' -Body '{"stream_output":true}' | Out-Null
for($i=0;$i -lt 60;$i++){$main=Get-MainWindow $app.Id;if($main){break};Start-Sleep -Milliseconds 250}
Start-Sleep -Milliseconds 1200; $dpr=$main.Dpi/96.0
Activate-Hwnd ([IntPtr]$main.HwndInt)
Click-At ([int]($main.Left + 1200*$dpr)) ([int]($main.Bottom - 55*$dpr)); Send-Text '长回复' 40 | Out-Null; Start-Sleep -Milliseconds 200; Send-Enter
$ans=Wait-Until { $a=@(Get-AnswerWindows $app.Id); if($a.Count -gt 0 -and $a[0].Visible){$a[0]} } 20000
Start-Sleep -Milliseconds 2500; $ans=@(Get-AnswerWindows $app.Id)[0]
"answer=$($ans.Left),$($ans.Top),$($ans.Width),$($ans.Height) fg=$([W32T]::GetForegroundWindow().ToInt64())"
$before="$ev\before.png"; Save-WindowShot ([IntPtr]$ans.HwndInt) $before | Out-Null
Wheel-At ([int]($ans.Left+$ans.Width/2)) ([int]($ans.Top+$ans.Height/2)) 600
$a1="$ev\after-realwheel.png"; Save-WindowShot ([IntPtr]$ans.HwndInt) $a1 | Out-Null
"realwheel diff=$( (Compare-Png $before $a1 4).Ratio )"
# direct WM_MOUSEWHEEL to answer window
$wp=[IntPtr]([int64]120 -shl 16); $lp=[IntPtr](([int]($ans.Width/2)) -bor ([int]($ans.Height/2) -shl 16))
[void][W32T]::SendMessage([IntPtr]$ans.HwndInt,0x020A,$wp,$lp)
Start-Sleep -Milliseconds 400
$a2="$ev\after-postwheel.png"; Save-WindowShot ([IntPtr]$ans.HwndInt) $a2 | Out-Null
"postwheel diff=$( (Compare-Png $before $a2 4).Ratio )"
# drag scrollbar at right edge from near bottom to top
Drag-At ([int]($ans.Right-5)) ([int]($ans.Bottom-40)) ([int]($ans.Right-5)) ([int]($ans.Top+120)) 14 120
Start-Sleep -Milliseconds 400
$a3="$ev\after-drag.png"; Save-WindowShot ([IntPtr]$ans.HwndInt) $a3 | Out-Null
"scrolldrag diff=$( (Compare-Png $before $a3 4).Ratio )"
# click body then wheel immediately
Click-At ([int]($ans.Left+100)) ([int]($ans.Top+100))
Wheel-At ([int]($ans.Left+$ans.Width/2)) ([int]($ans.Top+$ans.Height/2)) 600
$a4="$ev\after-clickwheel.png"; Save-WindowShot ([IntPtr]$ans.HwndInt) $a4 | Out-Null
"clickwheel diff=$( (Compare-Png $a3 $a4 4).Ratio ) fg=$([W32T]::GetForegroundWindow().ToInt64())"
} finally { Stop-Process -Id $app.Id -Force -ErrorAction SilentlyContinue; Stop-Process -Id $mock.Id -Force -ErrorAction SilentlyContinue }