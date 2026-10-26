import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

import 'answer_host/answer_transport_io.dart';
import 'answer_host/answer_window_host.dart';
import 'dwm.dart';
import 'floating_signals.dart';
import 'floating_window.dart';
import 'hotkeys.dart';
import 'minimal_window.dart';
import '../cloud/cloud_sync_coordinator.dart';
import 'screenshot_service.dart';
import 'system_scale.dart';
import 'win32_display.dart';
import 'window_mode.dart';
import 'window_resize_edge.dart';

/// 桌面窗口控制器：单例、唯一 Flutter 窗口。
///
/// v0.5.0 起：
/// - `floating` 持有 normal/floating 状态机（所有形态变更都经它）；
/// - `init()` 注册 `Alt+Q`/`Alt+A`（只投递信号，不在该层截图/上传）；
/// - 显示器/DPI 变化触发 `floating.ensureGeometry()`（去抖、不 focus）；
/// - `show({focus})` 拆分焦点策略（托盘显示仍可 focus 一次）。
class WindowController with WindowListener, ScreenListener {
  WindowController._();

  static final WindowController instance = WindowController._();

  final ValueNotifier<bool> maximized = ValueNotifier<bool>(false);
  final ValueNotifier<bool> readyNotifier = ValueNotifier<bool>(false);
  final ValueNotifier<bool> resizing = ValueNotifier<bool>(false);
  /// T5-05：主窗几何/形态变化 tick；UI 监听后重报回答窗 anchor rect。
  final ValueNotifier<int> geometryEpoch = ValueNotifier<int>(0);
  Timer? _resizeTimer;
  bool _floatingGeometryListenerAttached = false;

  final _DesktopWindowPlatform _platform = _DesktopWindowPlatform();

  /// 浮窗形态宿主（t3 的 Shell / FloatingBar 只依赖它的抽象接口）。
  late final FloatingWindowController floating = FloatingWindowController(
    _platform,
    onError: (message) => floatingError.value = message,
  );

  /// 回答浮窗宿主：第二顶层窗口 + IPC + 动态尺寸（t3 提交钩子调用）。
  late final AnswerWindowHost answers = AnswerWindowHost(
    platform: DesktopAnswerWindowPlatform(
      mainWindowHwnd: () => hwnd(),
      focusMain: () async {
        if (!ready) return;
        try {
          await windowManager.focus();
        } catch (error) {
          debugPrint('answer focus main failed: $error');
        }
      },
    ),
    onError: (message) => answerError.value = message,
    onPresenceChanged: _onAnswerPresenceChanged,
  );

  /// 形态切换失败的提示（UI 可监听并 snack 一次）。
  final ValueNotifier<String?> floatingError = ValueNotifier<String?>(null);

  /// 回答浮窗创建/渲染失败的提示（主聊天继续；显式失败，不静默降级）。
  final ValueNotifier<String?> answerError = ValueNotifier<String?>(null);

  /// 平台截图服务（ChatScreen 可注入 fake；默认走 ScreenshotCapture）。
  final ScreenshotService screenshots = const PlatformScreenshotService();

  bool get ready => readyNotifier.value;
  bool get isFloating => floating.isFloating;
  LoopWindowMode get mode => floating.mode;
  bool trayActive = false;

  int? _hwnd;
  bool _screenListenerAttached = false;
  bool _closing = false;
  bool _quitting = false;
  Timer? _minimalTriggerTimer;

  Future<void> init() async {
    try {
      await windowManager.ensureInitialized();
      await windowManager.setAsFrameless();
      await windowManager.setResizable(true);
      await windowManager.setBackgroundColor(Colors.transparent);
      await windowManager.setMinimumSize(normalMinSize);
      var initialSize = const Size(1440, 900);
      var initialPosition = const Offset(24, 24);
      try {
        final display = await screenRetriever.getPrimaryDisplay();
        final screen = display.size;
        final width = (screen.width - 80).clamp(900.0, 1440.0);
        final height = (screen.height - 80).clamp(600.0, 900.0);
        initialSize = Size(width, height);
        initialPosition = Offset(
          ((screen.width - width) / 2).clamp(0.0, double.infinity),
          ((screen.height - height) / 2).clamp(0.0, double.infinity),
        );
      } catch (_) {}
      await windowManager.setSize(initialSize);
      await windowManager.setPosition(initialPosition);
      await windowManager.show();
      await windowManager.focus();
      windowManager.addListener(this);
      if (!_screenListenerAttached) {
        try {
          screenRetriever.addListener(this);
          _screenListenerAttached = true;
        } catch (error) {
          debugPrint('screen listener attach failed: $error');
        }
      }
      maximized.value = await windowManager.isMaximized();
      final (rounded, hwnd) = applyDwmRoundedCorners();
      _hwnd = hwnd == 0 ? null : hwnd;
      debugPrint('dwm round corners: $rounded hwnd=$hwnd');
      readyNotifier.value = true;
      if (!_floatingGeometryListenerAttached) {
        floating.addListener(_bumpGeometry);
        _floatingGeometryListenerAttached = true;
      }
      // 快捷键注册失败不阻塞启动，按钮始终可用（规格 §8.3）。
      await _registerHotkeys();
    } catch (error) {
      debugPrint('window init failed: $error');
      readyNotifier.value = false;
    }
  }

