import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Windows 11 原生圆角：DWMWA_WINDOW_CORNER_PREFERENCE = 33, DWMWCP_ROUND = 2。
(bool, int) applyDwmRoundedCorners() {
  if (!Platform.isWindows) return (false, 0);
  try {
    final user32 = DynamicLibrary.open('user32.dll');
    final getActive = user32.lookupFunction<IntPtr Function(), int Function()>('GetActiveWindow');
    final hwnd = getActive();
    if (hwnd == 0) return (false, 0);
    final dwmapi = DynamicLibrary.open('dwmapi.dll');
    final setAttribute = dwmapi.lookupFunction<
        Int32 Function(IntPtr, Uint32, Pointer<Int32>, Uint32),
        int Function(int, int, Pointer<Int32>, int)>('DwmSetWindowAttribute');
    final value = calloc<Int32>();
    value.value = 2; // DWMWCP_ROUND
    final hr = setAttribute(hwnd, 33, value, 4);
    calloc.free(value);
    return (hr == 0, hwnd);
  } catch (_) {
    return (false, 0);
  }
}
