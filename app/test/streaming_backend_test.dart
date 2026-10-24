import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:loop/backend/agent.dart';
import 'package:loop/backend/agent_run.dart';
import 'package:loop/backend/db.dart';
import 'package:loop/backend/llm.dart';

/// 后端流式输出开关（stream_output）的行为测试。
///
/// 不访问网络：通过 [ChatChunkStream] 注入假模型流；数据库为内存库。
/// 用例编号与 docs/streaming-spec.md §6.2 的 B1–B9 对应。

typedef _Round = List<Map<String, dynamic>>;

class _RunResult {
  _RunResult({
    required this.events,
    required this.run,
    required this.conversationId,
    required this.userMessageId,
  });

  final List<AgentEvent> events;
  final AgentRun run;
  final int conversationId;
  final int userMessageId;

  List<AgentEvent> named(String name) => events.where((e) => e.event == name).toList();

  List<String> get deltas => named('delta').map((e) => '${e.data['text'] ?? ''}').toList();

  String get deltaText => deltas.join();

  Map<String, Object?> get done => named('done').single.data;

  int indexOf(String name) => events.indexWhere((e) => e.event == name);
}

Map<String, dynamic> _text(String text) => {
      'choices': [
        {
          'delta': {'content': text},
        },
      ],
    };

Map<String, dynamic> _toolCall(
  String id,
  String name,
  Map<String, dynamic> args, {
  int index = 0,
}) =>
    {
      'choices': [
        {
          'delta': {
            'tool_calls': [
              {
                'index': index,
                'id': id,
                'type': 'function',
                'function': {'name': name, 'arguments': jsonEncode(args)},
              },
            ],
          },
        },
      ],
    };

Map<String, dynamic> _usage(int prompt, int completion) => {
      'choices': <Object?>[],
      'usage': {'prompt_tokens': prompt, 'completion_tokens': completion},
    };

/// 按轮次返回 chunk。`onResume` 在 agent 消费完一个 chunk、请求下一个时触发，
/// 用来模拟“运行中取消/运行中改设置”等真实时序；`throwAfter` 用来模拟模型流中断。
ChatChunkStream _fakeChat(
  List<_Round> rounds, {
  void Function()? onResume,
  Object? throwAfter,
}) {
  var roundIndex = 0;
  return (config, messages, tools, thinking) async* {
    final round = rounds[roundIndex < rounds.length ? roundIndex : rounds.length - 1];
    roundIndex++;
    for (final chunk in round) {
      yield chunk;
      onResume?.call();
      if (throwAfter != null) throw throwAfter;
    }
  };
}

Future<_RunResult> _run({
  required String userText,
  required ChatChunkStream Function(AgentRun run) chat,
  bool streamOutput = true,
  bool background = false,
  void Function(AgentEvent event, AgentRun run)? onEvent,
}) async {
  final now = Db.nowIso();
  final conversationId = Db.insert('conversations', {
    'title': '流式测试',
    'mode': 'answer',
    'created_at': now,
    'updated_at': now,
  });
  final userMessageId = Db.insert('messages', {
    'conversation_id': conversationId,
    'role': 'user',
    'content': userText,
    'steps': '[]',
    'refs': '[]',
    'created_at': now,
  });
  final run = AgentRuns.start(conversationId);
  final events = <AgentEvent>[];
  await for (final event in runAgent(
    conversationId: conversationId,
    userMessageId: userMessageId,
    userText: userText,
    attachments: const [],
    run: run,
    streamOutput: streamOutput,
    background: background,
    chatStream: chat(run),
  )) {
    events.add(event);
    onEvent?.call(event, run);
  }
  AgentRuns.remove(run.id);
  return _RunResult(
    events: events,
    run: run,
    conversationId: conversationId,
    userMessageId: userMessageId,
  );
}

Map<String, Object?>? _savedAssistant(int conversationId) => Db.one(
      "SELECT * FROM messages WHERE conversation_id=? AND role='assistant' ORDER BY id DESC LIMIT 1",
      [conversationId],
    );

