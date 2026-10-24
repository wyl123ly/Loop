Add-Type -TypeDefinition @"
using System;
using System.Text;
using System.IO;
using System.Threading;
using System.Runtime.InteropServices;
public static class W32T {
  public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
  [StructLayout(LayoutKind.Sequential)] public struct MINMAXINFO {
    public POINT ptReserved; public POINT ptMaxSize; public POINT ptMaxPosition;
    public POINT ptMinTrackSize; public POINT ptMaxTrackSize; }
  [StructLayout(LayoutKind.Sequential)] public struct GUITHREADINFO {
    public int cbSize; public uint flags; public IntPtr hwndActive; public IntPtr hwndFocus;
    public IntPtr hwndCapture; public IntPtr hwndMenuOwner; public IntPtr hwndMoveSize; public IntPtr hwndCaret; public RECT rcCaret; }
  [StructLayout(LayoutKind.Sequential)] public struct INPUT { public uint type; public InputUnion U; }
  [StructLayout(LayoutKind.Explicit)] public struct InputUnion { [FieldOffset(0)] public KEYBDINPUT ki; [FieldOffset(0)] public MOUSEINPUT mi; }
  [StructLayout(LayoutKind.Sequential)] public struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
  [StructLayout(LayoutKind.Sequential)] public struct MOUSEINPUT { public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr ctx);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lParam);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr hWnd, StringBuilder sb, int max);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, IntPtr pid);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern IntPtr GetWindowLongPtr(IntPtr hWnd, int index);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
  [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr hWnd, uint msg, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr hWnd, uint msg, IntPtr w, ref MINMAXINFO l);
  [DllImport("user32.dll")] public static extern bool GetGUIThreadInfo(uint tid, ref GUITHREADINFO info);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int cmd);
  [DllImport("user32.dll", SetLastError=true)] public static extern uint SendInput(uint n, INPUT[] inputs, int size);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
  [DllImport("user32.dll")] public static extern IntPtr GetFocus();
  public static uint KeyUnicode(char ch) {
    var d = new INPUT { type = 1 }; d.U.ki.wScan = ch; d.U.ki.dwFlags = 0x0004;
    var u = new INPUT { type = 1 }; u.U.ki.wScan = ch; u.U.ki.dwFlags = 0x0006;
    return SendInput(1, new[] { d }, Marshal.SizeOf(typeof(INPUT))) + SendInput(1, new[] { u }, Marshal.SizeOf(typeof(INPUT)));
  }
  public static uint PressVk(ushort vk) {
    var d = new INPUT { type = 1 }; d.U.ki.wVk = vk;
    var u = new INPUT { type = 1 }; u.U.ki.wVk = vk; u.U.ki.dwFlags = 0x0002;
    return SendInput(1, new[] { d }, Marshal.SizeOf(typeof(INPUT))) + SendInput(1, new[] { u }, Marshal.SizeOf(typeof(INPUT)));
  }
  public static uint CtrlV() {
    var c1 = new INPUT { type = 1 }; c1.U.ki.wVk = 0x11;
    var v1 = new INPUT { type = 1 }; v1.U.ki.wVk = 0x56;
    var v2 = new INPUT { type = 1 }; v2.U.ki.wVk = 0x56; v2.U.ki.dwFlags = 0x0002;
    var c2 = new INPUT { type = 1 }; c2.U.ki.wVk = 0x11; c2.U.ki.dwFlags = 0x0002;
    return SendInput(1, new[] { c1 }, Marshal.SizeOf(typeof(INPUT)))
      + SendInput(1, new[] { v1 }, Marshal.SizeOf(typeof(INPUT)))
      + SendInput(1, new[] { v2 }, Marshal.SizeOf(typeof(INPUT)))
      + SendInput(1, new[] { c2 }, Marshal.SizeOf(typeof(INPUT)));
  }
  public static uint CtrlKey(ushort vk) {
    var c1 = new INPUT { type = 1 }; c1.U.ki.wVk = 0x11;
    var v1 = new INPUT { type = 1 }; v1.U.ki.wVk = vk;
    var v2 = new INPUT { type = 1 }; v2.U.ki.wVk = vk; v2.U.ki.dwFlags = 0x0002;
    var c2 = new INPUT { type = 1 }; c2.U.ki.wVk = 0x11; c2.U.ki.dwFlags = 0x0002;
    return SendInput(1, new[] { c1 }, Marshal.SizeOf(typeof(INPUT)))
      + SendInput(1, new[] { v1 }, Marshal.SizeOf(typeof(INPUT)))
      + SendInput(1, new[] { v2 }, Marshal.SizeOf(typeof(INPUT)))
      + SendInput(1, new[] { c2 }, Marshal.SizeOf(typeof(INPUT)));
  }
  public static string FocusedInfo() {
    var g = new GUITHREADINFO(); g.cbSize = Marshal.SizeOf(typeof(GUITHREADINFO));
    var fg = GetForegroundWindow();
    var tid = GetWindowThreadProcessId(fg, IntPtr.Zero);
    string focus = "0";
    if (GetGUIThreadInfo(tid, ref g)) focus = g.hwndFocus.ToInt64().ToString();
    var sb = new StringBuilder(256); GetClassName(fg, sb, 256);
    return fg.ToInt64() + "|" + sb + "|" + focus;
  }
}
public static class FgSampler {
  static Thread t; static volatile bool run; static StreamWriter w;
  public static void Start(string p) {
    run = true;
    w = new StreamWriter(new FileStream(p, FileMode.Create, FileAccess.Write, FileShare.ReadWrite));
    w.AutoFlush = true;
    t = new Thread(() => {
      var sw = System.Diagnostics.Stopwatch.StartNew();
      string last = "";
      while (run) {
        var info = W32T.FocusedInfo();
        if (info != last) {
          w.WriteLine(sw.ElapsedMilliseconds + "\t" + info);
          last = info;
        }
        Thread.Sleep(2);
      }
    });
    t.IsBackground = true; t.Start();
  }
  public static void Stop() { run = false; if (t != null) t.Join(2000); if (w != null) { w.Flush(); w.Close(); w = null; } }
}
public static class RectSampler {
  static Thread t; static volatile bool run; static StreamWriter w;
  public static void Start(string p, long hwnd, int intervalMs) {
    run = true;
    w = new StreamWriter(new FileStream(p, FileMode.Create, FileAccess.Write, FileShare.ReadWrite));
    w.AutoFlush = true;
    t = new Thread(() => {
      var sw = System.Diagnostics.Stopwatch.StartNew();
      var h = new IntPtr(hwnd);
      while (run) {
        W32T.RECT r;
        if (W32T.GetWindowRect(h, out r)) {
          w.WriteLine(sw.ElapsedMilliseconds + "\t" + r.Left + "\t" + r.Top + "\t" + (r.Right-r.Left) + "\t" + (r.Bottom-r.Top) + "\t" + W32T.IsWindowVisible(h));
        }
        Thread.Sleep(intervalMs);
      }
    });
    t.IsBackground = true; t.Start();
  }
  public static void Stop() { run = false; if (t != null) t.Join(2000); if (w != null) { w.Flush(); w.Close(); w = null; } }
}
"@
[void][W32T]::SetProcessDpiAwarenessContext([IntPtr](-4))

