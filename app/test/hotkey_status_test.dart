import 'package:flutter_test/flutter_test.dart';
import 'package:loop/desktop/hotkeys_types.dart';

/// t2 快捷键状态机测试：U-HK-01~05。
void main() {
  group('HotkeyRegistration 映射', () {
    test('U-HK-01 两键注册成功 -> bothRegistered', () {
      const registration = HotkeyRegistration(
        toggleRegistered: true,
        screenshotRegistered: true,
      );
      expect(registration.status, HotkeyStatus.bothRegistered);
      expect(registration.status.toggleTooltip, contains('Alt+Q'));
      expect(registration.status.screenshotTooltip, contains('Alt+A'));
      expect(registration.status.startupNotice, isNull);
    });

    test('U-HK-02 单键 1409 -> 对应 conflict，另一键仍可用', () {
      const toggleConflict = HotkeyRegistration(
        toggleRegistered: false,
        screenshotRegistered: true,
        toggleError: hotkeyConflictErrorCode,
      );
      expect(toggleConflict.status, HotkeyStatus.toggleConflict);
      expect(toggleConflict.status.screenshotRegistered, isTrue);
      expect(toggleConflict.status.toggleTooltip, contains('Alt+Q 被占用'));
      expect(toggleConflict.status.startupNotice, isNotNull);

      const screenshotConflict = HotkeyRegistration(
        toggleRegistered: true,
        screenshotRegistered: false,
        screenshotError: hotkeyConflictErrorCode,
      );
      expect(screenshotConflict.status, HotkeyStatus.screenshotConflict);
      expect(screenshotConflict.status.toggleRegistered, isTrue);
      expect(screenshotConflict.status.screenshotTooltip, contains('Alt+A 被占用'));

      const bothConflict = HotkeyRegistration(
        toggleRegistered: false,
        screenshotRegistered: false,
        toggleError: hotkeyConflictErrorCode,
        screenshotError: hotkeyConflictErrorCode,
      );
      expect(bothConflict.status, HotkeyStatus.bothConflict);
    });

    test('U-HK-03 unsupported/failed 映射与降级提示', () {
      expect(
        const HotkeyRegistration.unsupported().status,
        HotkeyStatus.unsupported,
      );
      expect(
        const HotkeyRegistration.unsupported().status.startupNotice,
        isNotNull,
      );
      expect(
        const HotkeyRegistration.failed().status,
        HotkeyStatus.failed,
      );
      expect(
        const HotkeyRegistration(
          toggleRegistered: true,
          screenshotRegistered: false,
        ).status,
        HotkeyStatus.failed,
      );
    });

    test('fromNative 解析原生返回（含 null 错误码）', () {
      final registration = HotkeyRegistration.fromNative({
        'toggle': true,
        'screenshot': false,
        'errors': {'toggle': null, 'screenshot': 1409},
      });
      expect(registration.toggleRegistered, isTrue);
      expect(registration.status, HotkeyStatus.screenshotConflict);
      expect(HotkeyRegistration.fromNative('oops').status, HotkeyStatus.failed);
    });
  });

  group('HotkeyController', () {
    test('U-HK-01/04 注册成功回调、300ms 去抖、两键独立', () async {
      final transport = _FakeHotkeyTransport([
        const HotkeyRegistration(
          toggleRegistered: true,
          screenshotRegistered: true,
        ),
      ]);
      var now = DateTime(2026, 1, 1, 12);
      final controller = HotkeyController(
        transport: transport,
        clock: () => now,
      );
      var toggles = 0;
      var shots = 0;
      final result = await controller.register(
        onToggle: () => toggles++,
        onScreenshot: () => shots++,
      );
      expect(result.status, HotkeyStatus.bothRegistered);
      expect(controller.status.value, HotkeyStatus.bothRegistered);
      expect(controller.isActive, isTrue);
      expect(transport.registerCount, 1);

      transport.emit(hotkeyToggleId);
      now = now.add(const Duration(milliseconds: 400));
      transport.emit(hotkeyScreenshotId);
      expect(toggles, 1);
      expect(shots, 1);
      controller.dispose();
    });

    test('U-HK-04 去抖窗口内重复事件只回调一次', () async {
      final transport = _FakeHotkeyTransport([
        const HotkeyRegistration(
          toggleRegistered: true,
          screenshotRegistered: true,
        ),
      ]);
      var now = DateTime(2026, 1, 1, 12);
      final controller = HotkeyController(
        transport: transport,
        debounce: const Duration(milliseconds: 300),
        clock: () => now,
      );
      var toggles = 0;
      var shots = 0;
      await controller.register(
        onToggle: () => toggles++,
        onScreenshot: () => shots++,
      );

      controller.handleHotkey(hotkeyToggleId);
      now = now.add(const Duration(milliseconds: 100));
      controller.handleHotkey(hotkeyToggleId); // 去抖内 -> 忽略
      expect(toggles, 1);

      now = now.add(const Duration(milliseconds: 300));
      controller.handleHotkey(hotkeyToggleId);
      expect(toggles, 2);

      now = now.add(const Duration(milliseconds: 300));
      controller.handleHotkey(hotkeyScreenshotId);
      expect(shots, 1);
      controller.dispose();
    });

    test('U-HK-05 unregister 后事件不再回调、状态可读', () async {
      final transport = _FakeHotkeyTransport([
        const HotkeyRegistration(
          toggleRegistered: true,
          screenshotRegistered: true,
        ),
      ]);
      final controller = HotkeyController(transport: transport);
      var toggles = 0;
      await controller.register(onToggle: () => toggles++);
      transport.emit(hotkeyToggleId);
      expect(toggles, 1);

      await controller.unregister();
      expect(transport.unregisterCount, greaterThanOrEqualTo(1));
      expect(controller.isActive, isFalse);
      expect(controller.status.value, HotkeyStatus.failed);
      transport.emit(hotkeyToggleId);
      expect(toggles, 1);
      controller.dispose();
    });

    test('冲突只影响对应键；retry 可恢复', () async {
      final transport = _FakeHotkeyTransport([
        const HotkeyRegistration(
          toggleRegistered: false,
          screenshotRegistered: true,
          toggleError: hotkeyConflictErrorCode,
        ),
        const HotkeyRegistration(
          toggleRegistered: true,
          screenshotRegistered: true,
        ),
      ]);
      final controller = HotkeyController(transport: transport);
      var shots = 0;
      await controller.register(onScreenshot: () => shots++);
      expect(controller.status.value, HotkeyStatus.toggleConflict);
      expect(controller.isActive, isTrue);
      transport.emit(hotkeyScreenshotId);
      expect(shots, 1);

      await controller.retry();
      expect(controller.status.value, HotkeyStatus.bothRegistered);
      expect(transport.registerCount, 2);
      controller.dispose();
    });

    test('不支持平台：注册返回 unsupported、按钮仍可用', () async {
      final transport = _FakeHotkeyTransport([
        const HotkeyRegistration.unsupported(),
      ]);
      final controller = HotkeyController(transport: transport);
      final result = await controller.register(onToggle: () {});
      expect(result.status, HotkeyStatus.unsupported);
      expect(controller.isActive, isFalse);
      expect(controller.status.value.startupNotice, isNotNull);
      controller.dispose();
    });
  });
}

class _FakeHotkeyTransport implements HotkeyTransport {
  _FakeHotkeyTransport(this.results);

  final List<HotkeyRegistration> results;
  int registerCount = 0;
  int unregisterCount = 0;
  void Function(int id)? handler;

  @override
  Future<HotkeyRegistration> register() async {
    final index = registerCount < results.length
        ? registerCount
        : results.length - 1;
    registerCount++;
    return results[index];
  }

  @override
  Future<void> unregister() async {
    unregisterCount++;
  }

  @override
  void bind(void Function(int id) handler) {
    this.handler = handler;
  }

  void emit(int id) => handler?.call(id);
}
