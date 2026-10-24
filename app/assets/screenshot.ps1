param(
  [Parameter(Mandatory = $true)][string]$Out,
  [int]$X = 0,
  [int]$Y = 0,
  [int]$W = 0,
  [int]$H = 0
)

# v2 contract (spec 7.3):
# - Explicit physical rectangle -X/-Y/-W/-H; fall back to the primary screen
#   when missing/invalid (keeps the old single-argument call working).
# - Prefer Per-Monitor-V2 DPI awareness, then system-aware, then continue.
# - Exit codes: 0 success / 2 invalid arguments / 3 capture failed / 4 save failed.
# NOTE: keep this file ASCII-only. Windows PowerShell 5.1 reads scripts without
# a BOM as ANSI, so non-ASCII comments can break parsing.
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class LoopDpi {
  [DllImport("user32.dll")]
  public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
  [DllImport("user32.dll")]
  public static extern bool SetProcessDPIAware();
}
"@

try {
  # DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 = -4
  [LoopDpi]::SetProcessDpiAwarenessContext([IntPtr](-4)) | Out-Null
} catch {
  try {
    [LoopDpi]::SetProcessDPIAware() | Out-Null
  } catch {
    # Continue: capture still works, coordinates may be DPI-scaled.
  }
}

if ($W -le 0 -or $H -le 0) {
  try {
    $screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $X = $screen.X
    $Y = $screen.Y
    $W = $screen.Width
    $H = $screen.Height
  } catch {
    [Console]::Error.WriteLine("bounds unavailable: $($_.Exception.Message)")
    exit 2
  }
}

if ($W -le 0 -or $H -le 0) {
  [Console]::Error.WriteLine("invalid bounds: X=$X Y=$Y W=$W H=$H")
  exit 2
}

$bitmap = $null
$graphics = $null
try {
  $bitmap = New-Object System.Drawing.Bitmap $W, $H
  $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
  $source = New-Object System.Drawing.Point $X, $Y
  $target = [System.Drawing.Point]::Empty
  $size = New-Object System.Drawing.Size $W, $H
  $graphics.CopyFromScreen($source, $target, $size)
} catch {
  [Console]::Error.WriteLine("capture failed: $($_.Exception.Message)")
  if ($graphics) { $graphics.Dispose() }
  if ($bitmap) { $bitmap.Dispose() }
  exit 3
}

try {
  $dir = [System.IO.Path]::GetDirectoryName($Out)
  if ($dir -and -not (Test-Path $dir)) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
  }
  $bitmap.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
} catch {
  [Console]::Error.WriteLine("save failed: $($_.Exception.Message)")
  if ($graphics) { $graphics.Dispose() }
  if ($bitmap) { $bitmap.Dispose() }
  exit 4
} finally {
  if ($graphics) { $graphics.Dispose() }
  if ($bitmap) { $bitmap.Dispose() }
}
