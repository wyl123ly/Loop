import 'package:flutter/foundation.dart';

import 'window_mode.dart';

/// Windows `RegisterHotKey` 冲突错误码（ERROR_HOTKEY_ALREADY_REGISTERED）。
const int hotkeyConflictErrorCode = 1409;

/// 快捷键状态（规格 §8.3，t3 的 TitleBar tooltip 直接读取）。
enum HotkeyStatus {
  bothRegistered,
  toggleConflict,
  screenshotConflict,
  bothConflict,
  unsupported,
  failed,
}

extension HotkeyStatusX on HotkeyStatus {
  bool get isSupported => this != HotkeyStatus.unsupported;

  bool get hasConflict =>
      this == HotkeyStatus.toggleConflict ||
      this == HotkeyStatus.screenshotConflict ||
      this == HotkeyStatus.bothConflict;

  bool get toggleRegistered =>
      this == HotkeyStatus.bothRegistered ||
      this == HotkeyStatus.screenshotConflict;

  bool get screenshotRegistered =>
      this == HotkeyStatus.bothRegistered ||
      this == HotkeyStatus.toggleConflict;

  /// 主窗口“浮窗答疑”按钮 tooltip 文案（按钮始终可用）。
  String get toggleTooltip {
    switch (this) {
      case HotkeyStatus.unsupported:
        return '浮窗答疑（当前平台不支持快捷键，可用按钮）';
      case HotkeyStatus.toggleConflict:
      case HotkeyStatus.bothConflict:
        return '浮窗答疑（Alt+Q 被占用，可用按钮）';
      case HotkeyStatus.failed:
        return '浮窗答疑（Alt+Q 注册失败，可用按钮）';
      default:
        return '浮窗答疑 (Alt+Q)';
    }
  }

  String get screenshotTooltip {
    switch (this) {
      case HotkeyStatus.unsupported:
        return '截图（当前平台不支持快捷键，可用按钮）';
      case HotkeyStatus.screenshotConflict:
      case HotkeyStatus.bothConflict:
        return '截图（Alt+A 被占用，可用按钮）';
      case HotkeyStatus.failed:
        return '截图（Alt+A 注册失败，可用按钮）';
      default:
        return '截图 (Alt+A)';
    }
  }

  /// 启动时的一次性提示文案；null 表示无需提示。
  String? get startupNotice {
    if (this == HotkeyStatus.bothRegistered) return null;
    if (!isSupported) return '当前平台不支持全局快捷键，请使用按钮切换浮窗/截图';
    if (hasConflict || this == HotkeyStatus.failed) {
      return '全局快捷键注册失败，按钮仍可使用';
    }
    return null;
  }
}

/// 一次原生注册结果。`toggleError/screenshotError` 为 Win32 错误码（1409=冲突）。
@immutable
class HotkeyRegistration {
  const HotkeyRegistration({
    required this.toggleRegistered,
    required this.screenshotRegistered,
    this.toggleError,
    this.screenshotError,
    this.unsupported = false,
  });

  const HotkeyRegistration.unsupported()
      : toggleRegistered = false,
        screenshotRegistered = false,
        toggleError = null,
        screenshotError = null,
        unsupported = true;

  const HotkeyRegistration.failed()
      : toggleRegistered = false,
        screenshotRegistered = false,
        toggleError = null,
        screenshotError = null,
        unsupported = false;

  factory HotkeyRegistration.fromNative(Object? raw) {
    if (raw is! Map) return const HotkeyRegistration.failed();
    final errors = raw['errors'];
    int? readError(String key) {
      if (errors is! Map) return null;
      final value = errors[key];
      return value is int ? value : null;
    }

    return HotkeyRegistration(
      toggleRegistered: raw['toggle'] == true,
      screenshotRegistered: raw['screenshot'] == true,
      toggleError: readError('toggle'),
      screenshotError: readError('screenshot'),
    );
  }

  final bool toggleRegistered;
  final bool screenshotRegistered;
  final int? toggleError;
  final int? screenshotError;
  final bool unsupported;

