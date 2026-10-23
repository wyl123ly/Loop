import 'dart:async';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'dwm.dart';


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
      await windowManager.setBackgroundColor(Colors.transparent);
      // 先不启用透明背景，避免 Windows 合成缩放问题
      await windowManager.setSize(const Size(1440, 900));
      await windowManager.setMinimumSize(const Size(1120, 720));
      await windowManager.setPosition(const Offset(24, 24));
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
