import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'window_mode.dart';

/// 截图计划：目标显示器 + PowerShell 参数。纯函数，可单测（规格 §7.2）。
class ScreenshotPlan {
  const ScreenshotPlan({
    required this.display,
    required this.physicalRect,
    required this.arguments,
  });

  final CaptureDisplay display;

  /// 传给脚本的物理矩形（工作区，四舍五入为 int）。
  final Rect physicalRect;

  /// `['-X','..','-Y','..','-W','..','-H','..']`
  final List<String> arguments;

  bool get isEmpty => physicalRect.width < 1 || physicalRect.height < 1;

  /// 期望的 PNG 像素尺寸。
  int get pixelWidth => physicalRect.width.round();

  int get pixelHeight => physicalRect.height.round();
}

/// 根据窗口物理矩形选择捕获显示器并生成计划。
///
/// [displays] 为空时返回 null；调用方回退主屏。
ScreenshotPlan? planCapture({
  required List<DisplayInfo> displays,
  required Rect windowPhysicalRect,
}) {
  final target = FloatingWindowPlanner.chooseDisplay(displays, windowPhysicalRect);
  if (target == null) return null;
  return planCaptureForDisplay(target);
}

/// 直接为指定显示器生成计划（主屏回退也走这里）。
ScreenshotPlan planCaptureForDisplay(DisplayInfo display) {
  final work = display.physicalWorkArea;
  final rect = Rect.fromLTWH(
    work.left.roundToDouble(),
    work.top.roundToDouble(),
    math.max(1.0, work.width.roundToDouble()),
    math.max(1.0, work.height.roundToDouble()),
  );
  return ScreenshotPlan(
    display: CaptureDisplay(
      id: display.id,
      physicalWorkArea: rect,
      scaleFactor: display.scaleFactor,
      isPrimary: display.isPrimary,
    ),
    physicalRect: rect,
    arguments: [
      '-X', '${rect.left.round()}',
      '-Y', '${rect.top.round()}',
      '-W', '${rect.width.round()}',
      '-H', '${rect.height.round()}',
    ],
  );
}

/// 解析 PNG 宽高（仅读 IHDR，不依赖图像编解码器）。
///
/// 返回 null 表示不是合法 PNG。
({int width, int height})? pngDimensions(Uint8List bytes) {
  if (bytes.length < 24) return null;
  const signature = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
  for (var i = 0; i < signature.length; i++) {
    if (bytes[i] != signature[i]) return null;
  }
  int readInt(int offset) =>
      (bytes[offset] << 24) |
      (bytes[offset + 1] << 16) |
      (bytes[offset + 2] << 8) |
      bytes[offset + 3];
  return (width: readInt(16), height: readInt(20));
}

/// 校验脚本输出尺寸与请求的物理矩形一致（规格 §7.2：不一致判失败）。
///
/// [tolerance] 允许 DPI 取整误差（默认 2px）。
bool pngMatchesPlan(Uint8List bytes, ScreenshotPlan plan, {int tolerance = 2}) {
  final size = pngDimensions(bytes);
  if (size == null) return false;
  return (size.width - plan.pixelWidth).abs() <= tolerance &&
      (size.height - plan.pixelHeight).abs() <= tolerance;
}
