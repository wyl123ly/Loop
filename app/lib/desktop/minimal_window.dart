import 'dart:math' as math;
import 'dart:ui';

import 'window_mode.dart';

/// 极简条几何规划（纯 Dart，可单测）。规格 §3.2/§3.4/§3.6。
///
/// 极简条是主窗口 `floating` 的子状态，不新建窗口：
/// - 高度恒为 [minimalHeight]（逻辑像素）；
/// - 宽度 = 进入前浮窗宽度，钳制 [minimalMinWidth]–[minimalMaxWidth]；
/// - 进入时保持右下角锚定（右上角/右下角不跳），越界再钳回工作区。
class MinimalWindowPlanner {
  const MinimalWindowPlanner._();

  /// 极简条逻辑尺寸。
  static Size barSizeLogical(double expandedWidthLogical) => Size(
        expandedWidthLogical
            .clamp(minimalMinWidth, minimalMaxWidth)
            .toDouble(),
        minimalHeight,
      );

  /// 计算进入极简时的物理矩形（保持右下角锚定，钳回工作区）。
  static Rect barPhysical({
    required Rect workPhysical,
    required Rect expandedPhysical,
    required double dpr,
  }) {
    final scale = FloatingWindowPlanner.normalizedDpr(dpr);
    final work = _valid(workPhysical)
        ? workPhysical
        : Rect.fromLTWH(0, 0, math.max(1.0, expandedPhysical.width), minimalHeight * scale);
    final width = math.min(
      work.width,
      barSizeLogical(expandedPhysical.width / scale).width * scale,
    );
    final height = math.min(work.height, minimalHeight * scale);
    final left = _clamp(
      expandedPhysical.right - width,
      work.left,
      work.right - width,
    );
    final top = _clamp(
      expandedPhysical.bottom - height,
      work.top,
      work.bottom - height,
    );
    return Rect.fromLTWH(left, top, width, height);
  }

  /// 显示器移除/DPI 变化后把极简条钳回工作区（宽度 360–560、高 52）。
  static Rect clampBar({
    required Rect physical,
    required Rect workPhysical,
    required double dpr,
  }) {
    final scale = FloatingWindowPlanner.normalizedDpr(dpr);
    final work = _valid(workPhysical) ? workPhysical : physical;
    final width = math.min(
      work.width,
      physical.width
          .clamp(minimalMinWidth * scale, minimalMaxWidth * scale)
          .toDouble(),
    );
    final height = math.min(work.height, minimalHeight * scale);
    final left = _clamp(physical.left, work.left, work.right - width);
    final top = _clamp(physical.top, work.top, work.bottom - height);
    return Rect.fromLTWH(left, top, width, height);
  }

  /// 逻辑 bounds 是否已到达浮窗最小尺寸（用于“拖到最小→极简”）。
  static bool isAtFloatingMinimum(
    Rect logicalBounds, {
    double tolerance = minimalEnterTolerance,
  }) {
    return (logicalBounds.width - floatingMinSize.width).abs() <= tolerance &&
        (logicalBounds.height - floatingMinSize.height).abs() <= tolerance;
  }

  static bool _valid(Rect rect) =>
      rect.width.isFinite && rect.height.isFinite && rect.width >= 1 && rect.height >= 1;

  static double _clamp(double value, double min, double max) {
    if (max < min) return min;
    return value.clamp(min, max).toDouble();
  }
}
