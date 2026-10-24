import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loop/answer_ui/answer_client.dart';
import 'package:loop/answer_ui/answer_widgets.dart';
import 'package:loop/answer_ui/answer_window_app.dart';
import 'package:loop/desktop/answer_host/answer_protocol.dart';
import 'package:loop/desktop/window_mode.dart'
    show
        AnswerWindowPlanner,
        answerChromeHeight,
        answerMaxHeightCap,
        answerMinHeight;
import 'package:loop/models.dart';
import 'package:loop/theme.dart';
import 'package:loop/widgets/markdown_text.dart';

/// 可编程的第二引擎传输 fake：记录 control 消息、注入失败、模拟主窗推送。
class _FakeTransport implements AnswerTransport {
  final List<(String, Map<String, Object?>)> sent = [];
  AnswerMessageHandler? streamHandler;
  AnswerMessageHandler? controlHandler;
  int sendFailures = 0;
  bool disposed = false;

  @override
  bool connected = true;

  @override
  Future<void> sendStream(String method, Map<String, Object?> arguments) async {
    sent.add((method, arguments));
  }

  @override
  Future<void> sendControl(String method, Map<String, Object?> arguments) async {
    if (sendFailures > 0) {
      sendFailures--;
      throw StateError('NO_HANDLER');
    }
    sent.add((method, arguments));
  }

  @override
  Future<void> setStreamHandler(AnswerMessageHandler? handler) async {
    streamHandler = handler;
  }

  @override
  Future<void> setControlHandler(AnswerMessageHandler? handler) async {
    controlHandler = handler;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
  }

  List<Map<String, Object?>> sentOf(String method) =>
      [for (final entry in sent) if (entry.$1 == method) entry.$2];

  Future<void> receive(String method, Map<String, Object?> arguments) async {
    final handler = streamHandler;
    if (handler == null) throw StateError('stream handler not registered');
    await handler(method, arguments);
  }
}

class _FakeDragDelegate implements AnswerDragDelegate {
  final List<String> calls = [];
  int? startedHwnd;
  Rect? finishRect = const Rect.fromLTWH(100, 50, 420, 300);

  @override
  bool get available => true;

  @override
  bool start(int? hwnd) {
    startedHwnd = hwnd;
    calls.add('start');
    return true;
  }

  @override
  void update() => calls.add('update');

  @override
  Rect? finish() {
    calls.add('finish');
    return finishRect;
  }

  @override
  void cancel() => calls.add('cancel');
}

(AnswerClient, _FakeTransport) _newClient({
  bool dark = false,
  Duration throttle = const Duration(milliseconds: 80),
}) {
  final transport = _FakeTransport();
  final client = AnswerClient(
    transport: transport,
    payload: AnswerLaunchPayload(dark: dark, themeMode: dark ? 'dark' : 'light'),
    windowId: 'w1',
    throttle: throttle,
  );
  addTearDown(client.dispose);
  return (client, transport);
}

Map<String, Object?> _snapshotMap({
  int seq = 1,
  String question = '问题',
  String answer = '',
  String status = 'thinking',
  List<Map<String, Object?>> plan = const [],
  List<Map<String, Object?>> refs = const [],
  String? error,
  int elapsedMs = 0,
}) {
  return AnswerSnapshot(
    conversationId: '1',
    runId: '2',
    question: question,
    answerMarkdown: answer,
    status: AnswerStatus.tryParse(status) ?? AnswerStatus.thinking,
    plan: plan,
    refs: refs,
    error: error,
    elapsedMs: elapsedMs,
    seq: seq,
  ).toMap();
}

Map<String, Object?> _statusMap(int seq, String state, {String? label, bool approval = false}) =>
    <String, Object?>{
      'seq': seq,
      'state': state,
      'label': label,
      'approvalRequired': approval,
      'runId': '2',
    };

AnswerViewState _view({
  String question = '问题',
  String answer = '',
  String status = 'done',
  String? statusLabel,
  bool approvalRequired = false,
  List<PlanItem> plan = const [],
  List<RefItem> refs = const [],
  String? error,
  int? elapsedMs,
  bool collapsed = false,
  bool hasSnapshot = true,
  int revision = 1,
  int scrollResetToken = 0,
  double minHeight = 180,
  double maxHeight = 760,
  bool dark = false,
  bool resyncing = false,
}) {
  return AnswerViewState(
    question: question,
    answer: answer,
    status: status,
    statusLabel: statusLabel,
    approvalRequired: approvalRequired,
    plan: plan,
    refs: refs,
    error: error,
    elapsedMs: elapsedMs,
    collapsed: collapsed,
    hasSnapshot: hasSnapshot,
    revision: revision,
    scrollResetToken: scrollResetToken,
    minHeight: minHeight,
    maxHeight: maxHeight,
    dark: dark,
    resyncing: resyncing,
  );
}

