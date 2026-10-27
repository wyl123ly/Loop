import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';

import '../theme.dart';

/// 窗口形态。整个应用只有这两种形态；同一 Flutter 窗口内切换。
enum LoopWindowMode { normal, floating }

// ---------------------------------------------------------------------------
// 常量（逻辑像素，除非另有说明）。规格 §4.1。
// ---------------------------------------------------------------------------

/// 普通窗口最小尺寸（与 v0.4.0 一致）。
const Size normalMinSize = Size(900, 600);

/// 首次进入浮窗的默认尺寸。
const Size floatingDefaultSize = Size(460, 600);

/// 浮窗最小尺寸（OS 最小尺寸 + 缩放热区下限）。
const Size floatingMinSize = Size(360, 420);

/// 浮窗距工作区右/上/下边距。
const double floatingMargin = 24;

/// 浮窗圆角。
const double floatingRadius = 16;

/// 普通窗口圆角。
const double normalRadius = 18;

/// 浮窗紧凑模式宽度阈值（< 该值进入紧凑模式）。
const double compactWidth = 420;

/// 浮窗紧凑模式高度阈值。
const double compactHeight = 520;

// ---------------------------------------------------------------------------
// 极简形态（floating 的子状态）常量。规格 §3.2 / §12.A。
// ---------------------------------------------------------------------------

/// 极简条总高（逻辑像素；含 1px 边框，内容填满，无上下留白）。
const double minimalHeight = 52;

/// 极简条窗口最小尺寸（动态 minSize）。
const Size minimalMinSize = Size(360, 52);

/// 极简条宽度下限（与浮窗最小宽一致）。
const double minimalMinWidth = 360;

/// 极简条宽度上限；超出则钳制。
const double minimalMaxWidth = 560;

/// 极简条圆角。
const double minimalRadius = 8;

/// 判定“拖到最小”的容差（逻辑像素）。
const double minimalEnterTolerance = 2;

/// 用户缩放结束后的去抖，避免拖动/缩放中误触发极简形态。
const Duration minimalEnterDelay = Duration(milliseconds: 250);

/// 极简条按钮热区（截图/返回）。
const double minimalButtonSize = 32;

/// 极简条输入容器高度（含内嵌发送/停止）。
const double minimalInputHeight = 38;

// ---------------------------------------------------------------------------
// 回答浮窗常量。规格 §4.2 / §4.3 / §12.A。
// ---------------------------------------------------------------------------

/// 回答窗固定宽度 = 工作区宽度 × 该比例（约 30%–40%）。
const double answerWidthRatio = 0.35;

/// 回答窗宽度钳制（逻辑像素）。
const double answerWidthMin = 420;
const double answerWidthMax = 900;

/// 回答窗最小高度（逻辑像素）。
const double answerMinHeight = 180;

/// 回答窗最大高度 = min(工作区高度 × 比例, cap)。
const double answerMaxHeightRatio = 0.70;
const double answerMaxHeightCap = 760;

/// 回答窗标题条高度。
const double answerHeaderHeight = 36;

/// 收起后的回答窗高度（只留标题条）。
const double answerCollapsedHeight = 36;

/// 回答窗与输入条/主窗口的间距。
const double answerGap = 8;

/// 回答窗圆角。
const double answerRadius = LoopRadius.control;

/// 回答窗非正文（header/问题/状态/padding）占用高度 = 36 + 18 + 22 + 16。
const double answerChromeHeight = answerHeaderHeight + 18 + 22 + 16;

/// 回答窗创建（等待第二引擎 ready）超时。
const Duration answerCreateTimeout = Duration(milliseconds: 4000);

/// 流式 IPC / 测高 / 改高节流（规格允许 60–100ms）。
const Duration answerStreamThrottle = Duration(milliseconds: 80);

/// 回答窗高度变化去抖阈值（像素）。
const double answerHeightEpsilon = 2;

/// 隐藏窗口后等待 DWM 动画完成再截图。
const Duration captureHideDelay = Duration(milliseconds: 280);

/// 显示器/DPI 变化去抖。
const Duration transitionDebounce = Duration(milliseconds: 300);

