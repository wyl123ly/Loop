import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loop/api.dart';
import 'package:loop/desktop/floating_signals.dart';
import 'package:loop/main.dart';
import 'package:loop/screens/chat_screen.dart';
import 'package:loop/state.dart';
import 'package:loop/theme.dart';

import 'support/fake_floating_host.dart';
import 'support/fake_loop_api.dart';
import 'support/fake_screenshot_service.dart';

Future<AppState> _pumpChat(
  WidgetTester tester,
  FakeLoopApi fake, {
  bool floating = true,
  bool compact = false,
  Size size = const Size(460, 600),
  bool streamOutput = true,
  FakeScreenshotService? screenshots,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final state = fakeAppState(fake, streamOutput: streamOutput);
  await tester.pumpWidget(MaterialApp(
    theme: loopTheme(LoopPalette.light),
    home: Scaffold(
      body: ChatScreen(
        active: true,
        state: state,
        floating: floating,
        compact: compact,
        screenshots: screenshots,
      ),
    ),
  ));
  await tester.pumpAndSettle();
  return state;
}

Future<void> _send(WidgetTester tester, String text) async {
  await tester.enterText(find.byKey(const Key('chat-input')), text);
  await tester.pump();
  await tester.tap(find.byKey(const Key('chat-send-stop')));
  await tester.pump();
}

Future<void> _finishStream(WidgetTester tester, FakeLoopApi fake) async {
  if (!fake.events.isClosed) await fake.events.close();
  await tester.pump();
  await tester.pump(const Duration(seconds: 4));
  await tester.pumpAndSettle();
}

/// Shell + 真实 ChatScreen（其余页面用占位），用于验证切换不重建 State。
///
/// 使用合法的普通窗口尺寸 900×600 起步：真实 normal 窗口不可能小于 900×600；
/// 更小约束只出现在过渡帧，由 FloatingQaScaffold 的最小尺寸守卫处理（T5-05）。
Future<(FakeLoopApi, AppState, FakeFloatingHost, GlobalKey<ChatScreenState>)>
    _pumpShell(WidgetTester tester, {Size size = const Size(900, 600)}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final api = FakeLoopApi();
  final state = fakeAppState(api);
  final host = FakeFloatingHost();
  final shots = FakeScreenshotService(
    bytes: await makeTestPng(tester, size.width.round(), size.height.round()),
  );
  final chatKey = GlobalKey<ChatScreenState>();
  final screens = <Widget>[
    ChatScreen(
      key: chatKey,
      active: true,
      state: state,
      floating: true,
      compact: true,
      screenshots: shots,
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
      state: state,
      modeHost: host,
      screensOverride: screens,
      screenshots: shots,
    ),
  ));
  await tester.pumpAndSettle();
  return (api, state, host, chatKey);
}

