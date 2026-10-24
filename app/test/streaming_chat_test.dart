import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loop/api.dart';
import 'package:loop/models.dart';
import 'package:loop/screens/chat_screen.dart';
import 'package:loop/state.dart';
import 'package:loop/theme.dart';

/// 假后端：不访问网络，chat() 返回可控的 SSE 事件流。
class _FakeLoopApi extends LoopApi {
  _FakeLoopApi() : super(baseUrl: 'http://127.0.0.1:1');

  final StreamController<SseEvent> events = StreamController<SseEvent>();
  final List<int> cancelledRuns = [];
  final List<(int, bool)> approvals = [];
  int chatCalls = 0;

  @override
  Future<List<Conversation>> conversations() async => [];

  @override
  Future<int> createConversation({String title = '新对话'}) async => 1;

  @override
  Future<List<Message>> messages(int conversationId) async => [];

  @override
  Stream<SseEvent> chat({
    required int conversationId,
    required String text,
    List<String> attachments = const [],
    String mode = 'answer',
    String modePrompt = '',
    String thinking = 'medium',
  }) {
    chatCalls++;
    return events.stream;
  }

  @override
  Future<void> cancelRun(int runId) async => cancelledRuns.add(runId);

  @override
  Future<void> approveRun(int runId, bool allow) async => approvals.add((runId, allow));
}

AppState _stateFor(_FakeLoopApi fake, {required bool streamOutput}) {
  return AppState(api: fake)
    ..settings = SettingsData(
      apiKeyMasked: '',
      hasKey: false,
      baseUrl: 'https://api.deepseek.com',
      model: 'deepseek-flash',
      reasonModel: 'deepseek-v4-pro',
      streamOutput: streamOutput,
    );
}

Future<AppState> _pumpChat(
  WidgetTester tester,
  _FakeLoopApi fake, {
  required bool streamOutput,
}) async {
  final state = _stateFor(fake, streamOutput: streamOutput);
  await tester.pumpWidget(MaterialApp(
    theme: loopTheme(LoopPalette.light),
    home: Scaffold(body: ChatScreen(active: true, state: state)),
  ));
  await tester.pumpAndSettle();
  return state;
}

Future<void> _sendText(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField), text);
  await tester.pump();
  await tester.tap(find.byTooltip('发送'));
  await tester.pump();
}

void main() {
  late _FakeLoopApi fake;

  setUp(() {
    fake = _FakeLoopApi();
  });

  tearDown(() {
    if (!fake.events.isClosed) fake.events.close();
  });

  testWidgets('F6 开启流式：delta 逐条增量显示，done 后正常收尾', (tester) async {
    final state = await _pumpChat(tester, fake, streamOutput: true);
    expect(state.streamOutput, isTrue);
    await _sendText(tester, '测试');

    fake.events.add(SseEvent('run', {'run_id': 1}));
    await tester.pump();

    fake.events.add(SseEvent('delta', {'text': '答'}));
    await tester.pump();
    expect(find.text('答'), findsOneWidget);
    expect(find.text('答案'), findsNothing);

    fake.events.add(SseEvent('delta', {'text': '案'}));
    await tester.pump();
    expect(find.text('答案'), findsOneWidget);

    fake.events.add(SseEvent('done', {
      'message_id': 1,
      'tokens_in': 10,
      'tokens_out': 5,
      'cost': 0.0,
      'refs': <Map<String, dynamic>>[],
    }));
    await tester.pump();
    await fake.events.close();
    await tester.pumpAndSettle();

    expect(find.text('10 in · 5 out'), findsOneWidget);
    expect(find.text('复制 Markdown'), findsOneWidget);
    expect(find.byTooltip('发送'), findsOneWidget);
  });

  testWidgets('F7 关闭流式：等待期显示“正在思考…”，step/plan 实时，正文一次到达', (tester) async {
    final state = await _pumpChat(tester, fake, streamOutput: false);
    expect(state.streamOutput, isFalse);
    await _sendText(tester, '测试');

    expect(find.text('正在思考…'), findsOneWidget);

    fake.events.add(SseEvent('run', {'run_id': 2}));
    fake.events.add(SseEvent('step', {
      'name': 'get_today',
      'status': 'running',
      'detail': '',
    }));
    await tester.pump();
    expect(find.text('今日统计'), findsOneWidget);
    expect(find.text('正在思考…'), findsOneWidget);
    expect(find.text('完整回答'), findsNothing);

    fake.events.add(SseEvent('plan', {
      'items': [
        {'id': '1', 'title': '检索资料', 'status': 'pending'},
      ],
    }));
    await tester.pump();
    expect(find.text('执行计划'), findsOneWidget);
    expect(find.text('检索资料'), findsOneWidget);
    expect(find.text('正在思考…'), findsOneWidget);

    // 关闭流式时整段正文只在最后发一次 delta。
    fake.events.add(SseEvent('delta', {'text': '**完整回答**'}));
    await tester.pump();
    expect(find.text('完整回答'), findsOneWidget);
    expect(find.text('正在思考…'), findsNothing);
    expect(find.text('今日统计'), findsOneWidget);

    fake.events.add(SseEvent('step', {
      'name': 'get_today',
      'status': 'done',
      'detail': '0 个待办',
    }));
    fake.events.add(SseEvent('done', {
      'message_id': 2,
      'tokens_in': 20,
      'tokens_out': 8,
      'cost': 0.0,
      'refs': <Map<String, dynamic>>[],
    }));
    await tester.pump();
    await fake.events.close();
    await tester.pumpAndSettle();

    expect(find.text('完整回答'), findsOneWidget);
    expect(find.text('今日统计'), findsOneWidget);
    expect(find.text('复制 Markdown'), findsOneWidget);
    expect(find.text('20 in · 8 out'), findsOneWidget);
  });

  testWidgets('F8 停止：调用 cancelRun，cancelled 后正文保留并提示', (tester) async {
    await _pumpChat(tester, fake, streamOutput: false);
    await _sendText(tester, '测试');

    fake.events.add(SseEvent('run', {'run_id': 42}));
    await tester.pump();
    await tester.tap(find.byTooltip('停止'));
    await tester.pump();
    await tester.pump();
    expect(fake.cancelledRuns, [42]);

    fake.events.add(SseEvent('delta', {'text': '部分回答'}));
    await tester.pump();
    expect(find.text('部分回答'), findsOneWidget);

    fake.events.add(SseEvent('cancelled', {'message_id': 9, 'partial': true}));
    await tester.pump();
    expect(find.text('已停止本次执行'), findsOneWidget);
    expect(find.text('部分回答'), findsOneWidget);
    expect(find.byTooltip('发送'), findsOneWidget);

    await fake.events.close();
    await tester.pump();
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
  });

  testWidgets('F9 error 事件移除助手气泡并提示，不崩溃', (tester) async {
    await _pumpChat(tester, fake, streamOutput: false);
    await _sendText(tester, '测试');

    fake.events.add(SseEvent('run', {'run_id': 7}));
    fake.events.add(SseEvent('error', {'message': '模型不可用'}));
    await tester.pump();
    expect(find.text('模型不可用'), findsOneWidget);
    expect(find.text('正在思考…'), findsNothing);

    await fake.events.close();
    await tester.pump();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    expect(find.text('模型不可用'), findsNothing);
  });

  testWidgets('F10 关闭流式时 approval 仍立即出现并可允许', (tester) async {
    await _pumpChat(tester, fake, streamOutput: false);
    await _sendText(tester, '测试');

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
    expect(find.text('需要你确认：fs_write'), findsNothing);

    await fake.events.close();
    await tester.pump();
  });
}
