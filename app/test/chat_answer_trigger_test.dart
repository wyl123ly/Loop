import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loop/api.dart';
import 'package:loop/desktop/floating_signals.dart';
import 'package:loop/models.dart';
import 'package:loop/screens/chat_screen.dart';
import 'package:loop/state.dart';
import 'package:loop/theme.dart';

import 'support/fake_loop_api.dart';
import 'support/fake_screenshot_service.dart';

class _RecordingApi extends FakeLoopApi {
  List<String> lastAttachments = const <String>[];

  @override
  Stream<SseEvent> chat({
    required int conversationId,
    required String text,
    List<String> attachments = const [],
    String mode = 'answer',
    String modePrompt = '',
    String thinking = 'medium',
  }) {
    lastAttachments = List<String>.of(attachments);
    return super.chat(
      conversationId: conversationId,
      text: text,
      attachments: attachments,
      mode: mode,
      modePrompt: modePrompt,
      thinking: thinking,
    );
  }
}

class _FakeSink implements ChatAnswerSink {
  final List<ChatSubmission> submissions = [];
  final List<String> deltas = [];
  final List<int?> runIds = [];
  final List<List<PlanItem>> plans = [];
  final List<(String, String?, bool)> statuses = [];
  final List<List<RefItem>> completions = [];
  int stops = 0;
  final List<String> failures = [];

  @override
  void submit(ChatSubmission submission) => submissions.add(submission);

  @override
  void appendText(String delta) => deltas.add(delta);

  @override
  void setRunId(int? runId) => runIds.add(runId);

  @override
  void setPlan(List<PlanItem> plan) => plans.add(plan);

  @override
  void setStatus(String state, {String? label, bool approvalRequired = false}) {
    statuses.add((state, label, approvalRequired));
  }

  @override
  void complete({List<RefItem> refs = const []}) => completions.add(refs);

  @override
  void stop() => stops++;

  @override
  void fail(String message) => failures.add(message);
}

class _Harness {
  late _RecordingApi api;
  late AppState state;
  late _FakeSink sink;
  late GlobalKey<ChatScreenState> chatKey;
  late FakeScreenshotService screenshots;
  late ValueNotifier<ScreenshotRequest?> signal;
}

Future<_Harness> _pumpChat(
  WidgetTester tester, {
  bool minimal = false,
  bool floating = false,
  bool withScreenshots = false,
}) async {
  tester.view.physicalSize = minimal ? const Size(360, 52) : const Size(900, 600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final harness = _Harness();
  harness.api = _RecordingApi();
  harness.state = fakeAppState(harness.api);
  harness.sink = _FakeSink();
  harness.chatKey = GlobalKey<ChatScreenState>();
  harness.signal = ValueNotifier<ScreenshotRequest?>(null);
  addTearDown(harness.signal.dispose);
  harness.screenshots = FakeScreenshotService(
    bytes: await makeTestPng(
      tester,
      minimal ? 360 : 900,
      minimal ? 52 : 600,
    ),
  );
  await tester.pumpWidget(MaterialApp(
    theme: loopTheme(LoopPalette.light),
    home: Scaffold(
      body: ChatScreen(
        key: harness.chatKey,
        active: true,
        state: harness.state,
        floating: floating,
        minimal: minimal,
        answerSink: harness.sink,
        screenshots: withScreenshots ? harness.screenshots : null,
        screenshotSignal: harness.signal,
        onMinimalBack: () {},
        onMinimalExpand: () {},
        onMinimalDragStart: () {},
      ),
    ),
  ));
  await tester.pumpAndSettle();
  return harness;
}

Future<void> _send(WidgetTester tester, String text, {bool minimal = false}) async {
  await tester.enterText(
    find.byKey(Key(minimal ? 'minimal-input' : 'chat-input')),
    text,
  );
  await tester.pump();
  await tester.tap(find.byKey(Key(minimal ? 'minimal-send-stop' : 'chat-send-stop')));
  await tester.pump();
  await tester.pump();
}

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

Future<void> _flushSnack(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 4));
  await tester.pumpAndSettle();
}