class _PanelHarness {
  int closes = 0;
  int collapses = 0;
  int expands = 0;
  int dragStarts = 0;
  int dragUpdates = 0;
  int dragEnds = 0;
  final List<double> heights = [];
}

Future<_PanelHarness> _pumpPanel(
  WidgetTester tester,
  AnswerViewState state, {
  Size size = const Size(420, 640),
}) async {
  final harness = _PanelHarness();
  LoopTheme.palette = state.dark ? LoopPalette.dark : LoopPalette.light;
  await tester.pumpWidget(MaterialApp(
    theme: loopTheme(LoopPalette.light),
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: size.width,
          height: size.height,
          child: AnswerPanel(
            state: state,
            onClose: () => harness.closes++,
            onCollapse: () => harness.collapses++,
            onExpand: () => harness.expands++,
            onDragStart: () => harness.dragStarts++,
            onDragUpdate: (_) => harness.dragUpdates++,
            onDragEnd: () => harness.dragEnds++,
            onDesiredHeight: harness.heights.add,
          ),
        ),
      ),
    ),
  ));
  await tester.pump();
  await tester.pump();
  return harness;
}

Future<void> _pumpApp(
  WidgetTester tester,
  _FakeTransport transport, {
  bool dark = false,
  AnswerDragDelegate? dragDelegate,
}) async {
  LoopTheme.palette = dark ? LoopPalette.dark : LoopPalette.light;
  final session = AnswerEngineSession(
    windowId: 'w1',
    payload: AnswerLaunchPayload(dark: dark, themeMode: dark ? 'dark' : 'light'),
    transport: transport,
  );
  await tester.pumpWidget(AnswerWindowApp(
    session: session,
    dragDelegate: dragDelegate,
    readyWorkArea: (_) => const Rect.fromLTWH(0, 0, 1920, 1040),
  ));
  await tester.pump();
  await tester.pump();
}

