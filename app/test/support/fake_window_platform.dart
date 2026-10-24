import 'dart:ui';

import 'package:loop/desktop/window_mode.dart';

/// 可编程的窗口平台 fake（t2 提供，t3 复用）。
///
/// 记录所有平台调用、维护物理矩形/最大化/置顶/最小尺寸/显示器，可注入延迟与
/// 异常；`focusCount` 用于焦点白名单测试。
class FakeWindowPlatform implements WindowPlatform {
  FakeWindowPlatform({
    Rect? physicalRect,
    Rect? normalPlacement,
    this.maximizedRectValue,
    this.dprValue = 1.0,
    this.scaleFactorValue = 1.0,
    List<DisplayInfo>? displays,
    this.supportedValue = true,
    this.visibleValue = true,
    this.maximizedValue = false,
    this.alwaysOnTopValue = false,
    this.minSizeValue = normalMinSize,
    this.supportsWindowPlacementValue = true,
  })  : physicalRectValue =
            physicalRect ?? const Rect.fromLTWH(0, 0, 1200, 800),
        normalPlacementValue = normalPlacement ??
            physicalRect ??
            const Rect.fromLTWH(0, 0, 1200, 800),
        displaysValue = displays ??
            [
              DisplayInfo(
                id: r'\\.\DISPLAY1',
                physicalBounds: const Rect.fromLTWH(0, 0, 1920, 1080),
                physicalWorkArea: const Rect.fromLTWH(0, 0, 1920, 1040),
                scaleFactor: 1.0,
                isPrimary: true,
              ),
            ];

  Rect physicalRectValue;

  /// Windows `WINDOWPLACEMENT.rcNormalPosition` 等价物（物理像素）。
  Rect normalPlacementValue;

  /// 最大化时窗口矩形（null 表示保持物理矩形不变，便于只测 placement 的用例）。
  Rect? maximizedRectValue;
  double dprValue;
  double scaleFactorValue;
  List<DisplayInfo> displaysValue;
  bool supportedValue;
  bool visibleValue;
  bool maximizedValue;
  bool alwaysOnTopValue;
  Size minSizeValue;
  bool resizableValue = true;

  /// false 时模拟平台不支持 SetWindowPlacement（走回退流程）。
  bool supportsWindowPlacementValue;

  int focusCount = 0;
  int showCount = 0;
  int hideCount = 0;
  int maximizeCount = 0;
  int unmaximizeCount = 0;

  /// 在 maximized 状态下调用 setBounds* 的次数（应为 0，用于 T5-02 顺序断言）。
  int boundsWhileMaximized = 0;

  /// 所有平台方法调用（按顺序）；参数以 `method:arg` 形式记录。
  final List<String> calls = [];

  /// 每方法剩余失败次数（模拟平台异常）。
  final Map<String, int> _failures = {};

  /// 每次调用的统一延迟（用于并发/串行测试）。
  Duration? delay;

  void failOn(String method, {int times = 1, Object? error}) {
    _failures[method] = times;
    failures[method] = error ?? StateError('fake failure: $method');
  }

  final Map<String, Object> failures = {};

  void resetCalls() => calls.clear();

  Future<void> _enter(String method, [Object? arg]) async {
    calls.add(arg == null ? method : '$method:$arg');
    if (delay != null) await Future<void>.delayed(delay!);
    final remaining = _failures[method];
    if (remaining != null && remaining > 0) {
      _failures[method] = remaining - 1;
      throw failures[method] ?? StateError('fake failure: $method');
    }
  }

  @override
  bool get supported => supportedValue;

  @override
  Future<WindowSnapshot> snapshot() async {
    await _enter('snapshot');
    final dpr = FloatingWindowPlanner.normalizedDpr(dprValue);
    final bounds = Rect.fromLTWH(
      physicalRectValue.left / dpr,
      physicalRectValue.top / dpr,
      physicalRectValue.width / dpr,
      physicalRectValue.height / dpr,
    );
    return WindowSnapshot(
      mode: LoopWindowMode.normal,
      bounds: bounds,
      physicalBounds: physicalRectValue,
      dpr: dpr,
      maximized: maximizedValue,
      alwaysOnTop: alwaysOnTopValue,
      minSize: minSizeValue,
      displayId:
          FloatingWindowPlanner.chooseDisplay(displaysValue, physicalRectValue)
              ?.id,
      normalPlacement: maximizedValue ? normalPlacementValue : null,
    );
  }