/// 全局快捷键去抖（叠加原生 MOD_NOREPEAT）。
const Duration hotkeyDebounce = Duration(milliseconds: 300);

/// 每次截图流程最多重截次数。
const int maxRetakes = 3;

/// 显示器信息（Win32 物理像素为权威）。
@immutable
class DisplayInfo {
  const DisplayInfo({
    required this.id,
    required this.physicalBounds,
    required this.physicalWorkArea,
    this.scaleFactor = 1.0,
    this.isPrimary = false,
  });

  /// Win32 device name（例如 `\\.\DISPLAY1`）或 screen_retriever 的 display id。
  final String id;

  /// 显示器完整物理矩形（rcMonitor）。
  final Rect physicalBounds;

  /// 显示器工作区物理矩形（rcWork，已排除任务栏）。
  final Rect physicalWorkArea;

  /// 有效 DPI 缩放（1.0 = 100%）。
  final double scaleFactor;

  /// 是否主显示器。
  final bool isPrimary;

  @override
  bool operator ==(Object other) =>
      other is DisplayInfo &&
      other.id == id &&
      other.physicalBounds == physicalBounds &&
      other.physicalWorkArea == physicalWorkArea &&
      other.scaleFactor == scaleFactor &&
      other.isPrimary == isPrimary;

  @override
  int get hashCode => Object.hash(
        id,
        physicalBounds,
        physicalWorkArea,
        scaleFactor,
        isPrimary,
      );

  @override
  String toString() =>
      'DisplayInfo($id, work=$physicalWorkArea, scale=$scaleFactor, primary=$isPrimary)';
}

/// 截图目标显示器（逻辑上属于展示层，不依赖 Win32 句柄）。
@immutable
class CaptureDisplay {
  const CaptureDisplay({
    required this.id,
    required this.physicalWorkArea,
    this.scaleFactor = 1.0,
    this.isPrimary = false,
  });

  final String id;

  /// 捕获矩形（物理像素，工作区，排除任务栏）。
  final Rect physicalWorkArea;

  final double scaleFactor;
  final bool isPrimary;

  @override
  bool operator ==(Object other) =>
      other is CaptureDisplay &&
      other.id == id &&
      other.physicalWorkArea == physicalWorkArea &&
      other.scaleFactor == scaleFactor &&
      other.isPrimary == isPrimary;

  @override
  int get hashCode =>
      Object.hash(id, physicalWorkArea, scaleFactor, isPrimary);

  @override
  String toString() => 'CaptureDisplay($id, $physicalWorkArea, scale=$scaleFactor)';
}

/// 窗口状态快照。规格 §4.2。
@immutable
class WindowSnapshot {
  const WindowSnapshot({
    required this.mode,
    required this.bounds,
    required this.physicalBounds,
    required this.dpr,
    required this.maximized,
    required this.alwaysOnTop,
    required this.minSize,
    this.pinned = false,
    this.minimal = false,
    this.displayId,
    this.normalPlacement,
  });

  /// 采集时的 UI 形态。
  final LoopWindowMode mode;

  /// 逻辑像素 bounds（当前窗口 DPR 空间）。
  final Rect bounds;

  /// Win32 物理像素矩形（权威，用于恢复/截图对齐）。
  final Rect physicalBounds;

  /// 采集时窗口 DPR。
  final double dpr;

  final bool maximized;
  final bool alwaysOnTop;

  /// 逻辑像素，最近一次应用的最小尺寸。
  final Size minSize;

  /// 仅 floating 有意义。
  final bool pinned;

  /// 浮窗的极简子状态（规格 §3.1）。normal/maximized 时为 false。
  final bool minimal;

  /// 例如 `\\.\DISPLAY2`（Win32）。
  final String? displayId;

  /// Windows restore-down placement（`WINDOWPLACEMENT.rcNormalPosition`，物理像素）。
  ///
  /// 最大化窗口的 [physicalBounds] 是最大化后的窗口矩形，不能用于恢复“还原”后的
  /// 位置；进入浮窗/截图前必须单独保存该字段，退出/恢复时先还原普通 bounds 再
  /// maximize，否则用户点“还原”会停在浮窗位置。
  final Rect? normalPlacement;

