param(
  [string]$Exe='D:\DSH_Workspace\Prog2_app\app\build\windows\x64\runner\Release\loop.exe',
  [string]$Mock='D:\DSH_Workspace\Prog2_app\docs\streaming-evidence\tools\mock_llm.py',
  [string]$Root=(Join-Path $env:TEMP 'loop-t13-evidence\click')
)
$ErrorActionPreference='Stop'; Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
. "$env:TEMP\loop-t13-evidence\ui.ps1"
if(Test-Path $Root){Remove-Item $Root -Recurse -Force}; New-Item -ItemType Directory -Force $Root|Out-Null
$logPath=Join-Path $Root 'click.log'; $jsonPath=Join-Path $Root 'click-results.jsonl'; $fail=0
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
Clear-In $app.Id;Send-Text '焦点保持' 40|Out-Null;Start-Sleep -Milliseconds 150;Send-Enter
$ans=Wait-A $app.Id;Start-Sleep -Milliseconds 2200;$ans=@(Get-AnswerWindows $app.Id)[0]
$main=Get-MainWindow $app.Id;Activate-Hwnd ([IntPtr]$main.HwndInt)
Click-At ([int]($main.Left+1200*$dpr)) ([int]($main.Bottom-55*$dpr));Send-Text '测试' 45|Out-Null;Start-Sleep -Milliseconds 250
$fgPath=Join-Path $Root 'click-foreground.tsv';[FgSampler]::Start($fgPath)
$fi0=[W32T]::FocusedInfo().Split('|')
for($i=1;$i-le5;$i++){Click-At ([int]($ans.Left+100)) ([int]($ans.Top+100));Start-Sleep -Milliseconds 400;$fi=[W32T]::FocusedInfo().Split('|');Check "F-01-click-$i" ($fi[0]-eq[string]$main.HwndInt) "第 $i 次点击正文 fg=$($fi[0]) focus=$($fi[2])" @{fg=$fi[0];focus=$fi[2]}}
$dx=[int]($ans.Left+200);$dy=[int]($ans.Top+18);Drag-At $dx $dy ($dx+20) ($dy+10) 8 100;Start-Sleep -Milliseconds 350
$fi2=[W32T]::FocusedInfo().Split('|');Check 'F-01-drag' ($fi2[0]-eq[string]$main.HwndInt-and$fi2[2]-eq$fi0[2]) "拖标题后 fg/focus 不变 fg=$($fi2[0]) focus=$($fi2[2])"
Drag-At ([int]($ans.Right-5)) ([int]($ans.Bottom-40)) ([int]($ans.Right-5)) ([int]($ans.Top+120)) 10 100;Start-Sleep -Milliseconds 350
$fi3=[W32T]::FocusedInfo().Split('|');Check 'F-01-scrollbar' ($fi3[0]-eq[string]$main.HwndInt-and$fi3[2]-eq$fi0[2]) "拖滚动条后 fg/focus 不变 fg=$($fi3[0]) focus=$($fi3[2])"
Wheel-At ([int]($ans.Left+$ans.Width/2)) ([int]($ans.Top+$ans.Height/2)) 600;Start-Sleep -Milliseconds 350
$fi4=[W32T]::FocusedInfo().Split('|');Check 'F-01-wheel' ($fi4[0]-eq[string]$main.HwndInt-and$fi4[2]-eq$fi0[2]) "滚轮后 fg/focus 不变 fg=$($fi4[0]) focus=$($fi4[2])"
$before=[pscustomobject]@{L=$ans.Left;T=$ans.Top;W=$ans.Width;H=$ans.Height}
DoubleClick-At ([int]($ans.Left+300)) ([int]($ans.Top+18));Start-Sleep -Milliseconds 600
$after=@(Get-AnswerWindows $app.Id)[0]
Check 'T5-13-dblclick' ($after.Left-eq$before.L-and$after.Top-eq$before.T-and$after.Width-eq$before.W-and$after.Height-eq$before.H) "双击标题不改变布局（resetPosition 已移除）" @{before=$before;after=$after}
Send-Text '好' 60|Out-Null;Start-Sleep -Milliseconds 300;Send-Enter
$ans2=Wait-A $app.Id;Start-Sleep -Milliseconds 1200
Check 'F-01-submit' ($null-ne$ans2) "交互后继续输入并提交成功"
[FgSampler]::Stop()
$fg=@(Get-Content $fgPath|ForEach-Object{$p=$_-split "`t";if($p.Count-ge2){$f=$p[1]-split '\|';if($f.Count-ge3){[pscustomobject]@{T=[int]$p[0];Hwnd=$f[0];Class=$f[1];Focus=$f[2]}}}})
$eps=New-Object System.Collections.ArrayList
for($i=0;$i-lt$fg.Count;$i++){if($fg[$i].Class-eq'FLUTTER_MULTI_WINDOW_WIN32_WINDOW'){$endT=if($i+1-lt$fg.Count){$fg[$i+1].T}else{$fg[$i].T};[void]$eps.Add([pscustomobject]@{StartMs=$fg[$i].T;DurationMs=($endT-$fg[$i].T);Hwnd=$fg[$i].Hwnd})}}
$maxEp=if($eps.Count){($eps|Measure-Object -Property DurationMs -Maximum).Maximum}else{0}
$over100=@($eps|Where-Object{$_.DurationMs-gt100})
Rec 'F-01-episodes' $(if($over100.Count-eq0){'PASS'}else{'FAIL'}) "focus 阶段前台 episodes=$($eps.Count) max=${maxEp}ms over100=$($over100.Count)" @{episodes=$eps}
$appOut=Get-Content (Join-Path $Root 'app-out.log') -Raw
$resync=([regex]::Matches($appOut,'resync_requested')).Count;$chrome=([regex]::Matches($appOut,'applyAnswerWindowChrome failed')).Count
Check 'T5-04' ($resync-eq0) "resync_requested=$resync";Check 'F-06' ($chrome-eq0) "chrome failed=$chrome"
$py=@'
import sqlite3, os, json
p=os.path.join(os.environ['TEMP'],'loop-t13-evidence','click','data','loop.db')
c=sqlite3.connect(p);cur=c.cursor()
print(json.dumps([r[0] for r in cur.execute("select content from messages where role='user' order by rowid desc limit 5")], ensure_ascii=True));c.close()
'@
$pyP=Join-Path $Root 'msgs.py';Set-Content $pyP $py -Encoding UTF8;$msgs=(python $pyP)|ConvertFrom-Json
Check 'F-01-text' (@($msgs|Where-Object{$_-match'测试好'}).Count-gt0) "中文文本完整提交（messages 含 测试好）" @{messages=$msgs}
[ordered]@{failures=$script:fail;maxAnswerForegroundMs=$maxEp;resync=$resync;chrome=$chrome}|ConvertTo-Json -Depth 5|Set-Content (Join-Path $Root 'summary.json') -Encoding UTF8
Log "DONE failures=$($script:fail)"
} finally {Get-CimInstance Win32_Process -Filter "Name='python.exe'"|Where-Object{$_.CommandLine-match'mock_llm'}|ForEach-Object{Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue};if(-not$app.HasExited){Stop-Process -Id $app.Id -Force -ErrorAction SilentlyContinue}}
