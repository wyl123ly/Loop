param(
  [Parameter(Mandatory = $true)][string]$Action,
  [int]$ProcessId = 0,
  [int]$X = 0,
  [int]$Y = 0,
  [int]$X2 = 0,
  [int]$Y2 = 0,
  [int]$Width = 0,
  [int]$Height = 0,
  [int]$HotkeyId = 0,
  [string]$Out = '',
  [string]$Text = '',
  [int]$DurationMs = 300,
  [string]$TitleContains = ''
)

# t4 floating-window Win32 helper: probe / PrintWindow shot / mouse click+drag / WM_HOTKEY injection.
# Coordinates: ClickClient = client physical pixels; DragScreen = screen physical pixels.
$ErrorActionPreference = 'Stop'

Add-Type @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public class T4Win {
  public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);

  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
  [StructLayout(LayoutKind.Sequential)] public struct MINMAXINFO {
    public int reservedX, reservedY;
    public int maxSizeX, maxSizeY;
    public int maxPosX, maxPosY;
    public int minTrackX, minTrackY;
    public int maxTrackX, maxTrackY;
  }
  [StructLayout(LayoutKind.Sequential)] public struct MOUSEINPUT {
    public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public IntPtr dwExtraInfo;
  }
  [StructLayout(LayoutKind.Sequential)] public struct KEYBDINPUT {
    public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo;
  }
  [StructLayout(LayoutKind.Explicit)] public struct INPUTUNION {
    [FieldOffset(0)] public MOUSEINPUT mi;
    [FieldOffset(0)] public KEYBDINPUT ki;
  }
  [StructLayout(LayoutKind.Sequential)] public struct INPUT {
    public uint type; public INPUTUNION u;
  }

  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
  [DllImport("user32.dll")] public static extern IntPtr GetWindowLongPtr(IntPtr h, int i);
  [DllImport("user32.dll")] public static extern IntPtr SetWindowLongPtr(IntPtr h, int i, IntPtr v);
  [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr h, int x, int y, int w, int hh, bool repaint);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetFocus();
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
  [DllImport("user32.dll")] public static extern bool GetWindowDisplayAffinity(IntPtr h, out uint affinity);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
  [DllImport("user32.dll")] public static extern uint SendInput(uint n, INPUT[] inputs, int size);
  [DllImport("gdi32.dll")] public static extern IntPtr CreateCompatibleDC(IntPtr hdc);
  [DllImport("gdi32.dll")] public static extern IntPtr CreateCompatibleBitmap(IntPtr hdc, int w, int h);
  [DllImport("gdi32.dll")] public static extern IntPtr SelectObject(IntPtr hdc, IntPtr obj);
  [DllImport("gdi32.dll")] public static extern bool DeleteObject(IntPtr obj);
  [DllImport("gdi32.dll")] public static extern bool DeleteDC(IntPtr hdc);
  [DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr h);
  [DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr h, IntPtr hdc);

  public const uint MOUSEEVENTF_MOVE = 0x0001;
  public const uint MOUSEEVENTF_LEFTDOWN = 0x0002;
  public const uint MOUSEEVENTF_LEFTUP = 0x0004;
  public const uint MOUSEEVENTF_WHEEL = 0x0800;
  public const uint KEYEVENTF_UNICODE = 0x0004;
  public const uint KEYEVENTF_KEYUP = 0x0002;

  public static IntPtr FindWindow(uint pid, string titleContains) {
    IntPtr found = IntPtr.Zero;
    EnumWindows((h, l) => {
      uint p; GetWindowThreadProcessId(h, out p);
      if (p != pid) return true;
      RECT r; GetWindowRect(h, out r);
      if ((r.Right - r.Left) < 100 || (r.Bottom - r.Top) < 100) return true;
      if (!string.IsNullOrEmpty(titleContains)) {
        StringBuilder sb = new StringBuilder(512);
        int len = GetWindowTextW(h, sb, 512);
        if (len <= 0 || sb.ToString().IndexOf(titleContains, StringComparison.OrdinalIgnoreCase) < 0) return true;
      }
      found = h;
      return false;
    }, IntPtr.Zero);
    return found;
  }

  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder sb, int max);

  public static string Probe(IntPtr h, int pid) {
    RECT r; GetWindowRect(h, out r);
    RECT c; GetClientRect(h, out c);
    POINT origin = new POINT();
    ClientToScreen(h, ref origin);
    long ex = GetWindowLongPtr(h, -20).ToInt64();
    long style = GetWindowLongPtr(h, -16).ToInt64();
    MINMAXINFO mm = new MINMAXINFO();
    IntPtr buf = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(MINMAXINFO)));
    try {
      Marshal.StructureToPtr(mm, buf, false);
      SendMessage(h, 0x0024, IntPtr.Zero, buf);
      mm = (MINMAXINFO)Marshal.PtrToStructure(buf, typeof(MINMAXINFO));
    } catch {
    } finally {
      Marshal.FreeHGlobal(buf);
    }
    IntPtr fg = GetForegroundWindow();
    uint fgPid = 0; GetWindowThreadProcessId(fg, out fgPid);
    uint affinity = 0; try { GetWindowDisplayAffinity(h, out affinity); } catch {}
    StringBuilder title = new StringBuilder(512); GetWindowTextW(h, title, 512);
    return "{" +
      "\"pid\":" + pid +
      ",\"hwnd\":" + h.ToInt64() +
      ",\"title\":" + Quote(title.ToString()) +
      ",\"left\":" + r.Left + ",\"top\":" + r.Top +
      ",\"width\":" + (r.Right - r.Left) + ",\"height\":" + (r.Bottom - r.Top) +
      ",\"clientWidth\":" + (c.Right - c.Left) + ",\"clientHeight\":" + (c.Bottom - c.Top) +
      ",\"clientOriginX\":" + origin.X + ",\"clientOriginY\":" + origin.Y +
      ",\"dpi\":" + GetDpiForWindow(h) +
      ",\"topmost\":" + ((ex & 0x8) != 0).ToString().ToLower() +
      ",\"maximized\":" + IsZoomed(h).ToString().ToLower() +
      ",\"minimized\":" + IsIconic(h).ToString().ToLower() +
      ",\"visible\":" + IsWindowVisible(h).ToString().ToLower() +
      ",\"hasCaption\":" + ((style & 0x00C00000) == 0x00C00000).ToString().ToLower() +
      ",\"layered\":" + ((ex & 0x00080000) != 0).ToString().ToLower() +
      ",\"noActivate\":" + ((ex & 0x08000000) != 0).ToString().ToLower() +
      ",\"minTrack\":\"" + mm.minTrackX + "x" + mm.minTrackY + "\"" +
      ",\"displayAffinity\":" + affinity +
      ",\"foregroundPid\":" + fgPid +
      "}";
  }

  public static string Quote(string s) {
    if (s == null) return "\"\"";
    return "\"" + s.Replace("\\", "\\\\").Replace("\"", "\\\"") + "\"";
  }

  public static void PostMouse(IntPtr h, int x, int y, uint msg, uint buttons) {
    IntPtr lp = (IntPtr)((y << 16) | (x & 0xFFFF));
    PostMessage(h, msg, (IntPtr)buttons, lp);
  }

  public static void ClickClient(IntPtr h, int x, int y) {
    PostMouse(h, x, y, 0x0200, 0);        // WM_MOUSEMOVE
    System.Threading.Thread.Sleep(30);
    PostMouse(h, x, y, 0x0201, 1);        // WM_LBUTTONDOWN
    System.Threading.Thread.Sleep(60);
    PostMouse(h, x, y, 0x0202, 0);        // WM_LBUTTONUP
  }

  public static void DragClient(IntPtr h, int x1, int y1, int x2, int y2, int steps) {
    PostMouse(h, x1, y1, 0x0200, 0);
    System.Threading.Thread.Sleep(20);
    PostMouse(h, x1, y1, 0x0201, 1);
    for (int i = 1; i <= steps; i++) {
      int x = x1 + (x2 - x1) * i / steps;
      int y = y1 + (y2 - y1) * i / steps;
      PostMouse(h, x, y, 0x0200, 1);
      System.Threading.Thread.Sleep(16);
    }
    PostMouse(h, x2, y2, 0x0202, 0);
  }

  public static void MouseInput(uint flags, int dx, int dy, uint data) {
    INPUT inp = new INPUT();
    inp.type = 0;
    inp.u.mi.dx = dx; inp.u.mi.dy = dy; inp.u.mi.mouseData = data;
    inp.u.mi.dwFlags = flags; inp.u.mi.time = 0; inp.u.mi.dwExtraInfo = IntPtr.Zero;
    SendInput(1, new INPUT[] { inp }, Marshal.SizeOf(typeof(INPUT)));
  }

  public static void RealClick(int x, int y) {
    SetCursorPos(x, y);
    System.Threading.Thread.Sleep(60);
    MouseInput(MOUSEEVENTF_LEFTDOWN, 0, 0, 0);
    System.Threading.Thread.Sleep(60);
    MouseInput(MOUSEEVENTF_LEFTUP, 0, 0, 0);
  }

  public static void RealWheel(int x, int y, int delta) {
    SetCursorPos(x, y);
    System.Threading.Thread.Sleep(40);
    MouseInput(MOUSEEVENTF_WHEEL, 0, 0, (uint)delta);
  }
  public static void RealDrag(int x1, int y1, int x2, int y2, int durationMs) {
    SetCursorPos(x1, y1);
    System.Threading.Thread.Sleep(80);
    MouseInput(MOUSEEVENTF_LEFTDOWN, 0, 0, 0);
    int steps = 20;
    for (int i = 1; i <= steps; i++) {
      int x = x1 + (x2 - x1) * i / steps;
      int y = y1 + (y2 - y1) * i / steps;
      SetCursorPos(x, y);
      System.Threading.Thread.Sleep(Math.Max(5, durationMs / steps));
    }
    MouseInput(MOUSEEVENTF_LEFTUP, 0, 0, 0);
  }

  public static void WheelClient(IntPtr h, int x, int y, int delta) {
    POINT pt = new POINT(); pt.X = x; pt.Y = y;
    ClientToScreen(h, ref pt);
    IntPtr lp = (IntPtr)((pt.Y << 16) | (pt.X & 0xFFFF));
    IntPtr wp = (IntPtr)((delta << 16) & 0xFFFFFFFF);
    PostMessage(h, 0x020A, wp, lp);
  }

  public static bool Shot(IntPtr h, string path) {
    RECT r; GetWindowRect(h, out r);
    int w = r.Right - r.Left, hh = r.Bottom - r.Top;
    if (w <= 0 || hh <= 0) return false;
    IntPtr screenDc = GetDC(IntPtr.Zero);
    IntPtr memDc = CreateCompatibleDC(screenDc);
    IntPtr bmp = CreateCompatibleBitmap(screenDc, w, hh);
    IntPtr old = SelectObject(memDc, bmp);
    bool ok = PrintWindow(h, memDc, 2);
    SelectObject(memDc, old);
    try {
      using (System.Drawing.Bitmap bitmap = System.Drawing.Image.FromHbitmap(bmp)) {
        bitmap.Save(path, System.Drawing.Imaging.ImageFormat.Png);
      }
    } finally {
      DeleteObject(bmp);
      DeleteDC(memDc);
      ReleaseDC(IntPtr.Zero, screenDc);
    }
    return ok;
  }

  public static void MoveWindowTo(IntPtr h, int x, int y, int w, int hh) {
    MoveWindow(h, x, y, w, hh, true);
  }

  public static void TypeText(string text) {
    foreach (char ch in text) {
      INPUT down = new INPUT();
      down.type = 1;
      down.u.ki.wVk = 0; down.u.ki.wScan = (ushort)ch; down.u.ki.dwFlags = KEYEVENTF_UNICODE;
      down.u.ki.time = 0; down.u.ki.dwExtraInfo = IntPtr.Zero;
      INPUT up = down;
      up.u.ki.dwFlags = KEYEVENTF_UNICODE | KEYEVENTF_KEYUP;
      SendInput(1, new INPUT[] { down }, Marshal.SizeOf(typeof(INPUT)));
      System.Threading.Thread.Sleep(8);
      SendInput(1, new INPUT[] { up }, Marshal.SizeOf(typeof(INPUT)));
      System.Threading.Thread.Sleep(8);
    }
  }

  public static void TypeVk(ushort vk, bool ctrl, bool shift) {
    INPUT[] arr = new INPUT[ctrl ? 6 : 2];
    int i = 0;
    if (ctrl) { arr[i].type = 1; arr[i].u.ki.wVk = 0x11; i++; }
    if (shift) { arr[i].type = 1; arr[i].u.ki.wVk = 0x10; i++; }
    arr[i].type = 1; arr[i].u.ki.wVk = vk; i++;
    arr[i] = arr[i - 1]; arr[i].u.ki.dwFlags = KEYEVENTF_KEYUP; i++;
    if (shift) { arr[i].type = 1; arr[i].u.ki.wVk = 0x10; arr[i].u.ki.dwFlags = KEYEVENTF_KEYUP; i++; }
    if (ctrl) { arr[i].type = 1; arr[i].u.ki.wVk = 0x11; arr[i].u.ki.dwFlags = KEYEVENTF_KEYUP; i++; }
    SendInput((uint)arr.Length, arr, Marshal.SizeOf(typeof(INPUT)));
  }
}
"@ -ReferencedAssemblies System.Drawing

