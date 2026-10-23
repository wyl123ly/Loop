import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

import 'screenshot_types.dart';

class ScreenshotCapture {
  static Future<ScreenshotSession?> start({required bool hideLoop}) async {
    final bounds = await windowManager.getBounds();
    final maximized = await windowManager.isMaximized();
    try {
      if (hideLoop) {
        await windowManager.hide();
        await Future<void>.delayed(const Duration(milliseconds: 280));
      }
      final bytes = await _capture();
      // 不能用 setFullScreen：无边框窗口下它是空操作，退出时还会把窗口样式
      // 恢复成 Windows 原生标题栏。这里只改 bounds，保持 frameless 自绘标题栏。
      final display = await screenRetriever.getPrimaryDisplay();
      if (maximized) await windowManager.unmaximize();
      await windowManager.setAlwaysOnTop(true);
      await windowManager.setBounds(
        Rect.fromLTWH(0, 0, display.size.width, display.size.height),
      );
      await windowManager.show();
      await windowManager.focus();
      return ScreenshotSession(bytes: bytes, bounds: bounds, maximized: maximized);
    } catch (_) {
      await _restoreRaw(bounds, maximized);
      rethrow;
    }
  }

  static Future<void> restore(ScreenshotSession session) async {
    await _restoreRaw(session.bounds, session.maximized);
  }

  static Future<void> _restoreRaw(Rect bounds, bool maximized) async {
    try {
      await windowManager.setAlwaysOnTop(false);
      if (maximized) {
        await windowManager.maximize();
      } else {
        await windowManager.setBounds(bounds);
      }
      await windowManager.show();
      await windowManager.focus();
    } catch (_) {}
  }

  static Future<Uint8List> _capture() async {
    final script = await rootBundle.loadString('assets/screenshot.ps1');
    final dir = Directory.systemTemp.createTempSync('loop_shot_');
    final scriptFile = File(p.join(dir.path, 'capture.ps1'));
    final imageFile = File(p.join(dir.path, 'shot.png'));
    try {
      scriptFile.writeAsStringSync(script);
      final result = await Process.run(
        'powershell.exe',
        [
          '-NoProfile',
          '-ExecutionPolicy', 'Bypass',
          '-WindowStyle', 'Hidden',
          '-File', scriptFile.path,
          '-Out', imageFile.path,
        ],
      ).timeout(const Duration(seconds: 15));
      if (result.exitCode != 0 || !imageFile.existsSync()) {
        throw Exception('截图失败：${(result.stderr as String).trim()}');
      }
      final bytes = await imageFile.readAsBytes();
      if (bytes.isEmpty) throw Exception('截图结果为空');
      return bytes;
    } finally {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    }
  }
}
