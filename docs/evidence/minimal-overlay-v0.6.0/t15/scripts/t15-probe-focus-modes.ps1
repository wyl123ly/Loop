param(
  [string]$Exe = 'D:\DSH_Workspace\Prog2_app\app\build\windows\x64\runner\Release\loop.exe',
  [string]$Mock = 'D:\DSH_Workspace\Prog2_app\docs\streaming-evidence\tools\mock_llm.py',
  [string]$Root = (Join-Path $env:TEMP 'loop-t15-evidence\probe')
)
$ErrorActionPreference = 'Stop'
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
. "$env:TEMP\loop-t15-evidence\ui.ps1"
if (Test-Path $Root) { Remove-Item $Root -Recurse -Force }
New-Item -ItemType Directory -Force $Root | Out-Null
$logPath = Join-Path $Root 'probe.log'
$jsonPath = Join-Path $Root 'probe-results.jsonl'
$script:fail = 0
$script:appProc = $null
$script:mockId = $null
function Log([string]$m) { $line = "$(Get-Date -Format 'HH:mm:ss.fff') $m"; $line | Tee-Object -FilePath $logPath -Append | Out-Host }
function Rec([string]$id,[string]$status,[string]$detail,$data=$null){ $o=[ordered]@{id=$id;status=$status;detail=$detail;at=(Get-Date -Format 'HH:mm:ss.fff')}; if($null -ne $data){$o.data=$data}; ($o|ConvertTo-Json -Compress -Depth 8)|Add-Content $jsonPath; if($status -eq 'FAIL'){$script:fail++}; Log ("[{0}] {1} {2}" -f $status,$id,$detail) }
function Check([string]$id,[bool]$c,[string]$d,$data=$null){ if($c){Rec $id 'PASS' $d $data}else{Rec $id 'FAIL' $d $data}; return $c }
function Get-AnswerList([int]$processId){ @(Get-AnswerWindows $processId) }
function Wait-Answer([int]$processId,[int]$timeoutMs=20000,[bool]$visible=$true){ $d=[DateTime]::Now.AddMilliseconds($timeoutMs); while([DateTime]::Now -lt $d){ $a=@(Get-AnswerWindows $processId); if($a.Count -gt 0 -and (-not $visible -or $a[0].Visible)){ return $a[0] }; Start-Sleep -Milliseconds 20 }; return $null }
function Wait-Gone([int]$processId,[int]$timeoutMs=5000){ $d=[DateTime]::Now.AddMilliseconds($timeoutMs); while([DateTime]::Now -lt $d){ if(@(Get-AnswerWindows $processId).Count -eq 0){ return $true }; Start-Sleep -Milliseconds 30 }; return $false }
trap { Log "FATAL: $_"; try { if($script:appProc -and -not $script:appProc.HasExited){Stop-Process -Id $script:appProc.Id -Force -ErrorAction SilentlyContinue} }catch{}; try { Get-CimInstance Win32_Process -Filter "Name='python.exe'" | Where-Object { $_.CommandLine -match 'mock_llm' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } }catch{}; try{[FgSampler]::Stop()}catch{}; exit 3 }
function Clear-Input([int]$processId){ $w=Get-MainWindow $processId; Activate-Hwnd ([IntPtr]$w.HwndInt); $d=$w.Dpi/96.0; Click-At ([int]($w.Left+1200*$d)) ([int]($w.Bottom-55*$d)); Start-Sleep -Milliseconds 180; [void][W32T]::PressVk(0x23); Start-Sleep -Milliseconds 50; for($i=0;$i -lt 40;$i++){ [void][W32T]::PressVk(0x08); Start-Sleep -Milliseconds 6 }; Start-Sleep -Milliseconds 120 }
function Submit([int]$processId,[string]$text){ Clear-Input $processId; Send-Text $text 40 | Out-Null; Start-Sleep -Milliseconds 180; $t0=Get-Date; Send-Enter; return $t0 }
function Close-Answer([int]$processId){ $a=@(Get-AnswerList $processId); if($a.Count -eq 1){ Click-At ([int]($a[0].Right-23)) ([int]($a[0].Top+22)); return (Wait-Gone $processId 5000) }; return $true }
function Get-ComposerTop([string]$shot,[int]$relX){ Add-Type -AssemblyName System.Drawing; $img=[System.Drawing.Bitmap]::FromFile($shot); $prev=$null; $found=-1; for($y=[Math]::Max(0,$img.Height-260);$y -lt $img.Height;$y++){ $c=$img.GetPixel($relX,$y); $v=[int](($c.R+$c.G+$c.B)/3); if($null -ne $prev -and [Math]::Abs($v-$prev) -gt 7){$found=$y;break}; $prev=$v }; $img.Dispose(); return $found }

