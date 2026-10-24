import 'dart:async';
import 'dart:ui';

import '../window_mode.dart';
import 'answer_protocol.dart';

/// 第二顶层窗口句柄（windowId 由 desktop_multi_window 生成；hwnd 由主引擎枚举）。
class AnswerWindowHandle {
  const AnswerWindowHandle({required this.windowId, this.hwnd});

  final String windowId;

  /// Win32 HWND（物理窗口操作；枚举失败时为 null）。
  final int? hwnd;

  @override
  String toString() => 'AnswerWindowHandle(windowId=$windowId, hwnd=$hwnd)';
}

/// 回答窗平台接口（冻结；io 实现用 desktop_multi_window + Win32 FFI）。
///
/// 主引擎通过它完成窗口的创建/样式/几何/显示/关闭；第二引擎不依赖它。
abstract class AnswerWindowPlatform {
  bool get supported;

  /// 创建隐藏的第二顶层窗口（`hiddenAtLaunch: true`）。
  Future<AnswerWindowHandle> create({required AnswerLaunchPayload payload});

  /// 应用无边框/置顶/无激活/工具窗口样式，并在隐藏状态写入物理矩形。
  Future<void> configure(
    AnswerWindowHandle handle, {
    required Rect physical,
    required bool topmost,
  });

  /// 无激活移动/缩放（`SetWindowPos` + `SWP_NOACTIVATE`）。
  Future<void> setBounds(
    AnswerWindowHandle handle,
    Rect physical, {
    bool topmost = true,
  });

  /// 无激活显示（`SW_SHOWNOACTIVATE`）。
  Future<void> showNoActivate(AnswerWindowHandle handle, {bool topmost = true});

  Future<void> hide(AnswerWindowHandle handle);

  /// 主窗口重新激活时把回答窗无激活抬到最上层（不改变焦点）。
  Future<void> bringToTop(AnswerWindowHandle handle);

  /// `PostMessage(WM_CLOSE)`。
  Future<void> close(AnswerWindowHandle handle);

  /// 窗口是否仍存在（HWND 有效性；hwnd 缺失时按 windowId 列表判断）。
  Future<bool> isAlive(AnswerWindowHandle handle);

  /// 当前进程内所有插件窗口 id（含主窗口；用于孤儿/外部关闭检测）。
  Future<List<String>> listWindowIds();

  /// 窗口列表变化（`onWindowsChanged`）；不支持时返回空流。
  Stream<void> get windowsChanged;

  /// 创建补偿：把前台与输入焦点还给主窗口（≤100ms，一次性）。
  Future<void> focusMainWindow();

  /// 显示器信息（目标工作区/DPI；失败返回空列表）。
  Future<List<DisplayInfo>> displays();

  /// 打开指定窗口的 IPC 传输。
  Future<AnswerTransport> openTransport(AnswerWindowHandle handle);

  Future<void> dispose();
}

/// 不支持多窗口（Web/非 Windows/未初始化）的占位实现。
class UnsupportedAnswerWindowPlatform implements AnswerWindowPlatform {
  const UnsupportedAnswerWindowPlatform();

  @override
  bool get supported => false;

  @override
  Future<AnswerWindowHandle> create({
    required AnswerLaunchPayload payload,
  }) async =>
      throw UnsupportedError('answer window unsupported');

  @override
  Future<void> configure(
    AnswerWindowHandle handle, {
    required Rect physical,
    required bool topmost,
  }) async {}

  @override
  Future<void> setBounds(
    AnswerWindowHandle handle,
    Rect physical, {
    bool topmost = true,
  }) async {}

  @override
  Future<void> showNoActivate(
    AnswerWindowHandle handle, {
    bool topmost = true,
  }) async {}

  @override
  Future<void> hide(AnswerWindowHandle handle) async {}

  @override
  Future<void> bringToTop(AnswerWindowHandle handle) async {}

  @override
  Future<void> close(AnswerWindowHandle handle) async {}

  @override
  Future<bool> isAlive(AnswerWindowHandle handle) async => false;

  @override
  Future<List<String>> listWindowIds() async => const <String>[];

  @override
  Stream<void> get windowsChanged => const Stream<void>.empty();

  @override
  Future<void> focusMainWindow() async {}

  @override
  Future<List<DisplayInfo>> displays() async => const <DisplayInfo>[];

  @override
  Future<AnswerTransport> openTransport(AnswerWindowHandle handle) async =>
      throw UnsupportedError('answer window unsupported');

  @override
  Future<void> dispose() async {}
}