  WindowSnapshot copyWith({
    LoopWindowMode? mode,
    Rect? bounds,
    Rect? physicalBounds,
    double? dpr,
    bool? maximized,
    bool? alwaysOnTop,
    Size? minSize,
    bool? pinned,
    bool? minimal,
    String? displayId,
    Rect? normalPlacement,
    bool clearDisplayId = false,
    bool clearNormalPlacement = false,
  }) {
    return WindowSnapshot(
      mode: mode ?? this.mode,
      bounds: bounds ?? this.bounds,
      physicalBounds: physicalBounds ?? this.physicalBounds,
      dpr: dpr ?? this.dpr,
      maximized: maximized ?? this.maximized,
      alwaysOnTop: alwaysOnTop ?? this.alwaysOnTop,
      minSize: minSize ?? this.minSize,
      pinned: pinned ?? this.pinned,
      minimal: minimal ?? this.minimal,
      displayId: clearDisplayId ? null : (displayId ?? this.displayId),
      normalPlacement:
          clearNormalPlacement ? null : (normalPlacement ?? this.normalPlacement),
    );
  }

  /// 恢复普通窗口应使用的物理矩形：最大化快照优先 restore-down placement。
  Rect get restorePhysicalBounds => normalPlacement ?? physicalBounds;

  @override
  String toString() =>
      'WindowSnapshot(mode=$mode, bounds=$bounds, physical=$physicalBounds, '
      'dpr=$dpr, maximized=$maximized, top=$alwaysOnTop, min=$minSize, '
      'pinned=$pinned, minimal=$minimal, display=$displayId, '
      'normalPlacement=$normalPlacement)';
}

/// 浮窗形态宿主：Shell / FloatingBar 只依赖该抽象。
/// 规格 §4.4（冻结接口；t3 只读依赖，t2 实现）。
abstract class FloatingModeHost implements Listenable {
  LoopWindowMode get mode;

  bool get isFloating;

  bool get pinned;

  bool get transitioning;

  bool get supported;

  /// 浮窗的极简子状态（规格 §3.1；normal 时恒 false）。
  bool get minimal;

  /// 截图覆盖/恢复进行中（t3 用于禁用切换/截图按钮）。
  bool get captureInProgress;

  WindowSnapshot? get normalSnapshot;

  WindowSnapshot? get lastFloatingSnapshot;

  /// 最近一次进入极简前的浮窗快照（退出极简恢复用）。
  WindowSnapshot? get lastExpandedSnapshot;

  Future<bool> enterFloating({bool focus = true});

  Future<bool> exitFloating({bool focus = true});

  Future<bool> toggleFloating({bool focus = true});

  Future<bool> enterMinimal({bool focus = true});

  Future<bool> exitMinimal({bool focus = true});

  Future<bool> toggleMinimal({bool focus = true});

  Future<void> setPinned(bool value);

  Future<void> ensureGeometry();

  Future<WindowSnapshot> snapshot();

  Future<CaptureDisplay?> captureDisplay();

  Future<void> beginCaptureOverlay(CaptureDisplay display);

  Future<void> applySnapshot(WindowSnapshot snapshot, {bool focus = false});
}

/// 窗口平台接口。io 实现基于 window_manager + Win32；stub 全部 no-op。
/// 规格 §4.4（冻结接口）。
abstract class WindowPlatform {
  bool get supported;

  Future<WindowSnapshot> snapshot();

  Future<void> setMinimumSize(Size logical);

  Future<void> setAlwaysOnTop(bool value);

  Future<bool> isAlwaysOnTop();

  Future<void> setBoundsPhysical(Rect physical);

  Future<void> setBoundsLogical(Rect logical);

  /// 一次设置 restore-down placement 与最大化状态（Windows `SetWindowPlacement`）。
  ///
  /// 默认不支持（返回 false，由调用方回退到 unmaximize/setBounds/maximize 流程）；
  /// Windows 实现覆盖，保证最大化恢复时不会把浮窗 bounds 写成 rcNormalPosition。
  Future<bool> setWindowPlacement(
    Rect normalPlacement, {
    required bool maximized,
  }) async =>
      false;