  @override
  Future<void> setMinimumSize(Size logical) async {
    await _enter('setMinimumSize', logical);
    minSizeValue = logical;
  }

  @override
  Future<void> setAlwaysOnTop(bool value) async {
    await _enter('setAlwaysOnTop', value);
    alwaysOnTopValue = value;
  }

  @override
  Future<bool> isAlwaysOnTop() async {
    await _enter('isAlwaysOnTop');
    return alwaysOnTopValue;
  }

  @override
  Future<void> setBoundsPhysical(Rect physical) async {
    await _enter('setBoundsPhysical', physical);
    if (maximizedValue) boundsWhileMaximized++;
    physicalRectValue = physical;
    if (!maximizedValue) normalPlacementValue = physical;
  }

  @override
  Future<void> setBoundsLogical(Rect logical) async {
    await _enter('setBoundsLogical', logical);
    final dpr = FloatingWindowPlanner.normalizedDpr(dprValue);
    final physical = Rect.fromLTWH(
      logical.left * dpr,
      logical.top * dpr,
      logical.width * dpr,
      logical.height * dpr,
    );
    if (maximizedValue) boundsWhileMaximized++;
    physicalRectValue = physical;
    if (!maximizedValue) normalPlacementValue = physical;
  }

  @override
  Future<bool> setWindowPlacement(
    Rect normalPlacement, {
    required bool maximized,
  }) async {
    await _enter('setWindowPlacement', maximized);
    if (!supportsWindowPlacementValue) return false;
    normalPlacementValue = normalPlacement;
    if (maximized) {
      maximizedValue = true;
      maximizeCount++;
      final maxRect = maximizedRectValue;
      if (maxRect != null) physicalRectValue = maxRect;
    } else {
      maximizedValue = false;
      physicalRectValue = normalPlacement;
      unmaximizeCount++;
    }
    return true;
  }

  @override
  Future<Rect> physicalRect() async {
    await _enter('physicalRect');
    return physicalRectValue;
  }

  @override
  Future<double> dpr() async {
    await _enter('dpr');
    return dprValue;
  }

  @override
  Future<bool> isMaximized() async {
    await _enter('isMaximized');
    return maximizedValue;
  }

  @override
  Future<void> maximize() async {
    await _enter('maximize');
    normalPlacementValue = physicalRectValue;
    maximizedValue = true;
    maximizeCount++;
    final maxRect = maximizedRectValue;
    if (maxRect != null) physicalRectValue = maxRect;
  }

  @override
  Future<void> unmaximize() async {
    await _enter('unmaximize');
    maximizedValue = false;
    physicalRectValue = normalPlacementValue;
    unmaximizeCount++;
  }

  @override
  Future<void> show() async {
    await _enter('show');
    visibleValue = true;
    showCount++;
  }

  @override
  Future<void> hide() async {
    await _enter('hide');
    visibleValue = false;
    hideCount++;
  }

  @override
  Future<bool> isVisible() async {
    await _enter('isVisible');
    return visibleValue;
  }

  @override
  Future<void> focus() async {
    await _enter('focus');
    focusCount++;
  }

  @override
  Future<void> restore() async {
    await _enter('restore');
  }

  @override
  Future<void> setResizable(bool value) async {
    await _enter('setResizable', value);
    resizableValue = value;
  }

  @override
  Future<List<DisplayInfo>> displays() async {
    await _enter('displays');
    return List<DisplayInfo>.of(displaysValue);
  }

  @override
  Future<String?> displayIdAt(Offset physicalPoint) async {
    await _enter('displayIdAt', physicalPoint);
    for (final display in displaysValue) {
      final rect = display.physicalWorkArea;
      if (physicalPoint.dx >= rect.left &&
          physicalPoint.dx <= rect.right &&
          physicalPoint.dy >= rect.top &&
          physicalPoint.dy <= rect.bottom) {
        return display.id;
      }
    }
    return null;
  }
}