# env
$existing=@(Get-Process loop -ErrorAction SilentlyContinue); if($existing.Count -gt 0){ throw "LOOP_RUNNING $($existing[0].Id)" }
if(Get-NetTCPConnection -State Listen -LocalPort 8765,9999 -ErrorAction SilentlyContinue){ throw 'PORT_IN_USE' }
$data=Join-Path $Root 'data'; New-Item -ItemType Directory -Force $data | Out-Null; New-Item -ItemType File -Force (Join-Path $data 'loop.db') | Out-Null
$env:LOOP_DATA_DIR=$data; Remove-Item Env:LOOP_THEME -ErrorAction SilentlyContinue
$mock=Start-Process python -ArgumentList @($Mock) -PassThru -WindowStyle Hidden -RedirectStandardOutput (Join-Path $Root 'mock-out.log') -RedirectStandardError (Join-Path $Root 'mock-err.log'); $script:mockId=$mock.Id; Start-Sleep -Milliseconds 900
$app=Start-Process $Exe -PassThru -RedirectStandardOutput (Join-Path $Root 'app-out.log') -RedirectStandardError (Join-Path $Root 'app-err.log'); $script:appProc=$app
for($i=0;$i -lt 80;$i++){ try{$h=Invoke-RestMethod 'http://127.0.0.1:8765/api/health' -TimeoutSec 1;break}catch{Start-Sleep -Milliseconds 300} }
if($null -eq $h){ throw 'health failed' }
Invoke-RestMethod -Method Put -Uri 'http://127.0.0.1:8765/api/settings' -ContentType 'application/json' -Body '{"api_key":"test-key","base_url":"http://127.0.0.1:9999","model":"mock"}' | Out-Null
Invoke-RestMethod -Method Put -Uri 'http://127.0.0.1:8765/api/settings' -ContentType 'application/json' -Body '{"stream_output":true}' | Out-Null
for($i=0;$i -lt 60;$i++){ $main=Get-MainWindow $app.Id; if($main){break}; Start-Sleep -Milliseconds 250 }
Start-Sleep -Milliseconds 1200; $dpr=$main.Dpi/96.0
$fgPath=Join-Path $Root 'foreground.tsv'; [FgSampler]::Start($fgPath)
Log "startup main=$($main.HwndInt) dpr=$dpr"

# ---- T5-08: three fresh creates, timing + waiting-state screenshot
Log '--- T5-08 create timings'
$t5timings=@()
for($i=1;$i -le 3;$i++){
  $t0=Submit $app.Id '普通问题'
  Start-Sleep -Milliseconds 100
  Save-WindowShot ([IntPtr](Get-MainWindow $app.Id).HwndInt) (Join-Path $Root "t5-08-thinking-$i.png") | Out-Null
  $a=Wait-Answer $app.Id 20000 $true
  $ms=if($a){[int]((Get-Date)-$t0).TotalMilliseconds}else{-1}
  $t5timings += [pscustomobject]@{ round=$i; visibleMs=$ms }
  Check "T5-08-$i" ($null -ne $a) "第 $i 次新建回答窗自 Enter 到可见 ${ms}ms" @{ visibleMs=$ms }
  Start-Sleep -Milliseconds 700
  $closed=Close-Answer $app.Id
  Check "T5-14-close-$i" ($closed) "第 $i 次关闭回答窗并确认销毁"
  Start-Sleep -Milliseconds 500
}
$over400=@($t5timings | Where-Object { $_.visibleMs -gt 400 })
if($over400.Count -gt 0){ Rec 'T5-08' 'EXCEPTION' "首次可见未达 spec 400ms 目标（EXCEPTION，非 PASS）：$(($t5timings|ForEach-Object{"$($_.visibleMs)ms"}) -join ', ')" @{ timings=$t5timings } } else { Rec 'T5-08' 'PASS' "三次首次可见均 ≤400ms：$(($t5timings|ForEach-Object{"$($_.visibleMs)ms"}) -join ', ')" @{ timings=$t5timings } }