  Future<Rect> physicalRect();

  Future<double> dpr();

  Future<bool> isMaximized();

  Future<void> maximize();

  Future<void> unmaximize();

  Future<void> show();

  Future<void> hide();

  Future<bool> isVisible();

  Future<void> focus();

  Future<void> restore();

  Future<void> setResizable(bool value);

  Future<List<DisplayInfo>> displays();

  Future<String?> displayIdAt(Offset physicalPoint);
}

/// 纯几何规划（无副作用、可单测）。规格 §4.3。
class FloatingWindowPlanner {
  const FloatingWindowPlanner._();

  /// DPI 归一化：缺失/0/NaN/Infinity/越界 → 1.0（越界值按规格丢弃）。
  static double normalizedDpr(double? value) {
    if (value == null || value.isNaN || value.isInfinite) return 1.0;
    if (value < 0.5 || value > 4.0) return 1.0;
    return value;
  }

  /// 计算浮窗逻辑矩形：右边缘内缩 [margin]、垂直居中，并保证不小于 [min]。
  ///
  /// [workPhysical] 是目标显示器工作区物理像素；返回值是**该显示器 DPR 空间**
  /// 的逻辑矩形。调用方按 `targetPhysical = logical × dpr` 换算物理矩形。
  static Rect placeFloating(
    Rect workPhysical,
    double dpr,
    Size preferred,
    Size min,
    double margin,
  ) {
    final scale = normalizedDpr(dpr);
    final work = Rect.fromLTWH(
      workPhysical.left / scale,
      workPhysical.top / scale,
      workPhysical.width / scale,
      workPhysical.height / scale,
    );
    final availW = math.max(0.0, work.width - 2 * margin);
    final availH = math.max(0.0, work.height - 2 * margin);
    final w = _clamp(preferred.width, min.width, math.max(min.width, availW));
    final h = _clamp(preferred.height, min.height, math.max(min.height, availH));
    final minX = work.left + margin;
    final maxX = math.max(minX, work.right - margin - w);
    final x = _clamp(work.right - margin - w, minX, maxX);
    final minY = work.top + margin;
    final maxY = math.max(minY, work.bottom - margin - h);
    final y = _clamp(work.top + (work.height - h) / 2, minY, maxY);
    return Rect.fromLTWH(x, y, w, h);
  }

  /// 选择窗口所属显示器：中心命中 → 交集最大 → 主屏 → 首个 → null。
  static DisplayInfo? chooseDisplay(
    List<DisplayInfo> displays,
    Rect windowPhysicalRect,
  ) {
    if (displays.isEmpty) return null;
    final center = windowPhysicalRect.center;
    for (final display in displays) {
      if (_containsPoint(display.physicalWorkArea, center)) return display;
    }
    DisplayInfo? best;
    var bestArea = 0.0;
    for (final display in displays) {
      final overlap = _intersectionArea(
        display.physicalWorkArea,
        windowPhysicalRect,
      );
      if (overlap > bestArea) {
        bestArea = overlap;
        best = display;
      }
    }
    if (best != null) return best;
    for (final display in displays) {
      if (display.isPrimary) return display;
    }
    return displays.first;
  }

  /// 屏幕移除/分辨率变化后，把浮窗钳制回目标显示器工作区。
  static Rect clampToWorkArea(Rect physical, Rect workArea, double dpr) {
    if (workArea.width <= 0 || workArea.height <= 0) return physical;
    final width = math.min(physical.width, workArea.width);
    final height = math.min(physical.height, workArea.height);
    final left = _clamp(
      physical.left,
      workArea.left,
      math.max(workArea.left, workArea.right - width),
    );
    final top = _clamp(
      physical.top,
      workArea.top,
      math.max(workArea.top, workArea.bottom - height),
    );
    return Rect.fromLTWH(left, top, width, height);
  }