  Future<void> _registerHotkeys() async {
    try {
      final result = await HotkeyService.instance.register(
        onToggle: _onHotkeyToggle,
        onScreenshot: _onHotkeyScreenshot,
      );
      debugPrint('hotkeys: $result');
    } catch (error) {
      debugPrint('hotkey register failed: $error');
    }
  }

  Future<void> enableTray() async {
    trayActive = true;
    await _syncPreventClose();
  }

  /// 回答窗存在期间主窗口必须 preventClose（避免原生 WM_CLOSE 先销毁主窗
  /// 留下孤儿；规格 §2.9）。
  Future<void> _syncPreventClose() async {
    if (!ready) return;
    final shouldPrevent = trayActive || answers.hasWindow;
    try {
      await windowManager.setPreventClose(shouldPrevent);
    } catch (error) {
      debugPrint('setPreventClose($shouldPrevent) failed: $error');
    }
  }

  void _onAnswerPresenceChanged(bool present) async {
    await _syncPreventClose();
  }

  /// T5-05：通知 UI 主窗几何/形态已变化（DEBOUNCE 由 Shell post-frame 合并）。
  void _bumpGeometry() {
    geometryEpoch.value++;
  }

  /// 显示窗口。仅托盘“显示回路”/启动等白名单路径允许 `focus: true`。
  Future<void> show({bool focus = true}) async {
    await _platform.show();
    await answers.restoreVisibility();
    if (focus) await _platform.focus();
  }

  /// 只显示不聚焦（例如显示器校正/后台恢复）。
  Future<void> showInactive() => show(focus: false);

  /// 用户动作后最多一次聚焦。
  Future<void> focusOnce() async {
    if (!ready) return;
    await windowManager.focus();
  }

  Future<void> quit() async {
    if (_quitting) return;
    try {
      if (!await windowManager.isVisible()) {
        await windowManager.show();
        await windowManager.focus();
      }
    } catch (_) {}
    if (!await CloudSyncCoordinator.instance.beforeExit()) return;
    _quitting = true;
    trayActive = false;
    _minimalTriggerTimer?.cancel();
    _minimalTriggerTimer = null;
    // 先关回答窗，再退主窗；否则主窗先关会留下孤儿进程（规格 §2.9）。
    try {
      await answers.shutdown();
    } catch (error) {
      debugPrint('answer shutdown failed: $error');
    }
    try {
      await HotkeyService.instance.unregister();
    } catch (error) {
      debugPrint('hotkey unregister failed: $error');
    }
    if (_screenListenerAttached) {
      try {
        screenRetriever.removeListener(this);
      } catch (_) {}
      _screenListenerAttached = false;
    }
    floating.dispose();
    try {
      await windowManager.setPreventClose(false);
    } catch (error) {
      debugPrint('setPreventClose(false) failed: $error');
    }
    await windowManager.close();
  }

  /// DPI/缩放变化（由 Shell 的 `didChangeMetrics` 调用）。不 focus、不改 mode。
  void onMetricsChanged() {
    floating.scheduleEnsureGeometry();
    _bumpGeometry();
    unawaited(answers.ensureOnScreen());
  }

  @override
  void onScreenEvent(String eventName) {
    floating.scheduleEnsureGeometry();
    _bumpGeometry();
    unawaited(answers.ensureOnScreen());
  }

  @override
  void onWindowResize() {
    resizing.value = true;
    _resizeTimer?.cancel();
    _resizeTimer = Timer(const Duration(milliseconds: 220), () {
      resizing.value = false;
    });
  }