  HotkeyStatus get status {
    if (unsupported) return HotkeyStatus.unsupported;
    if (toggleRegistered && screenshotRegistered) {
      return HotkeyStatus.bothRegistered;
    }
    final toggleConflict = toggleError == hotkeyConflictErrorCode;
    final screenshotConflict = screenshotError == hotkeyConflictErrorCode;
    if (toggleConflict && screenshotConflict) return HotkeyStatus.bothConflict;
    if (toggleConflict) return HotkeyStatus.toggleConflict;
    if (screenshotConflict) return HotkeyStatus.screenshotConflict;
    return HotkeyStatus.failed;
  }

  @override
  String toString() =>
      'HotkeyRegistration(toggle=$toggleRegistered/$toggleError, '
      'screenshot=$screenshotRegistered/$screenshotError, '
      'unsupported=$unsupported)';
}

/// 原生注册/注销通道；io 走 MethodChannel，stub 返回 unsupported。
abstract class HotkeyTransport {
  Future<HotkeyRegistration> register();

  Future<void> unregister();

  /// 绑定原生 → Dart 的 `hotkey` 回调（1=Alt+Q，2=Alt+A）。
  void bind(void Function(int id) handler);
}

/// 平台无关的快捷键状态机：注册结果映射、去抖、注销。
///
/// 只回调 UI 动作（切换形态/投递截图请求），**不**截图、不请求网络、
/// 不使用低层键盘钩子、不记录按键内容。
class HotkeyController {
  HotkeyController({
    required this.transport,
    this.debounce = hotkeyDebounce,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now {
    transport.bind(handleHotkey);
  }

  final HotkeyTransport transport;
  final Duration debounce;
  final DateTime Function() _clock;

  final ValueNotifier<HotkeyStatus> status =
      ValueNotifier<HotkeyStatus>(HotkeyStatus.unsupported);
  final ValueNotifier<HotkeyRegistration?> registration =
      ValueNotifier<HotkeyRegistration?>(null);

  VoidCallback? onToggle;
  VoidCallback? onScreenshot;

  DateTime? _lastEventAt;
  Future<HotkeyRegistration>? _pending;
  bool _active = false;

  /// 至少一个热键注册成功（事件才会被处理）。
  bool get isActive => _active;

  /// 幂等注册：已注册时先注销再注册，单个原生失败的键不影响另一个键。
  Future<HotkeyRegistration> register({
    VoidCallback? onToggle,
    VoidCallback? onScreenshot,
  }) {
    if (onToggle != null) this.onToggle = onToggle;
    if (onScreenshot != null) this.onScreenshot = onScreenshot;
    final pending = _pending;
    if (pending != null) return pending;
    final future = _register();
    _pending = future;
    return future.whenComplete(() => _pending = null);
  }

  Future<HotkeyRegistration> retry({VoidCallback? onToggle, VoidCallback? onScreenshot}) =>
      register(onToggle: onToggle, onScreenshot: onScreenshot);

  Future<HotkeyRegistration> _register() async {
    HotkeyRegistration result;
    try {
      await transport.unregister();
    } catch (_) {
      // 忽略“尚未注册”类错误；注册本身是幂等的。
    }
    try {
      result = await transport.register();
    } catch (error) {
      debugPrint('hotkey register failed: $error');
      result = const HotkeyRegistration.failed();
    }
    registration.value = result;
    status.value = result.status;
    _active = result.toggleRegistered || result.screenshotRegistered;
    return result;
  }

  Future<void> unregister() async {
    try {
      await transport.unregister();
    } catch (error) {
      debugPrint('hotkey unregister failed: $error');
    }
    _active = false;
    registration.value = null;
    if (status.value != HotkeyStatus.unsupported) {
      status.value = HotkeyStatus.failed;
    }
  }

  /// 原生 WM_HOTKEY 回调入口（测试可直接调用）。300ms 去抖 + MOD_NOREPEAT。
  void handleHotkey(int id) {
    if (!_active) return;
    final now = _clock();
    final last = _lastEventAt;
    if (last != null && now.difference(last) < debounce) return;
    _lastEventAt = now;
    switch (id) {
      case hotkeyToggleId:
        onToggle?.call();
      case hotkeyScreenshotId:
        onScreenshot?.call();
    }
  }

  void dispose() {
    status.dispose();
    registration.dispose();
  }
}

/// Alt+Q（0x4C51）与 Alt+A（0x4C52）的通道 id 映射。
const int hotkeyToggleId = 1;
const int hotkeyScreenshotId = 2;
