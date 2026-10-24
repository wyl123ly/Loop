import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'hotkeys_types.dart';

/// Windows 桌面端的全局快捷键服务（原生 RegisterHotKey + `loop/hotkeys`）。
///
/// 非 Windows 桌面/通道缺失时返回 [HotkeyStatus.unsupported] 或 failed，
/// 按钮仍然可用。
class HotkeyService {
  HotkeyService._()
      : _controller = HotkeyController(
          transport: _MethodChannelHotkeyTransport(),
        );

  static final HotkeyService instance = HotkeyService._();

  final HotkeyController _controller;

  ValueNotifier<HotkeyStatus> get status => _controller.status;

  ValueNotifier<HotkeyRegistration?> get registration => _controller.registration;

  /// 注册/重试（幂等；单个键冲突不影响另一个键）。
  Future<HotkeyRegistration> register({
    VoidCallback? onToggle,
    VoidCallback? onScreenshot,
  }) =>
      _controller.register(onToggle: onToggle, onScreenshot: onScreenshot);

  Future<HotkeyRegistration> retry({
    VoidCallback? onToggle,
    VoidCallback? onScreenshot,
  }) =>
      _controller.retry(onToggle: onToggle, onScreenshot: onScreenshot);

  /// 注销并释放（退出应用时调用）。
  Future<void> unregister() => _controller.unregister();

  /// 原生 WM_HOTKEY 回调入口；仅用于测试或原生桥接。
  void handleHotkey(int id) => _controller.handleHotkey(id);

  @visibleForTesting
  void dispose() => _controller.dispose();
}

class _MethodChannelHotkeyTransport implements HotkeyTransport {
  _MethodChannelHotkeyTransport() {
    if (!Platform.isWindows) {
      _unsupported = true;
      return;
    }
    _channel.setMethodCallHandler(_handleMethodCall);
  }

  static const MethodChannel _channel = MethodChannel('loop/hotkeys');

  bool _unsupported = false;
  void Function(int id)? _handler;

  Future<Object?> _handleMethodCall(MethodCall call) async {
    if (call.method == 'hotkey') {
      final id = call.arguments;
      if (id is int) _handler?.call(id);
    }
    return null;
  }

  @override
  Future<HotkeyRegistration> register() async {
    if (_unsupported) return const HotkeyRegistration.unsupported();
    try {
      final result = await _channel.invokeMethod<Object?>('register');
      return HotkeyRegistration.fromNative(result);
    } on MissingPluginException {
      _unsupported = true;
      return const HotkeyRegistration.unsupported();
    } on PlatformException catch (error) {
      debugPrint('hotkey platform error: $error');
      return const HotkeyRegistration.failed();
    }
  }

  @override
  Future<void> unregister() async {
    if (_unsupported) return;
    try {
      await _channel.invokeMethod<Object?>('unregister');
    } on MissingPluginException {
      _unsupported = true;
    } on PlatformException catch (error) {
      debugPrint('hotkey unregister error: $error');
    }
  }

  @override
  void bind(void Function(int id) handler) {
    _handler = handler;
  }
}