  @override
  void onWindowResized() {
    _resizeTimer?.cancel();
    resizing.value = false;
    _maybeEnterMinimalAfterResize();
    unawaited(_notifyMainWindowGeometry());
    _bumpGeometry();
  }

  @override
  void onWindowMoved() {
    unawaited(_notifyMainWindowGeometry());
    _bumpGeometry();
  }

  @override
  void onWindowMinimize() {
    // 主窗最小化：回答窗一并隐藏（保留引擎/状态），恢复时无激活显示。
    unawaited(answers.hide());
  }

  @override
  void onWindowRestore() {
    unawaited(answers.restoreVisibility());
  }

  @override
  void onWindowFocus() {
    // 主窗重新激活：无激活把回答窗抬到最上层，不改变焦点（规格 §2.8）。
    unawaited(answers.bringToFront());
  }

  @override
  void onWindowClose() {
    if (_quitting) return;
    if (trayActive) {
      // 关闭到托盘：隐藏而不是退出；回答窗随之隐藏（不销毁）。
      unawaited(_hideToTray());
      return;
    }
    unawaited(_closeWithAnswerCleanup());
  }

  Future<void> _hideToTray() async {
    await answers.hide();
    await windowManager.hide();
  }

  /// 主窗关闭顺序：先关回答窗（≤1s+兜底 500ms）再恢复 preventClose 并关主窗。
  Future<void> _closeWithAnswerCleanup() async {
    if (_closing) return;
    if (!await CloudSyncCoordinator.instance.beforeExit()) return;
    _closing = true;
    try {
      await answers.shutdown();
    } catch (error) {
      debugPrint('answer shutdown before close failed: $error');
    }
    try {
      await windowManager.setPreventClose(false);
    } catch (error) {
      debugPrint('setPreventClose(false) failed: $error');
    }
    try {
      await windowManager.close();
    } catch (error) {
      debugPrint('window close failed: $error');
    } finally {
      _closing = false;
    }
  }

  Future<void> _notifyMainWindowGeometry() async {
    if (!ready) return;
    try {
      final rect = await _platform.physicalRect();
      await answers.onMainWindowMoved(rect);
    } catch (error) {
      debugPrint('answer main window geometry sync failed: $error');
    }
  }

  /// 用户把浮窗缩放到最小（360×420）后 250ms 去抖进入极简条（规格 §3.3）。
  void _maybeEnterMinimalAfterResize() {
    if (!ready) return;
    if (!floating.isFloating || floating.minimal) return;
    if (floating.transitioning || floating.captureInProgress) return;
    _minimalTriggerTimer?.cancel();
    _minimalTriggerTimer = Timer(minimalEnterDelay, () async {
      if (!ready ||
          !floating.isFloating ||
          floating.minimal ||
          floating.transitioning ||
          floating.captureInProgress) {
        return;
      }
      try {
        final physical = await _platform.physicalRect();
        final dpr = FloatingWindowPlanner.normalizedDpr(await _platform.dpr());
        final logical = Rect.fromLTWH(
          physical.left / dpr,
          physical.top / dpr,
          physical.width / dpr,
          physical.height / dpr,
        );
        if (!MinimalWindowPlanner.isAtFloatingMinimum(logical)) return;
        await floating.enterMinimal();
      } catch (error) {
        debugPrint('auto enter minimal failed: $error');
      }
    });
  }

  @override
  void onWindowMaximize() {
    maximized.value = true;
    resizing.value = false;
    _bumpGeometry();
  }

  @override
  void onWindowUnmaximize() {
    maximized.value = false;
    resizing.value = false;
    _bumpGeometry();
  }

  Future<void> startResizing(LoopResizeEdge edge) async {
    if (!ready) return;
    final map = {
      LoopResizeEdge.top: ResizeEdge.top,
      LoopResizeEdge.topLeft: ResizeEdge.topLeft,
      LoopResizeEdge.topRight: ResizeEdge.topRight,
      LoopResizeEdge.left: ResizeEdge.left,
      LoopResizeEdge.right: ResizeEdge.right,
      LoopResizeEdge.bottom: ResizeEdge.bottom,
      LoopResizeEdge.bottomLeft: ResizeEdge.bottomLeft,
      LoopResizeEdge.bottomRight: ResizeEdge.bottomRight,
    };
    await windowManager.startResizing(map[edge]!);
  }

