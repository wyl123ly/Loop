import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

import 'floating_window.dart';
import 'screenshot_plan.dart';
import 'screenshot_types.dart';
import 'win32_display.dart';
import 'window_controls_io.dart';
import 'window_mode.dart';

/// 截图捕获（Windows 桌面版）。
///
/// 与 v0.4.0 的差异（规格 §7）：
/// - 按**窗口中心所在显示器**捕获，把该显示器工作区物理矩形传给脚本；
/// - 保存/恢复完整 [WindowSnapshot]（mode/minSize/alwaysOnTop/physicalBounds），
///   截图结束仍回到浮窗，而不是普通窗口；
/// - 覆盖窗口用物理 `SetWindowPos`（失败回退逻辑 bounds），禁止全屏 API；
/// - `hideLoop` 由调用方决定（浮窗默认 true / 主窗口菜单）。
class ScreenshotCapture {
  const ScreenshotCapture._();

  static const Duration _timeout = Duration(seconds: 20);

  static Future<ScreenshotSession?> start({required bool hideLoop}) async {
    final controller = WindowController.instance.floating;
    final answers = WindowController.instance.answers;
    if (!controller.supported) return null;

    final snapshot = await controller.snapshot();
    final plan = await _resolvePlan(controller, snapshot);
    if (plan == null) {
      throw Exception('截图失败：未找到可用显示器');
    }

    final answersWereVisible = answers.visible && !answers.hiddenByOwner;
    try {
      // 回答窗恒置顶，截图/覆盖层期间必须隐藏（规格 §3.7）；结束恢复。
      if (answersWereVisible) await answers.hide();
      if (hideLoop) {
        await windowManager.hide();
        await Future<void>.delayed(captureHideDelay);
      }
      final bytes = await _capture(plan);
      if (!pngMatchesPlan(bytes, plan)) {
        final size = pngDimensions(bytes);
        throw Exception(
          '截图尺寸与显示器不一致：'
          '${size?.width ?? '?'}×${size?.height ?? '?'} '
          '!= ${plan.pixelWidth}×${plan.pixelHeight}',
        );
      }
      // 覆盖窗口：物理矩形与截图矩形严格一致；置顶 + show + focus 恰一次。
      await controller.beginCaptureOverlay(plan.display);
      return ScreenshotSession(
        bytes: bytes,
        snapshot: snapshot,
        display: plan.display,
        hidden: hideLoop,
        startedAt: DateTime.now(),
        answersWereVisible: answersWereVisible,
      );
    } catch (error) {
      await _restoreQuietly(controller, snapshot, focus: hideLoop);
      if (answersWereVisible) await answers.restoreVisibility();
      rethrow;
    }
  }

  /// 恢复截图前的完整窗口状态（含浮窗形态/置顶/最小尺寸/极简标记）。
  ///
  /// 幂等：重复调用不累积副作用（[FloatingWindowController.applySnapshot]）。
  static Future<void> restore(ScreenshotSession session) async {
    final controller = WindowController.instance.floating;
    final answers = WindowController.instance.answers;
    await controller.applySnapshot(session.snapshot, focus: session.hidden);
    if (session.answersWereVisible) await answers.restoreVisibility();
    controller.scheduleEnsureGeometry();
  }

  static Future<void> _restoreQuietly(
    FloatingWindowController controller,
    WindowSnapshot snapshot, {
    required bool focus,
  }) async {
    try {
      await controller.applySnapshot(snapshot, focus: focus);
    } catch (error) {
      debugPrint('screenshot restore failed: $error');
    }
  }

  /// 解析捕获计划：优先平台（按窗口中心显示器），再 Win32 直读，最后主屏回退。
  static Future<ScreenshotPlan?> _resolvePlan(
    FloatingWindowController controller,
    WindowSnapshot snapshot,
  ) async {
    try {
      final display = await controller.captureDisplay();
      if (display != null) {
        return planCaptureForDisplay(
          DisplayInfo(
            id: display.id,
            physicalBounds: display.physicalWorkArea,
            physicalWorkArea: display.physicalWorkArea,
            scaleFactor: display.scaleFactor,
            isPrimary: display.isPrimary,
          ),
        );
      }
    } catch (error) {
      debugPrint('captureDisplay failed: $error');
    }

    final displays = Win32Display.displays();
    if (displays.isNotEmpty) {
      return planCapture(
            displays: displays,
            windowPhysicalRect: snapshot.physicalBounds,
          ) ??
          planCaptureForDisplay(displays.first);
    }

    // 主屏回退：screen_retriever 的 visible* 是逻辑像素，换算回物理像素。
    try {
      final primary = await screenRetriever.getPrimaryDisplay();
      final scale = FloatingWindowPlanner.normalizedDpr(
        primary.scaleFactor?.toDouble(),
      );
      final position = primary.visiblePosition ?? Offset.zero;
      final size = primary.visibleSize ?? primary.size;
      // screen_retriever 的 visible* 已是逻辑像素，乘回 scaleFactor 得物理像素。
      final physicalWork = Rect.fromLTWH(
        position.dx * scale,
        position.dy * scale,
        size.width * scale,
        size.height * scale,
      );
      return planCaptureForDisplay(
        DisplayInfo(
          id: primary.id,
          physicalBounds: physicalWork,
          physicalWorkArea: physicalWork,
          scaleFactor: scale,
          isPrimary: true,
        ),
      );
    } catch (error) {
      debugPrint('primary display fallback failed: $error');
      return null;
    }
  }

  static Future<Uint8List> _capture(ScreenshotPlan plan) async {
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
          '-NonInteractive',
          '-ExecutionPolicy', 'Bypass',
          '-WindowStyle', 'Hidden',
          '-File', scriptFile.path,
          '-Out', imageFile.path,
          ...plan.arguments,
        ],
      ).timeout(_timeout);
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