void main() {
  late Directory tempDir;

  setUpAll(() {
    Db.initInMemoryForTests();
  });

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('loop_stream_backend_');
    for (final table in const [
      'messages',
      'conversations',
      'agent_runs',
      'agent_audit',
      'usage',
      'notes',
      'tasks',
      'agent_jobs',
      'mcp_servers',
      'uploads',
      'materials',
    ]) {
      Db.run('DELETE FROM $table');
    }
    Db.setSetting('api_key', 'test-key');
    Db.setSetting('workspace_path', tempDir.path);
    Db.setSetting('stream_output', 'true');
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('B1 true 模式逐 delta 转发，done 最后且正文落库', () async {
    final result = await _run(
      userText: '你好',
      chat: (_) => _fakeChat([
        [_text('你'), _text('好'), _text('呀'), _usage(11, 3)],
      ]),
    );

    expect(result.deltas, ['你', '好', '呀']);
    expect(result.named('delta').length, 3);
    expect(result.events.last.event, 'done');
    expect(result.done['tokens_in'], 11);
    expect(result.done['tokens_out'], 3);
    expect(result.done['message_id'], isNotNull);
    expect(result.done['error'], '');
    expect(_savedAssistant(result.conversationId)!['content'], '你好呀');
  });

  test('B2 false 模式只在 done 前发一次完整正文', () async {
    final result = await _run(
      userText: '你好',
      streamOutput: false,
      chat: (_) => _fakeChat([
        [_text('你'), _text('好'), _text('呀'), _usage(11, 3)],
      ]),
    );

    expect(result.deltas, ['你好呀']);
    expect(result.named('delta').length, 1);
    expect(result.indexOf('delta'), lessThan(result.indexOf('done')));
    expect(result.events.last.event, 'done');
    expect(result.done['message_id'], isNotNull);
    expect(_savedAssistant(result.conversationId)!['content'], '你好呀');
  });

  test('B3 false 模式工具多轮：step/工具照常，正文拼接与 true 一致', () async {
    _Round round1() => [
          _text('我先查一下。'),
          _toolCall('call_today_1', 'get_today', {}),
        ];
    _Round round2() => [
          _text('今天有 0 个待办。'),
          _usage(20, 8),
        ];

    final off = await _run(
      userText: '今天有什么',
      streamOutput: false,
      chat: (_) => _fakeChat([round1(), round2()]),
    );

    expect(off.deltas, ['我先查一下。今天有 0 个待办。']);
    expect(off.named('delta').length, 1);
    expect(off.indexOf('delta'), lessThan(off.indexOf('done')));
    expect(off.named('step').isNotEmpty, isTrue);
    final offSteps = (off.done['steps'] as List).cast<Map<String, Object?>>();
    expect(offSteps.any((s) => s['name'] == 'get_today' && s['status'] == 'done'), isTrue);
    expect(Db.rows("SELECT * FROM agent_audit WHERE tool='get_today'").length, 1);
    final offSaved = _savedAssistant(off.conversationId)!;
    expect(offSaved['content'], '我先查一下。今天有 0 个待办。');

    final on = await _run(
      userText: '今天有什么',
      chat: (_) => _fakeChat([round1(), round2()]),
    );

    expect(on.named('delta').length, greaterThan(1));
    expect(on.deltaText, off.deltaText);
    expect(_savedAssistant(on.conversationId)!['content'], offSaved['content']);
    expect(on.done['tokens_in'], off.done['tokens_in']);
    expect(on.done['tokens_out'], off.done['tokens_out']);
  });

  test('B4 false 模式取消：已生成正文只补发一次，不重复', () async {
    final result = await _run(
      userText: '取消测试',
      streamOutput: false,
      chat: (run) => _fakeChat(
        [
          [_text('半'), _text('截')],
        ],
        onResume: run.cancel,
      ),
    );

    expect(result.deltas, ['半']);
    expect(result.named('delta').length, 1);
    final cancelled = result.named('cancelled').single;
    expect(cancelled.data['partial'], true);
    expect(cancelled.data['message_id'], isNotNull);
    expect(result.indexOf('delta'), lessThan(result.indexOf('cancelled')));
    expect(result.named('done'), isEmpty);
    expect(result.named('error'), isEmpty);
    expect(result.events.last.event, 'cancelled');
    expect(_savedAssistant(result.conversationId)!['content'], '半');
  });

  test('B5 false 模式审批等待中取消：无 delta，cancelled 一次', () async {
    final result = await _run(
      userText: '写文件',
      streamOutput: false,
      chat: (_) => _fakeChat([
        [
          _toolCall('call_write_1', 'fs_write', {'path': 'a.txt', 'content': 'hi'}),
        ],
      ]),
      onEvent: (event, run) {
        if (event.event == 'approval') run.cancel();
      },
    );

    expect(result.named('delta'), isEmpty);
    expect(result.named('cancelled').length, 1);
    expect(result.named('done'), isEmpty);
    expect(Db.rows("SELECT * FROM agent_audit WHERE tool='fs_write'"), isEmpty);
    expect(File('${tempDir.path}${Platform.pathSeparator}a.txt').existsSync(), isFalse);
    expect(_savedAssistant(result.conversationId), isNull);
  });

  test('B6 空回复：两种模式都不产生 delta，done 正常', () async {
    for (final streamOutput in [true, false]) {
      final result = await _run(
        userText: '空回复',
        streamOutput: streamOutput,
        chat: (_) => _fakeChat([
          [_usage(7, 0)],
        ]),
      );

      expect(result.named('delta'), isEmpty, reason: 'streamOutput=$streamOutput');
      expect(result.named('done').length, 1);
      expect(result.done['message_id'], isNull);
      expect(result.done['tokens_in'], 7);
      expect(result.done['tokens_out'], 0);
      expect(_savedAssistant(result.conversationId), isNull);
    }
  });

  test('B7 强制收尾补写正文：false 只发一次且与落库一致', () async {
    _Round duplicateRound() => [
          _text('我先查一下。'),
          _toolCall('call_1', 'get_today', {}, index: 0),
          _toolCall('call_2', 'get_today', {}, index: 1),
          _toolCall('call_3', 'get_today', {}, index: 2),
        ];

    final off = await _run(
      userText: '重复工具',
      streamOutput: false,
      chat: (_) => _fakeChat([duplicateRound()]),
    );

    expect(off.named('delta').length, 1);
    expect(off.deltaText, contains('已停止重复验证。'));
    expect(off.deltaText, contains('我先查一下。'));
    final offSaved = _savedAssistant(off.conversationId)!;
    expect(offSaved['content'], off.deltaText);
    expect(off.events.last.event, 'done');

    final on = await _run(
      userText: '重复工具',
      chat: (_) => _fakeChat([duplicateRound()]),
    );

    expect(on.named('delta').length, greaterThan(1));
    expect(on.deltaText, off.deltaText);
    expect(_savedAssistant(on.conversationId)!['content'], offSaved['content']);
  });

  test('失败（已有正文）：false 只发一次已生成正文，done.error 保留', () async {
    final off = await _run(
      userText: '失败',
      streamOutput: false,
      chat: (_) => _fakeChat(
        [
          [_text('部分'), _text('不应到达')],
        ],
        throwAfter: LlmException('模型连接中断'),
      ),
    );

    expect(off.deltas, ['部分']);
    expect(off.named('delta').length, 1);
    expect(off.named('error'), isEmpty);
    expect(off.done['error'], '模型连接中断');
    expect(_savedAssistant(off.conversationId)!['content'], '部分');
    expect(off.events.last.event, 'done');

    final on = await _run(
      userText: '失败',
      chat: (_) => _fakeChat(
        [
          [_text('部分'), _text('不应到达')],
        ],
        throwAfter: LlmException('模型连接中断'),
      ),
    );

    expect(on.deltas, ['部分']);
    expect(on.named('delta').length, 1);
    expect(on.done['error'], '模型连接中断');
  });

  test('B8 设置默认值与持久化（含老库补默认值）', () {
    // 新库由 _migrate → seedDefaults 写入默认 true。
    expect(Db.scalar("SELECT value FROM settings WHERE key='stream_output'"), 'true');
    expect(Db.setting('stream_output', 'true'), 'true');

    Db.setSetting('stream_output', 'false');
    expect(Db.setting('stream_output', 'true'), 'false');

    // 缺键回退 true；模拟老库升级时 seedDefaults 补齐。
    Db.run("DELETE FROM settings WHERE key='stream_output'");
    expect(Db.setting('stream_output', 'true'), 'true');
    Db.seedDefaults();
    expect(Db.scalar("SELECT value FROM settings WHERE key='stream_output'"), 'true');
    expect(Db.setting('stream_output'), 'true');

    // 已存在的值不会被 seedDefaults 覆盖。
    Db.setSetting('stream_output', 'false');
    Db.seedDefaults();
    expect(Db.setting('stream_output', 'true'), 'false');
  });

  test('B9 请求级快照：运行中改设置不影响本次，下一次生效', () async {
    final off = await _run(
      userText: '快照',
      streamOutput: false,
      chat: (_) => _fakeChat(
        [
          [_text('第一段'), _text('第二段')],
        ],
        onResume: () => Db.setSetting('stream_output', 'true'),
      ),
    );

    expect(off.named('delta').length, 1);
    expect(off.deltaText, '第一段第二段');
    expect(Db.setting('stream_output', 'true'), 'true');

    // 下一条消息按进入请求时的快照执行（server 在新请求开始时读取）。
    final snapshot = Db.setting('stream_output', 'true') == 'true';
    final on = await _run(
      userText: '下一条',
      streamOutput: snapshot,
      chat: (_) => _fakeChat([
        [_text('甲'), _text('乙')],
      ]),
    );

    expect(on.deltas, ['甲', '乙']);
  });
}