  /// 普通窗口离屏时的默认 bounds：主显示器工作区居中、900×600。
  static Rect defaultNormalBounds(DisplayInfo display) {
    final scale = normalizedDpr(display.scaleFactor);
    final work = Rect.fromLTWH(
      display.physicalWorkArea.left / scale,
      display.physicalWorkArea.top / scale,
      display.physicalWorkArea.width / scale,
      display.physicalWorkArea.height / scale,
    );
    final width = math.min(normalMinSize.width, work.width);
    final height = math.min(normalMinSize.height, work.height);
    final left = work.left + (work.width - width) / 2;
    final top = work.top + (work.height - height) / 2;
    return Rect.fromLTWH(left, top, width, height);
  }

  /// 浮窗是否与目标工作区有可见交集且基本位于其中。
  static bool isInsideWorkArea(Rect physical, Rect workArea) {
    final overlap = physical.intersect(workArea);
    if (overlap.width < 1 || overlap.height < 1) return false;
    return physical.left >= workArea.left - 2 &&
        physical.top >= workArea.top - 2 &&
        physical.right <= workArea.right + 2 &&
        physical.bottom <= workArea.bottom + 2;
  }

  static double _clamp(double value, double min, double max) {
    if (max < min) return min;
    return value.clamp(min, max).toDouble();
  }

  static bool _containsPoint(Rect rect, Offset point) =>
      point.dx >= rect.left &&
      point.dx <= rect.right &&
      point.dy >= rect.top &&
      point.dy <= rect.bottom;

  static double _intersectionArea(Rect a, Rect b) {
    final overlap = a.intersect(b);
    if (overlap.width <= 0 || overlap.height <= 0) return 0;
    return overlap.width * overlap.height;
  }
}

/// 回答浮窗纯几何规划（输入/输出均为物理像素；可单测）。规格 §4.2/§4.3/§5.2。
///
/// - 宽度：工作区逻辑宽度 × 35%，钳制 420–900；
/// - 高度：`chromeHeight + 正文高`，钳制 `[180, min(工作区高×70%, 760)]`；
/// - 位置：auto 模式优先“输入条上方”，其次下方/主窗右侧/左侧/兜底；
///   user 模式尊重用户位置，仅在覆盖输入条/越界时做最小位移；
/// - 所有输出保证与输入条（含 gap）零交集、且位于工作区内（容差 2px）。
class AnswerWindowPlanner {
  const AnswerWindowPlanner._();

  /// 固定舒适宽度（逻辑像素）。
  static double widthLogical(Rect workLogical) =>
      (workLogical.width * answerWidthRatio)
          .clamp(answerWidthMin, answerWidthMax)
          .toDouble();

  /// 最大高度（逻辑像素）。
  static double maxHeightLogical(Rect workLogical) {
    final limit = math.min(
      workLogical.height * answerMaxHeightRatio,
      answerMaxHeightCap,
    );
    return math.max(answerMinHeight, limit);
  }

  /// 期望高度（逻辑像素）= 固定行高 + 正文测量高度，再钳制。
  static double desiredHeightLogical(
    double contentHeightLogical, {
    required Rect workLogical,
    double chromeHeight = answerChromeHeight,
  }) {
    final desired = chromeHeight + math.max(0.0, contentHeightLogical);
    return desired
        .clamp(answerMinHeight, maxHeightLogical(workLogical))
        .toDouble();
  }