function Get-LoopWindows([int]$processId) {
  $list = New-Object System.Collections.ArrayList
  $cb = [W32T+EnumWindowsProc]{
    param([IntPtr]$hwnd, [IntPtr]$lparam)
    $sb = New-Object System.Text.StringBuilder 256
    [void][W32T]::GetClassName($hwnd, $sb, 256)
    $class = $sb.ToString()
    if ($class -in @('FLUTTER_RUNNER_WIN32_WINDOW','FLUTTER_MULTI_WINDOW_WIN32_WINDOW')) {
      $procId = 0
      [void][W32T]::GetWindowThreadProcessId($hwnd, [ref]$procId)
      if ($procId -eq $processId) {
        $r = New-Object W32T+RECT
        [void][W32T]::GetWindowRect($hwnd, [ref]$r)
        [void]$list.Add([pscustomobject]@{Hwnd=$hwnd; HwndInt=$hwnd.ToInt64(); Class=$class; ProcId=$procId;
          Left=$r.Left; Top=$r.Top; Right=$r.Right; Bottom=$r.Bottom; Width=$r.Right-$r.Left; Height=$r.Bottom-$r.Top;
          Visible=[W32T]::IsWindowVisible($hwnd); Style=('0x{0:X}' -f [W32T]::GetWindowLongPtr($hwnd,-16).ToInt64());
          ExStyle=('0x{0:X}' -f [W32T]::GetWindowLongPtr($hwnd,-20).ToInt64());
          Foreground=([W32T]::GetForegroundWindow() -eq $hwnd); Dpi=[W32T]::GetDpiForWindow($hwnd) })
      }
    }
    return $true
  }
  [void][W32T]::EnumWindows($cb, [IntPtr]::Zero)
  return $list
}

