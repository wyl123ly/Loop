import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loop/api.dart';
import 'package:loop/desktop/floating_signals.dart';
import 'package:loop/desktop/window_mode.dart';
import 'package:loop/main.dart';
import 'package:loop/screens/chat_screen.dart';
import 'package:loop/state.dart';
import 'package:loop/theme.dart';
import 'package:loop/widgets/image_preview.dart';

import 'support/fake_floating_host.dart';
import 'support/fake_loop_api.dart';
import 'support/fake_screenshot_service.dart';

class _Harness {
  late FakeLoopApi api;
  late AppState state;
  late FakeFloatingHost host;
  late FakeScreenshotService screenshots;
  late GlobalKey<ChatScreenState> chatKey;
}

Future<_Harness> _pumpFloatingShell(
  WidgetTester tester, {
  Size size = const Size(460, 600),
  bool floating = true,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final harness = _Harness();
  harness.api = FakeLoopApi();
  harness.state = fakeAppState(harness.api);
  harness.host = FakeFloatingHost();
  harness.screenshots = FakeScreenshotService(
    bytes: await makeTestPng(tester, size.width.round(), size.height.round()),
  );
  harness.chatKey = GlobalKey<ChatScreenState>();
  final screens = <Widget>[
    ChatScreen(
      key: harness.chatKey,
      active: true,
      state: harness.state,
      floating: floating,
      compact: size.width < 420 || size.height < 520,
      screenshots: harness.screenshots,
    ),
    const Placeholder(),
    const Placeholder(),
    const Placeholder(),
    const Placeholder(),
    const Placeholder(),
  ];
  await tester.pumpWidget(MaterialApp(
    theme: loopTheme(LoopPalette.light),
    home: Shell(
      state: harness.state,
      modeHost: harness.host,
      screensOverride: screens,
      screenshots: harness.screenshots,
    ),
  ));
  await tester.pumpAndSettle();
  if (!harness.host.isFloating) {
    await harness.host.enterFloating();
    await tester.pumpAndSettle();
  }
  return harness;
}

/// 触发截图并等待覆盖层就绪（含 150ms 去菜单延迟 + 图片解码）。
Future<void> _requestAndWaitOverlay(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
  await tester.pump();
  await tester.runAsync(() async {
    await Future<void>.delayed(const Duration(milliseconds: 250));
  });
  await tester.pump();
  expect(find.byKey(const Key('screenshot-overlay')), findsOneWidget);
}

Future<void> _completeOverlay(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('screenshot-select-all')));
  await tester.pump();
  await tester.tap(find.byKey(const Key('screenshot-done')));
  await tester.runAsync(() async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
  });
  await tester.pump();
  await tester.pumpAndSettle();
}

Future<void> _cancelOverlay(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('screenshot-cancel')));
  await tester.pump();
  await tester.pumpAndSettle();
}

Future<void> _retakeOverlay(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('screenshot-retake')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
  await tester.runAsync(() async {
    await Future<void>.delayed(const Duration(milliseconds: 250));
  });
  await tester.pump();
  await tester.pumpAndSettle();
}

Future<void> _flushSnack(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 4));
  await tester.pumpAndSettle();
}