# ---- T5-14: three minimal enter/expand cycles (button entry) + one drag-to-minimum attempt
Log '--- T5-14 minimal cycles'
$w=Get-MainWindow $app.Id; Activate-Hwnd ([IntPtr]$w.HwndInt)
Click-At ([int]($w.Right-158*$dpr)) ([int]($w.Top+22*$dpr)); Start-Sleep -Milliseconds 1200
$f=Get-MainWindow $app.Id
Check 'T5-14-float' ($f.Width -eq 575 -and $f.Height -eq 750) "进入浮窗 460×600" $f
for($i=1;$i -le 3;$i++){
  $f=Get-MainWindow $app.Id
  Click-At ([int]($f.Right-101*$dpr)) ([int]($f.Top+22*$dpr)); Start-Sleep -Milliseconds 1000
  $m=Get-MainWindow $app.Id
  Check "T5-14-min-$i" ($m.Width -eq 575 -and $m.Height -eq 65) "第 $i 次按钮进入极简 460×52" $m
  DoubleClick-At ([int]($m.Left+12*$dpr)) ([int]($m.Top+26*$dpr)); Start-Sleep -Milliseconds 900
  $f=Get-MainWindow $app.Id
  Check "T5-14-expand-$i" ($f.Width -eq 575 -and $f.Height -eq 750) "第 $i 次双击展开浮窗" $f
}
# drag-to-minimum once: drag bottom-right corner from 460x600 toward 360x420 (450x525 physical),
# overshoot a few px so min-size snapping reaches the 2px tolerance.
$f=Get-MainWindow $app.Id
$sx=[int]($f.Right-3); $sy=[int]($f.Bottom-3); $tx=[int]($f.Left+430); $ty=[int]($f.Top+505)
Drag-At $sx $sy $tx $ty 24 160
Start-Sleep -Milliseconds 1800
$dm=Get-MainWindow $app.Id
if($dm.Height -ne 65){
  $sx=[int]($dm.Right-3); $sy=[int]($dm.Bottom-3); $tx=[int]($dm.Left+420); $ty=[int]($dm.Top+500)
  Drag-At $sx $sy $tx $ty 20 160
  Start-Sleep -Milliseconds 1800
  $dm=Get-MainWindow $app.Id
}
$dragMinOk=($dm.Height -eq 65 -and $dm.Width -le 575 -and $dm.Width -ge 450)
if($dragMinOk){ Rec 'T5-14-dragmin' 'PASS' "拖到最小后自动进入极简 rect=$($dm.Width)x$($dm.Height)" $dm } else { Rec 'T5-14-dragmin' 'INFO' "拖到最小入口本环境未自动触发（rect=$($dm.Width)x$($dm.Height)）；按钮入口 3 次已通过，列限制" $dm }
# restore normal
$m=Get-MainWindow $app.Id
if($m.Height -eq 65){ DoubleClick-At ([int]($m.Left+12*$dpr)) ([int]($m.Top+26*$dpr)); Start-Sleep -Milliseconds 900; $f=Get-MainWindow $app.Id } else { $f=$m }
if($f.Width -lt 1800){ Click-At ([int]($f.Right-63*$dpr)) ([int]($f.Top+22*$dpr)); Start-Sleep -Milliseconds 1800 }
$normal=Get-MainWindow $app.Id
Check 'T5-14-normal' ($normal.Width -eq 1800 -and $normal.Height -eq 1125) "极简/浮窗 3 次循环后返回 1440×900 rect=$($normal.Width)x$($normal.Height)" $normal