  Future<void> startDragging() async {
    if (!ready) return;
    await windowManager.startDragging();
  }

  Future<void> minimize() async {
    if (!ready) return;
    await windowManager.minimize();
  }

  /// 最大化只在普通窗口可用；浮窗 no-op（规格 §4.5）。
  Future<void> toggleMaximize() async {
    if (!ready) return;
    if (floating.isFloating) return;
    if (await windowManager.isMaximized()) {
      await windowManager.unmaximize();
    } else {
      await windowManager.maximize();
    }
  }

  Future<void> close() async {
    if (!ready) return;
    await windowManager.close();
  }

  // -------------------------------------------------------------------------
  // 快捷键回调：只投递动作/信号，不截图、不上传、不抢焦点。
  // -------------------------------------------------------------------------

  void _onHotkeyToggle() {
    unawaited(_toggleFromHotkey());
  }

  Future<void> _toggleFromHotkey() async {
    if (!ready || floating.transitioning || floating.captureInProgress) return;
    try {
      final visible = await windowManager.isVisible();
      final minimized = await windowManager.isMinimized();
      if (!visible || minimized) {
        // 最小化/托盘隐藏：只显示，不切换形态（规格 §8.1）。
        await _platform.show();
        await _platform.focus();
        return;
      }
      await floating.toggleFloating(focus: true);
    } catch (error) {
      debugPrint('Alt+Q toggle failed: $error');
    }
  }

  void _onHotkeyScreenshot() {
    unawaited(_requestScreenshotFromHotkey());
  }

  Future<void> _requestScreenshotFromHotkey() async {
    if (!ready || floating.transitioning || floating.captureInProgress) return;
    try {
      final visible = await windowManager.isVisible();
      final minimized = await windowManager.isMinimized();
      if (!visible || minimized) return; // 不抢焦点、不后台采集
      requestScreenshot(hideLoop: floating.isFloating);
    } catch (error) {
      debugPrint('Alt+A request failed: $error');
    }
  }

  /// 供测试/诊断读取 HWND（失败返回 null）。
  Future<int?> hwnd() async {
    if (_hwnd != null) return _hwnd;
    try {
      final id = await windowManager.getId();
      if (id != 0) _hwnd = id;
      return _hwnd;
    } catch (_) {
      return null;
    }
  }
}

// ---------------------------------------------------------------------------
// WindowPlatform 的桌面实现：window_manager + Win32。
// ---------------------------------------------------------------------------

class _DesktopWindowPlatform implements WindowPlatform {
  int? _hwnd;

  @override
  bool get supported => Platform.isWindows;

  Future<int> _windowHandle() async {
    final cached = _hwnd;
    if (cached != null) return cached;
    final id = await windowManager.getId();
    _hwnd = id;
    return id;
  }

  @override
  Future<WindowSnapshot> snapshot() async {
    final ratio = await dpr();
    final physical = await physicalRect();
    final maximized = await isMaximized();
    final hwnd = await hwndOrNull();
    // 最大化时必须单独保存 restore-down placement，GetWindowRect 只是最大化矩形。
    final normalPlacement = maximized && hwnd != null
        ? Win32Display.normalPlacement(hwnd)
        : null;
    return WindowSnapshot(
      mode: LoopWindowMode.normal,
      bounds: Rect.fromLTWH(
        physical.left / ratio,
        physical.top / ratio,
        physical.width / ratio,
        physical.height / ratio,
      ),
      physicalBounds: physical,
      dpr: ratio,
      maximized: maximized,
      alwaysOnTop: await isAlwaysOnTop(),
      minSize: normalMinSize,
      displayId: Win32Display.displayIdAt(physical.center),
      normalPlacement: normalPlacement,
    );
  }

  @override
  Future<void> setMinimumSize(Size logical) =>
      windowManager.setMinimumSize(logical);

  @override
  Future<void> setAlwaysOnTop(bool value) =>
      windowManager.setAlwaysOnTop(value);

  @override
  Future<bool> isAlwaysOnTop() async {
    try {
      return await windowManager.isAlwaysOnTop();
    } catch (_) {
      final hwnd = await hwndOrNull();
      return hwnd != null && Win32Display.isAlwaysOnTop(hwnd);
    }
  }