function Get-MainWindow([int]$processId) {
  Get-LoopWindows $processId | Where-Object { $_.Class -eq 'FLUTTER_RUNNER_WIN32_WINDOW' } | Select-Object -First 1
}
function Get-AnswerWindows([int]$processId) {
  @(Get-LoopWindows $processId | Where-Object { $_.Class -eq 'FLUTTER_MULTI_WINDOW_WIN32_WINDOW' })
}

function Save-WindowShot([IntPtr]$hwnd, [string]$path) {
  Add-Type -AssemblyName System.Drawing
  $r = New-Object W32T+RECT
  [void][W32T]::GetWindowRect($hwnd, [ref]$r)
  $w=[Math]::Max(1,$r.Right-$r.Left); $h=[Math]::Max(1,$r.Bottom-$r.Top)
  $bmp=New-Object System.Drawing.Bitmap($w,$h)
  $g=[System.Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen($r.Left,$r.Top,0,0,(New-Object System.Drawing.Size($w,$h)))
  $bmp.Save($path,[System.Drawing.Imaging.ImageFormat]::Png)
  $g.Dispose(); $bmp.Dispose()
  return "$w x $h"
}
function Save-DesktopShot([string]$path, [int]$x, [int]$y, [int]$w, [int]$h) {
  Add-Type -AssemblyName System.Drawing
  $bmp=New-Object System.Drawing.Bitmap($w,$h)
  $g=[System.Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen($x,$y,0,0,(New-Object System.Drawing.Size($w,$h)))
  $bmp.Save($path,[System.Drawing.Imaging.ImageFormat]::Png)
  $g.Dispose(); $bmp.Dispose()
}
function Click-At([int]$x,[int]$y) {
  [void][W32T]::SetCursorPos($x,$y)
  Start-Sleep -Milliseconds 120
  [W32T]::mouse_event(0x0002,0,0,0,[UIntPtr]::Zero)
  Start-Sleep -Milliseconds 60
  [W32T]::mouse_event(0x0004,0,0,0,[UIntPtr]::Zero)
  Start-Sleep -Milliseconds 250
}
function DoubleClick-At([int]$x,[int]$y) {
  [void][W32T]::SetCursorPos($x,$y)
  Start-Sleep -Milliseconds 120
  for($i=0;$i -lt 2;$i++){ [W32T]::mouse_event(0x0002,0,0,0,[UIntPtr]::Zero); Start-Sleep -Milliseconds 40; [W32T]::mouse_event(0x0004,0,0,0,[UIntPtr]::Zero); Start-Sleep -Milliseconds 70 }
  Start-Sleep -Milliseconds 300
}
function Drag-At([int]$x1,[int]$y1,[int]$x2,[int]$y2,[int]$steps=12,[int]$holdMs=80) {
  [void][W32T]::SetCursorPos($x1,$y1); Start-Sleep -Milliseconds 150
  [W32T]::mouse_event(0x0002,0,0,0,[UIntPtr]::Zero); Start-Sleep -Milliseconds $holdMs
  for($i=1;$i -le $steps;$i++){ $x=[int]($x1+($x2-$x1)*$i/$steps); $y=[int]($y1+($y2-$y1)*$i/$steps); [void][W32T]::SetCursorPos($x,$y); Start-Sleep -Milliseconds 35 }
  Start-Sleep -Milliseconds 120
  [W32T]::mouse_event(0x0004,0,0,0,[UIntPtr]::Zero); Start-Sleep -Milliseconds 300
}
function Wheel-At([int]$x,[int]$y,[int]$delta) {
  [void][W32T]::SetCursorPos($x,$y); Start-Sleep -Milliseconds 120
  $wheelData = [System.BitConverter]::ToUInt32([System.BitConverter]::GetBytes([int32]$delta),0); [W32T]::mouse_event(0x0800,0,0,$wheelData,[UIntPtr]::Zero); Start-Sleep -Milliseconds 350
}
function Send-Text([string]$text,[int]$delay=45) {
  $n=0
  foreach($ch in $text.ToCharArray()){ $n += [W32T]::KeyUnicode($ch); Start-Sleep -Milliseconds $delay }
  return $n
}
function Send-Vk([int]$vk) { [void][W32T]::PressVk([uint16]$vk); Start-Sleep -Milliseconds 120 }
function Send-Enter { Send-Vk 0x0D }
function Send-CtrlV { [void][W32T]::CtrlV(); Start-Sleep -Milliseconds 400 }
function Send-CtrlA { [void][W32T]::CtrlKey(0x41); Start-Sleep -Milliseconds 250 }
function Send-CtrlC { [void][W32T]::CtrlKey(0x43); Start-Sleep -Milliseconds 250 }
function Activate-Hwnd([IntPtr]$hwnd) {
  [void][W32T]::SetForegroundWindow($hwnd)
  Start-Sleep -Milliseconds 350
  if([W32T]::GetForegroundWindow() -ne $hwnd){
    try { $wsh=New-Object -ComObject WScript.Shell; [void]$wsh.AppActivate($hwnd.ToInt64()) } catch {}
    Start-Sleep -Milliseconds 350
  }
}
function Paste-Text([string]$text) {
  Set-Clipboard -Value $text
  Start-Sleep -Milliseconds 150
  Send-CtrlV
}
function Get-MinMaxTrack([IntPtr]$hwnd) {
  $mi=New-Object W32T+MINMAXINFO
  [void][W32T]::SendMessage($hwnd, 0x0024, [IntPtr]::Zero, [ref]$mi)
  return [pscustomobject]@{ MinW=$mi.ptMinTrackSize.X; MinH=$mi.ptMinTrackSize.Y; MaxW=$mi.ptMaxTrackSize.X; MaxH=$mi.ptMaxTrackSize.Y }
}
function Compare-Png([string]$a,[string]$b,[int]$sampleStep=4) {
  Add-Type -AssemblyName System.Drawing
  $ia=[System.Drawing.Bitmap]::FromFile($a); $ib=[System.Drawing.Bitmap]::FromFile($b)
  if($ia.Width -ne $ib.Width -or $ia.Height -ne $ib.Height){ $r="$($ia.Width)x$($ia.Height) vs $($ib.Width)x$($ib.Height)"; $ia.Dispose();$ib.Dispose(); return $r }
  $diff=0; $n=0
  for($y=0;$y -lt $ia.Height;$y+=$sampleStep){ for($x=0;$x -lt $ia.Width;$x+=$sampleStep){ $pa=$ia.GetPixel($x,$y); $pb=$ib.GetPixel($x,$y); $d=[Math]::Abs($pa.R-$pb.R)+[Math]::Abs($pa.G-$pb.G)+[Math]::Abs($pa.B-$pb.B); if($d -gt 24){$diff++}; $n++ } }
  $ia.Dispose();$ib.Dispose()
  return [pscustomobject]@{ DiffPixels=$diff; Samples=$n; Ratio=($(if($n){[Math]::Round($diff/$n,4)}else{0})) }
}
function Count-Colors([string]$path,[int]$sampleStep=2) {
  Add-Type -AssemblyName System.Drawing
  $img=[System.Drawing.Bitmap]::FromFile($path); $set=New-Object 'System.Collections.Generic.HashSet[int]'
  for($y=0;$y -lt $img.Height;$y+=$sampleStep){ for($x=0;$x -lt $img.Width;$x+=$sampleStep){ [void]$set.Add($img.GetPixel($x,$y).ToArgb()) } }
  $img.Dispose(); return $set.Count
}
