import 'screenshot_capture.dart';
import 'screenshot_types.dart';

/// 截图服务抽象：ChatScreen 依赖该接口，测试可注入 fake（规格 §5.3）。
abstract class ScreenshotService {
  Future<ScreenshotSession?> start({required bool hideLoop});

  Future<void> restore(ScreenshotSession session);
}

/// 平台实现：调用现有 [ScreenshotCapture]（Windows 桌面版）。
class PlatformScreenshotService implements ScreenshotService {
  const PlatformScreenshotService();

  @override
  Future<ScreenshotSession?> start({required bool hideLoop}) =>
      ScreenshotCapture.start(hideLoop: hideLoop);

  @override
  Future<void> restore(ScreenshotSession session) =>
      ScreenshotCapture.restore(session);
}