void main() {
  tearDown(() {
    screenshotRequestSignal.value = null;
    captureInProgress.value = false;
  });

  testWidgets('W-SHOT-01/02 浮窗截图默认 hideLoop=true；完成 → upload 一次 → img_ 附件', (tester) async {
    final h = await _pumpFloatingShell(tester);
    await tester.tap(find.byKey(const Key('floating-screenshot')));
    await _requestAndWaitOverlay(tester);
    expect(h.screenshots.hideLoopRequests, [true]);
    expect(h.screenshots.startCalls, 1);

    await _completeOverlay(tester);
    expect(find.byKey(const Key('screenshot-overlay')), findsNothing);
    expect(h.screenshots.restoreCalls, 1);
    expect(h.api.uploadCalls, 1);
    expect(h.chatKey.currentState!.attachmentCount, 1);
    expect(find.text('截图已加入附件'), findsOneWidget);

    // 附件在浮窗内可预览（图片可能加载失败，errorBuilder 仍在对话框内）。
    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('chat-composer')),
        matching: find.byType(Image),
      ),
      warnIfMissed: false,
    );
    await tester.pump();
    expect(find.byType(ImagePreview), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.descendant(
      of: find.byType(ImagePreview),
      matching: find.byTooltip('关闭'),
    ));
    await tester.pump();

    // 切换形态附件不丢。
    await h.host.toggleFloating();
    await tester.pump();
    expect(h.chatKey.currentState!.attachmentCount, 1);
    await _flushSnack(tester);
  });

  testWidgets('W-SHOT-03 取消：无 upload、无附件、restore 一次', (tester) async {
    final h = await _pumpFloatingShell(tester);
    await tester.tap(find.byKey(const Key('floating-screenshot')));
    await _requestAndWaitOverlay(tester);
    await _cancelOverlay(tester);

    expect(h.screenshots.restoreCalls, 1);
    expect(h.api.uploadCalls, 0);
    expect(h.chatKey.currentState!.attachmentCount, 0);
    await _flushSnack(tester);
  });

  testWidgets('W-SHOT-04 重截：start 两次、restore 两次、最终完成上传一次', (tester) async {
    final h = await _pumpFloatingShell(tester);
    await tester.tap(find.byKey(const Key('floating-screenshot')));
    await _requestAndWaitOverlay(tester);
    await _retakeOverlay(tester);
    expect(h.screenshots.startCalls, 2);
    expect(h.screenshots.restoreCalls, 1);
    expect(find.byKey(const Key('screenshot-overlay')), findsOneWidget);

    await _completeOverlay(tester);
    expect(h.screenshots.startCalls, 2);
    expect(h.screenshots.restoreCalls, 2);
    expect(h.api.uploadCalls, 1);
    expect(h.chatKey.currentState!.attachmentCount, 1);
    await _flushSnack(tester);
  });

  testWidgets('W-SHOT-05 重截 3 次后第 4 次提示上限', (tester) async {
    final h = await _pumpFloatingShell(tester);
    await tester.tap(find.byKey(const Key('floating-screenshot')));
    await _requestAndWaitOverlay(tester);
    await _retakeOverlay(tester);
    await _retakeOverlay(tester);
    await _retakeOverlay(tester);
    expect(h.screenshots.startCalls, 4);
    expect(h.screenshots.restoreCalls, 3);

    await _retakeOverlay(tester);
    expect(find.text('重截次数已用完（最多 3 次）'), findsOneWidget);
    expect(h.screenshots.startCalls, 4);
    expect(h.screenshots.restoreCalls, 4);
    expect(find.byKey(const Key('screenshot-overlay')), findsNothing);
    expect(h.api.uploadCalls, 0);
    await _flushSnack(tester);
  });

  testWidgets('W-SHOT-06 上传失败：无附件、提示、restore 一次', (tester) async {
    final h = await _pumpFloatingShell(tester);
    h.api.uploadError = ApiException('上传失败，请重试');
    await tester.tap(find.byKey(const Key('floating-screenshot')));
    await _requestAndWaitOverlay(tester);
    await _completeOverlay(tester);

    expect(h.api.uploadCalls, 0);
    expect(h.chatKey.currentState!.attachmentCount, 0);
    expect(h.screenshots.restoreCalls, 1);
    expect(find.text('上传失败，请重试'), findsOneWidget);
    await _flushSnack(tester);
  });

  testWidgets('W-SHOT-07 截图恢复保持浮窗：session 快照含 mode/minSize/置顶', (tester) async {
    final h = await _pumpFloatingShell(tester);
    await tester.tap(find.byKey(const Key('floating-screenshot')));
    await _requestAndWaitOverlay(tester);
    await _cancelOverlay(tester);

    final session = h.screenshots.started.single;
    expect(session.snapshot.mode, LoopWindowMode.floating);
    expect(session.snapshot.minSize, floatingMinSize);
    expect(session.snapshot.alwaysOnTop, isTrue);
    expect(session.snapshot.pinned, isTrue);
    expect(session.hidden, isTrue);
    expect(h.screenshots.restored.single, same(session));
    await _flushSnack(tester);
  });

  testWidgets('W-SHOT-08 浮窗截图按钮右键菜单“直接截图”→ hideLoop=false', (tester) async {
    final h = await _pumpFloatingShell(tester);
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('floating-screenshot'))),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.text('直接截图'), findsOneWidget);
    await tester.tap(find.text('直接截图'));
    await _requestAndWaitOverlay(tester);

    expect(h.screenshots.hideLoopRequests, [false]);
    await _cancelOverlay(tester);
    await _flushSnack(tester);
  });

  testWidgets('W-SHOT-09 同一 nonce 不重复截图；新 nonce 可再次截图', (tester) async {
    final h = await _pumpFloatingShell(tester);
    screenshotRequestSignal.value =
        const ScreenshotRequest(hideLoop: true, nonce: 101);
    screenshotRequestSignal.value =
        const ScreenshotRequest(hideLoop: true, nonce: 101);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    });
    await tester.pump();
    expect(h.screenshots.startCalls, 1);
    await _cancelOverlay(tester);

    screenshotRequestSignal.value =
        const ScreenshotRequest(hideLoop: false, nonce: 102);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    });
    await tester.pump();
    expect(h.screenshots.startCalls, 2);
    expect(h.screenshots.hideLoopRequests, [true, false]);
    await _cancelOverlay(tester);
    await _flushSnack(tester);
  });

  testWidgets('W-SHOT-10 发送中截图请求被拒绝并提示（不丢请求）', (tester) async {
    final h = await _pumpFloatingShell(tester);
    await tester.enterText(find.byKey(const Key('chat-input')), '正在生成');
    await tester.pump();
    await tester.tap(find.byKey(const Key('chat-send-stop')));
    await tester.pump();
    h.api.events.add(SseEvent('run', {'run_id': 12}));
    await tester.pump();

    await tester.tap(find.byKey(const Key('floating-screenshot')));
    await tester.pump();
    await tester.pump();
    expect(h.screenshots.startCalls, 0);
    expect(find.text('等这条回答结束再截图'), findsOneWidget);

    if (!h.api.events.isClosed) await h.api.events.close();
    await tester.pump();
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
  });

  testWidgets('W-SHOT-11 截图流程进行中按钮禁用，不并发截图', (tester) async {
    final h = await _pumpFloatingShell(tester);
    await tester.tap(find.byKey(const Key('floating-screenshot')));
    await _requestAndWaitOverlay(tester);
    // 覆盖层在顶层；再次投递请求会被 active/_screenshotting 守卫忽略。
    requestScreenshot(hideLoop: true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(h.screenshots.startCalls, 1);
    await _cancelOverlay(tester);
    await _flushSnack(tester);
  });
}