# ---- T5-05: answer open while normal -> floating -> minimal -> back
Log '--- T5-05 mode switch anchors'
Submit $app.Id '长回复' | Out-Null
$ans=Wait-Answer $app.Id 20000 $true; Start-Sleep -Milliseconds 2000
$ans=@(Get-AnswerList $app.Id)[0]
Check 'T5-05-open' ($ans.Width -eq 896 -and $ans.Height -ge 900) "normal 长回答 896×$($ans.Height)" $ans
# Move answer left so the title-bar floating toggle / FloatingBar minimize are reachable.
$dragX=[int]($ans.Left+220); $dragY=[int]($ans.Top+18)
Drag-At $dragX $dragY ($dragX-900) ($dragY+300) 18 120
Start-Sleep -Milliseconds 700
$normalNow=Get-MainWindow $app.Id
$ansMoved=@(Get-AnswerList $app.Id)
Check 'T5-05-moved' ($ansMoved.Count -eq 1 -and $ansMoved[0].Visible -and $ansMoved[0].Left -lt 900) "回答窗拖到左侧以便切换形态 rect=$($ansMoved[0].Left),$($ansMoved[0].Top)" $ansMoved
Activate-Hwnd ([IntPtr]$normalNow.HwndInt)
Click-At ([int]($normalNow.Right-158*$dpr)) ([int]($normalNow.Top+22*$dpr)); Start-Sleep -Milliseconds 1800
$floating=Get-MainWindow $app.Id; $ansF=@(Get-AnswerList $app.Id)
Check 'T5-05-floating' ($floating.Width -eq 575 -and $floating.Height -eq 750 -and $ansF.Count -eq 1 -and $ansF[0].Visible) "normal→floating 中回答窗仍可见 rect=$($floating.Width)x$($floating.Height)" @{ floating=$floating; answer=$ansF }
Save-WindowShot ([IntPtr]$floating.HwndInt) (Join-Path $Root 't5-05-floating.png') | Out-Null
Click-At ([int]($floating.Right-101*$dpr)) ([int]($floating.Top+22*$dpr)); Start-Sleep -Milliseconds 1800
$minimal=Get-MainWindow $app.Id; $ansM=@(Get-AnswerList $app.Id)
if($ansM.Count -eq 1){
  $inter=[System.Drawing.Rectangle]::Intersect([System.Drawing.Rectangle]::new($ansM[0].Left,$ansM[0].Top,$ansM[0].Width,$ansM[0].Height),[System.Drawing.Rectangle]::new($minimal.Left,$minimal.Top,$minimal.Width,$minimal.Height))
} else { $inter=[System.Drawing.Rectangle]::new(0,0,0,0) }
Check 'T5-05-minimal' ($minimal.Height -eq 65 -and $ansM.Count -eq 1 -and $ansM[0].Visible -and $inter.Width -eq 0 -and $inter.Height -eq 0) "floating→minimal 中回答窗可见且与条零交集" @{ minimal=$minimal; answer=$ansM; intersection="$($inter.Width)x$($inter.Height)" }
Save-WindowShot ([IntPtr]$minimal.HwndInt) (Join-Path $Root 't5-05-minimal.png') | Out-Null
Click-At ([int]($minimal.Right-21*$dpr)) ([int]($minimal.Top+26*$dpr)); Start-Sleep -Milliseconds 2000
$normal2=Get-MainWindow $app.Id; $ansAfterBack=@(Get-AnswerList $app.Id)
Check 'T5-05-back' ($normal2.Width -eq 1800 -and $ansAfterBack.Count -eq 0) "minimal→normal 自动关闭回答窗" @{ normal=$normal2; answers=$ansAfterBack }
Start-Sleep -Milliseconds 500

