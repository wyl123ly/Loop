import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:window_manager/window_manager.dart';

import 'screenshot_types.dart';

class ScreenshotCapture {
  static Future<ScreenshotSession?> start({required bool hideLoop}) async {
    final bounds = await windowManager.getBounds();
    final maximized = await windowManager.isMaximized();
    final fullScreen = await windowManager.isFullScreen();
    try {
      if (hideLoop) {
        await windowManager.hide();
        await Future<void>.delayed(const Duration(milliseconds: 280));
      }
      final bytes = await _capture();
      await windowManager.setAlwaysOnTop(true);
      if (!fullScreen) await windowManager.setFullScreen(true);
      await windowManager.show();
      await windowManager.focus();
      return ScreenshotSession(
        bytes: bytes,
        bounds: bounds,
        maximized: maximized,
        fullScreen: fullScreen,
      );
    } catch (_) {
      await _restoreRaw(bounds, maximized, fullScreen);
      rethrow;
    }
  }

  static Future<void> restore(ScreenshotSession session) async {
    await _restoreRaw(session.bounds, session.maximized, session.fullScreen);
  }

  static Future<void> _restoreRaw(Rect bounds, bool maximized, bool fullScreen) async {
    try {
      await windowManager.setAlwaysOnTop(false);
      if (await windowManager.isFullScreen()) {
        await windowManager.setFullScreen(false);
      }
      if (fullScreen) {
        await windowManager.setFullScreen(true);
      } else if (maximized) {
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
