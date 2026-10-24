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
  bool _minimal = false;

  bool enterShouldFail = false;
  bool exitShouldFail = false;
  bool minimalShouldFail = false;

  int enterCalls = 0;
  int exitCalls = 0;
  int toggleCalls = 0;
  int pinCalls = 0;
  int ensureGeometryCalls = 0;
  int enterMinimalCalls = 0;
  int exitMinimalCalls = 0;
  int toggleMinimalCalls = 0;
  int focusCount = 0;

  final List<String> log = [];

  WindowSnapshot? _normalSnapshot;
  WindowSnapshot? _lastFloatingSnapshot;
  WindowSnapshot? _lastExpandedSnapshot;

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
  bool get minimal => _minimal;

  @override
  WindowSnapshot? get normalSnapshot => _normalSnapshot;

  @override
  WindowSnapshot? get lastFloatingSnapshot => _lastFloatingSnapshot;

  @override
  WindowSnapshot? get lastExpandedSnapshot => _lastExpandedSnapshot;

  /// 测试直接模拟“截图覆盖进行中”。
  set captureInProgress(bool value) {
    _captureInProgress = value;
    notifyListeners();
  }

  WindowSnapshot _snapshotFor(LoopWindowMode mode) {
    final floating = mode == LoopWindowMode.floating;
    final bar = floating && _minimal;
    return WindowSnapshot(
      mode: mode,
      bounds: floating
          ? (bar
              ? const Rect.fromLTWH(1436, 768, 460, minimalHeight)
              : const Rect.fromLTWH(1436, 220, 460, 600))
          : const Rect.fromLTWH(100, 80, 1200, 800),
      physicalBounds: floating
          ? (bar
              ? const Rect.fromLTWH(1436, 768, 460, minimalHeight)
              : const Rect.fromLTWH(1436, 220, 460, 600))
          : const Rect.fromLTWH(100, 80, 1200, 800),
      dpr: 1.0,
      maximized: false,
      alwaysOnTop: bar ? true : _pinned,
      minSize: bar
          ? minimalMinSize
          : (floating ? floatingMinSize : normalMinSize),
      pinned: _pinned,
      minimal: bar,
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
    _minimal = false;
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
    _minimal = false;
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
  Future<bool> enterMinimal({bool focus = true}) async {
    enterMinimalCalls++;
    log.add('enter-minimal');
    if (!supported) return false;
    if (!isFloating || _minimal) return isFloating;
    if (_transitioning || _captureInProgress) return false;
    _transitioning = true;
    notifyListeners();
    if (focus) focusCount++;
    if (minimalShouldFail) {
      _transitioning = false;
      notifyListeners();
      return false;
    }
    _lastExpandedSnapshot = _snapshotFor(LoopWindowMode.floating);
    _minimal = true;
    _pinned = true;
    _transitioning = false;
    notifyListeners();
    return true;
  }

  @override
  Future<bool> exitMinimal({bool focus = true}) async {
    exitMinimalCalls++;
    log.add('exit-minimal');
    if (!supported) return false;
    if (!_minimal) return true;
    if (_transitioning || _captureInProgress) return false;
    _transitioning = true;
    notifyListeners();
    if (focus) focusCount++;
    _minimal = false;
    _transitioning = false;
    notifyListeners();
    return true;
  }

  @override
  Future<bool> toggleMinimal({bool focus = true}) {
    toggleMinimalCalls++;
    return _minimal ? exitMinimal(focus: focus) : enterMinimal(focus: focus);
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
    _minimal = snapshot.mode == LoopWindowMode.floating && snapshot.minimal;
    _captureInProgress = false;
    if (focus) focusCount++;
    notifyListeners();
  }
}