  @override
  Future<void> setBoundsPhysical(Rect physical) async {
    final hwnd = await hwndOrNull();
    if (hwnd == null) throw StateError('HWND unavailable');
    if (!Win32Display.setWindowPos(hwnd, physical, topmost: false)) {
      throw StateError('SetWindowPos failed');
    }
  }

  @override
  Future<void> setBoundsLogical(Rect logical) => windowManager.setBounds(logical);

  @override
  Future<bool> setWindowPlacement(
    Rect normalPlacement, {
    required bool maximized,
  }) async {
    final hwnd = await hwndOrNull();
    if (hwnd == null) return false;
    return Win32Display.setWindowPlacement(
      hwnd,
      normalPlacement,
      maximized: maximized,
    );
  }

  @override
  Future<Rect> physicalRect() async {
    final hwnd = await hwndOrNull();
    if (hwnd != null) {
      final rect = Win32Display.windowRect(hwnd);
      if (rect != null) return rect;
    }
    // 兜底：逻辑 bounds × dpr（已知限制，日志记录一次）。
    final ratio = await dpr();
    final bounds = await windowManager.getBounds();
    debugPrint('physicalRect fallback to logical bounds');
    return Rect.fromLTWH(
      bounds.left * ratio,
      bounds.top * ratio,
      bounds.width * ratio,
      bounds.height * ratio,
    );
  }

  @override
  Future<double> dpr() async {
    try {
      final ratio = windowManager.getDevicePixelRatio();
      if (ratio.isFinite && ratio > 0) {
        return FloatingWindowPlanner.normalizedDpr(ratio);
      }
    } catch (_) {}
    final hwnd = await hwndOrNull();
    if (hwnd != null) {
      final scale = Win32Display.scaleForWindow(hwnd);
      if (scale.isFinite && scale > 0) {
        return FloatingWindowPlanner.normalizedDpr(scale);
      }
    }
    return FloatingWindowPlanner.normalizedDpr(systemScaleFactor());
  }

  @override
  Future<bool> isMaximized() => windowManager.isMaximized();

  @override
  Future<void> maximize() => windowManager.maximize();

  @override
  Future<void> unmaximize() => windowManager.unmaximize();

  @override
  Future<void> show() async {
    final hwnd = await hwndOrNull();
    if (hwnd != null && Win32Display.isMinimized(hwnd)) {
      if (Win32Display.restoreNoActivate(hwnd)) return;
    }
    if (hwnd != null && Win32Display.showNoActivate(hwnd)) return;
    await windowManager.show(); // 非 Windows/FFI 失败回退（可能聚焦）
  }

  @override
  Future<void> hide() => windowManager.hide();

  @override
  Future<bool> isVisible() => windowManager.isVisible();

  @override
  Future<void> focus() => windowManager.focus();

  @override
  Future<void> restore() => windowManager.restore();

  @override
  Future<void> setResizable(bool value) => windowManager.setResizable(value);

  @override
  Future<List<DisplayInfo>> displays() async {
    final win32 = Win32Display.displays();
    if (win32.isNotEmpty) return win32;
    // screen_retriever 回退：把逻辑 work area 还原成物理像素。
    try {
      final all = await screenRetriever.getAllDisplays();
      Display? primary;
      try {
        primary = await screenRetriever.getPrimaryDisplay();
      } catch (_) {}
      final result = <DisplayInfo>[];
      for (final display in all) {
        final scale = FloatingWindowPlanner.normalizedDpr(
          display.scaleFactor?.toDouble(),
        );
        final position = display.visiblePosition ?? Offset.zero;
        final size = display.visibleSize ?? display.size;
        // screen_retriever 的 visible* 是“逻辑像素”（已除以 scaleFactor），
        // 乘回 scaleFactor 还原为物理像素。
        final physical = Rect.fromLTWH(
          position.dx * scale,
          position.dy * scale,
          size.width * scale,
          size.height * scale,
        );
        result.add(
          DisplayInfo(
            id: display.id,
            physicalBounds: physical,
            physicalWorkArea: physical,
            scaleFactor: scale,
            isPrimary: primary?.id == display.id,
          ),
        );
      }
      return result;
    } catch (error) {
      debugPrint('displays fallback failed: $error');
      return const <DisplayInfo>[];
    }
  }

  @override
  Future<String?> displayIdAt(Offset physicalPoint) async =>
      Win32Display.displayIdAt(physicalPoint);

  Future<int?> hwndOrNull() async {
    try {
      return await _windowHandle();
    } catch (_) {
      return null;
    }
  }
}
