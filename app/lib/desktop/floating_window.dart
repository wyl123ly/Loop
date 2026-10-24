import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';

import 'floating_signals.dart' as signals;
import 'window_mode.dart';

/// 浮窗形态控制器：唯一的窗口形态状态机（规格 §3 / §4.4）。
///
/// 纯 Dart（只依赖 [WindowPlatform]），因此可用 FakeWindowPlatform 在单测里
/// 覆盖完整进入/退出/失败回滚/显示器校正流程。所有窗口变更都必须经过它；
/// UI 只读状态。
class FloatingWindowController extends ChangeNotifier
    implements FloatingModeHost {
  FloatingWindowController(
    this.platform, {
    this.onError,
    this.pollInterval = const Duration(milliseconds: 50),
    this.maxPollAttempts = 10,
    this.geometryDebounce = transitionDebounce,
  });

  final WindowPlatform platform;

  /// 失败提示回调（UI 弹一次 snack，由 t3 注入；测试可计数）。
  final void Function(String message)? onError;

  final Duration pollInterval;
  final int maxPollAttempts;
  final Duration geometryDebounce;

  LoopWindowMode _mode = LoopWindowMode.normal;
  bool _pinned = false;
  bool _transitioning = false;
  WindowSnapshot? _normalSnapshot;
  WindowSnapshot? _lastFloatingSnapshot;
  Size _minSize = normalMinSize;
  Timer? _geometryTimer;
  bool _geometryBusy = false;
  bool _captureInProgress = false;
  String? _lastError;
  int _errorCount = 0;

  @override
  LoopWindowMode get mode => _mode;

  @override
  bool get isFloating => _mode == LoopWindowMode.floating;

  @override
  bool get pinned => _pinned;

  @override
  bool get transitioning => _transitioning;

  @override
  bool get supported => platform.supported;

  @override
  WindowSnapshot? get normalSnapshot => _normalSnapshot;

  @override
  WindowSnapshot? get lastFloatingSnapshot => _lastFloatingSnapshot;

  /// 截图覆盖/恢复进行中（与全局信号同步）。
  @override
  bool get captureInProgress => _captureInProgress;

  /// 当前应用的最小尺寸（逻辑像素），用于快照组合。
  Size get minimumSize => _minSize;

  /// 最近一次失败原因（UI tooltip/提示用）。
  String? get lastError => _lastError;

  /// 失败次数（测试断言“提示一次”）。
  int get errorCount => _errorCount;

  @override
  Future<WindowSnapshot> snapshot() async {
    final base = await platform.snapshot();
    return base.copyWith(
      mode: _mode,
      minSize: _minSize,
      pinned: _mode == LoopWindowMode.floating && _pinned,
      alwaysOnTop: base.alwaysOnTop,
    );
  }

  @override
  Future<CaptureDisplay?> captureDisplay() async {
    final displays = await _safeDisplays();
    if (displays.isEmpty) return null;
    final physical = await platform.physicalRect();
    final target = FloatingWindowPlanner.chooseDisplay(displays, physical) ??
        displays.first;
    return CaptureDisplay(
      id: target.id,
      physicalWorkArea: target.physicalWorkArea,
      scaleFactor: target.scaleFactor,
      isPrimary: target.isPrimary,
    );
  }

  @override
  Future<bool> enterFloating({bool focus = true}) async {
    if (!platform.supported) return false;
    if (_transitioning || _captureInProgress) return false;
    if (_mode == LoopWindowMode.floating) return true;

    _transitioning = true;
    notifyListeners();

    final previous = _normalSnapshot;
    WindowSnapshot? snapshot;
    try {
      snapshot = await this.snapshot();
      _normalSnapshot = snapshot;
      final displays = await _safeDisplays();
      final target = FloatingWindowPlanner.chooseDisplay(
        displays,
        snapshot.physicalBounds,
      );

      if (snapshot.maximized) {
        await platform.unmaximize();
        await _waitForUnmaximize();
      }

      await platform.setResizable(true);
      await platform.setMinimumSize(floatingMinSize);
      _minSize = floatingMinSize;

      final preferred = _preferredFloatingSize();
      final dpr = FloatingWindowPlanner.normalizedDpr(
        target?.scaleFactor ?? snapshot.dpr,
      );
      final workPhysical = target?.physicalWorkArea ??
          _fallbackWorkArea(snapshot);
      final logical = FloatingWindowPlanner.placeFloating(
        workPhysical,
        dpr,
        preferred,
        floatingMinSize,
        floatingMargin,
      );
      final physical = _toPhysical(logical, dpr);

      await platform.setAlwaysOnTop(true);
      await _applyBounds(physical, logical);
      await platform.show();
      if (focus) await platform.focus();
      await _verifyBounds(physical, logical, dpr);

      _pinned = true;
      _mode = LoopWindowMode.floating;
      _lastFloatingSnapshot = await this.snapshot();
      _transitioning = false;
      notifyListeners();
      return true;
    } catch (error) {
      debugPrint('enterFloating failed: $error');
      await _rollback(previous ?? snapshot);
      _mode = LoopWindowMode.normal;
      _pinned = false;
      _normalSnapshot = null;
      _transitioning = false;
      _raiseError('切到浮窗失败，已恢复窗口');
      notifyListeners();
      return false;
    }
  }

  @override
  Future<bool> exitFloating({bool focus = true}) async {
    if (!platform.supported) return false;
    if (_transitioning || _captureInProgress) return false;
    if (_mode == LoopWindowMode.normal) return true;

    _transitioning = true;
    notifyListeners();

    try {
      // 记住本次浮窗尺寸（退出后用于下一次进入），必须在恢复普通 bounds 前读取。
      _lastFloatingSnapshot = await this.snapshot();

      var snapshot = _normalSnapshot;
      if (snapshot == null) {
        snapshot = await _defaultNormalSnapshot();
        _normalSnapshot = snapshot;
      }

      await platform.setAlwaysOnTop(snapshot.alwaysOnTop);
      await platform.setMinimumSize(snapshot.minSize);
      _minSize = snapshot.minSize;
      await _restoreNormalBounds(snapshot, retryOnFailure: true);
      await platform.show();
      if (focus) await platform.focus();

      _mode = LoopWindowMode.normal;
      _pinned = false;
      _normalSnapshot = null;
      _transitioning = false;
      notifyListeners();
      return true;
    } catch (error) {
      debugPrint('exitFloating failed: $error');
      // 尽力回到一个可见的普通窗口，避免卡在“半恢复”状态。
      await _applyDefaultNormalWindow();
      _mode = LoopWindowMode.normal;
      _pinned = false;
      _normalSnapshot = null;
      _transitioning = false;
      _raiseError('恢复主窗口失败，已使用默认窗口');
      notifyListeners();
      return false;
    }
  }

  @override
  Future<bool> toggleFloating({bool focus = true}) {
    return isFloating ? exitFloating(focus: focus) : enterFloating(focus: focus);
  }

  @override
  Future<void> setPinned(bool value) async {
    if (!supported) return;
    if (_mode != LoopWindowMode.floating) return; // 普通窗口不主动置顶
    if (_pinned == value) return;
    await platform.setAlwaysOnTop(value);
    _pinned = value;
    notifyListeners();
  }

  /// 显示器/DPI 变化后去抖校正（不 focus、不改 mode）。
  void scheduleEnsureGeometry() {
    _geometryTimer?.cancel();
    _geometryTimer = Timer(geometryDebounce, () {
      unawaited(ensureGeometry());
    });
  }

  @override
  Future<void> ensureGeometry() async {
    if (!supported || _geometryBusy || _transitioning || _captureInProgress) {
      return;
    }
    _geometryBusy = true;
    try {
      // 最大化窗口不做几何校正（规格 §4.4：最大化不处理）。
      if (_mode == LoopWindowMode.normal &&
          await platform.isMaximized()) {
        return;
      }
      final displays = await _safeDisplays();
      if (displays.isEmpty) return;
      final physical = await platform.physicalRect();
      final dpr = FloatingWindowPlanner.normalizedDpr(await platform.dpr());

      if (_mode == LoopWindowMode.floating) {
        final target = FloatingWindowPlanner.chooseDisplay(displays, physical);
        if (target == null) return;
        if (FloatingWindowPlanner.isInsideWorkArea(
          physical,
          target.physicalWorkArea,
        )) {
          return;
        }
        final clamped = FloatingWindowPlanner.clampToWorkArea(
          physical,
          target.physicalWorkArea,
          dpr,
        );
        if (clamped == physical) return;
        final logical = Rect.fromLTWH(
          clamped.left / dpr,
          clamped.top / dpr,
          clamped.width / dpr,
          clamped.height / dpr,
        );
        await _applyBounds(clamped, logical);
        if (_pinned) await platform.setAlwaysOnTop(true);
      } else {
        final visible = displays.any(
          (display) =>
              display.physicalWorkArea.intersect(physical).width >= 1 &&
              display.physicalWorkArea.intersect(physical).height >= 1,
        );
        if (visible) return;
        final primary = displays.firstWhere(
          (display) => display.isPrimary,
          orElse: () => displays.first,
        );
        final bounds = FloatingWindowPlanner.defaultNormalBounds(primary);
        final targetPhysical = _toPhysical(
          bounds,
          FloatingWindowPlanner.normalizedDpr(primary.scaleFactor),
        );
        await _applyBounds(targetPhysical, bounds);
      }
      notifyListeners();
    } catch (error) {
      debugPrint('ensureGeometry failed: $error');
    } finally {
      _geometryBusy = false;
    }
  }

  /// 截图开始：把窗口覆盖到捕获显示器工作区并置顶（不改 mode）。
  ///
  /// 只由 [ScreenshotCapture] 在用户动作后调用；focus 恰一次。
  @override
  Future<void> beginCaptureOverlay(CaptureDisplay display) async {
    if (!supported) return;
    _captureInProgress = true;
    signals.captureInProgress.value = true;
    notifyListeners();
    await platform.setAlwaysOnTop(true);
    // 最大化窗口上的 SetWindowPos 不会铺满工作区：必须先 unmaximize。
    if (await platform.isMaximized()) {
      await platform.unmaximize();
      await _waitForUnmaximize();
    }
    final scale = FloatingWindowPlanner.normalizedDpr(display.scaleFactor);
    final logical = Rect.fromLTWH(
      display.physicalWorkArea.left / scale,
      display.physicalWorkArea.top / scale,
      display.physicalWorkArea.width / scale,
      display.physicalWorkArea.height / scale,
    );
    await _applyBounds(display.physicalWorkArea, logical);
    await platform.show();
    await platform.focus();
  }

  /// 恢复完整快照（截图结束/失败回滚）。按契约**不修改** [LoopWindowMode]。
  ///
  /// - `snapshot.maximized` 时恢复最大化 + restore-down placement（T5-01/02/03）；
  /// - 中途异常也必须在 finally 清理 `captureInProgress`/全局信号（T5-06）。
  @override
  Future<void> applySnapshot(
    WindowSnapshot snapshot, {
    bool focus = false,
  }) async {
    if (!supported) return;
    try {
      await platform.setResizable(true);
      await platform.setMinimumSize(snapshot.minSize);
      _minSize = snapshot.minSize;
      await platform.setAlwaysOnTop(snapshot.alwaysOnTop);
      if (snapshot.maximized) {
        await _restoreMaximized(snapshot);
      } else {
        if (await platform.isMaximized()) {
          await platform.unmaximize();
          await _waitForUnmaximize();
        }
        await _restoreBounds(snapshot);
      }
      await platform.show();
      if (focus) await platform.focus();
      if (_mode != snapshot.mode) {
        // applySnapshot 不修改形态：截图前是浮窗，恢复后仍是浮窗。
        debugPrint(
          'applySnapshot mode mismatch: current=$_mode snapshot=${snapshot.mode}',
        );
      }
    } finally {
      _captureInProgress = false;
      signals.captureInProgress.value = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _geometryTimer?.cancel();
    _geometryTimer = null;
    super.dispose();
  }

  // -------------------------------------------------------------------------
  // 内部工具
  // -------------------------------------------------------------------------

  Size _preferredFloatingSize() {
    final last = _lastFloatingSnapshot;
    if (last == null) return floatingDefaultSize;
    final dpr = FloatingWindowPlanner.normalizedDpr(last.dpr);
    if (last.physicalBounds.width <= 0 || last.physicalBounds.height <= 0) {
      return floatingDefaultSize;
    }
    final width = last.physicalBounds.width / dpr;
    final height = last.physicalBounds.height / dpr;
    if (width < floatingMinSize.width || height < floatingMinSize.height) {
      return floatingDefaultSize;
    }
    return Size(width, height);
  }

  Future<List<DisplayInfo>> _safeDisplays() async {
    try {
      return await platform.displays();
    } catch (error) {
      debugPrint('displays() failed: $error');
      return const <DisplayInfo>[];
    }
  }

  Rect _fallbackWorkArea(WindowSnapshot snapshot) {
    // 显示器 API 全部失败时的最后兜底：至少保证浮窗可见。
    final bounds = snapshot.physicalBounds;
    if (bounds.width >= floatingMinSize.width &&
        bounds.height >= floatingMinSize.height) {
      return Rect.fromLTWH(0, 0, math.max(bounds.width, bounds.right), math.max(bounds.height, bounds.bottom));
    }
    return Rect.fromLTWH(0, 0, 1440, 900);
  }

  Rect _toPhysical(Rect logical, double dpr) => Rect.fromLTWH(
        logical.left * dpr,
        logical.top * dpr,
        logical.width * dpr,
        logical.height * dpr,
      );

  Future<void> _applyBounds(Rect physical, Rect logical) async {
    try {
      await platform.setBoundsPhysical(physical);
    } catch (error) {
      debugPrint('setBoundsPhysical failed ($error), fallback logical');
      await platform.setBoundsLogical(logical);
    }
  }

  Future<void> _verifyBounds(
    Rect physical,
    Rect logical,
    double dpr,
  ) async {
    var actual = await platform.physicalRect();
    if (!_closeEnough(actual, physical)) {
      await _applyBounds(physical, logical);
      actual = await platform.physicalRect();
      if (!_closeEnough(actual, physical)) {
        throw StateError('窗口尺寸校验失败: $actual != $physical');
      }
    }
  }

  bool _closeEnough(Rect a, Rect b) {
    const tolerance = 4.0;
    return (a.left - b.left).abs() <= tolerance &&
        (a.top - b.top).abs() <= tolerance &&
        (a.width - b.width).abs() <= tolerance &&
        (a.height - b.height).abs() <= tolerance;
  }

  Future<void> _waitForUnmaximize() async {
    for (var i = 0; i < maxPollAttempts; i++) {
      if (!await platform.isMaximized()) return;
      await Future<void>.delayed(pollInterval);
    }
  }

  Future<void> _waitForMaximize() async {
    for (var i = 0; i < maxPollAttempts; i++) {
      if (await platform.isMaximized()) return;
      await Future<void>.delayed(pollInterval);
    }
    throw StateError('恢复最大化失败');
  }

  /// 恢复最大化 + 原 restore-down placement（Windows `SetWindowPlacement`）。
  ///
  /// 直接 maximize() 会让 rcNormalPosition 变成浮窗/覆盖层 bounds，用户点“还原”
  /// 停在浮窗位置；因此先一次性写回 placement，再 poll 确认已最大化。平台不支持
  /// 时回退为“unmaximize → 恢复普通 bounds → maximize”。
  Future<void> _restoreMaximized(WindowSnapshot snapshot) async {
    final placement = snapshot.restorePhysicalBounds;
    if (await platform.setWindowPlacement(placement, maximized: true)) {
      try {
        await _waitForMaximize();
        return;
      } catch (error) {
        debugPrint('SetWindowPlacement maximize not confirmed: $error');
      }
    }
    if (await platform.isMaximized()) {
      await platform.unmaximize();
      await _waitForUnmaximize();
    }
    await _restoreBounds(snapshot, useNormalPlacement: true);
    if (snapshot.normalPlacement != null) {
      final actual = await platform.physicalRect();
      if (!_closeEnough(actual, snapshot.normalPlacement!)) {
        throw StateError('恢复最大化前普通位置失败: $actual');
      }
    }
    await platform.maximize();
    await _waitForMaximize();
  }

  Future<void> _restoreNormalBounds(
    WindowSnapshot snapshot, {
    required bool retryOnFailure,
  }) async {
    Future<void> attempt() async {
      if (snapshot.maximized) {
        await _restoreMaximized(snapshot);
        return;
      }
      if (await platform.isMaximized()) {
        await platform.unmaximize();
        await _waitForUnmaximize();
      }
      await _restoreBounds(snapshot);
      final actual = await platform.physicalRect();
      if (!_closeEnough(actual, snapshot.physicalBounds)) {
        throw StateError('恢复普通窗口 bounds 失败: $actual');
      }
    }

    try {
      await attempt();
    } catch (error) {
      if (!retryOnFailure) rethrow;
      debugPrint('restore normal retry: $error');
      await attempt();
    }
  }

  /// 恢复 bounds：优先物理矩形，物理不可用时用逻辑矩形。
  ///
  /// [useNormalPlacement] 为 true 时用最大化快照的 restore-down placement。
  Future<void> _restoreBounds(
    WindowSnapshot snapshot, {
    bool useNormalPlacement = false,
  }) async {
    final physical =
        useNormalPlacement ? snapshot.restorePhysicalBounds : snapshot.physicalBounds;
    if (physical.width >= 1 && physical.height >= 1) {
      try {
        await platform.setBoundsPhysical(physical);
        return;
      } catch (error) {
        debugPrint('restore physical bounds failed: $error');
      }
    }
    final dpr = FloatingWindowPlanner.normalizedDpr(snapshot.dpr);
    final logical = useNormalPlacement && snapshot.normalPlacement != null
        ? Rect.fromLTWH(
            physical.left / dpr,
            physical.top / dpr,
            physical.width / dpr,
            physical.height / dpr,
          )
        : snapshot.bounds;
    await platform.setBoundsLogical(logical);
  }

  Future<WindowSnapshot> _defaultNormalSnapshot() async {
    final displays = await _safeDisplays();
    DisplayInfo? primary;
    for (final display in displays) {
      if (display.isPrimary) {
        primary = display;
        break;
      }
    }
    primary ??= displays.isEmpty ? null : displays.first;
    final dpr = FloatingWindowPlanner.normalizedDpr(primary?.scaleFactor);
    final bounds = primary == null
        ? const Rect.fromLTWH(0, 0, 900, 600)
        : FloatingWindowPlanner.defaultNormalBounds(primary);
    return WindowSnapshot(
      mode: LoopWindowMode.normal,
      bounds: bounds,
      physicalBounds: _toPhysical(bounds, dpr),
      dpr: dpr,
      maximized: false,
      alwaysOnTop: false,
      minSize: normalMinSize,
      displayId: primary?.id,
    );
  }

  Future<void> _applyDefaultNormalWindow() async {
    try {
      final snapshot = await _defaultNormalSnapshot();
      await platform.setAlwaysOnTop(false);
      await platform.setMinimumSize(normalMinSize);
      _minSize = normalMinSize;
      if (await platform.isMaximized()) {
        await platform.unmaximize();
        await _waitForUnmaximize();
      }
      await _restoreBounds(snapshot);
      await platform.show();
    } catch (error) {
      debugPrint('applyDefaultNormalWindow failed: $error');
    }
  }

  Future<void> _rollback(WindowSnapshot? snapshot) async {
    if (snapshot == null) return;
    try {
      await applySnapshot(snapshot, focus: false);
    } catch (error) {
      debugPrint('rollback failed: $error');
    }
  }

  void _raiseError(String message) {
    _lastError = message;
    _errorCount++;
    onError?.call(message);
  }
}