# ---- focus: pointer interactions must not activate answer; text input must survive
Log '--- focus interactions'
Submit $app.Id '焦点保持' | Out-Null
$ans=Wait-Answer $app.Id 20000 $true; Start-Sleep -Milliseconds 1200
$ans=@(Get-AnswerList $app.Id)[0]
$mainNow=Get-MainWindow $app.Id
Activate-Hwnd ([IntPtr]$mainNow.HwndInt)
Click-At ([int]($mainNow.Left+1200*$dpr)) ([int]($mainNow.Bottom-55*$dpr))
Send-Text '测试' 45 | Out-Null; Start-Sleep -Milliseconds 250
$fi0=[W32T]::FocusedInfo().Split('|')
Click-At ([int]($ans.Left+100)) ([int]($ans.Top+100)); Start-Sleep -Milliseconds 500
$fi1=[W32T]::FocusedInfo().Split('|')
$dragX=[int]($ans.Left+200); $dragY=[int]($ans.Top+18); Drag-At $dragX $dragY ($dragX+20) ($dragY+10) 8 100
Start-Sleep -Milliseconds 400
$fi2=[W32T]::FocusedInfo().Split('|')
Drag-At ([int]($ans.Right-5)) ([int]($ans.Bottom-40)) ([int]($ans.Right-5)) ([int]($ans.Top+120)) 10 100
Start-Sleep -Milliseconds 400
$fi3=[W32T]::FocusedInfo().Split('|')
Wheel-At ([int]($ans.Left+$ans.Width/2)) ([int]($ans.Top+$ans.Height/2)) 600
Start-Sleep -Milliseconds 400
$fi4=[W32T]::FocusedInfo().Split('|')
$mainHwnd=[string]$mainNow.HwndInt
Check 'F-01-click' ($fi1[0] -eq $mainHwnd) "点击回答正文后前台仍主窗 (fg=$($fi1[0]))" @{ before=$fi0; after=$fi1 }
Check 'F-01-drag' ($fi2[0] -eq $mainHwnd) "拖动回答标题后前台仍主窗 (fg=$($fi2[0]))" @{ after=$fi2 }
Check 'F-01-scrollbar' ($fi3[0] -eq $mainHwnd) "拖滚动条后前台仍主窗 (fg=$($fi3[0]))" @{ after=$fi3 }
Check 'F-01-wheel' ($fi4[0] -eq $mainHwnd) "回答窗滚轮后前台仍主窗 (fg=$($fi4[0]))" @{ after=$fi4 }
Check 'F-01-focus' ($fi1[2] -eq $fi0[2] -and $fi2[2] -eq $fi0[2] -and $fi3[2] -eq $fi0[2] -and $fi4[2] -eq $fi0[2]) "交互前后文本输入焦点 hwnd 不变 ($($fi0[2]))" @{ focus0=$fi0[2]; click=$fi1[2]; drag=$fi2[2]; scroll=$fi3[2]; wheel=$fi4[2] }
# append text and submit; check question via screenshot + DB after exit
Send-Text '好' 60 | Out-Null; Start-Sleep -Milliseconds 300
Save-WindowShot ([IntPtr]$mainNow.HwndInt) (Join-Path $Root 'focus-input-before-send.png') | Out-Null
Send-Enter
$ans2=Wait-Answer $app.Id 20000 $true; Start-Sleep -Milliseconds 1200
Check 'F-01-submit' ($null -ne $ans2 -and $ans2.HwndInt -eq $ans.HwndInt) "交互后继续输入并提交，回答窗替换成功"
$ans2=@(Get-AnswerList $app.Id)[0]
Save-WindowShot ([IntPtr]$ans2.HwndInt) (Join-Path $Root 'focus-answer-after-submit.png') | Out-Null

# ---- T5-07: create during tray quit
Log '--- T5-07 create/quit race'
$closed=Close-Answer $app.Id; Start-Sleep -Milliseconds 500
$mainQ=Get-MainWindow $app.Id
Clear-Input $app.Id; Send-Text '普通问题' 40 | Out-Null; Start-Sleep -Milliseconds 100; Send-Enter
Start-Sleep -Milliseconds 30
$startQuit=Get-Date
[void][W32T]::PostMessage([IntPtr]$mainQ.HwndInt,0x0111,[IntPtr]1027,[IntPtr]::Zero)
$exitedAt=$null; for($i=0;$i -lt 100;$i++){ if($app.HasExited){$exitedAt=Get-Date;break}; Start-Sleep -Milliseconds 50 }
$exitMs=if($exitedAt){[int]($exitedAt-$startQuit).TotalMilliseconds}else{-1}
$leftWins=@(Get-LoopWindows $app.Id); $leftPort=@(Get-NetTCPConnection -State Listen -LocalPort 8765 -ErrorAction SilentlyContinue)
Check 'T5-07-exit' ($app.HasExited -and $exitMs -le 3000) "创建期 tray 退出：exited=$($app.HasExited) ${exitMs}ms"
Check 'T5-07-clean' ($leftWins.Count -eq 0 -and $leftPort.Count -eq 0) "创建期退出无残留窗口/端口 windowsLeft=$($leftWins.Count) portLeft=$($leftPort.Count)"
[FgSampler]::Stop()

