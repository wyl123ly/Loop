import 'dart:async';

import 'package:flutter/material.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

import 'dwm.dart';
import 'window_resize_edge.dart';


class WindowController with WindowListener {
  WindowController._();

  static final WindowController instance = WindowController._();

  final ValueNotifier<bool> maximized = ValueNotifier<bool>(false);
  final ValueNotifier<bool> readyNotifier = ValueNotifier<bool>(false);

  bool get ready => readyNotifier.value;
  bool trayActive = false;

  Future<void> init() async {
    try {
      await windowManager.ensureInitialized();
      await windowManager.setAsFrameless();
      await windowManager.setResizable(true);
      await windowManager.setBackgroundColor(Colors.transparent);
      await windowManager.setMinimumSize(const Size(900, 600));
      var initialSize = const Size(1440, 900);
      var initialPosition = const Offset(24, 24);
      try {
        final display = await screenRetriever.getPrimaryDisplay();
        final screen = display.size;
        final width = (screen.width - 80).clamp(900.0, 1440.0);
        final height = (screen.height - 80).clamp(600.0, 900.0);
        initialSize = Size(width, height);
        initialPosition = Offset(
          ((screen.width - width) / 2).clamp(0.0, double.infinity),
          ((screen.height - height) / 2).clamp(0.0, double.infinity),
        );
      } catch (_) {}
      await windowManager.setSize(initialSize);
      await windowManager.setPosition(initialPosition);
      await windowManager.show();
      await windowManager.focus();
      windowManager.addListener(this);
      maximized.value = await windowManager.isMaximized();
      final (rounded, hwnd) = applyDwmRoundedCorners();
      debugPrint('dwm round corners: $rounded hwnd=$hwnd');
      readyNotifier.value = true;
    } catch (error) {
      debugPrint('window init failed: $error');
      readyNotifier.value = false;
    }
  }

  Future<void> enableTray() async {
    trayActive = true;
    await windowManager.setPreventClose(true);
  }

  Future<void> show() async {
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> quit() async {
    trayActive = false;
    await windowManager.setPreventClose(false);
    await windowManager.close();
  }

  @override
  void onWindowClose() {
    if (trayActive) unawaited(windowManager.hide());
  }

  @override
  void onWindowMaximize() => maximized.value = true;

  @override
  void onWindowUnmaximize() => maximized.value = false;

  Future<void> startResizing(LoopResizeEdge edge) async {
    if (!ready) return;
    final map = {
      LoopResizeEdge.top: ResizeEdge.top,
      LoopResizeEdge.topLeft: ResizeEdge.topLeft,
      LoopResizeEdge.topRight: ResizeEdge.topRight,
      LoopResizeEdge.left: ResizeEdge.left,
      LoopResizeEdge.right: ResizeEdge.right,
      LoopResizeEdge.bottom: ResizeEdge.bottom,
      LoopResizeEdge.bottomLeft: ResizeEdge.bottomLeft,
      LoopResizeEdge.bottomRight: ResizeEdge.bottomRight,
    };
    await windowManager.startResizing(map[edge]!);
  }

  Future<void> startDragging() async {
    if (!ready) return;
    await windowManager.startDragging();
  }

  Future<void> minimize() async {
    if (!ready) return;
    await windowManager.minimize();
  }

  Future<void> toggleMaximize() async {
    if (!ready) return;
    if (await windowManager.isMaximized()) {
      await windowManager.unmaximize();
    } else {
      await windowManager.maximize();
    }
  }

  Future<void> close() async {
    if (!ready) return;
    await windowManager.close();
  }
}
