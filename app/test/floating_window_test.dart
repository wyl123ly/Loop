import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loop/desktop/floating_signals.dart' as signals;
import 'package:loop/desktop/floating_window.dart';
import 'package:loop/desktop/window_mode.dart';

import 'support/fake_window_platform.dart';

/// t2 窗口形态状态机测试（U-WM-01~11），使用真实 FloatingWindowController +
/// FakeWindowPlatform。
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

  test('U-WM-01 进入浮窗：快照/还原最大化/最小尺寸/置顶/几何/focus', () async {
    final platform = makePlatform();
    final controller = makeController(platform);

    expect(await controller.enterFloating(), isTrue);

    expect(controller.mode, LoopWindowMode.floating);
    expect(controller.isFloating, isTrue);
    expect(controller.pinned, isTrue);
    expect(controller.transitioning, isFalse);
    expect(platform.minSizeValue, floatingMinSize);
    expect(platform.alwaysOnTopValue, isTrue);
    // 窗口中心 (700,480) 在主屏 -> 右侧内缩 24、垂直居中。
    expect(platform.physicalRectValue, const Rect.fromLTWH(1436, 220, 460, 600));
    expect(platform.focusCount, 1);

    final normal = controller.normalSnapshot;
    expect(normal, isNotNull);
    expect(normal!.mode, LoopWindowMode.normal);
    expect(normal.bounds, initialRect);
    expect(normal.physicalBounds, initialRect);
    expect(normal.maximized, isFalse);
    expect(normal.alwaysOnTop, isFalse);
    expect(normal.minSize, normalMinSize);

    final floating = controller.lastFloatingSnapshot;
    expect(floating, isNotNull);
    expect(floating!.mode, LoopWindowMode.floating);
    expect(floating.minSize, floatingMinSize);
    expect(floating.alwaysOnTop, isTrue);
    expect(floating.physicalBounds, const Rect.fromLTWH(1436, 220, 460, 600));
    controller.dispose();
  });

  test('U-WM-02 退出浮窗：minSize/置顶/bounds 恢复', () async {
    final platform = makePlatform();
    final controller = makeController(platform);
    await controller.enterFloating();

    expect(await controller.exitFloating(), isTrue);

    expect(controller.mode, LoopWindowMode.normal);
    expect(controller.pinned, isFalse);
    expect(controller.normalSnapshot, isNull);
    expect(platform.minSizeValue, normalMinSize);
    expect(platform.alwaysOnTopValue, isFalse);
    expect(platform.physicalRectValue, initialRect);
    expect(platform.focusCount, 2);
    // 记住上次浮窗尺寸（下一次进入复用）。
    expect(controller.lastFloatingSnapshot?.physicalBounds,
        const Rect.fromLTWH(1436, 220, 460, 600));
    controller.dispose();
  });

  test('U-WM-03 幂等与并发：重复/同时切换不改变最终状态', () async {
    final platform = makePlatform();
    final controller = makeController(platform);

    expect(await controller.enterFloating(), isTrue);
    expect(await controller.enterFloating(), isTrue); // 幂等，不重复 focus
    expect(platform.focusCount, 1);

    expect(await controller.exitFloating(), isTrue);
    expect(await controller.exitFloating(), isTrue);
    expect(platform.focusCount, 2);

    platform.delay = const Duration(milliseconds: 20);
    final first = controller.enterFloating();
    final second = controller.enterFloating(); // transitioning 中 -> 忽略
    expect(await second, isFalse);
    expect(await first, isTrue);
    expect(controller.mode, LoopWindowMode.floating);
    platform.delay = null;
    controller.dispose();
  });

  test('U-WM-04 最大化进入浮窗，退出恢复最大化', () async {
    final platform = makePlatform()..maximizedValue = true;
    final controller = makeController(platform);

    expect(await controller.enterFloating(), isTrue);
    expect(platform.unmaximizeCount, 1);
    expect(platform.maximizedValue, isFalse);
    expect(platform.physicalRectValue, const Rect.fromLTWH(1436, 220, 460, 600));
    expect(controller.normalSnapshot?.maximized, isTrue);

    expect(await controller.exitFloating(), isTrue);
    expect(platform.maximizeCount, 1);
    expect(platform.maximizedValue, isTrue);
    expect(platform.minSizeValue, normalMinSize);
    controller.dispose();
  });

  test('U-WM-05 平台异常：回滚普通窗口、提示一次、下次可成功', () async {
    final platform = makePlatform();
    final errors = <String>[];
    final controller = makeController(platform, onError: errors.add);
    platform.failOn('setMinimumSize', times: 1);

    expect(await controller.enterFloating(), isFalse);

    expect(controller.mode, LoopWindowMode.normal);
    expect(controller.transitioning, isFalse);
    expect(errors, hasLength(1));
    expect(controller.errorCount, 1);
    // 回滚到进入前快照。
    expect(platform.minSizeValue, normalMinSize);
    expect(platform.alwaysOnTopValue, isFalse);
    expect(platform.physicalRectValue, initialRect);

    // 失败注入已用完，下一次切换成功。
    expect(await controller.enterFloating(), isTrue);
    expect(controller.mode, LoopWindowMode.floating);
    controller.dispose();
  });

  test('U-WM-06 focus 白名单：切换各 +1，ensureGeometry/setPinned 不增', () async {
    final platform = makePlatform();
    final controller = makeController(platform);

    expect(await controller.enterFloating(), isTrue);
    expect(platform.focusCount, 1);
    await controller.ensureGeometry();
    await controller.setPinned(false);
    await controller.setPinned(true);
    await controller.ensureGeometry();
    expect(platform.focusCount, 1);

    expect(await controller.exitFloating(), isTrue);
    expect(platform.focusCount, 2);

    final platform2 = makePlatform();
    final controller2 = makeController(platform2);
    expect(await controller2.enterFloating(focus: false), isTrue);
    expect(platform2.focusCount, 0);
    controller.dispose();
    controller2.dispose();
  });

  test('U-WM-07 连续 10 次切换无漂移', () async {
    final platform = makePlatform();
    final controller = makeController(platform);
    for (var i = 0; i < 10; i++) {
      expect(await controller.enterFloating(), isTrue, reason: 'enter #$i');
      expect(platform.physicalRectValue,
          const Rect.fromLTWH(1436, 220, 460, 600),
          reason: 'floating bounds #$i');
      expect(await controller.exitFloating(), isTrue, reason: 'exit #$i');
      expect(platform.physicalRectValue, initialRect, reason: 'normal #$i');
      expect(platform.minSizeValue, normalMinSize);
      expect(platform.maximizedValue, isFalse);
    }
    expect(controller.mode, LoopWindowMode.normal);
    controller.dispose();
  });

  test('U-WM-08 截图快照：覆盖后恢复仍为浮窗（mode/minSize/置顶）', () async {
    final platform = makePlatform();
    final controller = makeController(platform);
    await controller.enterFloating();
    final floatingSnapshot = await controller.snapshot();
    expect(floatingSnapshot.mode, LoopWindowMode.floating);
    expect(floatingSnapshot.minSize, floatingMinSize);
    expect(floatingSnapshot.alwaysOnTop, isTrue);

    final display = await controller.captureDisplay();
    expect(display?.physicalWorkArea, const Rect.fromLTWH(0, 0, 1920, 1040));

    await controller.beginCaptureOverlay(display!);
    expect(controller.captureInProgress, isTrue);
    expect(signals.captureInProgress.value, isTrue);
    expect(platform.focusCount, 2); // 覆盖层 show+focus 恰一次
    expect(platform.physicalRectValue,
        const Rect.fromLTWH(0, 0, 1920, 1040));
    expect(controller.mode, LoopWindowMode.floating); // 截图不改 mode

    // 覆盖期间禁止切换/再次截图。
    expect(await controller.toggleFloating(), isFalse);
    expect(await controller.exitFloating(), isFalse);

    await controller.applySnapshot(floatingSnapshot);
    expect(controller.captureInProgress, isFalse);
    expect(signals.captureInProgress.value, isFalse);
    expect(controller.mode, LoopWindowMode.floating);
    expect(platform.physicalRectValue,
        const Rect.fromLTWH(1436, 220, 460, 600));
    expect(platform.minSizeValue, floatingMinSize);
    expect(platform.alwaysOnTopValue, isTrue);
    expect(platform.focusCount, 2); // 未 hidden -> 不额外 focus

    await controller.applySnapshot(floatingSnapshot, focus: true);
    expect(platform.focusCount, 3); // hidden 时恢复焦点一次
    // 幂等：重复恢复不累积副作用。
    await controller.applySnapshot(floatingSnapshot);
    expect(platform.physicalRectValue,
        const Rect.fromLTWH(1436, 220, 460, 600));
    expect(platform.alwaysOnTopValue, isTrue);
    controller.dispose();
  });

  test('U-WM-09 本会话记住上次浮窗尺寸', () async {
    final platform = makePlatform();
    final controller = makeController(platform);
    await controller.enterFloating();
    // 模拟用户拖动缩放浮窗。
    platform.physicalRectValue = const Rect.fromLTWH(1200, 300, 480, 620);
    await controller.exitFloating();
    expect(controller.lastFloatingSnapshot?.physicalBounds,
        const Rect.fromLTWH(1200, 300, 480, 620));

    expect(await controller.enterFloating(), isTrue);
    expect(platform.physicalRectValue,
        const Rect.fromLTWH(1416, 210, 480, 620));
    controller.dispose();
  });

  test('U-WM-10 captureInProgress 时禁止切换', () async {
    final platform = makePlatform();
    final controller = makeController(platform);
    await controller.enterFloating();
    final display = (await controller.captureDisplay())!;
    await controller.beginCaptureOverlay(display);
    expect(await controller.enterFloating(), isFalse);
    expect(await controller.exitFloating(), isFalse);
    expect(controller.mode, LoopWindowMode.floating);
    await controller.applySnapshot(await controller.snapshot());
    expect(await controller.exitFloating(), isTrue);
    controller.dispose();
  });

  test('U-WM-11 显示器移除：浮窗回主屏工作区、不 focus、不改 mode', () async {
    final platform = makePlatform();
    final controller = makeController(platform);
    await controller.enterFloating();
    final focusBefore = platform.focusCount;

    // 原主屏被移除，只剩右侧 1920x1080 显示器。
    platform.displaysValue = const [
      DisplayInfo(
        id: r'\\.\DISPLAY2',
        physicalBounds: Rect.fromLTWH(1920, 0, 1920, 1080),
        physicalWorkArea: Rect.fromLTWH(1920, 0, 1920, 1040),
        scaleFactor: 1.0,
        isPrimary: true,
      ),
    ];
    await controller.ensureGeometry();

    expect(controller.mode, LoopWindowMode.floating);
    expect(controller.pinned, isTrue);
    expect(platform.focusCount, focusBefore);
    expect(platform.physicalRectValue.left, greaterThanOrEqualTo(1920));
    expect(platform.physicalRectValue.right, lessThanOrEqualTo(3840));
    expect(platform.physicalRectValue.bottom, lessThanOrEqualTo(1040));
    controller.dispose();
  });

  test('U-WM-11 普通窗口离屏：回主屏居中、不 focus', () async {
    final platform = FakeWindowPlatform(
      physicalRect: const Rect.fromLTWH(-5000, -5000, 1200, 800),
    );
    final controller = makeController(platform);
    await controller.ensureGeometry();
    expect(controller.mode, LoopWindowMode.normal);
    expect(platform.focusCount, 0);
    expect(platform.physicalRectValue, const Rect.fromLTWH(510, 220, 900, 600));
    controller.dispose();
  });

  test('U-WM-12 captureDisplay 按窗口中心选择副屏', () async {
    final platform = FakeWindowPlatform(
      physicalRect: const Rect.fromLTWH(2200, 100, 460, 600),
      displays: const [
        DisplayInfo(
          id: r'\\.\DISPLAY1',
          physicalBounds: Rect.fromLTWH(0, 0, 1920, 1080),
          physicalWorkArea: Rect.fromLTWH(0, 0, 1920, 1040),
          scaleFactor: 1.0,
          isPrimary: true,
        ),
        DisplayInfo(
          id: r'\\.\DISPLAY2',
          physicalBounds: Rect.fromLTWH(1920, 0, 1920, 1080),
          physicalWorkArea: Rect.fromLTWH(1920, 0, 1920, 1040),
          scaleFactor: 1.0,
        ),
      ],
    );
    final controller = makeController(platform);
    final display = await controller.captureDisplay();
    expect(display?.id, r'\\.\DISPLAY2');
    controller.dispose();
  });

  // -------------------------------------------------------------------------
  // T5 findings 回归：最大化 placement / 最大化截图 / 回滚 / 异常清理
  // -------------------------------------------------------------------------

  const maxRect = Rect.fromLTWH(-8, -8, 2578, 1458);
  const hidpiNormalRect = Rect.fromLTWH(380, 157, 1800, 1125);
  const hidpiDisplays = [
    DisplayInfo(
      id: r'\\.\DISPLAY1',
      physicalBounds: Rect.fromLTWH(0, 0, 2560, 1440),
      physicalWorkArea: Rect.fromLTWH(0, 0, 2560, 1440),
      scaleFactor: 1.25,
      isPrimary: true,
    ),
  ];

  FakeWindowPlatform makeMaximizedPlatform() => FakeWindowPlatform(
        physicalRect: maxRect,
        normalPlacement: hidpiNormalRect,
        maximizedValue: true,
        dprValue: 1.25,
        displays: hidpiDisplays,
      );

  test('U-WM-13/T5-01 最大化→浮窗→返回→点还原恢复原 normal placement', () async {
    final platform = makeMaximizedPlatform();
    final controller = makeController(platform);

    expect(await controller.enterFloating(), isTrue);
    expect(controller.normalSnapshot?.maximized, isTrue);
    expect(controller.normalSnapshot?.normalPlacement, hidpiNormalRect);
    expect(platform.maximizedValue, isFalse);
    // 主屏 2560×1440@125%：浮窗 460×600 逻辑 = 575×750 物理，右/垂直居中。
    expect(platform.physicalRectValue,
        const Rect.fromLTWH(1955, 345, 575, 750));

    expect(await controller.exitFloating(), isTrue);
    expect(platform.maximizedValue, isTrue);
    expect(platform.normalPlacementValue, hidpiNormalRect);
    expect(platform.calls, contains('setWindowPlacement:true'));

    // 用户点击“向下还原”：必须回到原 normal bounds，而不是浮窗位置/900×600。
    await platform.unmaximize();
    expect(platform.maximizedValue, isFalse);
    expect(platform.physicalRectValue, hidpiNormalRect);
    expect(platform.physicalRectValue.left, 380);
    expect(platform.physicalRectValue.top, 157);
    expect(platform.physicalRectValue.width, 1800);
    expect(platform.physicalRectValue.height, 1125);
    controller.dispose();
  });

  test('U-WM-14/T5-02 最大化截图：先 unmaximize 铺满工作区，结束恢复 maximized+placement',
      () async {
    final platform = makeMaximizedPlatform();
    final controller = makeController(platform);

    final snapshot = await controller.snapshot();
    expect(snapshot.maximized, isTrue);
    expect(snapshot.physicalBounds, maxRect);
    expect(snapshot.normalPlacement, hidpiNormalRect);

    final display = (await controller.captureDisplay())!;
    expect(display.physicalWorkArea, const Rect.fromLTWH(0, 0, 2560, 1440));

    await controller.beginCaptureOverlay(display);
    // SetWindowPos 必须发生在 unmaximize 之后，且覆盖层铺满工作区。
    expect(platform.maximizedValue, isFalse);
    expect(platform.boundsWhileMaximized, 0);
    expect(platform.physicalRectValue, const Rect.fromLTWH(0, 0, 2560, 1440));
    expect(platform.alwaysOnTopValue, isTrue);
    expect(platform.focusCount, 1);
    expect(controller.captureInProgress, isTrue);

    await controller.applySnapshot(snapshot);
    expect(controller.captureInProgress, isFalse);
    expect(signals.captureInProgress.value, isFalse);
    expect(platform.maximizedValue, isTrue);
    expect(platform.normalPlacementValue, hidpiNormalRect);

    await platform.unmaximize();
    expect(platform.physicalRectValue, hidpiNormalRect);
    controller.dispose();
  });

  test('U-WM-15/T5-03 最大化 enter 失败回滚恢复 maximized 与原 placement', () async {
    final platform = makeMaximizedPlatform();
    final errors = <String>[];
    final controller = makeController(platform, onError: errors.add);
    platform.failOn('setMinimumSize', times: 1);

    expect(await controller.enterFloating(), isFalse);
    expect(controller.mode, LoopWindowMode.normal);
    expect(controller.errorCount, 1);
    expect(errors, hasLength(1));
    expect(controller.normalSnapshot, isNull);
    // 回滚必须恢复最大化 + 原 restore-down placement。
    expect(platform.maximizedValue, isTrue);
    expect(platform.normalPlacementValue, hidpiNormalRect);
    await platform.unmaximize();
    expect(platform.physicalRectValue, hidpiNormalRect);
    controller.dispose();
  });

  test('U-WM-16/T5-06 applySnapshot 中途异常仍清理 captureInProgress/全局信号', () async {
    final platform = FakeWindowPlatform(physicalRect: initialRect);
    final controller = makeController(platform);
    await controller.enterFloating();
    final snapshot = await controller.snapshot();
    final display = (await controller.captureDisplay())!;
    await controller.beginCaptureOverlay(display);
    expect(controller.captureInProgress, isTrue);
    expect(signals.captureInProgress.value, isTrue);

    // 物理与逻辑 bounds 恢复都失败 -> applySnapshot 抛错，但必须走 finally 清理。
    platform.failOn('setBoundsPhysical', times: 2);
    platform.failOn('setBoundsLogical', times: 1);
    await expectLater(
      controller.applySnapshot(snapshot),
      throwsA(isA<StateError>()),
    );
    expect(controller.captureInProgress, isFalse);
    expect(signals.captureInProgress.value, isFalse);

    // 清理后截图/切换都没有被永久禁用：可以再次进入覆盖态并成功恢复。
    final display2 = (await controller.captureDisplay())!;
    await controller.beginCaptureOverlay(display2);
    expect(controller.captureInProgress, isTrue);
    await controller.applySnapshot(snapshot);
    expect(controller.captureInProgress, isFalse);

    // 切换也仍然可用。
    expect(await controller.exitFloating(), isTrue);
    expect(controller.mode, LoopWindowMode.normal);
    expect(controller.captureInProgress, isFalse);
    controller.dispose();
  });

  test('U-WM-17/T5-01 平台不支持 SetWindowPlacement 时回退仍恢复正确 placement',
      () async {
    final platform = makeMaximizedPlatform()
      ..supportsWindowPlacementValue = false;
    final controller = makeController(platform);

    expect(await controller.enterFloating(), isTrue);
    expect(await controller.exitFloating(), isTrue);
    expect(platform.maximizedValue, isTrue);
    expect(platform.normalPlacementValue, hidpiNormalRect);
    // 回退路径：先恢复普通位置再 maximize。
    expect(platform.calls, contains('setBoundsPhysical:$hidpiNormalRect'));
    await platform.unmaximize();
    expect(platform.physicalRectValue, hidpiNormalRect);
    controller.dispose();
  });
}