void main() {
  group('布局契约（复用主窗 planner）', () {
    test('A-GEO-01 宽度 35% 钳制、内容高 → 窗口 minH/maxH 钳制', () {
      const work = Rect.fromLTWH(0, 0, 1920, 1040);
      expect(AnswerWindowPlanner.widthLogical(work), 672); // 1920 × 0.35
      expect(AnswerWindowPlanner.widthLogical(const Rect.fromLTWH(0, 0, 1024, 768)),
          420);
      expect(
        AnswerWindowPlanner.widthLogical(const Rect.fromLTWH(0, 0, 3440, 1440)),
        900,
      );

      // 内容很短：窗口高度被 minH 钳制。
      expect(
        AnswerWindowPlanner.desiredHeightLogical(10, workLogical: work),
        answerMinHeight,
      );
      // 内容中等：窗口高 = 固定 chrome + 正文内容高。
      expect(
        AnswerWindowPlanner.desiredHeightLogical(300, workLogical: work),
        answerChromeHeight + 300,
      );
      // 超长内容：窗口高度被 maxH 钳制（1040×70% = 728 < 760）。
      expect(
        AnswerWindowPlanner.desiredHeightLogical(5000, workLogical: work),
        lessThanOrEqualTo(answerMaxHeightCap),
      );
      expect(
        AnswerWindowPlanner.desiredHeightLogical(5000, workLogical: work),
        728,
      );
    });
  });

  group('IPC 客户端（只读镜像）', () {
    test('A-IPC-01 hello/snapshot/delta/status/presentation/theme 解码', () async {
      final (client, transport) = _newClient();
      await Future<void>.delayed(Duration.zero);
      await transport.receive('hello', <String, Object?>{
        'protocol': 1,
        'windowId': 'w1',
        'hwnd': 4321,
        'widthLogical': 640,
        'minH': 180,
        'maxH': 700,
        'themeMode': 'dark',
        'dark': true,
        'fontFamily': 'NotoSC',
      });
      expect(client.widthLogical, 640);
      expect(client.windowHandle, 4321);
      expect(client.state.minHeight, 180);
      expect(client.state.maxHeight, 700);
      expect(client.state.dark, isTrue);
      expect(client.state.placeholder, '等待问题…');

      await transport.receive('snapshot', _snapshotMap(
        seq: 1,
        question: '什么是极限？',
        answer: '**极限**是',
        status: 'streaming',
        plan: [
          {'id': 'p1', 'title': '检索资料', 'status': 'pending'},
        ],
        refs: [
          {'name': '高数.pdf', 'page': 12},
        ],
        elapsedMs: 1500,
      ));
      expect(client.state.hasSnapshot, isTrue);
      expect(client.state.revision, 1);
      expect(client.state.question, '什么是极限？');
      expect(client.state.answer, '**极限**是');
      expect(client.state.status, 'streaming');
      expect(client.state.plan.single.title, '检索资料');
      expect(client.state.refs.single.page, 12);
      expect(client.state.elapsedMs, 1500);

      await transport.receive('delta', {'seq': 2, 'text': '定义'});
      expect(client.state.answer, '**极限**是定义');
      expect(client.state.status, 'streaming');

      await transport.receive('status', _statusMap(3, 'waiting_approval', label: '等待审批', approval: true));
      expect(client.state.status, 'waiting_approval');
      expect(client.state.approvalRequired, isTrue);
      expect(client.state.label, '等待审批');

      await transport.receive('presentation', {'collapsed': true});
      expect(client.state.collapsed, isTrue);
      await transport.receive('presentation', {'collapsed': false});
      expect(client.state.collapsed, isFalse);

      await transport.receive('theme', {'themeMode': 'light', 'dark': false});
      expect(client.state.dark, isFalse);

      await transport.receive('resize_ack', {'seq': 3, 'heightLogical': 240});
      expect(client.appliedHeightLogical, 240);
    });

    test('A-IPC-02 seq 断档只请求一次重同步，snapshot 重置', () async {
      final (client, transport) = _newClient();
      await Future<void>.delayed(Duration.zero);
      await transport.receive('snapshot', _snapshotMap(seq: 1, answer: 'A', status: 'streaming'));

      await transport.receive('delta', {'seq': 3, 'text': 'X'});
      expect(client.state.answer, 'A', reason: '断档增量不得应用');
      expect(client.state.resyncing, isTrue);
      await transport.receive('delta', {'seq': 4, 'text': 'Y'});
      expect(transport.sentOf('resync_requested').length, 1);

      await transport.receive('snapshot', _snapshotMap(
        seq: 10,
        answer: '全文',
        status: 'done',
        elapsedMs: 3000,
      ));
      expect(client.state.answer, '全文');
      expect(client.state.resyncing, isFalse);
      expect(client.state.revision, 2);

      await transport.receive('delta', {'seq': 11, 'text': '!'});
      expect(client.state.answer, '全文!');
    });

    test('A-IPC-03 测高上报：原始内容高、±2px 去抖、80ms 节流（钳制由主窗 planner）', () async {
      final (client, transport) = _newClient();
      await Future<void>.delayed(Duration.zero);
      await transport.receive('hello', {
        'protocol': 1,
        'minH': 200,
        'maxH': 600,
      });

      client.reportContentHeight(100);
      expect(transport.sentOf('content_height'), isEmpty, reason: '80ms 内不发');
      await Future<void>.delayed(const Duration(milliseconds: 120));
      final first = transport.sentOf('content_height');
      expect(first.length, 1);
      expect(first.single['heightLogical'], 100, reason: '上报原始内容高，钳制在主窗');
      expect(first.single['seq'], 1);

      client.reportContentHeight(101);
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(transport.sentOf('content_height').length, 1, reason: '±2px 去抖');

      client.reportContentHeight(900);
      await Future<void>.delayed(const Duration(milliseconds: 120));
      final heights = transport.sentOf('content_height');
      expect(heights.length, 2);
      expect(heights.last['heightLogical'], 900, reason: '内容高不做上限钳制');

      client.reportContentHeight(640);
      client.reportContentHeight(320);
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(transport.sentOf('content_height').last['heightLogical'], 320,
          reason: '同一窗口内合并为最后一次');
    });

    test('A-IPC-04 ready 在 NO_HANDLER 时 100ms 退避重试；彻底失败显示错误', () async {
      final (client, transport) = _newClient();
      transport.sendFailures = 2;
      final ok = await client.sendReady(
        dpr: 1.5,
        workAreaLogical: const Rect.fromLTWH(0, 0, 1920, 1040),
        contentHeightLogical: 180,
      );
      expect(ok, isTrue);
      final ready = transport.sentOf('ready').single;
      expect(ready['protocol'], answerProtocolVersion);
      expect(ready['windowId'], 'w1');
      expect(ready['dpr'], 1.5);
      expect(ready['contentHeightLogical'], 180);
      expect(ready['workAreaLogical'], isA<Map<String, Object?>>());
      expect(client.readySent, isTrue);

      final (failing, failingTransport) = _newClient();
      failingTransport.sendFailures = 100;
      final failed = await failing.sendReady(
        dpr: 1.0,
        workAreaLogical: const Rect.fromLTWH(0, 0, 100, 100),
      );
      expect(failed, isFalse);
      expect(failing.state.error, contains('无法连接主窗口'));
      expect(failing.state.hasSnapshot, isTrue);
    });

    test('A-IPC-05 收起/展开/关闭/拖动/moved/render_error/resync 控制消息', () async {
      final (client, transport) = _newClient();
      await client.requestCollapse();
      await client.requestExpand();
      await client.requestClose();
      await client.reportMoved(const Rect.fromLTWH(10, 20, 300, 200));
      await client.reportDragStarted();
      await client.reportDragEnded();
      await client.reportRenderError('E1', '渲染失败');
      await client.requestResync();
      await client.requestResync();

      expect(transport.sentOf('collapse_requested').length, 1);
      expect(transport.sentOf('expand_requested').length, 1);
      expect(transport.sentOf('close_requested').length, 1);
      expect(transport.sentOf('drag_started').length, 1);
      expect(transport.sentOf('drag_ended').length, 1);
      expect(transport.sentOf('render_error').single['code'], 'E1');
      expect(transport.sentOf('resync_requested').length, 1, reason: '去重');
      final moved = transport.sentOf('moved').single;
      final rect = decodeRect(moved['physicalRect']);
      expect(rect, const Rect.fromLTWH(10, 20, 300, 200));
    });

    test('A-IPC-06 流式正文通知 80ms 合并，首条立即', () async {
      final (client, transport) = _newClient(throttle: const Duration(milliseconds: 40));
      await Future<void>.delayed(Duration.zero);
      var notifications = 0;
      client.addListener(() => notifications++);

      await transport.receive('hello', {'protocol': 1});
      expect(notifications, 1, reason: 'hello 立即通知');

      await transport.receive('snapshot', _snapshotMap(seq: 1, status: 'streaming'));
      expect(notifications, 2);

      await Future<void>.delayed(const Duration(milliseconds: 60));
      await transport.receive('delta', {'seq': 2, 'text': 'a'});
      expect(notifications, 3, reason: '距上次通知超过窗口后立即通知');
      await transport.receive('delta', {'seq': 3, 'text': 'b'});
      await transport.receive('delta', {'seq': 4, 'text': 'c'});
      expect(notifications, 3, reason: '40ms 窗口内合并');
      expect(client.state.answer, 'abc');
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(notifications, 4);
    });

    test('A-IPC-07 协议不兼容/未知方法不崩溃、不写正文日志', () async {
      final (client, transport) = _newClient();
      await Future<void>.delayed(Duration.zero);
      await transport.receive('hello', {'protocol': 99});
      expect(client.state.error, contains('不兼容'));
      await transport.receive('unknown_method', {'text': 'secret'});
      expect(client.state.error, contains('不兼容'));
    });

    test('A-IPC-08 T5-09 非替换 snapshot 不递增 scrollResetToken，替换才递增', () async {
      final (client, transport) = _newClient();
      await Future<void>.delayed(Duration.zero);
      await transport.receive('snapshot', _snapshotMap(
        seq: 1,
        question: '同一个问题',
        answer: '长回答正文',
        status: 'streaming',
      ));
      final token = client.state.scrollResetToken;
      expect(token, 0, reason: '首帧不触发替换');
      expect(client.state.revision, 1);

      // plan 全量 snapshot：同 question/会话/run，带当前正文和状态。
      await transport.receive('snapshot', _snapshotMap(
        seq: 2,
        question: '同一个问题',
        answer: '长回答正文',
        status: 'streaming',
        plan: [
          {'id': 'p1', 'title': '检索资料', 'status': 'done'},
        ],
      ));
      expect(client.state.scrollResetToken, token, reason: 'plan 不是替换');
      expect(client.state.revision, 2);

      // 重同步 snapshot（seq 跳号后主窗回全量）：仍不是替换。
      await transport.receive('snapshot', _snapshotMap(
        seq: 9,
        question: '同一个问题',
        answer: '长回答正文',
        status: 'done',
        refs: [
          {'name': '高数.pdf', 'page': 3},
        ],
      ));
      expect(client.state.scrollResetToken, token, reason: 'resync 不是替换');

      // 新问题替换：token 递增。
      await transport.receive('snapshot', _snapshotMap(
        seq: 10,
        question: '新的问题',
        answer: '',
        status: 'thinking',
      ));
      expect(client.state.scrollResetToken, token + 1);
      expect(client.state.question, '新的问题');
    });

    test('A-IPC-09 同一问题再次提问（正文清零+thinking）按替换处理', () async {
      final (client, transport) = _newClient();
      await Future<void>.delayed(Duration.zero);
      await transport.receive('snapshot', _snapshotMap(
        seq: 1,
        question: '重复问题',
        answer: '上一轮回答',
        status: 'done',
      ));
      final token = client.state.scrollResetToken;
      await transport.receive('snapshot', _snapshotMap(
        seq: 2,
        question: '重复问题',
        answer: '',
        status: 'thinking',
      ));
      expect(client.state.scrollResetToken, token + 1);
    });
  });

  group('回答面板（只读 UI）', () {
    testWidgets('A-UI-01 无空窗：等待/思考/空回答/错误/停止均有占位', (tester) async {
      await _pumpPanel(tester, _view(hasSnapshot: false, question: '', status: 'thinking'));
      expect(find.text('等待问题…'), findsOneWidget);

      await _pumpPanel(tester, _view(answer: '', status: 'thinking'));
      expect(find.text('正在思考…'), findsOneWidget);

      await _pumpPanel(tester, _view(answer: '', status: 'done'));
      expect(find.text('（无内容）'), findsOneWidget);

      await _pumpPanel(tester, _view(answer: '', status: 'error', error: '模型不可用'));
      expect(find.byKey(const Key('answer-error')), findsOneWidget);
      expect(find.textContaining('模型不可用'), findsOneWidget);
      expect(find.text('（无内容）'), findsOneWidget);

      await _pumpPanel(tester, _view(answer: '部分回答', status: 'stopped'));
      expect(find.text('（无内容）'), findsNothing);
      expect(find.textContaining('部分回答'), findsOneWidget);
      expect(find.text('已停止'), findsWidgets);
    });

    testWidgets('A-UI-02 Markdown/公式/代码块/表格渲染，无输入控件', (tester) async {
      await _pumpPanel(
        tester,
        _view(
          answer: '## 标题\n\n```dart\nvoid main() {}\n```\n\n'
              r'行内 $x^2$ 与' '\n\n' r'$$\nE=mc^2\n$$' '\n\n'
              '> 引用\n\n| a | b |\n|---|---|\n| 1 | 2 |',
        ),
      );
      expect(find.byType(MarkdownText), findsOneWidget);
      expect(find.byType(Math), findsWidgets);
      expect(find.byType(SelectableText), findsOneWidget);
      expect(find.textContaining('标题'), findsWidgets);
      expect(find.textContaining('引用'), findsWidgets);
      expect(find.byType(TextField), findsNothing);
      expect(find.byTooltip('发送'), findsNothing);
    });

    testWidgets('A-UI-03 内容自适应：正文内容高上报、长内容内部滚动', (tester) async {
      final short = await _pumpPanel(tester, _view(answer: '短答案'));
      expect(short.heights.last, lessThan(180),
          reason: '上报的是正文内容高，窗口 minH 由主窗钳制');

      final longAnswer = '这是一段很长的回答。' * 300;
      final long = await _pumpPanel(
        tester,
        _view(answer: longAnswer, maxHeight: 300),
      );
      expect(long.heights.last, greaterThan(300));
      final scrollable = tester.state<ScrollableState>(find.descendant(
        of: find.byKey(const Key('answer-scroll')),
        matching: find.byType(Scrollable),
      ));
      expect(scrollable.position.maxScrollExtent, greaterThan(0));
      expect(tester.takeException(), isNull);
    });

    testWidgets('A-UI-04 达 maxH 后用户上滚出现“回到底部”，点击回到底部', (tester) async {
      await _pumpPanel(tester, _view(answer: '很长。' * 400, maxHeight: 240));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('answer-scroll-bottom')), findsNothing);
      await tester.drag(
        find.byKey(const Key('answer-scroll')),
        const Offset(0, 400),
      );
      await tester.pump();
      expect(find.byKey(const Key('answer-scroll-bottom')), findsOneWidget);

      await tester.tap(find.byKey(const Key('answer-scroll-bottom')));
      await tester.pump();
      expect(find.byKey(const Key('answer-scroll-bottom')), findsNothing);
    });

    testWidgets('A-UI-05 收起只留标题条；展开/关闭/拖动回调（双击不再承诺恢复位置）', (tester) async {
      final expanded = await _pumpPanel(tester, _view(answer: '内容'));
      expect(find.byKey(const Key('answer-body')), findsOneWidget);
      expect(tester.getSize(find.byKey(const Key('answer-header'))).height, 36);

      await tester.tap(find.byKey(const Key('answer-collapse')));
      await tester.tap(find.byKey(const Key('answer-close')));
      expect(expanded.collapses, 1);
      expect(expanded.closes, 1);

      final collapsed = await _pumpPanel(tester, _view(answer: '内容', collapsed: true));
      expect(find.byKey(const Key('answer-body')), findsNothing);
      expect(find.byKey(const Key('answer-scroll')), findsNothing);
      await tester.tap(find.byKey(const Key('answer-collapse')));
      await tester.pump();
      expect(collapsed.expands, 1);

      final dragging = await _pumpPanel(tester, _view(answer: '内容'));
      await tester.drag(find.byKey(const Key('answer-drag')), const Offset(24, 10));
      await tester.pump();
      expect(dragging.dragStarts, greaterThanOrEqualTo(1));
      expect(dragging.dragUpdates, greaterThanOrEqualTo(1));
      expect(dragging.dragEnds, greaterThanOrEqualTo(1));

      // T5-13：双击标题条不再绑定“恢复 auto 位置”（control 协议无该消息），
      // 不允许出现无响应承诺；双击不抛异常、不改变布局。
      final handle = find.byKey(const Key('answer-drag'));
      await tester.tap(handle);
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tap(handle);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('answer-body')), findsOneWidget);
    });

    testWidgets('A-UI-06 T5-09 非替换 snapshot 保留用户滚动；替换新问题才回到底部', (tester) async {
      final longAnswer = '旧回答。' * 400;
      await _pumpPanel(
        tester,
        _view(answer: longAnswer, revision: 1, scrollResetToken: 1, maxHeight: 240),
      );
      await tester.pumpAndSettle();
      final scrollable = tester.state<ScrollableState>(find.descendant(
        of: find.byKey(const Key('answer-scroll')),
        matching: find.byType(Scrollable),
      ));
      await tester.drag(
        find.byKey(const Key('answer-scroll')),
        const Offset(0, 500),
      );
      await tester.pumpAndSettle();
      final anchor = scrollable.position.pixels;
      expect(anchor, lessThan(scrollable.position.maxScrollExtent - 100));
      expect(find.byKey(const Key('answer-scroll-bottom')), findsOneWidget);

      // 非替换全量 snapshot（plan 更新）：token 不变，保留像素位置与“已上滚”状态。
      await _pumpPanel(
        tester,
        _view(
          answer: longAnswer,
          revision: 2,
          scrollResetToken: 1,
          maxHeight: 240,
          plan: const [PlanItem(id: 'p1', title: '检索资料', status: 'done')],
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('检索资料'), findsOneWidget);
      expect(scrollable.position.pixels, closeTo(anchor, 1));
      expect(find.byKey(const Key('answer-scroll-bottom')), findsOneWidget);
      expect(tester.takeException(), isNull);

      // 替换新问题：token+1，回到正文末尾跟随。
      await _pumpPanel(
        tester,
        _view(
          question: '新问题',
          answer: '新回答。' * 400,
          revision: 3,
          scrollResetToken: 2,
          maxHeight: 240,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('旧回答'), findsNothing);
      expect(find.textContaining('新回答'), findsOneWidget);
      expect(
        scrollable.position.pixels,
        closeTo(scrollable.position.maxScrollExtent, 1),
      );
    });

    testWidgets('A-UI-07 窄宽 420 + 长代码/表格不溢出', (tester) async {
      await _pumpPanel(
        tester,
        _view(
          answer: '```\n${'x' * 200}\n```\n\n| c1 | c2 | c3 | c4 |\n|---|---|---|---|\n'
              '| ${'很长的单元格' * 6} | b | c | d |',
        ),
        size: const Size(420, 600),
      );
      expect(tester.takeException(), isNull);
      expect(find.byType(MarkdownText), findsOneWidget);
    });

    testWidgets('A-UI-08 T5-11 滚轮路由：标题条与正文区域都能滚动，且不双倍', (tester) async {
      await _pumpPanel(
        tester,
        _view(answer: '长内容。' * 400, maxHeight: 240),
      );
      await tester.pumpAndSettle();
      final position = tester.state<ScrollableState>(find.descendant(
        of: find.byKey(const Key('answer-scroll')),
        matching: find.byType(Scrollable),
      )).position;
      expect(position.maxScrollExtent, greaterThan(0));
      final bottom = position.pixels;

      final mouse = TestPointer(1, PointerDeviceKind.mouse);
      // 标题条没有内层 Scrollable：面板级兜底应把纵向滚轮转给正文。
      final headerCenter = tester.getCenter(find.byKey(const Key('answer-header')));
      await tester.sendEventToBinding(mouse.addPointer(location: headerCenter));
      await tester.sendEventToBinding(mouse.hover(headerCenter));
      await tester.sendEventToBinding(mouse.scroll(const Offset(0, -120)));
      await tester.pump();
      final afterHeader = position.pixels;
      expect(afterHeader, lessThan(bottom));
      expect(bottom - afterHeader, closeTo(120, 2),
          reason: '兜底路径只滚动一次，不允许双倍');

      // 正文区域由内层 Scrollable 处理。
      final bodyCenter = tester.getCenter(find.byKey(const Key('answer-scroll')));
      await tester.sendEventToBinding(mouse.hover(bodyCenter));
      await tester.sendEventToBinding(mouse.scroll(const Offset(0, -120)));
      await tester.pump();
      final afterBody = position.pixels;
      expect(afterBody, lessThan(afterHeader));
      expect(afterHeader - afterBody, closeTo(120, 2));
      await tester.sendEventToBinding(mouse.removePointer());
      expect(tester.takeException(), isNull);
    });

    testWidgets('A-UI-09 T5-11 纵向滚轮位于横向代码块上时仍滚动外层正文', (tester) async {
      final code = List<String>.generate(200, (index) => 'code line $index').join('\n');
      await _pumpPanel(tester, _view(answer: '```\n$code\n```', maxHeight: 240));
      await tester.pumpAndSettle();
      final position = tester.state<ScrollableState>(find.descendant(
        of: find.byKey(const Key('answer-scroll')),
        matching: find.byType(Scrollable),
      ).first).position;
      expect(position.maxScrollExtent, greaterThan(0));
      final bottom = position.pixels;

      // 代码块自身是横向 Scrollable；纵向 wheel delta 为 0，不应吞掉外层滚动。
      final codeFinder = find.byType(SelectableText);
      expect(codeFinder, findsOneWidget);
      final mouse = TestPointer(1, PointerDeviceKind.mouse);
      // 200 行代码块整体高度远大于视口，取视口内（底部）的一点保证命中代码块。
      final viewport = tester.getRect(find.byKey(const Key('answer-scroll')));
      final target = Offset(viewport.center.dx, viewport.bottom - 40);
      await tester.sendEventToBinding(mouse.addPointer(location: target));
      await tester.sendEventToBinding(mouse.hover(target));
      await tester.sendEventToBinding(mouse.scroll(const Offset(0, -120)));
      await tester.pump();

      expect(position.pixels, lessThan(bottom));
      expect(bottom - position.pixels, closeTo(120, 2));
      await tester.sendEventToBinding(mouse.removePointer());
      expect(tester.takeException(), isNull);
    });
  });

  group('第二引擎根组件', () {
    testWidgets('A-APP-01 发送 ready（含协议/windowId/dpr），无空窗', (tester) async {
      final transport = _FakeTransport();
      await _pumpApp(tester, transport);
      final ready = transport.sentOf('ready').single;
      expect(ready['protocol'], answerProtocolVersion);
      expect(ready['windowId'], 'w1');
      expect(ready['dpr'], isA<double>());
      expect(find.byKey(const Key('answer-window')), findsOneWidget);
      expect(find.text('等待问题…'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
    });

    testWidgets('A-APP-02 hello/snapshot/theme/收起/关闭全链路', (tester) async {
      final transport = _FakeTransport();
      await _pumpApp(tester, transport);
      await transport.receive('hello', {
        'protocol': 1,
        'windowId': 'w1',
        'hwnd': 777,
        'widthLogical': 640,
        'minH': 180,
        'maxH': 700,
        'themeMode': 'dark',
        'dark': true,
      });
      await tester.pump();
      expect(LoopTheme.palette.isDark, isTrue);

      await transport.receive('snapshot', _snapshotMap(
        seq: 1,
        question: '解释极限',
        answer: r'设 $x_n$ 收敛，则……',
        status: 'streaming',
        plan: [
          {'id': 'p1', 'title': '检索资料', 'status': 'done'},
        ],
      ));
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('解释极限'), findsOneWidget);
      expect(find.textContaining('检索资料'), findsOneWidget);

      // 测高：正文内容高度上报（80ms 节流，钳制/窗口高度由主窗 planner 负责）。
      await tester.pump(const Duration(milliseconds: 120));
      final heights = transport.sentOf('content_height');
      expect(heights, isNotEmpty);
      final height = heights.last['heightLogical'] as double;
      expect(height, greaterThan(0));

      await transport.receive('theme', {'themeMode': 'light', 'dark': false});
      await tester.pump();
      expect(LoopTheme.palette.isDark, isFalse);

      await tester.tap(find.byKey(const Key('answer-collapse')));
      await tester.pump();
      expect(transport.sentOf('collapse_requested').length, 1);
      await transport.receive('presentation', {'collapsed': true});
      await tester.pump();
      expect(find.byKey(const Key('answer-body')), findsNothing);
      await tester.tap(find.byKey(const Key('answer-collapse')));
      await tester.pump();
      expect(transport.sentOf('expand_requested').length, 1);
      await transport.receive('presentation', {'collapsed': false});
      await tester.pump();
      expect(find.byType(MarkdownText), findsOneWidget, reason: '展开后内容仍在');

      await tester.tap(find.byKey(const Key('answer-close')));
      await tester.pump();
      expect(transport.sentOf('close_requested').length, 1);
    });

    testWidgets('A-APP-05 关闭后重开：新窗口从快照重新渲染，不残留旧内容', (tester) async {
      final first = _FakeTransport();
      await _pumpApp(tester, first);
      await first.receive('snapshot', _snapshotMap(seq: 1, answer: '旧回答', status: 'done'));
      await tester.pump();
      expect(find.textContaining('旧回答'), findsOneWidget);
      await tester.tap(find.byKey(const Key('answer-close')));
      await tester.pump();
      expect(first.sentOf('close_requested').length, 1);

      // 主窗销毁旧窗口后再次非空提交 → 新 windowId/新引擎重新渲染。
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      final second = _FakeTransport();
      await _pumpApp(tester, second);
      await second.receive('snapshot', _snapshotMap(seq: 1, answer: '新回答', status: 'done'));
      await tester.pump();
      expect(find.textContaining('旧回答'), findsNothing);
      expect(find.textContaining('新回答'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('A-APP-03 标题条拖动 → FFI 代理 + moved/drag_started/ended', (tester) async {
      final transport = _FakeTransport();
      final drag = _FakeDragDelegate();
      await _pumpApp(tester, transport, dragDelegate: drag);
      await transport.receive('hello', {
        'protocol': 1,
        'windowId': 'w1',
        'hwnd': 888,
      });
      await tester.pump();

      await tester.drag(find.byKey(const Key('answer-drag')), const Offset(30, 12));
      await tester.pump();
      expect(drag.startedHwnd, 888);
      expect(drag.calls.first, 'start');
      expect(drag.calls, contains('update'));
      expect(drag.calls.last, 'finish');
      expect(transport.sentOf('drag_started').length, 1);
      expect(transport.sentOf('drag_ended').length, 1);
      final moved = transport.sentOf('moved').single;
      expect(decodeRect(moved['physicalRect']), drag.finishRect);
    });

    testWidgets('A-APP-04 流式 delta 增量 + maxH 滚动 + 停止保留正文', (tester) async {
      final transport = _FakeTransport();
      await _pumpApp(tester, transport);
      await transport.receive('hello', {
        'protocol': 1,
        'minH': 180,
        'maxH': 240,
      });
      await transport.receive('snapshot', _snapshotMap(
        seq: 1,
        answer: '开始',
        status: 'streaming',
      ));
      await tester.pump();
      await transport.receive('delta', {'seq': 2, 'text': '，继续。' * 80});
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      final markdown = tester.widget<MarkdownText>(find.byType(MarkdownText));
      expect(markdown.data.startsWith('开始，继续。'), isTrue);

      await transport.receive('status', _statusMap(3, 'stopped', label: '已停止'));
      await tester.pump();
      expect(find.text('已停止'), findsWidgets);
      expect(find.byType(MarkdownText), findsOneWidget);
    });
  });
}
