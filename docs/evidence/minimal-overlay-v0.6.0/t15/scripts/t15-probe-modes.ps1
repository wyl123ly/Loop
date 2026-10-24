param(
  [string]$Exe='D:\DSH_Workspace\Prog2_app\app\build\windows\x64\runner\Release\loop.exe',
  [string]$Mock='D:\DSH_Workspace\Prog2_app\docs\streaming-evidence\tools\mock_llm.py',
  [string]$Root=(Join-Path $env:TEMP 'loop-t15-evidence\modes')
)
$ErrorActionPreference='Stop'; Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
. "$env:TEMP\loop-t15-evidence\ui.ps1"
if(Test-Path $Root){Remove-Item $Root -Recurse -Force}; New-Item -ItemType Directory -Force $Root|Out-Null
Add-Type -AssemblyName System.Drawing
$logPath=Join-Path $Root 'modes.log'; $jsonPath=Join-Path $Root 'modes-results.jsonl'; $fail=0
function Log($m){$l="$(Get-Date -Format 'HH:mm:ss.fff') $m";$l|Tee-Object -FilePath $logPath -Append|Out-Host}
function Rec($id,$st,$d,$data=$null){$o=[ordered]@{id=$id;status=$st;detail=$d;at=(Get-Date -Format 'HH:mm:ss.fff')};if($null-ne$data){$o.data=$data};($o|ConvertTo-Json -Compress -Depth 8)|Add-Content $jsonPath;if($st-eq'FAIL'){$script:fail++};Log "[$st] $id $d"}
function Check($id,$c,$d,$data=$null){if($c){Rec $id 'PASS' $d $data}else{Rec $id 'FAIL' $d $data};return $c}
function Wait-A($p,$t=20000){$dl=[DateTime]::Now.AddMilliseconds($t);while([DateTime]::Now-lt$dl){$a=@(Get-AnswerWindows $p);if($a.Count-gt0-and$a[0].Visible){return $a[0]};Start-Sleep -Milliseconds 20};return $null}
function Clear-In($p){$w=Get-MainWindow $p;Activate-Hwnd ([IntPtr]$w.HwndInt);$d=$w.Dpi/96.0;Click-At ([int]($w.Left+1200*$d)) ([int]($w.Bottom-55*$d));Start-Sleep -Milliseconds 180;[void][W32T]::PressVk(0x23);for($i=0;$i-lt40;$i++){[void][W32T]::PressVk(0x08);Start-Sleep -Milliseconds 6};Start-Sleep -Milliseconds 120}
if(@(Get-Process loop -ErrorAction SilentlyContinue).Count-gt0){throw 'LOOP_RUNNING'}
if(Get-NetTCPConnection -State Listen -LocalPort 8765,9999 -ErrorAction SilentlyContinue){throw 'PORT_IN_USE'}
$data=Join-Path $Root 'data';New-Item -ItemType Directory -Force $data|Out-Null;New-Item -ItemType File -Force (Join-Path $data 'loop.db')|Out-Null
$env:LOOP_DATA_DIR=$data;Remove-Item Env:LOOP_THEME -ErrorAction SilentlyContinue
$mock=Start-Process python -ArgumentList @($Mock) -PassThru -WindowStyle Hidden -RedirectStandardOutput (Join-Path $Root 'mock-out.log') -RedirectStandardError (Join-Path $Root 'mock-err.log');Start-Sleep -Milliseconds 900
$app=Start-Process $Exe -PassThru -RedirectStandardOutput (Join-Path $Root 'app-out.log') -RedirectStandardError (Join-Path $Root 'app-err.log')
try{
for($i=0;$i-lt80;$i++){try{$h=Invoke-RestMethod 'http://127.0.0.1:8765/api/health' -TimeoutSec 1;break}catch{Start-Sleep -Milliseconds 300}}
Invoke-RestMethod -Method Put -Uri 'http://127.0.0.1:8765/api/settings' -ContentType 'application/json' -Body '{"api_key":"test-key","base_url":"http://127.0.0.1:9999","model":"mock"}'|Out-Null
Invoke-RestMethod -Method Put -Uri 'http://127.0.0.1:8765/api/settings' -ContentType 'application/json' -Body '{"stream_output":true}'|Out-Null
for($i=0;$i-lt60;$i++){$main=Get-MainWindow $app.Id;if($main){break};Start-Sleep -Milliseconds 250}
Start-Sleep -Milliseconds 1200;$dpr=$main.Dpi/96.0
Clear-In $app.Id;Send-Text '长回复' 40|Out-Null;Start-Sleep -Milliseconds 150;Send-Enter
$ans=Wait-A $app.Id;Start-Sleep -Milliseconds 2200;$ans=@(Get-AnswerWindows $app.Id)[0]
$dx=[int]($ans.Left+220);$dy=[int]($ans.Top+18);Drag-At $dx $dy ($dx-900) ($dy+250) 18 120;Start-Sleep -Milliseconds 700
$n=Get-MainWindow $app.Id;Activate-Hwnd ([IntPtr]$n.HwndInt);Click-At ([int]($n.Right-158*$dpr)) ([int]($n.Top+22*$dpr));Start-Sleep -Milliseconds 1800
$f=Get-MainWindow $app.Id;$af=@(Get-AnswerWindows $app.Id)
Check 'T5-05-floating' ($f.Width-lt1800-and$af.Count-eq1-and$af[0].Visible) "normal→floating（$($f.Width)x$($f.Height)）回答窗仍可见" @{floating=$f;answer=$af}
Click-At ([int]($f.Right-101*$dpr)) ([int]($f.Top+22*$dpr));Start-Sleep -Milliseconds 1800
$m=Get-MainWindow $app.Id;$am=@(Get-AnswerWindows $app.Id)
$inter=if($am.Count-eq1){[System.Drawing.Rectangle]::Intersect([System.Drawing.Rectangle]::new($am[0].Left,$am[0].Top,$am[0].Width,$am[0].Height),[System.Drawing.Rectangle]::new($m.Left,$m.Top,$m.Width,$m.Height))}else{[System.Drawing.Rectangle]::new(0,0,0,0)}
Check 'T5-05-minimal' ($m.Height-eq65-and$am.Count-eq1-and$am[0].Visible-and$inter.Width-eq0-and$inter.Height-eq0) "floating→minimal 回答窗可见且与条零交集" @{minimal=$m;answer=$am;inter="$($inter.Width)x$($inter.Height)"}
Click-At ([int]($m.Right-21*$dpr)) ([int]($m.Top+26*$dpr));Start-Sleep -Milliseconds 2200
$n2=Get-MainWindow $app.Id;$ag=@(Get-AnswerWindows $app.Id)
Check 'T5-05-back' ($n2.Width-eq1800-and$ag.Count-eq0) "minimal→normal 自动关闭回答窗" @{normal=$n2;answers=$ag}
$appOut=Get-Content (Join-Path $Root 'app-out.log') -Raw
$anchors=([regex]::Matches($appOut,'answer anchors updated')).Count;$overlaps=([regex]::Matches($appOut,'answer overlaps input bar')).Count
Check 'T5-05-overlap' ($overlaps-eq0) "主窗形态切换期间 answer overlaps input bar=$overlaps" @{anchors=$anchors;overlaps=$overlaps}
[ordered]@{failures=$script:fail;anchors=$anchors;overlaps=$overlaps}|ConvertTo-Json -Depth 5|Set-Content (Join-Path $Root 'summary.json') -Encoding UTF8
Log "DONE failures=$($script:fail)"
} finally {Get-CimInstance Win32_Process -Filter "Name='python.exe'"|Where-Object{$_.CommandLine-match'mock_llm'}|ForEach-Object{Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue};if(-not$app.HasExited){Stop-Process -Id $app.Id -Force -ErrorAction SilentlyContinue}}
