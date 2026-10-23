import 'package:flutter/foundation.dart';

import 'window_resize_edge.dart';

/// Web 端占位，保证同一套界面代码可以编译。
class WindowController {
  WindowController._();

  static final WindowController instance = WindowController._();

  final ValueNotifier<bool> maximized = ValueNotifier<bool>(false);
  final ValueNotifier<bool> readyNotifier = ValueNotifier<bool>(false);

  bool get ready => readyNotifier.value;

  Future<void> init() async {}
  Future<void> startDragging() async {}
  Future<void> startResizing(LoopResizeEdge edge) async {}
  Future<void> minimize() async {}
  Future<void> toggleMaximize() async {}
  Future<void> close() async {}
  Future<void> enableTray() async {}
  Future<void> show() async {}
  Future<void> quit() async {}
}
