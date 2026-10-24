import 'dart:typed_data';

import 'window_mode.dart';

/// 截图完成后恢复窗口所需的完整状态（v2）。规格 §7.4。
///
/// 与 v0.4.0 的 `{bytes, bounds, maximized}` 相比，内嵌完整 [WindowSnapshot]，
/// 因此恢复时能还原 `mode / minSize / alwaysOnTop / physicalBounds`，不会把浮窗
/// 错误恢复成普通窗口，也不会丢置顶。
class ScreenshotSession {
  const ScreenshotSession({
    required this.bytes,
    required this.snapshot,
    required this.display,
    required this.hidden,
    required this.startedAt,
  });

  final Uint8List bytes;

  /// 截图前完整窗口状态（含 mode / minSize / alwaysOnTop）。
  final WindowSnapshot snapshot;

  /// 捕获显示器（物理工作区/scale），用于参数与覆盖层对齐。
  final CaptureDisplay display;

  /// 是否“隐藏 Loop 后截图”。
  final bool hidden;

  final DateTime startedAt;

  @override
  String toString() =>
      'ScreenshotSession(bytes=${bytes.length}, hidden=$hidden, '
      'display=${display.id}, snapshot=$snapshot)';
}