void main() {
  late FakeLoopApi fake;

  setUp(() {
    fake = FakeLoopApi();
  });

  tearDown(() {
    if (!fake.events.isClosed) fake.events.close();
    screenshotRequestSignal.value = null;
    captureInProgress.value = false;
  });

  testWidgets('W-CHAT-01 发送后切换浮窗：消息仍在、chatCalls==1、State 不变', (tester) async {
    final (api, _, host, chatKey) = await _pumpShell(tester);
    final before = chatKey.currentState!;
    await _send(tester, '浮窗保活测试');
    api.events.add(SseEvent('run', {'run_id': 1}));
    api.events.add(SseEvent('delta', {'text': '回答第一段'}));
    await tester.pump();
    expect(find.text('浮窗保活测试'), findsOneWidget);

    await host.toggleFloating();
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(host.isFloating, isTrue);
    expect(api.chatCalls, 1);
    expect(find.text('浮窗保活测试'), findsOneWidget);
    expect(find.text('回答第一段'), findsOneWidget);
    expect(identical(chatKey.currentState, before), isTrue);
    expect(before.messageCount, 2);
    expect(api.createConversationCalls, 1, reason: '切换不得新建会话');

    await _finishStream(tester, api);
  });

  testWidgets('W-CHAT-02 流式中切换 2 次：delta 继续、done 完整、无重复', (tester) async {
    final (api, _, host, chatKey) = await _pumpShell(tester);
    final before = chatKey.currentState!;
    await _send(tester, '慢速回答');
    api.events.add(SseEvent('run', {'run_id': 2}));
    api.events.add(SseEvent('delta', {'text': '一'}));
    await tester.pump();

    await host.toggleFloating();
    await tester.pump();
    await host.toggleFloating();
    await tester.pump();
    expect(host.isFloating, isFalse);
    expect(identical(chatKey.currentState, before), isTrue);

    api.events.add(SseEvent('delta', {'text': '二'}));
    await tester.pump();
    api.events.add(SseEvent('delta', {'text': '三'}));
    await tester.pump();
    expect(find.text('一二三'), findsOneWidget);

    api.events.add(SseEvent('done', {
      'message_id': 3,
      'tokens_in': 10,
      'tokens_out': 5,
      'cost': 0.0,
      'refs': <Map<String, dynamic>>[],
    }));
    await tester.pump();
    await _finishStream(tester, api);

    expect(find.text('一二三'), findsOneWidget);
    expect(find.text('10 in · 5 out'), findsOneWidget);
    expect(api.chatCalls, 1);
    expect(before.messageCount, 2);
    // 无重复字符：完整文本只出现一次。
    expect(find.text('一二三一二三'), findsNothing);
  });

  testWidgets('W-CHAT-03 浮窗中停止可用，cancelRun 恰好一次', (tester) async {
    await _pumpChat(tester, fake);
    await _send(tester, '停止测试');
    fake.events.add(SseEvent('run', {'run_id': 42}));
    await tester.pump();

    expect(find.byTooltip('停止'), findsOneWidget);
    await tester.tap(find.byKey(const Key('chat-send-stop')));
    await tester.pump();
    await tester.pump();
    expect(fake.cancelledRuns, [42]);

    fake.events.add(SseEvent('delta', {'text': '部分回答'}));
    await tester.pump();
    expect(find.text('部分回答'), findsOneWidget);

    fake.events.add(SseEvent('cancelled', {'message_id': 9, 'partial': true}));
    await tester.pump();
    expect(find.text('已停止本次执行'), findsOneWidget);
    expect(find.byTooltip('发送'), findsOneWidget);
    await _finishStream(tester, fake);
  });

  testWidgets('W-CHAT-05 返回主窗口看到同一回答（不重载历史）', (tester) async {
    final (api, _, host, chatKey) = await _pumpShell(tester);
    await _send(tester, '同一问答');
    api.events.add(SseEvent('run', {'run_id': 3}));
    api.events.add(SseEvent('done', {
      'message_id': 7,
      'tokens_in': 1,
      'tokens_out': 2,
      'cost': 0.0,
      'refs': <Map<String, dynamic>>[],
    }));
    await tester.pump();
    await _finishStream(tester, api);
    final callsAfterDone = api.messagesCalls;

    await host.toggleFloating();
    await tester.pump();
    await tester.tap(find.byKey(const Key('floating-back')));
    await tester.pump();
    expect(host.isFloating, isFalse);
    expect(find.text('同一问答'), findsOneWidget);
    expect(api.messagesCalls, callsAfterDone, reason: '切换不得重新拉取历史');
    expect(chatKey.currentState!.conversationId, 1);
  });

  testWidgets('W-CHAT-06 360×420 空态/长文/附件无溢出、输入常驻', (tester) async {
    final shots = FakeScreenshotService(bytes: await makeTestPng(tester, 360, 420));
    await _pumpChat(tester, fake, size: const Size(360, 420), compact: true, screenshots: shots);
    expect(find.byKey(const Key('floating-welcome')), findsOneWidget);
    expect(tester.takeException(), isNull);

    await _send(tester, '长回答');
    fake.events.add(SseEvent('run', {'run_id': 5}));
    final long = List.generate(120, (index) => '第 $index 行：矩阵的秩与特征值的关系，以及一个更长的中文说明用来撑开高度。').join('\n\n');
    fake.events.add(SseEvent('delta', {'text': long}));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('chat-input')), findsOneWidget);
    expect(find.byKey(const Key('chat-composer')), findsOneWidget);
    final composer = tester.widget<Container>(find.byKey(const Key('chat-composer')));
    final composerDecoration = composer.decoration! as BoxDecoration;
    expect(
      composerDecoration.borderRadius,
      const BorderRadius.vertical(top: Radius.circular(16)),
      reason: '输入框后面的横向背景必须与整体 UI 一样有顶部圆角',
    );
    expect(composer.clipBehavior, Clip.antiAlias);
    expect(find.byKey(const Key('chat-message-list')), findsOneWidget);
    await _finishStream(tester, fake);
    expect(tester.takeException(), isNull);
  });

  testWidgets('W-CHAT-07 上滚后不被拉回，回到底部胶囊可用', (tester) async {
    await _pumpChat(tester, fake, size: const Size(360, 420), compact: true);
    await _send(tester, '滚动测试');
    fake.events.add(SseEvent('run', {'run_id': 6}));
    final long = List.generate(80, (index) => '第 $index 段：滚动跟随测试内容，需要足够高。').join('\n\n');
    fake.events.add(SseEvent('delta', {'text': long}));
    await tester.pump();
    await tester.pump();

    final controller = tester.widget<ListView>(find.byKey(const Key('chat-message-list'))).controller!;
    expect(controller.offset, greaterThan(0));
    await tester.drag(find.byKey(const Key('chat-message-list')), const Offset(0, 260));
    await tester.pump();
    final offsetAfterDrag = controller.offset;
    expect(offsetAfterDrag, lessThan(controller.position.maxScrollExtent - 80));
    expect(find.byKey(const Key('chat-scroll-bottom')), findsOneWidget);

    fake.events.add(SseEvent('delta', {'text': '\n\n又来一段。'}));
    await tester.pump();
    expect(controller.offset, closeTo(offsetAfterDrag, 1.0));
    expect(find.byKey(const Key('chat-scroll-bottom')), findsOneWidget);

    await tester.tap(find.byKey(const Key('chat-scroll-bottom')));
    await tester.pump();
    expect(find.byKey(const Key('chat-scroll-bottom')), findsNothing);
    expect(controller.offset, closeTo(controller.position.maxScrollExtent, 1.0));
    await _finishStream(tester, fake);
  });

  testWidgets('W-CHAT-09 关闭流式：等待期“正在思考…”+ 正文一次到达（浮窗）', (tester) async {
    final state = await _pumpChat(tester, fake, floating: true, streamOutput: false);
    expect(state.streamOutput, isFalse);
    await _send(tester, '非流式');
    expect(find.text('正在思考…'), findsOneWidget);

    fake.events.add(SseEvent('run', {'run_id': 8}));
    fake.events.add(SseEvent('step', {'name': 'get_today', 'status': 'running', 'detail': ''}));
    await tester.pump();
    expect(find.text('今日统计'), findsOneWidget);

    fake.events.add(SseEvent('plan', {
      'items': [
        {'id': '1', 'title': '检索资料', 'status': 'pending'},
      ],
    }));
    await tester.pump();
    expect(find.text('执行计划'), findsOneWidget);

    fake.events.add(SseEvent('delta', {'text': '**完整回答**'}));
    await tester.pump();
    expect(find.text('完整回答'), findsOneWidget);
    expect(find.text('正在思考…'), findsNothing);

    fake.events.add(SseEvent('step', {'name': 'get_today', 'status': 'done', 'detail': '0 个待办'}));
    fake.events.add(SseEvent('done', {
      'message_id': 10,
      'tokens_in': 20,
      'tokens_out': 8,
      'cost': 0.0,
      'refs': <Map<String, dynamic>>[],
    }));
    await tester.pump();
    await _finishStream(tester, fake);
    expect(find.text('20 in · 8 out'), findsOneWidget);
  });

  testWidgets('W-CHAT-10 浮窗中审批可允许/拒绝', (tester) async {
    await _pumpChat(tester, fake);
    await _send(tester, '审批测试');
    fake.events.add(SseEvent('run', {'run_id': 9}));
    fake.events.add(SseEvent('approval', {
      'run_id': 9,
      'tool': 'fs_write',
      'args': {'path': 'a.txt'},
      'risk': 'high',
    }));
    await tester.pump();
    expect(find.text('需要你确认：fs_write'), findsOneWidget);
    await tester.tap(find.text('允许'));
    await tester.pump();
    await tester.pump();
    expect(fake.approvals, [(9, true)]);

    fake.events.add(SseEvent('approval', {
      'run_id': 9,
      'tool': 'fs_write',
      'args': {'path': 'b.txt'},
      'risk': 'high',
    }));
    await tester.pump();
    await tester.tap(find.text('拒绝'));
    await tester.pump();
    await tester.pump();
    expect(fake.approvals, [(9, true), (9, false)]);
    await _finishStream(tester, fake);
  });

  testWidgets('W-FOCUS-01 输入聚焦后 20 条 delta 焦点不变', (tester) async {
    await _pumpChat(tester, fake);
    await tester.tap(find.byKey(const Key('chat-input')));
    await tester.pump();
    final focused = FocusManager.instance.primaryFocus;
    expect(focused, isNotNull);

    await _send(tester, '焦点测试');
    fake.events.add(SseEvent('run', {'run_id': 11}));
    for (var i = 0; i < 20; i++) {
      fake.events.add(SseEvent('delta', {'text': '$i'}));
      await tester.pump();
    }
    expect(FocusManager.instance.primaryFocus, same(focused));
    await _finishStream(tester, fake);
  });

  testWidgets('W-CHAT-06b 浮窗隐藏页头、输入区无截图菜单；主窗口保留', (tester) async {
    await _pumpChat(tester, fake);
    expect(find.byTooltip('问答模式'), findsNothing);
    expect(find.byTooltip('新对话'), findsNothing);
    expect(find.byTooltip('截图'), findsNothing, reason: '浮窗截图入口收进 FloatingBar');
    expect(find.byTooltip('上传资料 / 图片'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());

    await _pumpChat(tester, fake, floating: false, compact: false);
    expect(find.byTooltip('问答模式'), findsOneWidget);
    expect(find.byTooltip('新对话'), findsOneWidget);
    expect(find.byTooltip('截图'), findsOneWidget);
  });

  testWidgets('W-UI-06c 暗色主题下浮窗空态/消息可读、无溢出', (tester) async {
    LoopTheme.palette = LoopPalette.dark;
    addTearDown(() => LoopTheme.palette = LoopPalette.light);
    await _pumpChat(tester, fake, size: const Size(360, 420), compact: true);
    expect(find.byKey(const Key('floating-welcome')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _send(tester, '暗色主题');
    fake.events.add(SseEvent('run', {'run_id': 21}));
    fake.events.add(SseEvent('delta', {'text': '**暗色回答**'}));
    await tester.pump();
    expect(find.text('暗色主题'), findsOneWidget);
    expect(find.text('暗色回答'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _finishStream(tester, fake);
  });

  testWidgets('W-UI-08 紧凑模式隐藏页脚提示、缩短 hint', (tester) async {
    await _pumpChat(tester, fake, size: const Size(360, 420), compact: true);
    expect(find.text('Enter 发送 · Shift + Enter 换行 · 每个对话独立上下文'), findsNothing);
    final field = tester.widget<TextField>(find.byKey(const Key('chat-input')));
    expect(field.maxLines, 4);
    expect(field.decoration?.hintText, '问点什么，或贴截图…');
    expect(tester.takeException(), isNull);
  });

  testWidgets('W-CHAT-12 360×420 工具步骤/计划/审批/错误均不溢出', (tester) async {
    await _pumpChat(tester, fake, size: const Size(360, 420), compact: true);
    await _send(tester, '小窗复杂状态');
    fake.events.add(SseEvent('run', {'run_id': 30}));
    fake.events.add(SseEvent('step', {'name': 'get_today', 'status': 'running', 'detail': ''}));
    fake.events.add(SseEvent('plan', {
      'items': [
        {'id': '1', 'title': '第一步：检索资料并核对页码', 'status': 'in_progress'},
        {'id': '2', 'title': '第二步：写一段很长的中文结论', 'status': 'pending'},
      ],
    }));
    await tester.pump();
    expect(find.text('执行计划'), findsOneWidget);
    expect(find.text('今日统计'), findsOneWidget);
    expect(tester.takeException(), isNull);

    fake.events.add(SseEvent('approval', {
      'run_id': 30,
      'tool': 'fs_write',
      'args': {'path': '一个很长很长的文件路径/草稿.md'},
      'risk': 'high',
    }));
    await tester.pump();
    expect(find.text('需要你确认：fs_write'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('拒绝'));
    await tester.pump();
    expect(fake.approvals, [(30, false)]);

    fake.events.add(SseEvent('step', {'name': 'get_today', 'status': 'done', 'detail': '0 个待办'}));
    fake.events.add(SseEvent('error', {'message': '模型不可用'}));
    await tester.pump();
    expect(find.text('模型不可用'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _finishStream(tester, fake);
    expect(tester.takeException(), isNull);
  });

  testWidgets('W-CHAT-04 附件（截图）在切换后仍保留', (tester) async {
    final shots = FakeScreenshotService(bytes: await makeTestPng(tester, 460, 600));
    await _pumpChat(tester, fake, size: const Size(460, 600), screenshots: shots);
    requestScreenshot(hideLoop: true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(shots.startCalls, 1);
    // 开着的覆盖层：取消
    expect(find.byKey(const Key('screenshot-overlay')), findsOneWidget);
    await tester.tap(find.byKey(const Key('screenshot-cancel')));
    await tester.pump();
    expect(shots.restoreCalls, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