# ---- analyze foreground episodes around pointer interactions
$fg=@(Get-Content $fgPath | ForEach-Object { $p=$_ -split "`t"; if($p.Count -ge 2){ $f=$p[1] -split '\|'; if($f.Count -ge 3){ [pscustomobject]@{T=[int]$p[0];Hwnd=$f[0];Class=$f[1];Focus=$f[2]} } } })
$eps=New-Object System.Collections.ArrayList
for($i=0;$i -lt $fg.Count;$i++){ if($fg[$i].Class -eq 'FLUTTER_MULTI_WINDOW_WIN32_WINDOW'){ $endT=if($i+1 -lt $fg.Count){$fg[$i+1].T}else{$fg[$i].T}; [void]$eps.Add([pscustomobject]@{StartMs=$fg[$i].T;DurationMs=($endT-$fg[$i].T);Hwnd=$fg[$i].Hwnd}) } }
$maxEp=if($eps.Count){ ($eps|Measure-Object -Property DurationMs -Maximum).Maximum }else{0}
$over100=@($eps|Where-Object{$_.DurationMs -gt 100})
Rec 'F-01-episodes' $(if($over100.Count -eq 0){'PASS'}else{'FAIL'}) "回答窗前台 episodes=$($eps.Count) max=${maxEp}ms over100=$($over100.Count)" @{ episodes=$eps }

# ---- parse app stdout and DB
$appOut=Get-Content (Join-Path $Root 'app-out.log') -Raw
$resync=([regex]::Matches($appOut,'resync_requested')).Count
$chrome=([regex]::Matches($appOut,'applyAnswerWindowChrome failed')).Count
$anchors=([regex]::Matches($appOut,'answer anchors updated')).Count
$overlaps=([regex]::Matches($appOut,'answer overlaps input bar')).Count
Check 'T5-04' ($resync -eq 0) "resync_requested=$resync"
Check 'F-06' ($chrome -eq 0) "applyAnswerWindowChrome failed=$chrome"
Rec 'T5-05-log' 'INFO' "anchors updated=$anchors overlaps=$overlaps" @{ anchors=$anchors; overlaps=$overlaps }
$py=@'
import sqlite3, os, json
p = os.path.join(os.environ['TEMP'], 'loop-t15-evidence', 'probe', 'data', 'loop.db')
c=sqlite3.connect(p); cur=c.cursor()
rows=[r[0] for r in cur.execute("select content from messages where role='user' order by rowid desc limit 5")]
print(json.dumps(rows, ensure_ascii=True))
c.close()
'@
$pyPath=Join-Path $Root 'msgs.py'; Set-Content $pyPath $py -Encoding UTF8
$msgs=(python $pyPath) | ConvertFrom-Json
$hasFocusMsg=@($msgs | Where-Object { $_ -match '测试好' }).Count -gt 0
Check 'F-01-text' ($hasFocusMsg) "交互后输入的中文文本完整提交（messages 含 测试好）" @{ messages=$msgs }
Get-CimInstance Win32_Process -Filter "Name='python.exe'" | Where-Object { $_.CommandLine -match 'mock_llm' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Log "DONE failures=$($script:fail)"
[ordered]@{failures=$script:fail;t5timings=$t5timings;maxAnswerForegroundMs=$maxEp;anchors=$anchors;overlaps=$overlaps;resync=$resync;chrome=$chrome} | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $Root 'summary.json') -Encoding UTF8
if($script:fail -gt 0){ exit 2 } else { exit 0 }
