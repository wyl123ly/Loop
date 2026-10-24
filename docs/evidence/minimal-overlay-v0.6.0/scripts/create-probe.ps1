$ErrorActionPreference='Stop'
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
$ev = Join-Path $env:TEMP 'loop-t4-probe'
if (Test-Path $ev) { Remove-Item $ev -Recurse -Force }
New-Item -ItemType Directory -Force $ev | Out-Null
. "$env:TEMP\loop-t4-evidence\ui.ps1"
$data = Join-Path $ev 'data'; New-Item -ItemType Directory -Force $data | Out-Null
New-Item -ItemType File -Force (Join-Path $data 'loop.db') | Out-Null
$env:LOOP_DATA_DIR = $data
$mock = Start-Process python -ArgumentList 'D:\DSH_Workspace\Prog2_app\docs\streaming-evidence\tools\mock_llm.py' -PassThru -WindowStyle Hidden -RedirectStandardOutput "$ev\mock-out.log" -RedirectStandardError "$ev\mock-err.log"
Start-Sleep -Milliseconds 800
$app = Start-Process 'D:\DSH_Workspace\Prog2_app\app\build\windows\x64\runner\Release\loop.exe' -PassThru -RedirectStandardOutput "$ev\app-out.log" -RedirectStandardError "$ev\app-err.log"
for($i=0;$i -lt 80;$i++){ try { $h=Invoke-RestMethod 'http://127.0.0.1:8765/api/health' -TimeoutSec 1; break } catch { Start-Sleep -Milliseconds 300 } }
Invoke-RestMethod -Method Put -Uri 'http://127.0.0.1:8765/api/settings' -ContentType 'application/json' -Body '{"api_key":"test-key","base_url":"http://127.0.0.1:9999","model":"mock"}' | Out-Null
Invoke-RestMethod -Method Put -Uri 'http://127.0.0.1:8765/api/settings' -ContentType 'application/json' -Body '{"stream_output":true}' | Out-Null
for($i=0;$i -lt 60;$i++){ $main=Get-MainWindow $app.Id; if($main){break}; Start-Sleep -Milliseconds 250 }
Start-Sleep -Milliseconds 1500
Activate-Hwnd ([IntPtr]$main.HwndInt)
$dpr=$main.Dpi/96.0
Click-At ([int]($main.Left + 1200*$dpr)) ([int]($main.Bottom - 55*$dpr))
Send-Text '长回复' 40 | Out-Null
Start-Sleep -Milliseconds 200
$t0 = Get-Date
Send-Enter
$firstSeen=$null; $firstVisible=$null; $firstStyled=$null; $samples=New-Object System.Collections.ArrayList
for($i=0;$i -lt 1200;$i++){
  $a=@(Get-AnswerWindows $app.Id)
  if($a.Count -gt 0){
    if(-not $firstSeen){ $firstSeen = ((Get-Date)-$t0).TotalMilliseconds; }
    if(-not $firstVisible -and $a[0].Visible){ $firstVisible = ((Get-Date)-$t0).TotalMilliseconds }
    if(-not $firstStyled -and $a[0].ExStyle -eq '0x8000088'){ $firstStyled = ((Get-Date)-$t0).TotalMilliseconds }
    [void]$samples.Add([pscustomobject]@{ ms=((Get-Date)-$t0).TotalMilliseconds; vis=$a[0].Visible; ex=$a[0].ExStyle; style=$a[0].Style; w=$a[0].Width; h=$a[0].Height })
    if($firstStyled -and $a[0].Height -ge 900){ break }
  }
  Start-Sleep -Milliseconds 10
}
"firstSeen=$firstSeen firstVisible=$firstVisible firstStyled=$firstStyled samples=$($samples.Count)"
$samples | Select-Object -First 5 | Format-Table -AutoSize
$samples | Select-Object -Last 5 | Format-Table -AutoSize
Start-Sleep -Milliseconds 1000
$app.HasExited
Stop-Process -Id $app.Id -Force -ErrorAction SilentlyContinue
Stop-Process -Id $mock.Id -Force -ErrorAction SilentlyContinue