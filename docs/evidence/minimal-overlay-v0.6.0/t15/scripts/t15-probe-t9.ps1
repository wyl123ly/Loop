param(
  [string]$Exe='D:\DSH_Workspace\Prog2_app\app\build\windows\x64\runner\Release\loop.exe',
  [string]$Mock='D:\DSH_Workspace\Prog2_app\docs\streaming-evidence\tools\mock_llm.py',
  [string]$Root=(Join-Path $env:TEMP 'loop-t15-evidence\t9')
)
$ErrorActionPreference='Stop'; Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
. "$env:TEMP\loop-t15-evidence\ui.ps1"
if(Test-Path $Root){Remove-Item $Root -Recurse -Force}; New-Item -ItemType Directory -Force $Root|Out-Null
$logPath=Join-Path $Root 't9.log'; $jsonPath=Join-Path $Root 't9-results.jsonl'; $fail=0
function Log($m){$l="$(Get-Date -Format 'HH:mm:ss.fff') $m";$l|Tee-Object -FilePath $logPath -Append|Out-Host}
function Rec($id,$st,$d,$data=$null){$o=[ordered]@{id=$id;status=$st;detail=$d;at=(Get-Date -Format 'HH:mm:ss.fff')};if($null-ne$data){$o.data=$data};($o|ConvertTo-Json -Compress -Depth 8)|Add-Content $jsonPath;if($st-eq'FAIL'){$script:fail++};Log "[$st] $id $d"}
function Check($id,$c,$d,$data=$null){if($c){Rec $id 'PASS' $d $data}else{Rec $id 'FAIL' $d $data};return $c}
function Get-AL($p){@(Get-AnswerWindows $p)}
function Wait-A($p,$t=20000){$dl=[DateTime]::Now.AddMilliseconds($t);while([DateTime]::Now-lt$dl){$a=@(Get-AnswerWindows $p);if($a.Count-gt0-and$a[0].Visible){return $a[0]};Start-Sleep -Milliseconds 20};return $null}
function Wait-Height($p,$h,$t=5000){$dl=[DateTime]::Now.AddMilliseconds($t);while([DateTime]::Now-lt$dl){$a=@(Get-AnswerWindows $p);if($a.Count-gt0-and[Math]::Abs($a[0].Height-$h)-le2){return $a[0]};Start-Sleep -Milliseconds 30};return $null}
function Clear-In($p){$w=Get-MainWindow $p;Activate-Hwnd ([IntPtr]$w.HwndInt);$d=$w.Dpi/96.0;Click-At ([int]($w.Left+1200*$d)) ([int]($w.Bottom-55*$d));Start-Sleep -Milliseconds 180;[void][W32T]::PressVk(0x23);for($i=0;$i-lt40;$i++){[void][W32T]::PressVk(0x08);Start-Sleep -Milliseconds 6};Start-Sleep -Milliseconds 120}
function Submit($p,$text){Clear-In $p;Send-Text $text 40|Out-Null;Start-Sleep -Milliseconds 150;Send-Enter}
function Get-LastInput([string]$appOut){ for($k=0;$k -lt 30;$k++){ $lines=Get-Content $appOut -ErrorAction SilentlyContinue; $last=$null; foreach($l in $lines){ $m=[regex]::Match($l,'input=\((-?\d+),(-?\d+),(\d+),(\d+)\)'); if($m.Success){ $last=[pscustomobject]@{L=[int]$m.Groups[1].Value;T=[int]$m.Groups[2].Value;W=[int]$m.Groups[3].Value;H=[int]$m.Groups[4].Value} } }; if($null -ne $last){ return $last }; Start-Sleep -Milliseconds 100 }; return $null }
function Overlaps($a,$i,$gap){ if($null-eq$a-or$null-eq$i){return $true}; $inter=[System.Drawing.Rectangle]::Intersect([System.Drawing.Rectangle]::new($a.Left,$a.Top,$a.Width,$a.Height),[System.Drawing.Rectangle]::new($i.L,$i.T,$i.W+2*$gap,$i.H+2*$gap)); return ($inter.Width-gt0-and$inter.Height-gt0) }
if(@(Get-Process loop -ErrorAction SilentlyContinue).Count-gt0){throw 'LOOP_RUNNING'}
if(Get-NetTCPConnection -State Listen -LocalPort 8765,9999 -ErrorAction SilentlyContinue){throw 'PORT_IN_USE'}
$data=Join-Path $Root 'data';New-Item -ItemType Directory -Force $data|Out-Null;New-Item -ItemType File -Force (Join-Path $data 'loop.db')|Out-Null
$env:LOOP_DATA_DIR=$data;Remove-Item Env:LOOP_THEME -ErrorAction SilentlyContinue
$mock=Start-Process python -ArgumentList @($Mock) -PassThru -WindowStyle Hidden -RedirectStandardOutput (Join-Path $Root 'mock-out.log') -RedirectStandardError (Join-Path $Root 'mock-err.log');Start-Sleep -Milliseconds 900
$appOut=Join-Path $Root 'app-out.log'; $app=Start-Process $Exe -PassThru -RedirectStandardOutput $appOut -RedirectStandardError (Join-Path $Root 'app-err.log')
try{
for($i=0;$i-lt80;$i++){try{$h=Invoke-RestMethod 'http://127.0.0.1:8765/api/health' -TimeoutSec 1;break}catch{Start-Sleep -Milliseconds 300}}
Invoke-RestMethod -Method Put -Uri 'http://127.0.0.1:8765/api/settings' -ContentType 'application/json' -Body '{"api_key":"test-key","base_url":"http://127.0.0.1:9999","model":"mock"}'|Out-Null
Invoke-RestMethod -Method Put -Uri 'http://127.0.0.1:8765/api/settings' -ContentType 'application/json' -Body '{"stream_output":true}'|Out-Null
for($i=0;$i-lt60;$i++){$main=Get-MainWindow $app.Id;if($main){break};Start-Sleep -Milliseconds 250}
Start-Sleep -Milliseconds 1200;$dpr=$main.Dpi/96.0
Add-Type -AssemblyName System.Drawing
# A. light userMoved -> floating/minimal; overlap must be 0 and input usable
Submit $app.Id '长回复'; $ans=Wait-A $app.Id; Start-Sleep -Milliseconds 2500; $ans=@(Get-AL $app.Id)[0]
$main=Get-MainWindow $app.Id
$dx=[int]($ans.Left+220);$dy=[int]($ans.Top+18)
Drag-At $dx $dy ($dx+40) ($dy+10) 8 100; Start-Sleep -Milliseconds 800
$ans0=@(Get-AL $app.Id)[0]
Log "N0 normal answer=$($ans0.Left),$($ans0.Top),$($ans0.Width),$($ans0.Height)@$($ans0.Dpi)"
$main=Get-MainWindow $app.Id; Activate-Hwnd ([IntPtr]$main.HwndInt)
Click-At ([int]($main.Right-158*$dpr)) ([int]($main.Top+22*$dpr)); Start-Sleep -Milliseconds 1800
$float=Get-MainWindow $app.Id; $ansF=@(Get-AL $app.Id)[0]; $inF=Get-LastInput $appOut
$overlapF=Overlaps $ansF $inF (8*$dpr)
Check 'T9-01-float-visible' ($float.Width-lt1800-and$ansF.Visible-and$ansF.Dpi-eq120) "floating 回答窗可见/dpr 不变 rect=$($ansF.Left),$($ansF.Top),$($ansF.Width)x$($ansF.Height)@$($ansF.Dpi)" @{floating=$float;answer=$ansF;input=$inF}
Check 'T9-01-float-overlap' (-not $overlapF) "floating 回答窗与真实输入条零交集 input=$($inF.L),$($inF.T),$($inF.W)x$($inF.H)" @{input=$inF;answer=$ansF}
$nudgedF=($ansF.Left-ne$ans0.Left-or$ansF.Top-ne$ans0.Top)
Rec 'T9-01-float-nudge' 'INFO' "userMoved 浮窗 nudge=$nudgedF 位置变化=($($ansF.Left-$ans0.Left),$($ansF.Top-$ans0.Top))"
# click minimal
Click-At ([int]($float.Right-101*$dpr)) ([int]($float.Top+22*$dpr)); Start-Sleep -Milliseconds 1800
$min=Get-MainWindow $app.Id; $ansM=@(Get-AL $app.Id)[0]; $inM=Get-LastInput $appOut
$overlapM=Overlaps $ansM $inM (8*$dpr)
Check 'T9-01-min-visible' ($min.Height-eq65-and$ansM.Visible-and$ansM.Dpi-eq120) "minimal 回答窗可见/dpr 不变 rect=$($ansM.Left),$($ansM.Top),$($ansM.Width)x$($ansM.Height)@$($ansM.Dpi)" @{minimal=$min;answer=$ansM;input=$inM}
Check 'T9-01-min-overlap' (-not $overlapM) "minimal 回答窗与真实输入条零交集 input=$($inM.L),$($inM.T),$($inM.W)x$($inM.H)" @{input=$inM;answer=$ansM}
$nudgedM=($ansM.Left-ne$ansF.Left-or$ansM.Top-ne$ansF.Top)
Rec 'T9-01-min-nudge' 'INFO' "userMoved 极简 nudge=$nudgedM 位置变化=($($ansM.Left-$ansF.Left),$($ansM.Top-$ansF.Top))"
# input usable: click minimal input, type, send; answer replaces and shrinks
$m=Get-MainWindow $app.Id
Click-At ([int]($m.Left+$m.Width/2)) ([int]($m.Top+$m.Height/2)); Start-Sleep -Milliseconds 250
Send-Text '测试好' 45|Out-Null; Start-Sleep -Milliseconds 250; $t0=Get-Date; Send-Enter
$ans2=Wait-A $app.Id; $shrunk=Wait-Height $app.Id 225 5000; Start-Sleep -Milliseconds 800
$ans2=@(Get-AL $app.Id)[0]
Check 'T9-01-input' ($null-ne$ans2-and$null-ne$shrunk) "极简输入条可点击输入并提交，回答窗替换并缩回 minH=225（$([int]((Get-Date)-$t0).TotalMilliseconds)ms）" @{answer=$ans2}
$min2=Get-MainWindow $app.Id
Check 'T9-01-min2' ($min2.Height-eq65) "提交后仍在极简形态"
# B. far userMoved (no overlap) -> mode changes must NOT move answer
$main=Get-MainWindow $app.Id
DoubleClick-At ([int]($min2.Left+12*$dpr)) ([int]($min2.Top+26*$dpr)); Start-Sleep -Milliseconds 900
$f=Get-MainWindow $app.Id; Click-At ([int]($f.Right-63*$dpr)) ([int]($f.Top+22*$dpr)); Start-Sleep -Milliseconds 1800
$normal=Get-MainWindow $app.Id
Submit $app.Id '长回复'; $ansB=Wait-A $app.Id; Start-Sleep -Milliseconds 2500; $ansB=@(Get-AL $app.Id)[0]
$bx=[int]($ansB.Left+220);$by=[int]($ansB.Top+18)
Drag-At $bx $by ($bx-500) ($by-300) 16 120; Start-Sleep -Milliseconds 900
$ansFar=@(Get-AL $app.Id)[0]
$main=Get-MainWindow $app.Id; Activate-Hwnd ([IntPtr]$main.HwndInt)
Click-At ([int]($main.Right-158*$dpr)) ([int]($main.Top+22*$dpr)); Start-Sleep -Milliseconds 1800
$ansFarF=@(Get-AL $app.Id)[0]
Check 'T9-02-float-keep' ([Math]::Abs($ansFarF.Left-$ansFar.Left)-le2-and[Math]::Abs($ansFarF.Top-$ansFar.Top)-le2) "无遮挡 userMoved 进入 floating 不被移动 rect=$($ansFarF.Left),$($ansFarF.Top)" @{before=$ansFar;after=$ansFarF}
$f2=Get-MainWindow $app.Id
Click-At ([int]($f2.Right-101*$dpr)) ([int]($f2.Top+22*$dpr)); Start-Sleep -Milliseconds 1800
$ansFarM=@(Get-AL $app.Id)[0]
Check 'T9-02-min-keep' ([Math]::Abs($ansFarM.Left-$ansFarF.Left)-le2-and[Math]::Abs($ansFarM.Top-$ansFarF.Top)-le2) "无遮挡 userMoved 进入 minimal 不被移动 rect=$($ansFarM.Left),$($ansFarM.Top)" @{before=$ansFarF;after=$ansFarM}
# parse host logs + DB
$out=Get-Content $appOut -Raw
$nudges=([regex]::Matches($out,'answer userMoved nudged for input bar')).Count; $warn=([regex]::Matches($out,'answer overlaps input bar')).Count; $still=([regex]::Matches($out,'stillOverlap')).Count
Check 'T9-01-host' ($warn-eq0) "host overlapWarn=$warn stillOverlap=$still userMovedNudged=$nudges"
$py=@'
import sqlite3, os, json
p=os.path.join(os.environ['TEMP'],'loop-t15-evidence','t9','data','loop.db')
c=sqlite3.connect(p); cur=c.cursor()
print(json.dumps([r[0] for r in cur.execute("select content from messages where role='user' order by rowid desc limit 5")], ensure_ascii=True)); c.close()
'@
$pyP=Join-Path $Root 'msgs.py';Set-Content $pyP $py -Encoding UTF8;$msgs=(python $pyP)|ConvertFrom-Json
Check 'T9-02-db' (@($msgs|Where-Object{$_-match'测试好'}).Count-gt0) "极简输入提交消息落库（messages 含 测试好）" @{messages=$msgs}
[ordered]@{failures=$script:fail;nudges=$nudges;overlapWarn=$warn;stillOverlap=$still}|ConvertTo-Json -Depth 5|Set-Content (Join-Path $Root 'summary.json') -Encoding UTF8
Log "DONE failures=$($script:fail)"
} finally {Get-CimInstance Win32_Process -Filter "Name='python.exe'"|Where-Object{$_.CommandLine-match'mock_llm'}|ForEach-Object{Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue};if(-not$app.HasExited){Stop-Process -Id $app.Id -Force -ErrorAction SilentlyContinue}}