if (-not ('System.Drawing.Bitmap' -as [type])) {
  Add-Type -AssemblyName System.Drawing
}

# Raise DPI awareness so GetWindowRect/PrintWindow return real physical pixels.
try {
  [T4Win]::SetProcessDpiAwarenessContext([IntPtr](-4)) | Out-Null
} catch {
  try { [T4Win]::SetProcessDPIAware() | Out-Null } catch {}
}

function Get-Window {
  if ($ProcessId -le 0) { throw 'ProcessId required' }
  $hwnd = [T4Win]::FindWindow([uint32]$ProcessId, $TitleContains)
  if ($hwnd -eq [IntPtr]::Zero) { throw "window not found for pid=$ProcessId" }
  return $hwnd
}

switch ($Action.ToLower()) {
  'probe' {
    $h = Get-Window
    [T4Win]::Probe($h, $ProcessId)
  }
  'shot' {
    $h = Get-Window
    if (-not $Out) { throw 'Out required' }
    $ok = [T4Win]::Shot($h, $Out)
    $json = [T4Win]::Probe($h, $ProcessId)
    '{"printWindowOk":' + $ok.ToString().ToLower() + ',"out":' + [T4Win]::Quote($Out) + ',"probe":' + $json + '}'
  }
  'click' {
    $h = Get-Window
    [T4Win]::ClickClient($h, $X, $Y)
    Start-Sleep -Milliseconds 250
    [T4Win]::Probe($h, $ProcessId)
  }
  'drag-client' {
    $h = Get-Window
    [T4Win]::DragClient($h, $X, $Y, $X2, $Y2, 20)
    Start-Sleep -Milliseconds 300
    [T4Win]::Probe($h, $ProcessId)
  }
  'click-screen' {
    [T4Win]::RealClick($X, $Y)
    Start-Sleep -Milliseconds 300
    $h = Get-Window
    [T4Win]::Probe($h, $ProcessId)
  }
  'drag-screen' {
    $h = Get-Window
    [T4Win]::RealDrag($X, $Y, $X2, $Y2, $DurationMs)
    Start-Sleep -Milliseconds 300
    [T4Win]::Probe($h, $ProcessId)
  }
  'wheel-screen' {
    [T4Win]::RealWheel($X, $Y, $HotkeyId)
    Start-Sleep -Milliseconds 300
    $h = Get-Window
    [T4Win]::Probe($h, $ProcessId)
  }
  'wheel' {
    $h = Get-Window
    [T4Win]::WheelClient($h, $X, $Y, $HotkeyId)
    Start-Sleep -Milliseconds 200
    [T4Win]::Probe($h, $ProcessId)
  }
  'hotkey' {
    $h = Get-Window
    [T4Win]::PostMessage($h, 0x0312, [IntPtr]$HotkeyId, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 900
    [T4Win]::Probe($h, $ProcessId)
  }
  'move' {
    $h = Get-Window
    [T4Win]::MoveWindowTo($h, $X, $Y, $Width, $Height)
    Start-Sleep -Milliseconds 300
    [T4Win]::Probe($h, $ProcessId)
  }
  'maximize' {
    $h = Get-Window
    [T4Win]::ShowWindow($h, 3) | Out-Null
    Start-Sleep -Milliseconds 600
    [T4Win]::Probe($h, $ProcessId)
  }
  'restore' {
    $h = Get-Window
    [T4Win]::ShowWindow($h, 9) | Out-Null
    Start-Sleep -Milliseconds 600
    [T4Win]::Probe($h, $ProcessId)
  }
  'foreground' {
    $h = Get-Window
    [T4Win]::SetForegroundWindow($h) | Out-Null
    Start-Sleep -Milliseconds 300
    [T4Win]::Probe($h, $ProcessId)
  }
  'type' {
    [T4Win]::TypeText($Text)
    Start-Sleep -Milliseconds 300
    $h = Get-Window
    [T4Win]::Probe($h, $ProcessId)
  }
  'key' {
    # key: ctrl+shift flags + virtual-key in HotkeyId
    [T4Win]::TypeVk([ushort]$HotkeyId, $false, $false)
    Start-Sleep -Milliseconds 300
  }
  'cursor' {
    $p = New-Object T4Win+POINT
    [T4Win]::GetCursorPos([ref]$p) | Out-Null
    '{"cursorX":' + $p.X + ',"cursorY":' + $p.Y + '}'
  }
  'cursor-set' {
    [T4Win]::SetCursorPos($X, $Y) | Out-Null
    '{"cursorSet":true}'
  }
  'close' {
    $h = Get-Window
    [T4Win]::PostMessage($h, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
    '{"closePosted":true}'
  }
  default { throw "unknown action: $Action" }
}