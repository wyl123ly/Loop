import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:loop/desktop/screenshot_service.dart';
import 'package:loop/desktop/screenshot_types.dart';
import 'package:loop/desktop/window_mode.dart';

/// 假截图服务：记录 start/restore 次数与 hideLoop 参数，可注入失败/取消。
class FakeScreenshotService implements ScreenshotService {
  FakeScreenshotService({required this.bytes});

  Uint8List bytes;

  /// 返回 null 模拟“非 Windows/不支持”。
  bool unsupported = false;

  /// 抛错模拟截图失败。
  Object? startError;

  /// 自定义每次 start 的返回值（优先级最高）。
  Future<ScreenshotSession?>? Function()? startOverride;

  int startCalls = 0;
  int restoreCalls = 0;
  final List<bool> hideLoopRequests = [];
  final List<ScreenshotSession> started = [];
  final List<ScreenshotSession> restored = [];

  @override
  Future<ScreenshotSession?> start({required bool hideLoop}) async {
    startCalls++;
    hideLoopRequests.add(hideLoop);
    final override = startOverride;
    if (override != null) return override();
    if (unsupported) return null;
    final error = startError;
    if (error != null) throw error;
    final session = ScreenshotSession(
      bytes: bytes,
      snapshot: const WindowSnapshot(
        mode: LoopWindowMode.floating,
        bounds: Rect.fromLTWH(1436, 220, 460, 600),
        physicalBounds: Rect.fromLTWH(1436, 220, 460, 600),
        dpr: 1.0,
        maximized: false,
        alwaysOnTop: true,
        minSize: floatingMinSize,
        pinned: true,
      ),
      display: const CaptureDisplay(
        id: 'test-display',
        physicalWorkArea: Rect.fromLTWH(0, 0, 1920, 1040),
      ),
      hidden: hideLoop,
      startedAt: DateTime.now(),
    );
    started.add(session);
    return session;
  }

  @override
  Future<void> restore(ScreenshotSession session) async {
    restoreCalls++;
    restored.add(session);
  }
}

/// 生成与视口同宽高比的 PNG（截图覆盖层校验宽高比，1% 容差）。
Future<Uint8List> makeTestPng(
  WidgetTester tester,
  int width,
  int height,
) async {
  late Uint8List bytes;
  await tester.runAsync(() async {
    final recorder = PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(
      Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      Paint()..color = const Color(0xFF3355AA),
    );
    final picture = recorder.endRecording();
    final image = await picture.toImage(width, height);
    final data = await image.toByteData(format: ImageByteFormat.png);
    bytes = data!.buffer.asUint8List();
    image.dispose();
  });
  return bytes;
}