void main() {
  tearDown(() {
    screenshotRequestSignal.value = null;
    captureInProgress.value = false;
  });

  testWidgets('W-TRIG-01 极简形态非空提交才创建回答窗；SSE 全事件转发、主聊天不被改写', (tester) async {
    final h = await _pumpChat(tester, minimal: true);
    await _send(tester, '  什么是极限？  ', minimal: true);

    expect(h.api.chatCalls, 1);
    expect(h.sink.submissions.length, 1);
    final submission = h.sink.submissions.single;
    expect(submission.question, '什么是极限？');
    expect(submission.conversationId, 1);
    expect(submission.runId, isNull);
    expect(submission.inputBarRect, isNotNull);
    expect(submission.inputBarRect!.height, greaterThan(0));
    expect(submission.themeMode, ThemeMode.system);

    h.api.events.add(SseEvent('run', {'run_id': 5}));
    h.api.events.add(SseEvent('delta', {'text': '极限'}));
    h.api.events.add(SseEvent('plan', {
      'items': [
        {'id': 'p1', 'title': '检索资料', 'status': 'pending'},
      ],
    }));
    h.api.events.add(SseEvent('approval', {
      'run_id': 5,
      'tool': 'fs_write',
      'args': {'path': 'a.txt'},
    }));
    await tester.pump();

    expect(h.sink.runIds, [5]);
    expect(h.sink.deltas, ['极限']);
    expect(h.sink.plans.single.single.title, '检索资料');
    expect(h.sink.statuses.any((item) => item.$1 == 'waiting_approval' && item.$3), isTrue);
    expect(h.chatKey.currentState!.messageCount, 2, reason: '主聊天仍保留 user+assistant');

    h.api.events.add(SseEvent('done', {
      'message_id': 7,
      'tokens_in': 3,
      'tokens_out': 4,
      'cost': 0.0,
      'refs': [
        {'name': '高数.pdf', 'page': 9},
      ],
    }));
    await tester.pump();
    await h.api.events.close();
    await tester.pumpAndSettle();

    expect(h.sink.completions.single.single.page, 9);
    expect(h.chatKey.currentState!.messageCount, 2);
    expect(h.chatKey.currentState!.isSending, isFalse);
  });

  testWidgets('W-TRIG-02 空文本/纯空格不发送、不创建回答窗', (tester) async {
    final h = await _pumpChat(tester);

    await tester.tap(find.byKey(const Key('chat-send-stop')));
    await tester.pump();
    await _send(tester, '   ');
    expect(h.api.chatCalls, 0);
    expect(h.sink.submissions, isEmpty);
    expect(h.chatKey.currentState!.messageCount, 0);
  });

  testWidgets('W-TRIG-03 附件-only：不创建回答窗，主聊天照常发送附件', (tester) async {
    final h = await _pumpChat(tester, withScreenshots: true);
    h.signal.value = const ScreenshotRequest(hideLoop: true, nonce: 1);
    await _requestAndWaitOverlay(tester);
    await _completeOverlay(tester);
    expect(h.api.uploadCalls, 1);
    expect(h.chatKey.currentState!.attachmentCount, 1);

    await tester.tap(find.byKey(const Key('chat-send-stop')));
    await tester.pump();
    await tester.pump();

    expect(h.api.chatCalls, 1);
    expect(h.api.lastAttachments.length, 1);
    expect(h.sink.submissions, isEmpty, reason: '附件-only 不创建回答窗');

    h.api.events.add(SseEvent('delta', {'text': '附件回答'}));
    h.api.events.add(SseEvent('done', {
      'message_id': 8,
      'tokens_in': 1,
      'tokens_out': 1,
      'cost': 0.0,
      'refs': <Map<String, dynamic>>[],
    }));
    await tester.pump();
    expect(h.sink.deltas, isEmpty, reason: '没有回答窗时不推送镜像');
    expect(h.sink.completions, isEmpty);

    await h.api.events.close();
    await tester.pump();
    await _flushSnack(tester);
  });

  testWidgets('W-TRIG-04 停止：cancelRun + cancelled → 回答窗“已停止”，主聊天保留正文', (tester) async {
    final h = await _pumpChat(tester, minimal: true);
    await _send(tester, '测试停止', minimal: true);
    h.api.events.add(SseEvent('run', {'run_id': 42}));
    h.api.events.add(SseEvent('delta', {'text': '部分回答'}));
    await tester.pump();
    await tester.tap(find.byKey(const Key('minimal-send-stop')));
    await tester.pump();
    await tester.pump();
    expect(h.api.cancelledRuns, [42]);

    h.api.events.add(SseEvent('cancelled', {'message_id': 9, 'partial': true}));
    await tester.pump();
    expect(h.sink.stops, 1);
    expect(h.chatKey.currentState!.messageCount, 2);
    expect(find.text('已停止本次执行'), findsOneWidget);

    await h.api.events.close();
    await tester.pump();
    await _flushSnack(tester);
  });

  testWidgets('W-TRIG-05 error 事件：回答窗进入 error，主聊天移除空气泡并提示', (tester) async {
    final h = await _pumpChat(tester, minimal: true);
    await _send(tester, '会失败的问题', minimal: true);
    h.api.events.add(SseEvent('run', {'run_id': 7}));
    h.api.events.add(SseEvent('error', {'message': '模型不可用'}));
    await tester.pump();

    expect(h.sink.failures, ['模型不可用']);
    expect(find.text('模型不可用'), findsOneWidget);
    expect(h.chatKey.currentState!.messageCount, 1, reason: '空助手气泡被移除');

    await h.api.events.close();
    await tester.pump();
    await _flushSnack(tester);
  });

  testWidgets('W-TRIG-06 极简条复用同一 ChatScreen：输入/发送/截图/返回/状态保活', (tester) async {
    final h = await _pumpChat(tester, minimal: true);
    final stateBefore = h.chatKey.currentState!;
    expect(find.byKey(const Key('minimal-bar')), findsOneWidget);
    expect(find.byKey(const Key('chat-input')), findsNothing);

    await _send(tester, '极简条提问', minimal: true);
    expect(h.api.chatCalls, 1);
    final submission = h.sink.submissions.single;
    expect(submission.question, '极简条提问');
    expect(submission.inputBarRect, isNotNull);
    expect(submission.inputBarRect!.width, greaterThan(200));

    h.api.events.add(SseEvent('run', {'run_id': 3}));
    h.api.events.add(SseEvent('delta', {'text': '流式'}));
    await tester.pump();
    expect(find.byTooltip('停止'), findsOneWidget);
    expect(h.sink.deltas, ['流式']);

    // 切回展开浮窗/主窗口后 State 不重建。
    tester.view.physicalSize = const Size(900, 600);
    await tester.pump();
    await tester.pumpWidget(MaterialApp(
      theme: loopTheme(LoopPalette.light),
      home: Scaffold(
        body: ChatScreen(
          key: h.chatKey,
          active: true,
          state: h.state,
          answerSink: h.sink,
          screenshots: h.screenshots,
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(identical(stateBefore, h.chatKey.currentState), isTrue);
    expect(find.byKey(const Key('minimal-bar')), findsNothing);
    expect(find.byKey(const Key('chat-input')), findsOneWidget);

    await h.api.events.close();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('W-TRIG-07 非极简浮窗提交不会创建回答窗，回答留在主聊天', (tester) async {
    final h = await _pumpChat(tester, floating: true);
    await _send(tester, '普通浮窗提问');

    expect(h.api.chatCalls, 1);
    expect(h.sink.submissions, isEmpty, reason: '普通浮窗不应创建回答窗');

    h.api.events.add(SseEvent('delta', {'text': '普通回答'}));
    await tester.pump();
    expect(h.sink.deltas, isEmpty, reason: '没有回答窗时不推送镜像');
    expect(find.text('普通回答'), findsOneWidget);

    h.api.events.add(SseEvent('done', {
      'message_id': 10,
      'tokens_in': 1,
      'tokens_out': 1,
      'cost': 0.0,
      'refs': <Map<String, dynamic>>[],
    }));
    await tester.pump();
    await h.api.events.close();
    await tester.pump();
    await _flushSnack(tester);
  });
}
