import 'package:flutter/material.dart';

import 'floating_window.dart';
import 'screenshot_service.dart';
import 'window_mode.dart';
import 'window_resize_edge.dart';

/// Web/非桌面占位：保证同一套界面代码可以编译。
///
/// 浮窗 API 与 io 完全对等，但 `supported=false`，`enter/exit` 返回 false，
/// Shell 保持普通形态、按钮隐藏（规格 §9.5）。
class WindowController {
  WindowController._();

  static final WindowController instance = WindowController._();

  final ValueNotifier<bool> maximized = ValueNotifier<bool>(false);
  final ValueNotifier<bool> readyNotifier = ValueNotifier<bool>(false);
  final ValueNotifier<bool> resizing = ValueNotifier<bool>(false);

  late final FloatingWindowController floating = FloatingWindowController(
    const _StubWindowPlatform(),
    onError: (message) => floatingError.value = message,
  );

  final ValueNotifier<String?> floatingError = ValueNotifier<String?>(null);

  final ScreenshotService screenshots = const PlatformScreenshotService();

  bool get ready => readyNotifier.value;
  bool get isFloating => floating.isFloating;
  LoopWindowMode get mode => floating.mode;
  bool trayActive = false;

  Future<void> init() async {}
  Future<void> startDragging() async {}
  Future<void> startResizing(LoopResizeEdge edge) async {}
  Future<void> minimize() async {}
  Future<void> toggleMaximize() async {}
  Future<void> close() async {}
  Future<void> enableTray() async {}
  Future<void> show({bool focus = true}) async {}
  Future<void> showInactive() async {}
  Future<void> focusOnce() async {}
  Future<void> quit() async {}
  void onMetricsChanged() {}
}

class _StubWindowPlatform implements WindowPlatform {
  const _StubWindowPlatform();

  @override
  bool get supported => false;

  @override
  Future<WindowSnapshot> snapshot() async => WindowSnapshot(
        mode: LoopWindowMode.normal,
        bounds: const Rect.fromLTWH(0, 0, 900, 600),
        physicalBounds: const Rect.fromLTWH(0, 0, 900, 600),
        dpr: 1.0,
        maximized: false,
        alwaysOnTop: false,
        minSize: normalMinSize,
      );

  @override
  Future<void> setMinimumSize(Size logical) async {}

  @override
  Future<void> setAlwaysOnTop(bool value) async {}

  @override
  Future<bool> isAlwaysOnTop() async => false;

  @override
  Future<void> setBoundsPhysical(Rect physical) async {}

  @override
  Future<void> setBoundsLogical(Rect logical) async {}

  @override
  Future<bool> setWindowPlacement(
    Rect normalPlacement, {
    required bool maximized,
  }) async =>
      false;

  @override
  Future<Rect> physicalRect() async => const Rect.fromLTWH(0, 0, 900, 600);

  @override
  Future<double> dpr() async => 1.0;

  @override
  Future<bool> isMaximized() async => false;

  @override
  Future<void> maximize() async {}

  @override
  Future<void> unmaximize() async {}

  @override
  Future<void> show() async {}

  @override
  Future<void> hide() async {}

  @override
  Future<bool> isVisible() async => true;

  @override
  Future<void> focus() async {}

  @override
  Future<void> restore() async {}

  @override
  Future<void> setResizable(bool value) async {}

  @override
  Future<List<DisplayInfo>> displays() async => const <DisplayInfo>[];

  @override
  Future<String?> displayIdAt(Offset physicalPoint) async => null;
}
