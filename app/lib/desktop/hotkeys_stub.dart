import 'package:flutter/foundation.dart';

import 'hotkeys_types.dart';

/// Web/非桌面占位：快捷键不可用，但保持与 io 完全相同的 API。
class HotkeyService {
  HotkeyService._()
      : _controller = HotkeyController(
          transport: const _UnsupportedHotkeyTransport(),
        );

  static final HotkeyService instance = HotkeyService._();

  final HotkeyController _controller;

  ValueNotifier<HotkeyStatus> get status => _controller.status;

  ValueNotifier<HotkeyRegistration?> get registration => _controller.registration;

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

  Future<void> unregister() => _controller.unregister();

  void handleHotkey(int id) => _controller.handleHotkey(id);

  @visibleForTesting
  void dispose() => _controller.dispose();
}

class _UnsupportedHotkeyTransport implements HotkeyTransport {
  const _UnsupportedHotkeyTransport();

  @override
  Future<HotkeyRegistration> register() async =>
      const HotkeyRegistration.unsupported();

  @override
  Future<void> unregister() async {}

  @override
  void bind(void Function(int id) handler) {}
}