  /// 计算回答窗物理矩形。
  ///
  /// [userMoved] 为 true 时用 [userRect] 的左上角作为锚点（顶边固定，
  /// 高度变化向下生长）；auto 模式高度变化时保持输入条上方的底边固定。
  static Rect place({
    required Rect workPhysical,
    required Rect inputBarPhysical,
    required Rect mainWindowPhysical,
    required double dpr,
    required double widthLogical,
    required double heightLogical,
    required bool userMoved,
    Rect? userRect,
    double gap = answerGap,
  }) {
    final scale = FloatingWindowPlanner.normalizedDpr(dpr);
    final work = _validRect(workPhysical)
        ? workPhysical
        : Rect.fromLTWH(
            0,
            0,
            math.max(1.0, workPhysical.width),
            math.max(1.0, workPhysical.height),
          );
    final widthPhysical = math.max(
      1.0,
      math.min(widthLogical * scale, work.width),
    );
    final heightPhysical = math.max(
      1.0,
      math.min(heightLogical * scale, work.height),
    );
    final gapPhysical = math.max(0.0, gap * scale);
    final input =
        _validRect(inputBarPhysical) ? inputBarPhysical : Rect.zero;
    final exclusion = input.isEmpty ? Rect.zero : input.inflate(gapPhysical);
    final mainWindow =
        _validRect(mainWindowPhysical) ? mainWindowPhysical : input;

    Rect clampInside(Rect rect) => _clampInside(rect, work);

    Rect autoPlace() => _autoPlace(
          work: work,
          input: input,
          exclusion: exclusion,
          mainWindow: mainWindow,
          widthPhysical: widthPhysical,
          heightPhysical: heightPhysical,
          gapPhysical: gapPhysical,
          scale: scale,
        );

    if (!userMoved || !_validRect(userRect)) return autoPlace();

    final base = userRect!;
    var desired = clampInside(
      Rect.fromLTWH(base.left, base.top, widthPhysical, heightPhysical),
    );
    if (!_intersects(desired, exclusion)) return desired;
    if (exclusion.isEmpty) return desired;

    // 最小位移候选：上方、下方、左侧、右侧。
    final candidates = <Rect>[];
    void addIfSpace(Rect rect) {
      final candidate = clampInside(rect);
      if (!_intersects(candidate, exclusion)) candidates.add(candidate);
    }

    addIfSpace(Rect.fromLTWH(
      desired.left,
      exclusion.top - heightPhysical,
      widthPhysical,
      heightPhysical,
    ));
    addIfSpace(Rect.fromLTWH(
      desired.left,
      exclusion.bottom,
      widthPhysical,
      heightPhysical,
    ));
    addIfSpace(Rect.fromLTWH(
      exclusion.left - widthPhysical,
      desired.top,
      widthPhysical,
      heightPhysical,
    ));
    addIfSpace(Rect.fromLTWH(
      exclusion.right,
      desired.top,
      widthPhysical,
      heightPhysical,
    ));

    Rect? best;
    var bestDistance = double.infinity;
    for (final candidate in candidates) {
      final distance = (candidate.topLeft - desired.topLeft).distance;
      if (distance < bestDistance) {
        bestDistance = distance;
        best = candidate;
      }
    }
    if (best != null) return best;

    // 用户位置无法避开输入条（例如输入条占据整个宽度）：回到 auto 候选。
    return autoPlace();
  }

  /// 回答窗是否与输入条排除区（含 gap）相交。
  static bool overlapsInputBar({
    required Rect answerPhysical,
    required Rect inputBarPhysical,
    required double dpr,
    double gap = answerGap,
  }) {
    if (!_validRect(answerPhysical) || !_validRect(inputBarPhysical)) {
      return false;
    }
    final scale = FloatingWindowPlanner.normalizedDpr(dpr);
    return _intersects(
      answerPhysical,
      inputBarPhysical.inflate(math.max(0.0, gap * scale)),
    );
  }

