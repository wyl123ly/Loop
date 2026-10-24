$ErrorActionPreference='Stop'
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
. "$env:TEMP\loop-t4-evidence\ui.ps1"
function Wait-Until([scriptblock]$cond,[int]$timeoutMs=20000,[int]$intervalMs=50){$d=[DateTime]::Now.AddMilliseconds($timeoutMs);while([DateTime]::Now -lt $d){try{$v=& $cond}catch{$v=$null};if($v){return $v};Start-Sleep -Milliseconds $intervalMs};return $null}
$ev=Join-Path $env:TEMP 'loop-t4-anchor'; if(Test-Path $ev){Remove-Item $ev -Recurse -Force}; New-Item -ItemType Directory -Force $ev | Out-Null
$data=Join-Path $ev 'data'; New-Item -ItemType Directory -Force $data | Out-Null; New-Item -ItemType File -Force (Join-Path $data 'loop.db') | Out-Null
$env:LOOP_DATA_DIR=$data; Remove-Item Env:LOOP_THEME -ErrorAction SilentlyContinue
$mock=Start-Process python -ArgumentList 'D:\DSH_Workspace\Prog2_app\docs\streaming-evidence\tools\mock_llm.py' -PassThru -WindowStyle Hidden -RedirectStandardOutput "$ev\mock-out.log" -RedirectStandardError "$ev\mock-err.log"
$mockId=$mock.Id
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
Start-Sleep -Milliseconds 2500
$main=Get-MainWindow $app.Id; $ans=@(Get-AnswerWindows $app.Id)[0]
"before move main=$($main.Left),$($main.Top),$($main.Width),$($main.Height) dpi=$($main.Dpi) answer=$($ans.Left),$($ans.Top),$($ans.Width),$($ans.Height) dpi=$($ans.Dpi)"
Save-DesktopShot "$ev\before.png" 0 0 2560 1440
# drag main by titlebar +120,+80 (same monitor)
$sx=[int]($main.Left+600); $sy=[int]($main.Top+22)
Drag-At $sx $sy ($sx+120) ($sy+80) 14 120
Start-Sleep -Milliseconds 900
$main2=Get-MainWindow $app.Id; $ans2=@(Get-AnswerWindows $app.Id)[0]
"after small move main=$($main2.Left),$($main2.Top),$($main2.Width),$($main2.Height) delta=($($main2.Left-$main.Left),$($main2.Top-$main.Top)) answer=$($ans2.Left),$($ans2.Top),$($ans2.Width),$($ans2.Height) ansdelta=($($ans2.Left-$ans.Left),$($ans2.Top-$ans.Top))"
# drag main to secondary
$sx=[int]($main2.Left+600); $sy=[int]($main2.Top+22)
Drag-At $sx $sy -1800 300 30 160
Start-Sleep -Milliseconds 2500
$main3=Get-MainWindow $app.Id; $ans3=@(Get-AnswerWindows $app.Id)
"after cross move main=$($main3.Left),$($main3.Top),$($main3.Width),$($main3.Height) dpi=$($main3.Dpi) answers=$($ans3.Count)"
if($ans3.Count -gt 0){ "answer=$($ans3[0].Left),$($ans3[0].Top),$($ans3[0].Width),$($ans3[0].Height) dpi=$($ans3[0].Dpi) vis=$($ans3[0].Visible)" }
Save-WindowShot ([IntPtr]$main3.HwndInt) "$ev\main-secondary.png" | Out-Null
if($ans3.Count -gt 0){ Save-WindowShot ([IntPtr]$ans3[0].HwndInt) "$ev\answer-secondary.png" | Out-Null }
"fg=$([W32T]::FocusedInfo())"
} finally {
Stop-Process -Id $app.Id -Force -ErrorAction SilentlyContinue
Stop-Process -Id $mockId -Force -ErrorAction SilentlyContinue
}