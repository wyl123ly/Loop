import 'package:flutter/material.dart';
import 'package:loop/desktop/window_mode.dart';

/// 测试用浮窗形态宿主：不触碰窗口插件，行为可控（成功/失败/忙碌）。
class FakeFloatingHost extends ChangeNotifier implements FloatingModeHost {
  FakeFloatingHost({this.supported = true});

  @override
  final bool supported;

  LoopWindowMode _mode = LoopWindowMode.normal;
  bool _pinned = false;
  bool _transitioning = false;
  bool _captureInProgress = false;

  bool enterShouldFail = false;
  bool exitShouldFail = false;

  int enterCalls = 0;
  int exitCalls = 0;
  int toggleCalls = 0;
  int pinCalls = 0;
  int ensureGeometryCalls = 0;
  int focusCount = 0;

  final List<String> log = [];

  WindowSnapshot? _normalSnapshot;
  WindowSnapshot? _lastFloatingSnapshot;

  @override
  LoopWindowMode get mode => _mode;

  @override
  bool get isFloating => _mode == LoopWindowMode.floating;

  @override
  bool get pinned => _pinned;

  @override
  bool get transitioning => _transitioning;

  @override
  bool get captureInProgress => _captureInProgress;

  @override
  WindowSnapshot? get normalSnapshot => _normalSnapshot;

  @override
  WindowSnapshot? get lastFloatingSnapshot => _lastFloatingSnapshot;

  /// 测试直接模拟“截图覆盖进行中”。
  set captureInProgress(bool value) {
    _captureInProgress = value;
    notifyListeners();
  }

  WindowSnapshot _snapshotFor(LoopWindowMode mode) {
    final floating = mode == LoopWindowMode.floating;
    return WindowSnapshot(
      mode: mode,
      bounds: floating
          ? const Rect.fromLTWH(1436, 220, 460, 600)
          : const Rect.fromLTWH(100, 80, 1200, 800),
      physicalBounds: floating
          ? const Rect.fromLTWH(1436, 220, 460, 600)
          : const Rect.fromLTWH(100, 80, 1200, 800),
      dpr: 1.0,
      maximized: false,
      alwaysOnTop: _pinned,
      minSize: floating ? floatingMinSize : normalMinSize,
      pinned: _pinned,
    );
  }

  @override
  Future<WindowSnapshot> snapshot() async =>
      _snapshotFor(_mode).copyWith(pinned: _pinned);

  @override
  Future<bool> enterFloating({bool focus = true}) async {
    enterCalls++;
    log.add('enter');
    if (!supported) return false;
    if (_mode == LoopWindowMode.floating) return true;
    if (_transitioning || _captureInProgress) return false;
    _transitioning = true;
    notifyListeners();
    if (focus) focusCount++;
    if (enterShouldFail) {
      _transitioning = false;
      notifyListeners();
      return false;
    }
    _normalSnapshot = _snapshotFor(LoopWindowMode.normal);
    _pinned = true;
    _mode = LoopWindowMode.floating;
    _lastFloatingSnapshot = _snapshotFor(LoopWindowMode.floating);
    _transitioning = false;
    notifyListeners();
    return true;
  }

  @override
  Future<bool> exitFloating({bool focus = true}) async {
    exitCalls++;
    log.add('exit');
    if (!supported) return false;
    if (_mode == LoopWindowMode.normal) return true;
    if (_transitioning || _captureInProgress) return false;
    _transitioning = true;
    notifyListeners();
    if (focus) focusCount++;
    if (exitShouldFail) {
      _transitioning = false;
      notifyListeners();
      return false;
    }
    _lastFloatingSnapshot = _snapshotFor(LoopWindowMode.floating);
    _mode = LoopWindowMode.normal;
    _pinned = false;
    _normalSnapshot = null;
    _transitioning = false;
    notifyListeners();
    return true;
  }

  @override
  Future<bool> toggleFloating({bool focus = true}) {
    toggleCalls++;
    return isFloating
        ? exitFloating(focus: focus)
        : enterFloating(focus: focus);
  }

  @override
  Future<void> setPinned(bool value) async {
    pinCalls++;
    log.add('pin:$value');
    if (_pinned == value) return;
    _pinned = value;
    notifyListeners();
  }

  @override
  Future<void> ensureGeometry() async {
    ensureGeometryCalls++;
  }

  @override
  Future<CaptureDisplay?> captureDisplay() async => const CaptureDisplay(
        id: 'test-display',
        physicalWorkArea: Rect.fromLTWH(0, 0, 1920, 1040),
      );

  @override
  Future<void> beginCaptureOverlay(CaptureDisplay display) async {
    _captureInProgress = true;
    notifyListeners();
  }

  @override
  Future<void> applySnapshot(WindowSnapshot snapshot, {bool focus = false}) async {
    _mode = snapshot.mode;
    _pinned = snapshot.pinned;
    _captureInProgress = false;
    if (focus) focusCount++;
    notifyListeners();
  }
}
