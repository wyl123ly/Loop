import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:desktop_multi_window/desktop_multi_window.dart' as dmw;
import 'package:flutter/foundation.dart';

import '../win32_display.dart';
import '../window_mode.dart';
import 'answer_protocol.dart';
import 'answer_window_platform.dart';

/// 插件第二窗口的 Win32 窗口类名（desktop_multi_window 0.3.1）。
const String answerWindowClassName = 'FLUTTER_MULTI_WINDOW_WIN32_WINDOW';

/// 主窗口 runner 的 Win32 窗口类名。
const String mainWindowClassName = 'FLUTTER_RUNNER_WIN32_WINDOW';

/// 第二引擎启动 helper：主入口分流后调用。
///
/// - 只应在 `args[0] == 'multi_window'` 分支调用；
/// - 内部 `WindowController.fromCurrentEngine()` 100ms 退避重试（≤2s）；
/// - 参数为空/协议不匹配返回 null（不是回答窗入口）；
/// - 失败写一次日志并返回 null，调用方不得静默显示空白窗口。
Future<AnswerEngineSession?> prepareAnswerEngine({
  Duration retryDelay = const Duration(milliseconds: 100),
  int maxAttempts = 20,
}) async {
  if (!Platform.isWindows) return null;
  Object? lastError;
  for (var attempt = 0; attempt < maxAttempts; attempt++) {
    try {
      final controller = await dmw.WindowController.fromCurrentEngine();
      final payload = AnswerLaunchPayload.tryParse(controller.arguments);
      if (payload == null) {
        debugPrint('answer engine: no launch payload (not an answer window)');
        return null;
      }
      if (!payload.isCompatible) {
        debugPrint(
          'answer engine: protocol mismatch (${payload.protocol} != '
          '$answerProtocolVersion)',
        );
        return null;
      }
      return AnswerEngineSession(
        windowId: controller.windowId,
        payload: payload,
        transport: AnswerTransportIo(windowId: controller.windowId),
      );
    } catch (error) {
      lastError = error;
      if (attempt < maxAttempts - 1) await Future<void>.delayed(retryDelay);
    }
  }
  debugPrint('answer engine: fromCurrentEngine failed: $lastError');
  return null;
}

/// 基于 `desktop_multi_window` WindowMethodChannel 的 IPC 传输。
///
/// 两端共用：主引擎注册 control handler / 发 stream；第二引擎注册 stream
/// handler / 发 control（unidirectional 模式下一个通道只有一个 handler）。
class AnswerTransportIo implements AnswerTransport {
  AnswerTransportIo({required this.windowId});

  final String windowId;

  late final dmw.WindowMethodChannel _stream = dmw.WindowMethodChannel(
    answerStreamChannel(windowId),
    mode: dmw.ChannelMode.unidirectional,
  );

  late final dmw.WindowMethodChannel _control = dmw.WindowMethodChannel(
    answerControlChannel(windowId),
    mode: dmw.ChannelMode.unidirectional,
  );

  bool _connected = true;

  @override
  bool get connected => _connected;

  Future<void> _invoke(
    dmw.WindowMethodChannel channel,
    String method,
    Map<String, Object?> arguments,
  ) async {
    try {
      await channel.invokeMethod<Object?>(method, arguments);
      _connected = true;
    } on dmw.WindowChannelException catch (error) {
      _connected = false;
      debugPrint('answer ipc $method failed: ${error.code}');
      rethrow;
    }
  }

  @override
  Future<void> sendStream(String method, Map<String, Object?> arguments) =>
      _invoke(_stream, method, arguments);

  @override
  Future<void> sendControl(String method, Map<String, Object?> arguments) =>
      _invoke(_control, method, arguments);

  @override
  Future<void> setStreamHandler(AnswerMessageHandler? handler) async {
    await _stream.setMethodCallHandler(
      handler == null
          ? null
          : (call) => handler(call.method, asStringMap(call.arguments)),
    );
  }

  @override
  Future<void> setControlHandler(AnswerMessageHandler? handler) async {
    await _control.setMethodCallHandler(
      handler == null
          ? null
          : (call) => handler(call.method, asStringMap(call.arguments)),
    );
  }

  @override
  Future<void> dispose() async {
    try {
      await _stream.setMethodCallHandler(null);
    } catch (_) {}
    try {
      await _control.setMethodCallHandler(null);
    } catch (_) {}
  }
}

/// 主引擎的回答窗平台实现：`desktop_multi_window` 创建 + 主引擎 Win32 FFI
/// 完成样式/几何/显示/关闭/焦点补偿。**第二引擎不使用本类。**
class DesktopAnswerWindowPlatform implements AnswerWindowPlatform {
  DesktopAnswerWindowPlatform({
    this.mainWindowHwnd,
    this.focusMain,
  });

  final Future<int?> Function()? mainWindowHwnd;
  final Future<void> Function()? focusMain;

  int? _cachedMainHwnd;

  @override
  bool get supported => Platform.isWindows;

