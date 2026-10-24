import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loop/desktop/floating_signals.dart' as signals;
import 'package:loop/desktop/floating_window.dart';
import 'package:loop/desktop/minimal_window.dart';
import 'package:loop/desktop/window_mode.dart';

import 'support/fake_window_platform.dart';

/// t2 极简形态窗口状态机测试（规格 §3.1–§3.8）。
void main() {
  const initialRect = Rect.fromLTWH(100, 80, 1200, 800);

  FakeWindowPlatform makePlatform() =>
      FakeWindowPlatform(physicalRect: initialRect);

  FloatingWindowController makeController(
    FakeWindowPlatform platform, {
    void Function(String)? onError,
  }) =>
      FloatingWindowController(
        platform,
        onError: onError,
        pollInterval: const Duration(milliseconds: 1),
        geometryDebounce: const Duration(milliseconds: 5),
      );

  void expectRect(Rect actual, Rect expected, {double tolerance = 0.6}) {
    expect(actual.left, closeTo(expected.left, tolerance), reason: 'left');
    expect(actual.top, closeTo(expected.top, tolerance), reason: 'top');
    expect(actual.width, closeTo(expected.width, tolerance), reason: 'width');
    expect(actual.height, closeTo(expected.height, tolerance), reason: 'height');
  }

  test('U-MW-01 进入极简：360×52/右下锚定/禁用缩放/恒置顶/快照', () async {
    final platform = makePlatform();
    final controller = makeController(platform);
    await controller.enterFloating();
    expect(platform.physicalRectValue, const Rect.fromLTWH(1436, 220, 460, 600));

    expect(await controller.enterMinimal(), isTrue);

    expect(controller.minimal, isTrue);
    expect(controller.mode, LoopWindowMode.floating);
    expect(platform.minSizeValue, minimalMinSize);
    expect(platform.resizableValue, isFalse);
    expect(platform.alwaysOnTopValue, isTrue);
    expect(platform.focusCount, 2); // enterFloating + enterMinimal 各 1
    // 460 宽 → 高 52，右下角锚定。
    expectRect(platform.physicalRectValue, const Rect.fromLTWH(1436, 768, 460, 52));

    final snapshot = await controller.snapshot();
    expect(snapshot.minimal, isTrue);
    expect(snapshot.minSize, minimalMinSize);
    expect(snapshot.pinned, isTrue);

    final expanded = controller.lastExpandedSnapshot;
    expect(expanded, isNotNull);
    expect(expanded!.physicalBounds, const Rect.fromLTWH(1436, 220, 460, 600));
    expect(expanded.minSize, floatingMinSize);
    expect(expanded.pinned, isTrue);
    controller.dispose();
  });

  test('U-MW-02 退出极简：恢复展开 bounds/minSize/缩放/置顶/focus', () async {
    final platform = makePlatform();
    final controller = makeController(platform);
    await controller.enterFloating();
    await controller.enterMinimal();

    expect(await controller.exitMinimal(), isTrue);

    expect(controller.minimal, isFalse);
    expect(platform.minSizeValue, floatingMinSize);
    expect(platform.resizableValue, isTrue);
    expect(platform.alwaysOnTopValue, isTrue);
    expect(platform.physicalRectValue, const Rect.fromLTWH(1436, 220, 460, 600));
    expect(platform.focusCount, 3);
    expect(controller.lastExpandedSnapshot, isNull);
    controller.dispose();
  });

  test('U-MW-03 幂等/并发：重复进入不重复 focus，过渡中拒绝', () async {
    final platform = makePlatform();
    final controller = makeController(platform);
    await controller.enterFloating();
    expect(await controller.enterMinimal(), isTrue);
    expect(await controller.enterMinimal(), isTrue);
    expect(platform.focusCount, 2);

    expect(await controller.exitMinimal(), isTrue);
    expect(await controller.exitMinimal(), isTrue);
    expect(platform.focusCount, 3);

    platform.delay = const Duration(milliseconds: 20);
    final first = controller.enterMinimal();
    final second = controller.enterMinimal();
    expect(await second, isFalse);
    expect(await first, isTrue);
    platform.delay = null;
    controller.dispose();
  });

  test('U-MW-04 触发条件：normal/截图覆盖中不可进入极简', () async {
    final platform = makePlatform();
    final controller = makeController(platform);
    expect(await controller.enterMinimal(), isFalse);
    expect(controller.minimal, isFalse);

    await controller.enterFloating();
    final display = (await controller.captureDisplay())!;
    await controller.beginCaptureOverlay(display);
    expect(await controller.enterMinimal(), isFalse);
    expect(controller.minimal, isFalse);
    expect(controller.mode, LoopWindowMode.floating);
    await controller.applySnapshot(await controller.snapshot());
    expect(await controller.enterMinimal(), isTrue);
    controller.dispose();
  });

  test('U-MW-05 toggleMinimal 幂等切换', () async {
    final platform = makePlatform();
    final controller = makeController(platform);
    await controller.enterFloating();
    expect(await controller.toggleMinimal(), isTrue);
    expect(controller.minimal, isTrue);
    expect(await controller.toggleMinimal(), isTrue);
    expect(controller.minimal, isFalse);
    controller.dispose();
  });

  test('U-MW-06 宽度钳制 360–560（保持右下角）', () async {
    final platform = makePlatform();
    final controller = makeController(platform);
    await controller.enterFloating();

    platform.physicalRectValue = const Rect.fromLTWH(1200, 300, 800, 620);
    expect(await controller.enterMinimal(), isTrue);
    // 右边缘 2000 超出工作区右界 1920 → 宽度 560、右锚点钳到 1920。
    expectRect(platform.physicalRectValue, const Rect.fromLTWH(1360, 868, 560, 52));

    await controller.exitMinimal();
    platform.physicalRectValue = const Rect.fromLTWH(1200, 300, 380, 620);
    expect(await controller.enterMinimal(), isTrue);
    expectRect(platform.physicalRectValue, const Rect.fromLTWH(1200, 868, 380, 52));
    controller.dispose();
  });

  test('U-MW-07 150% DPI：物理 690×78、minSize 逻辑 360×52', () async {
    final hidpiDisplays = <DisplayInfo>[
      const DisplayInfo(
        id: r'\\.\DISPLAY1',
        physicalBounds: Rect.fromLTWH(0, 0, 2880, 1560),
        physicalWorkArea: Rect.fromLTWH(0, 0, 2880, 1560),
        scaleFactor: 1.5,
        isPrimary: true,
      ),
    ];
    final platform = FakeWindowPlatform(
      physicalRect: const Rect.fromLTWH(0, 0, 2880, 1560),
      dprValue: 1.5,
      displays: hidpiDisplays,
    );
    final controller = makeController(platform);
    expect(await controller.enterFloating(), isTrue);
    expect(platform.physicalRectValue,
        const Rect.fromLTWH(2154, 330, 690, 900));

    expect(await controller.enterMinimal(), isTrue);
    expect(platform.minSizeValue, minimalMinSize);
    expectRect(platform.physicalRectValue, const Rect.fromLTWH(2154, 1152, 690, 78));
    controller.dispose();
  });

  test('U-MW-08 进入失败回滚浮窗、提示一次、minSize/缩放恢复', () async {
    final platform = makePlatform();
    final errors = <String>[];
    final controller = makeController(platform, onError: errors.add);
    await controller.enterFloating();
    final focusBefore = platform.focusCount;

    platform.failOn('setBoundsPhysical', times: 1);
    platform.failOn('setBoundsLogical', times: 1);

    expect(await controller.enterMinimal(), isFalse);

    expect(controller.minimal, isFalse);
    expect(controller.mode, LoopWindowMode.floating);
    expect(controller.transitioning, isFalse);
    expect(errors, hasLength(1));
    expect(controller.errorCount, 1);
    expect(platform.minSizeValue, floatingMinSize);
    expect(platform.resizableValue, isTrue);
    expect(platform.physicalRectValue, const Rect.fromLTWH(1436, 220, 460, 600));
    expect(platform.alwaysOnTopValue, isTrue);
    expect(platform.focusCount, focusBefore, reason: '回滚不额外 focus');
    controller.dispose();
  });

  test('U-MW-09 截图快照往返：minimal/minSize/置顶/resizable 恢复', () async {
    final platform = makePlatform();
    final controller = makeController(platform);
    await controller.enterFloating();
    await controller.enterMinimal();
    final snapshot = await controller.snapshot();
    expect(snapshot.minimal, isTrue);
    expect(snapshot.minSize, minimalMinSize);

    final display = (await controller.captureDisplay())!;
    await controller.beginCaptureOverlay(display);
    expect(signals.captureInProgress.value, isTrue);
    expect(platform.physicalRectValue, const Rect.fromLTWH(0, 0, 1920, 1040));

    await controller.applySnapshot(snapshot);
    expect(controller.minimal, isTrue);
    expect(controller.mode, LoopWindowMode.floating);
    expect(platform.minSizeValue, minimalMinSize);
    expect(platform.resizableValue, isFalse);
    expect(platform.alwaysOnTopValue, isTrue);
    expectRect(platform.physicalRectValue, const Rect.fromLTWH(1436, 768, 460, 52));
    controller.dispose();
  });

  test('U-MW-10 显示器移除：极简条钳回工作区、保持 52 高、不 focus', () async {
    final platform = makePlatform();
    final controller = makeController(platform);
    await controller.enterFloating();
    await controller.enterMinimal();
    final focusBefore = platform.focusCount;

    platform.displaysValue = const <DisplayInfo>[
      DisplayInfo(
        id: r'\\.\DISPLAY2',
        physicalBounds: Rect.fromLTWH(1920, 0, 1920, 1080),
        physicalWorkArea: Rect.fromLTWH(1920, 0, 1920, 1040),
        scaleFactor: 1.0,
        isPrimary: true,
      ),
    ];
    await controller.ensureGeometry();

    expect(controller.minimal, isTrue);
    expect(controller.mode, LoopWindowMode.floating);
    expect(platform.focusCount, focusBefore);
    expect(platform.physicalRectValue.left, greaterThanOrEqualTo(1920));
    expect(platform.physicalRectValue.right, lessThanOrEqualTo(3840));
    expect(platform.physicalRectValue.height, closeTo(minimalHeight, 0.6));
    expect(platform.physicalRectValue.bottom, lessThanOrEqualTo(1040));
    controller.dispose();
  });

  test('U-MW-11 极简状态下退出浮窗：恢复 normal、resizable/minSize 正确', () async {
    final platform = makePlatform();
    final controller = makeController(platform);
    await controller.enterFloating();
    await controller.enterMinimal();

    expect(await controller.exitFloating(), isTrue);

    expect(controller.mode, LoopWindowMode.normal);
    expect(controller.minimal, isFalse);
    expect(platform.resizableValue, isTrue);
    expect(platform.minSizeValue, normalMinSize);
    expect(platform.physicalRectValue, initialRect);
    // 下次进入浮窗复用展开尺寸而不是 360×52。
    expect(controller.lastFloatingSnapshot?.physicalBounds,
        const Rect.fromLTWH(1436, 220, 460, 600));
    controller.dispose();
  });

  test('U-MW-12 极简恒置顶：setPinned(false) 不生效，退出恢复 pinned', () async {
    final platform = makePlatform();
    final controller = makeController(platform);
    await controller.enterFloating();
    await controller.enterMinimal();

    await controller.setPinned(false);
    expect(controller.pinned, isTrue);
    expect(platform.alwaysOnTopValue, isTrue);

    await controller.exitMinimal();
    expect(controller.pinned, isTrue);
    expect(platform.alwaysOnTopValue, isTrue);
    controller.dispose();
  });

  test('U-MW-13 快照 copyWith/minimal 与 toString', () {
    const snapshot = WindowSnapshot(
      mode: LoopWindowMode.floating,
      bounds: Rect.fromLTWH(1436, 768, 460, 52),
      physicalBounds: Rect.fromLTWH(1436, 768, 460, 52),
      dpr: 1.0,
      maximized: false,
      alwaysOnTop: true,
      minSize: minimalMinSize,
      pinned: true,
    );
    expect(snapshot.minimal, isFalse);
    final minimal = snapshot.copyWith(minimal: true);
    expect(minimal.minimal, isTrue);
    expect(minimal.toString(), contains('minimal=true'));
    final restored = minimal.copyWith(minimal: false);
    expect(restored.minimal, isFalse);
  });

  test('U-MW-14 MinimalWindowPlanner 纯几何', () {
    expect(MinimalWindowPlanner.barSizeLogical(460), const Size(460, 52));
    expect(MinimalWindowPlanner.barSizeLogical(200), const Size(360, 52));
    expect(MinimalWindowPlanner.barSizeLogical(900), const Size(560, 52));

    expect(
      MinimalWindowPlanner.isAtFloatingMinimum(const Rect.fromLTWH(0, 0, 360, 420)),
      isTrue,
    );
    expect(
      MinimalWindowPlanner.isAtFloatingMinimum(const Rect.fromLTWH(0, 0, 361, 421)),
      isTrue,
    );
    expect(
      MinimalWindowPlanner.isAtFloatingMinimum(const Rect.fromLTWH(0, 0, 400, 420)),
      isFalse,
    );

    final clamped = MinimalWindowPlanner.clampBar(
      physical: const Rect.fromLTWH(-100, 2000, 400, 700),
      workPhysical: const Rect.fromLTWH(0, 0, 1920, 1040),
      dpr: 1.0,
    );
    expect(clamped.left, 0);
    expect(clamped.top, 1040 - 52);
    expect(clamped.width, 400);
    expect(clamped.height, 52);
  });
}