  static Rect _autoPlace({
    required Rect work,
    required Rect input,
    required Rect exclusion,
    required Rect mainWindow,
    required double widthPhysical,
    required double heightPhysical,
    required double gapPhysical,
    required double scale,
  }) {
    Rect placeAboveBelow({required bool above}) {
      // exclusion 已包含 gap：上方底边 = exclusion.top，下方顶边 = exclusion.bottom。
      final available = above
          ? exclusion.top - work.top
          : work.bottom - exclusion.bottom;
      final effectiveHeight = math.min(heightPhysical, math.max(0.0, available));
      final left = _clamp(
        input.right - widthPhysical,
        work.left,
        work.right - widthPhysical,
      );
      final top = above
          ? exclusion.top - effectiveHeight
          : exclusion.bottom;
      return Rect.fromLTWH(left, top, widthPhysical, effectiveHeight);
    }

    bool fitsVertically(bool above) {
      if (input.isEmpty) return false;
      final available = above
          ? (input.top - gapPhysical) - work.top
          : work.bottom - (input.bottom + gapPhysical);
      final minimum = math.min(heightPhysical, answerMinHeight * scale);
      return available >= minimum - 0.5;
    }

    // 1) 输入条上方（右对齐）。
    if (fitsVertically(true)) return placeAboveBelow(above: true);
    // 2) 输入条下方。
    if (fitsVertically(false)) return placeAboveBelow(above: false);

    // 3) 主窗口/极简条右侧，顶部对齐输入条。
    final rightLeft = mainWindow.right + gapPhysical;
    if (rightLeft + widthPhysical <= work.right + 0.5) {
      final top = _clamp(
        input.top,
        work.top,
        work.bottom - heightPhysical,
      );
      final effectiveHeight = math.min(heightPhysical, work.bottom - top);
      return Rect.fromLTWH(rightLeft, top, widthPhysical, effectiveHeight);
    }
    // 4) 主窗口/极简条左侧。
    final leftRight = mainWindow.left - gapPhysical;
    final leftLeft = leftRight - widthPhysical;
    if (leftLeft >= work.left - 0.5) {
      final top = _clamp(
        input.top,
        work.top,
        work.bottom - heightPhysical,
      );
      final effectiveHeight = math.min(heightPhysical, work.bottom - top);
      return Rect.fromLTWH(leftLeft, top, widthPhysical, effectiveHeight);
    }

    // 5) 兜底：工作区内不覆盖输入条的最大可用矩形（高度可小于 minH）。
    final bands = <Rect>[
      if (!input.isEmpty)
        Rect.fromLTWH(
          work.left,
          work.top,
          work.width,
          math.max(0.0, input.top - gapPhysical - work.top),
        ),
      if (!input.isEmpty)
        Rect.fromLTWH(
          work.left,
          input.bottom + gapPhysical,
          work.width,
          math.max(0.0, work.bottom - (input.bottom + gapPhysical)),
        ),
      if (!input.isEmpty)
        Rect.fromLTWH(
          work.left,
          work.top,
          math.max(0.0, input.left - gapPhysical - work.left),
          work.height,
        ),
      if (!input.isEmpty)
        Rect.fromLTWH(
          input.right + gapPhysical,
          work.top,
          math.max(0.0, work.right - (input.right + gapPhysical)),
          work.height,
        ),
    ];
    Rect? bestBand;
    var bestArea = 0.0;
    for (final band in bands) {
      final area = band.width * band.height;
      if (area > bestArea) {
        bestArea = area;
        bestBand = band;
      }
    }
    if (bestBand == null) {
      return Rect.fromLTWH(
        work.left,
        work.top,
        widthPhysical,
        heightPhysical,
      );
    }
    final width = math.min(widthPhysical, bestBand.width);
    final height = math.min(heightPhysical, bestBand.height);
    final isVerticalBand = bestBand.width >= work.width - 0.5;
    double left;
    double top;
    if (isVerticalBand) {
      left = _clamp(
        input.right - width,
        bestBand.left,
        bestBand.right - width,
      );
      top = bestBand.top == work.top
          ? bestBand.bottom - height
          : bestBand.top;
    } else {
      left = bestBand.left == work.left
          ? bestBand.right - width
          : bestBand.left;
      top = _clamp(input.top, bestBand.top, bestBand.bottom - height);
    }
    return Rect.fromLTWH(left, top, width, height);
  }

  static Rect _clampInside(Rect rect, Rect work) {
    final width = math.min(rect.width, work.width);
    final height = math.min(rect.height, work.height);
    final left = _clamp(rect.left, work.left, work.right - width);
    final top = _clamp(rect.top, work.top, work.bottom - height);
    return Rect.fromLTWH(left, top, width, height);
  }

  static bool _intersects(Rect a, Rect b) {
    if (a.isEmpty || b.isEmpty) return false;
    final overlap = a.intersect(b);
    return overlap.width > 0 && overlap.height > 0;
  }

  static bool _validRect(Rect? rect) =>
      rect != null &&
      rect.width.isFinite &&
      rect.height.isFinite &&
      rect.width >= 1 &&
      rect.height >= 1;

  static double _clamp(double value, double min, double max) {
    if (max < min) return min;
    return value.clamp(min, max).toDouble();
  }
}
