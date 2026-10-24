# desktop_multi_window 0.3.1 — Loop v0.6.0 R1-B patch

Vendored fork of `desktop_multi_window 0.3.1` (pub.dev), used only by the
official Loop Windows app. The Dart API is unchanged; only the Windows native
window activation semantics are patched (spec §2.4 R1-B / §2.8, t4 F-01).

## Why

`WS_EX_NOACTIVATE` + `SW_SHOWNOACTIVATE` alone did not stop real mouse clicks
on the second window from activating it (t4 F-01: foreground switched to the
answer window for 1.5–3.3 s, changing the text/IME focus of the main window).

## Patch (Windows only)

`windows/win32_window.cpp`
- create the second top-level window with
  `CreateWindowEx(WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW, ..., WS_POPUP, ...)`
  so it never appears in the taskbar / Alt+Tab and never activates on creation;
- `WM_MOUSEACTIVATE` → `MA_NOACTIVATE` (click/drag/wheel never activates);
- `WM_ACTIVATE`: no longer calls `SetFocus(child_content_)` (a read-only answer
  window must never steal keyboard focus);
- `WM_DPICHANGED`: ignore the OS-suggested rect and only re-layout the Flutter
  child. The answer window's physical geometry is owned by the main engine
  (Win32 FFI) and the user drag FFI; applying the suggested rect double-scales
  the window across monitors with different DPI (t12: 1075×1120 became
  1290×1344 at 150%);
- `Win32Window::Show()` → `SW_SHOWNOACTIVATE`.

`windows/flutter_window.cc`
- `WM_MOUSEACTIVATE` → `MA_NOACTIVATE` before forwarding to Flutter.

`windows/flutter_window_wrapper.h`
- plugin `window_show` → `SW_SHOWNOACTIVATE`.

## Update procedure

When upgrading `desktop_multi_window`, re-apply the five changes above (they are
small and isolated) and re-run the t4 real-mouse focus/IME matrix plus the
cross-monitor 125%↔150% auto-follow matrix. Do **not** upgrade without
re-running the focus gate and cross-DPI geometry tests.