  Future<int?> _mainHwnd() async {
    final cached = _cachedMainHwnd;
    if (cached != null) return cached;
    try {
      final hwnd = await mainWindowHwnd?.call();
      _cachedMainHwnd = hwnd;
      return hwnd;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<AnswerWindowHandle> create({
    required AnswerLaunchPayload payload,
  }) async {
    final controller = await dmw.WindowController.create(
      dmw.WindowConfiguration(
        arguments: payload.toJsonString(),
        hiddenAtLaunch: true,
      ),
    );
    final hwnd = await _awaitAnswerHwnd();
    return AnswerWindowHandle(windowId: controller.windowId, hwnd: hwnd);
  }

  /// 枚举本进程内 `FLUTTER_MULTI_WINDOW_WIN32_WINDOW` 类窗口，排除主窗口。
  Future<int?> _awaitAnswerHwnd() async {
    for (var attempt = 0; attempt < 40; attempt++) {
      try {
        final pid = Win32Display.currentProcessId();
        final main = await _mainHwnd();
        final candidates = Win32Display.windowsOfClass(answerWindowClassName)
            .where(
              (hwnd) =>
                  Win32Display.windowProcessId(hwnd) == pid && hwnd != main,
            )
            .toList();
        if (candidates.isNotEmpty) return candidates.first;
      } catch (error) {
        debugPrint('answer hwnd lookup failed: $error');
      }
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    return null;
  }

  @override
  Future<void> configure(
    AnswerWindowHandle handle, {
    required Rect physical,
    required bool topmost,
  }) async {
    final hwnd = handle.hwnd;
    if (hwnd == null) {
      throw StateError('answer HWND unavailable (windowId=${handle.windowId})');
    }
    if (!Win32Display.applyAnswerWindowChrome(hwnd, topmost: topmost)) {
      final style = Win32Display.windowStyle(hwnd).toRadixString(16);
      final ex = Win32Display.windowExStyle(hwnd).toRadixString(16);
      debugPrint(
        'applyAnswerWindowChrome failed hwnd=$hwnd style=0x$style ex=0x$ex',
      );
    }
    Win32Display.setWindowTitle(hwnd, 'Loop 回答');
    if (!Win32Display.setWindowPos(hwnd, physical, topmost: topmost)) {
      throw StateError('SetWindowPos(answer) failed hwnd=$hwnd');
    }
  }

  @override
  Future<void> setBounds(
    AnswerWindowHandle handle,
    Rect physical, {
    bool topmost = true,
  }) async {
    final hwnd = handle.hwnd;
    if (hwnd == null) return;
    Win32Display.setWindowPos(hwnd, physical, topmost: topmost);
  }

  @override
  Future<void> showNoActivate(
    AnswerWindowHandle handle, {
    bool topmost = true,
  }) async {
    final hwnd = handle.hwnd;
    if (hwnd == null) return;
    Win32Display.showNoActivateWindow(hwnd);
    if (topmost) Win32Display.raiseNoActivate(hwnd);
  }

  @override
  Future<void> hide(AnswerWindowHandle handle) async {
    final hwnd = handle.hwnd;
    if (hwnd == null) return;
    Win32Display.hideWindow(hwnd);
  }

  @override
  Future<void> bringToTop(AnswerWindowHandle handle) async {
    final hwnd = handle.hwnd;
    if (hwnd == null) return;
    Win32Display.raiseNoActivate(hwnd);
  }

  @override
  Future<void> close(AnswerWindowHandle handle) async {
    var hwnd = handle.hwnd;
    hwnd ??= await _awaitAnswerHwnd();
    if (hwnd != null) Win32Display.postClose(hwnd);
  }

  @override
  Future<bool> isAlive(AnswerWindowHandle handle) async {
    final hwnd = handle.hwnd;
    if (hwnd != null) return Win32Display.isWindow(hwnd);
    return (await listWindowIds()).contains(handle.windowId);
  }

  @override
  Future<List<String>> listWindowIds() async {
    try {
      final windows = await dmw.WindowController.getAll();
      return windows.map((window) => window.windowId).toList();
    } catch (error) {
      debugPrint('listWindowIds failed: $error');
      return const <String>[];
    }
  }

  @override
  Stream<void> get windowsChanged => dmw.onWindowsChanged;

  @override
  Future<void> focusMainWindow() async {
    final hwnd = await _mainHwnd();
    if (hwnd != null) Win32Display.setForeground(hwnd);
    try {
      await focusMain?.call();
    } catch (error) {
      debugPrint('answer focus compensation failed: $error');
    }
  }

  @override
  Future<List<DisplayInfo>> displays() async {
    try {
      return Win32Display.displays();
    } catch (error) {
      debugPrint('answer displays failed: $error');
      return const <DisplayInfo>[];
    }
  }

  @override
  Future<AnswerTransport> openTransport(AnswerWindowHandle handle) async =>
      AnswerTransportIo(windowId: handle.windowId);

  @override
  Future<void> dispose() async {}
}
