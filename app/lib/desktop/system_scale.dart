import 'dart:ffi';

/// Windows 系统 DPI 缩放（1.0 = 100%）。窗口尺寸需要按物理像素传。
double systemScaleFactor() {
  try {
    final user32 = DynamicLibrary.open('user32.dll');
    final getDpi = user32.lookupFunction<Uint32 Function(), int Function()>('GetDpiForSystem');
    final dpi = getDpi();
    if (dpi > 0) return dpi / 96.0;
  } catch (_) {}
  return 1.0;
}
