import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:loop/backend/agent.dart';
import 'package:loop/backend/agent_run.dart';
import 'package:loop/backend/agent_tools.dart';
import 'package:loop/backend/db.dart';
import 'package:loop/backend/llm.dart';
import 'package:loop/backend/server.dart';
import 'package:loop/backend/subject_progress.dart';
import 'package:loop/backend/subject_store.dart';

/// 学习进度测试（t4；规格 docs/subject-feature-spec.md §8 / §11.4 / §14 AC-03）。
///
/// 纪律：
/// - 隔离数据目录；真实学科库 + 真实工具入口 + 真实 HTTP 接口；
/// - 用例编号 P1..P11：工具写入→读取、答错规则、幂等、持久化、隔离、用户纠正、
///   限幅/证据校验、复习间隔、日汇总、提示注入与端到端回答。

Directory _tempRoot() => Directory.systemTemp.createTempSync('loop-subject-progress-');

void _deleteQuietly(Directory dir) {
  try {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  } catch (_) {}
}

String _dayOffset(int days) {
  final base = DateTime.now();
  final target = DateTime(base.year, base.month, base.day).add(Duration(days: days));
  return '${target.year.toString().padLeft(4, '0')}-'
      '${target.month.toString().padLeft(2, '0')}-'
      '${target.day.toString().padLeft(2, '0')}';
}

class _ToolRun {
  _ToolRun(this.payload, this.detail);

  final Map<String, Object?> payload;
  final String detail;
}

Future<_ToolRun> _callTool(String key, String name, Map<String, dynamic> args) async {
  final handle = SubjectStore.open(key);
  final run = AgentRuns.start(0, subjectKey: key);
  final ctx = ToolContext(conversationId: 0, run: run, plan: PlanState(), refs: []);
  try {
    final result = await Db.runScoped(
      handle.database,
      () => executeTool(name, args, ctx),
      subjectKey: key,
      filesDir: SubjectRecord.fromRow(
        Db.globalOne('SELECT * FROM subjects WHERE key=?', [key])!,
      ).filesPath,
    );
    return _ToolRun(result.payload, result.detail);
  } finally {
    AgentRuns.remove(run.id);
  }
}

T _inScope<T>(String key, T Function() body) {
  final handle = SubjectStore.open(key);
  return Db.runScopedSync(handle.database, body, subjectKey: key);
}

Future<T> _inScopeAsync<T>(String key, Future<T> Function() body) {
  final handle = SubjectStore.open(key);
  return Db.runScoped(handle.database, body, subjectKey: key);
}

Map<String, Object?> _snapshot(String key) => _inScope(key, () => ProgressModel.snapshot());

Map<String, Object?>? _topicNamed(String key, String name) => _inScope(
      key,
      () => Db.one('SELECT * FROM topics WHERE name=? COLLATE NOCASE', [name]),
    );

List<Map<String, Object?>> _eventsOf(String key, [String topic = '']) => _inScope(
      key,
      () => topic.isEmpty
          ? Db.rows('SELECT * FROM study_events ORDER BY id')
          : Db.rows('SELECT * FROM study_events WHERE topic=? ORDER BY id', [topic]),
    );

Map<String, dynamic> _text(String text) => {
      'choices': [
        {
          'delta': {'content': text},
        },
      ],
    };

Map<String, dynamic> _toolCall(String id, String name, Map<String, dynamic> args) => {
      'choices': [
        {
          'delta': {
            'tool_calls': [
              {
                'index': 0,
                'id': id,
                'type': 'function',
                'function': {'name': name, 'arguments': jsonEncode(args)},
              },
            ],
          },
        },
      ],
    };

void main() {
  group('P 进度模型（学科库内，直接工具入口）', () {
    late Directory root;
    late SubjectRecord subjectA;
    late SubjectRecord subjectB;

    setUp(() {
      root = _tempRoot();
      SubjectStore.initTempForTests(root);
      subjectA = SubjectStore.create(name: '进度甲');
      subjectB = SubjectStore.create(name: '进度乙');
    });

    tearDown(() {
      SubjectStore.resetForTests();
      _deleteQuietly(root);
    });

    test('P1 工具写入事件 → get_subject_progress 返回结构化进度', () async {
      final write = await _callTool(subjectA.key, 'update_subject_progress', {
        'events': [
          {
            'kind': 'explain',
            'topic': '特征值与特征向量',
            'duration_min': 20,
            'message_id': 101,
            'note': '讲解完成',
          },
        ],
      });
      expect(write.payload['ok'], isTrue);
      expect(write.payload['applied_events'], 1);
      expect(write.payload['applied_topics'], 0, reason: '未显式传 topics[]');
      expect(write.payload['touched_topics'], 1, reason: '事件派生新建了 1 个知识点');
      expect((write.payload['topics'] as List), hasLength(1));
      expect(write.payload['committed'], isTrue);
      final summary = write.payload['summary'] as Map<String, Object?>;
      expect(summary['topics_total'], 1);
      expect(summary['studied_topics'], 1);
      expect(summary['coverage'], greaterThan(0));
      expect(summary['last_studied_at'], isNotEmpty);

      final read = await _callTool(subjectA.key, 'get_subject_progress', {
        'topic': '特征值与特征向量',
      });
      expect(read.payload['ok'], isTrue);
      expect(read.payload['subject_key'], subjectA.key);
      expect(read.payload['subject_name'], '进度甲');
      expect(read.payload['found'], isTrue);
      // 四项必含：覆盖度 / 掌握度 / 最近学习 / 待复习。
      for (final field in ['coverage', 'mastery_avg', 'last_studied_at', 'review_due']) {
        expect(read.payload['summary'], contains(field));
      }
      final topic = read.payload['topic'] as Map<String, Object?>;
      expect(topic['status'], 'learning');
      expect(topic['mastery'], 0.1, reason: '讲解新建知识点按 §8.2 记 mastery=0.1');
      expect(topic['evidence_count'], 1);
      expect(topic['last_studied_at'], isNotEmpty);
      expect(topic['source_refs'], isNotEmpty);
      expect((read.payload['events'] as List), hasLength(1));
      expect(((read.payload['events'] as List).first as Map)['message_id'], 101);
      expect((read.payload['profile'] as Map), contains('goal'));

      final all = await _callTool(subjectA.key, 'get_subject_progress', {});
      expect((all.payload['topics'] as List), hasLength(1));
      expect((all.payload['recent_events'] as List), hasLength(1));
      expect(all.detail, contains('知识点'));
    });

    test('P2 答错：mastery 下降、status=review_due、next_review=+1 天、证据落库', () async {
      final write = await _callTool(subjectA.key, 'update_subject_progress', {
        'events': [
          {
            'kind': 'practice',
            'topic': '概率论基础',
            'result': 'wrong',
            'duration_min': 12,
            'message_id': 201,
            'note': '混淆了条件概率',
          },
        ],
      });
      expect(write.payload['applied_events'], 1);

      final topic = _topicNamed(subjectA.key, '概率论基础')!;
      expect((topic['mastery'] as num).toDouble(), 0.0);
      expect(topic['status'], 'review_due');
      expect(topic['next_review_at'], _dayOffset(1));
      expect(topic['evidence_count'], 1);

      final events = _eventsOf(subjectA.key, '概率论基础');
      expect(events, hasLength(1));
      expect(events.single['message_id'], 201);
      expect(events.single['kind'], 'practice');
      expect(events.single['result'], 'wrong');
      expect(events.single['duration_min'], 12);
      expect(events.single['note'], '混淆了条件概率');

      // 待复习项：答错后排到明天 → 今天尚未到期（review_due 只计"已到期"）。
      final summary = _snapshot(subjectA.key)['summary'] as Map<String, Object?>;
      expect(summary['review_due'], 0, reason: '明天到期，今天还不算待复习');
      expect(summary['next_review_at'], _dayOffset(1));

      // 模拟时间流逝：把 next_review_at 挪到昨天 → 立刻进入待复习清单与日汇总。
      _inScope(subjectA.key, () {
        Db.run('UPDATE topics SET next_review_at=? WHERE name=?', [
          _dayOffset(-1),
          '概率论基础',
        ]);
        return ProgressModel.recompute();
      });
      final dueSummary = _snapshot(subjectA.key)['summary'] as Map<String, Object?>;
      expect(dueSummary['review_due'], 1);
      expect(dueSummary['next_review_at'], '',
          reason: 'next_review_at 只表示"未来下一次"，已到期的不再计入');
      final due = _inScope(subjectA.key, () => ProgressModel.dueTopics(limit: 5));
      expect(due.single['name'], '概率论基础');
      expect(due.single['status'], 'review_due');

      final daily = (_snapshot(subjectA.key)['daily'] as List).cast<Map<String, Object?>>();
      final today = daily.firstWhere((row) => row['day'] == Db.today());
      expect(today['events'], 1);
      expect(today['minutes'], 12);
      final scheduled = daily.firstWhere((row) => row['day'] == _dayOffset(-1));
      expect(scheduled['review_due'], 1, reason: '日汇总按"到期日"排期');
    });

    test('P3 幂等：同一 message_id 重复触发不重复计分、不改 mastery', () async {
      const event = {
        'kind': 'quiz',
        'topic': '幂等知识点',
        'result': 'correct',
        'duration_min': 8,
        'message_id': 301,
      };
      final first = await _callTool(subjectA.key, 'update_subject_progress', {
        'events': [event],
      });
      expect(first.payload['applied_events'], 1);
      final masteryAfterFirst = (_topicNamed(subjectA.key, '幂等知识点')!['mastery'] as num).toDouble();

      final second = await _callTool(subjectA.key, 'update_subject_progress', {
        'events': [event],
      });
      expect(second.payload['applied_events'], 0);
      expect(second.payload['duplicate_events'], 1);
      expect(_eventsOf(subjectA.key, '幂等知识点'), hasLength(1));
      expect(
        (_topicNamed(subjectA.key, '幂等知识点')!['mastery'] as num).toDouble(),
        masteryAfterFirst,
        reason: '重复写入不得再计分',
      );
      // HTTP 事件接口同样幂等（管理/测试路径）。
      final httpSecond = _inScope(
        subjectA.key,
        () => ProgressModel.recordEvents([event]),
      );
      expect(httpSecond['duplicate_events'], 1);
      expect(_eventsOf(subjectA.key, '幂等知识点'), hasLength(1));
    });

    test('P4 持久化：模拟重启后数值一致（AC-03 断言 2）', () async {
      await _callTool(subjectA.key, 'update_subject_progress', {
        'events': [
          {'kind': 'explain', 'topic': '持久化知识点', 'message_id': 401, 'duration_min': 30},
        ],
        'topics': [
          {
            'name': '持久化知识点',
            'mastery_delta': 0.15,
            'source_refs': [
              {'material_id': 7, 'page': 42},
            ],
          },
        ],
      });
      final before = _snapshot(subjectA.key);
      final beforeDaily = jsonEncode(before['daily']);

      // 关闭全部句柄后重开（数据目录不变）= 重启进程。
      SubjectStore.reopenForTests();

      final after = _snapshot(subjectA.key);
      expect(jsonEncode(after['summary']), jsonEncode(before['summary']));
      expect(jsonEncode(after['topics']), jsonEncode(before['topics']));
      expect(jsonEncode(after['daily']), beforeDaily);
      expect(jsonEncode(after['profile']), jsonEncode(before['profile']));

      final read = await _callTool(subjectA.key, 'get_subject_progress', {});
      expect(read.payload['summary'], containsPair('topics_total', 1));
    });

    test('P5 隔离：A 的进度不出现在 B（文件级 + 接口级）', () async {
      await _callTool(subjectA.key, 'update_subject_progress', {
        'events': [
          {'kind': 'explain', 'topic': '甲学科知识点', 'message_id': 501, 'duration_min': 5},
        ],
      });

      final snapshotB = _snapshot(subjectB.key);
      expect((snapshotB['summary'] as Map)['topics_total'], 0);
      expect(snapshotB['topics'], isEmpty);
      expect(jsonEncode(snapshotB), isNot(contains('甲学科知识点')));

      expect(SubjectStore.open(subjectA.key).count('topics'), 1);
      expect(SubjectStore.open(subjectB.key).count('topics'), 0);
      expect(SubjectStore.open(subjectB.key).count('study_events'), 0);
      expect(SubjectStore.open(subjectB.key).count('progress_daily'), 0);

      // B 里同名知识点互不影响（各自库内独立）。
      await _callTool(subjectB.key, 'update_subject_progress', {
        'events': [
          {'kind': 'explain', 'topic': '甲学科知识点', 'message_id': 502, 'duration_min': 9},
        ],
      });
      expect((_topicNamed(subjectA.key, '甲学科知识点')!['evidence_count'] as num).toInt(), 1);
      expect((_topicNamed(subjectB.key, '甲学科知识点')!['evidence_count'] as num).toInt(), 1);
      expect((_snapshot(subjectA.key)['summary'] as Map)['topics_total'], 1);
    });

    test('P6 限幅 / 证据 / 非法字段：警告说明且不写脏数据（§8.5）', () async {
      final r = await _callTool(subjectA.key, 'update_subject_progress', {
        'events': [
          {'kind': 'bogus', 'topic': '非法事件', 'message_id': 699},
          for (var i = 0; i < 5; i++)
            {'kind': 'read', 'topic': '超限知识点$i', 'message_id': 600 + i},
        ],
        'topics': [
          {'name': '无证据知识点'},
          {
            'name': '超限掌握度',
            'mastery_delta': 0.9,
            'source_refs': [
              {'message_id': 601},
            ],
          },
          {
            'name': '非法状态',
            'status': 'bogus',
            'source_refs': [
              {'message_id': 602},
            ],
          },
        ],
      });
      final warnings = (r.payload['warnings'] as List).cast<String>();
      expect(warnings.any((w) => w.contains('单次事件上限')), isTrue);
      expect(warnings.any((w) => w.contains('kind 非法')), isTrue);
      expect(warnings.any((w) => w.contains('缺少证据来源')), isTrue);
      expect(warnings.any((w) => w.contains('限幅')), isTrue);
      expect(warnings.any((w) => w.contains('status 非法')), isTrue);
      expect(r.payload['applied_events'], 4, reason: '单次最多 5 条，且其中 1 条 kind 非法被忽略');
      expect(r.payload['applied_topics'], 2, reason: '显式 topics[] 中 2 条合法、1 条缺证据被拒');
      expect(_topicNamed(subjectA.key, '无证据知识点'), isNull, reason: '无证据的知识点必须拒绝写入');
      expect(_topicNamed(subjectA.key, '非法事件'), isNull);
      expect(
        (_topicNamed(subjectA.key, '超限掌握度')!['mastery'] as num).toDouble(),
        0.25,
        reason: '|delta| ≤ 0.25',
      );
      expect(_topicNamed(subjectA.key, '非法状态')!['status'], 'learning');

      // 10 分钟滑窗：同一知识点第 3 次计分被合并。
      final window = await _callTool(subjectA.key, 'update_subject_progress', {
        'events': [
          {'kind': 'quiz', 'topic': '滑窗知识点', 'result': 'correct', 'message_id': 701},
          {'kind': 'quiz', 'topic': '滑窗知识点', 'result': 'correct', 'message_id': 702},
          {'kind': 'quiz', 'topic': '滑窗知识点', 'result': 'correct', 'message_id': 703},
        ],
      });
      expect(
        (window.payload['warnings'] as List).any((w) => '$w'.contains('已合并')),
        isTrue,
      );
      final mastery = (_topicNamed(subjectA.key, '滑窗知识点')!['mastery'] as num).toDouble();
      expect(mastery, lessThanOrEqualTo(0.4), reason: '第 3 次计分不得叠加');
    });

    test('P7 复习间隔（§8.6）：mastery 分档 + 二连对 mastered', () async {
      expect(ProgressModel.reviewIntervalDays(0.3), 1);
      expect(ProgressModel.reviewIntervalDays(0.5), 3);
      expect(ProgressModel.reviewIntervalDays(0.8), 7);
      expect(ProgressModel.reviewIntervalDays(0.95), 16);
      expect(ProgressModel.reviewIntervalDays(0.5, wrong: true), 1);
      expect(ProgressModel.reviewIntervalDays(0.1, masteredTwice: true), 16);

      // 显式 mastery 0.55 → 答对 +0.15 = 0.7 → 7 天。
      await _callTool(subjectA.key, 'update_subject_progress', {
        'topics': [
          {
            'name': '间隔知识点',
            'mastery': 0.55,
            'source_refs': [
              {'message_id': 801},
            ],
          },
        ],
      });
      expect((_topicNamed(subjectA.key, '间隔知识点')!['mastery'] as num).toDouble(), 0.55);
      await _callTool(subjectA.key, 'update_subject_progress', {
        'events': [
          {'kind': 'quiz', 'topic': '间隔知识点', 'result': 'correct', 'message_id': 802},
        ],
      });
      final topic = _topicNamed(subjectA.key, '间隔知识点')!;
      expect((topic['mastery'] as num).toDouble(), closeTo(0.7, 0.0001));
      expect(topic['next_review_at'], _dayOffset(7));

      // 连续两次 correct → mastered + 16 天。
      await _callTool(subjectA.key, 'update_subject_progress', {
        'events': [
          {'kind': 'quiz', 'topic': '二连对知识点', 'result': 'correct', 'message_id': 901},
          {'kind': 'quiz', 'topic': '二连对知识点', 'result': 'correct', 'message_id': 902},
        ],
      });
      final mastered = _topicNamed(subjectA.key, '二连对知识点')!;
      expect(mastered['status'], 'mastered');
      expect(mastered['next_review_at'], _dayOffset(16));
      expect((_snapshot(subjectA.key)['summary'] as Map)['mastered'], 1);
    });

    test('P8 日汇总由事件派生：重复读取一致、重算幂等', () async {
      await _callTool(subjectA.key, 'update_subject_progress', {
        'events': [
          {'kind': 'explain', 'topic': '日汇总一', 'duration_min': 15, 'message_id': 1001},
          {'kind': 'practice', 'topic': '日汇总二', 'duration_min': 25, 'message_id': 1002, 'result': 'correct'},
        ],
      });
      final first = jsonEncode(_snapshot(subjectA.key)['daily']);
      final second = jsonEncode(_snapshot(subjectA.key)['daily']);
      expect(second, first);
      final day = (_snapshot(subjectA.key)['daily'] as List).single as Map;
      expect(day['events'], 2);
      expect(day['minutes'], 40);

      final recompute1 = _inScope(subjectA.key, () => ProgressModel.recompute());
      final dayAfter1 = jsonEncode(_snapshot(subjectA.key)['daily']);
      final recompute2 = _inScope(subjectA.key, () => ProgressModel.recompute());
      expect(jsonEncode(_snapshot(subjectA.key)['daily']), dayAfter1);
      expect(recompute1['ok'], isTrue);
      expect(recompute2['ok'], isTrue);
      expect(recompute2['topics_updated'], 0, reason: '重算幂等：第二次不再改动');
      expect(recompute2['daily_days'], recompute1['daily_days']);
      expect((recompute2['summary'] as Map)['events_total'], 2);
    });

    test('P9 端到端：system 注入进度、模型可调用 get_subject_progress 并引用进度', () async {
      await _callTool(subjectA.key, 'update_subject_progress', {
        'events': [
          {
            'kind': 'explain',
            'topic': '特征值',
            'duration_min': 20,
            'message_id': 1101,
          },
        ],
      });

      // 工具定义必须暴露进度读写工具。
      final names = toolDefinitions.map((e) => (e['function'] as Map)['name']).toSet();
      expect(names, contains('get_subject_progress'));
      expect(names, contains('update_subject_progress'));
      expect(names, contains('search_materials'));

      final captured = <List<Map<String, dynamic>>>[];
      Stream<Map<String, dynamic>> chat(
        LlmConfig config,
        List<Map<String, dynamic>> messages,
        List<Map<String, dynamic>>? tools,
        String thinking,
      ) {
        captured.add(List.of(messages));
        final round = captured.length == 1
            ? [_toolCall('c1', 'get_subject_progress', {})]
            : [_text('你的「特征值」掌握度约 0.1，建议先复习再做题。')];
        return Stream.fromIterable(round);
      }

      final (conversationId, userMessageId) = _inScope(subjectA.key, () {
        final now = Db.nowIso();
        final id = Db.insert('conversations', {
          'title': '进度对话',
          'mode': 'answer',
          'created_at': now,
          'updated_at': now,
        });
        final mid = Db.insert('messages', {
          'conversation_id': id,
          'role': 'user',
          'content': '我现在的进度怎么样？',
          'steps': '[]',
          'refs': '[]',
          'created_at': now,
        });
        return (id, mid);
      });

      final run = AgentRuns.start(conversationId, subjectKey: subjectA.key);
      final events = <AgentEvent>[];
      await _inScopeAsync(subjectA.key, () async {
        await for (final event in runAgent(
          conversationId: conversationId,
          userMessageId: userMessageId,
          userText: '我现在的进度怎么样？',
          attachments: const [],
          run: run,
          chatStream: chat,
        )) {
          events.add(event);
        }
      });
      AgentRuns.remove(run.id);
      expect(events.map((e) => e.event), contains('done'));

      // system 提示注入学科上下文与进度摘要。
      final system = captured.first.first['content'] as String;
      expect(system, contains('当前学科：进度甲（${subjectA.key}）'));
      expect(system, contains('学科进度摘要：1 个知识点'));
      expect(system, contains('get_subject_progress'));
      expect(system, contains('update_subject_progress'));

      // 模型看到的是结构化进度（mastery/coverage/待复习）。
      final toolContents = captured.last
          .where((m) => m['role'] == 'tool')
          .map((m) => '${m['content']}')
          .join();
      expect(toolContents, contains('mastery'));
      expect(toolContents, contains('coverage'));
      expect(toolContents, contains('特征值'));
      expect(toolContents, contains(subjectA.key));

      // 回答落库，且引用了进度数值。
      final assistant = _inScope(
        subjectA.key,
        () => Db.one(
          "SELECT * FROM messages WHERE conversation_id=? AND role='assistant' ORDER BY id DESC LIMIT 1",
          [conversationId],
        ),
      );
      expect('${assistant?['content']}', contains('掌握度'));
      expect('${assistant?['content']}', contains('特征值'));
      expect(_inScope(subjectA.key, () => Db.scalar("SELECT quote(content) FROM messages WHERE role='assistant'")),
          isNotNull);
    });
  });

  group('P10 HTTP /api/subjects/{id}/progress*（§11.4）', () {
    late Directory root;
    late int port;
    late String base;
    late _HttpClient client;

    setUp(() async {
      root = _tempRoot();
      port = await Backend.startForTests(root);
      base = 'http://127.0.0.1:$port';
      client = _HttpClient(base);
    });

    tearDown(() async {
      await Backend.stopForTests();
      SubjectStore.resetForTests();
      _deleteQuietly(root);
    });

    test('P10 GET/PATCH/events/recompute/DELETE 全链路 + 默认学科外隔离', () async {
      final (_, a) = await client.post('/api/subjects', {'name': '接口甲'});
      final (_, b) = await client.post('/api/subjects', {'name': '接口乙'});
      final keyA = (a as Map)['key'] as String;
      final idA = a['id'] as int;
      final idB = (b as Map)['id'] as int;

      // 事件写入（管理/测试路径，AI 走工具）。
      final (statusEvents, eventsBody) = await client.post(
        '/api/subjects/$idA/progress/events',
        {
          'events': [
            {'kind': 'explain', 'topic': '线性映射', 'message_id': 1201, 'duration_min': 15},
          ],
        },
      );
      expect(statusEvents, 200);
      expect((eventsBody as Map)['applied_events'], 1);
      expect(eventsBody['subject_id'], idA);

      final (statusGet, progress) = await client.get('/api/subjects/$idA/progress');
      expect(statusGet, 200);
      final map = progress as Map;
      expect(map['subject_key'], keyA);
      expect(map['profile'], isA<Map>());
      final summary = map['summary'] as Map;
      for (final field in ['coverage', 'mastery_avg', 'last_studied_at', 'review_due']) {
        expect(summary, contains(field));
      }
      expect(summary['topics_total'], 1);
      final topics = (map['topics'] as List).cast<Map>().toList();
      expect(topics.single['name'], '线性映射');
      expect(map['daily'], isA<List>());
      final topicId = topics.single['id'] as int;

      // 用户手工纠正：PATCH 改 mastery/status/画像 → 立即生效。
      final (statusPatch, patched) = await client.patch('/api/subjects/$idA/progress', {
        'profile': {'goal': '期末 90 分', 'daily_minutes': 60, 'level': 'intermediate'},
        'topics': [
          {'id': topicId, 'mastery': 0.8, 'status': 'mastered'},
        ],
      });
      expect(statusPatch, 200);
      final patchedMap = patched as Map;
      expect(patchedMap['warnings'], isNull);
      final patchedTopic = (patchedMap['topics'] as List).cast<Map>().single;
      expect((patchedTopic['mastery'] as num).toDouble(), 0.8);
      expect(patchedTopic['status'], 'mastered');
      expect(patchedTopic['manual'], isTrue, reason: '手工值必须打 source=user 标记');
      expect((patchedMap['profile'] as Map)['goal'], '期末 90 分');
      // 画像镜像到注册表（侧栏/学科页同源）。
      final (_, subjectRow) = await client.get('/api/subjects/$keyA');
      expect((subjectRow as Map)['goal'], '期末 90 分');
      expect(subjectRow['daily_minutes'], 60);

      // 重算：不覆盖手工值（AC-03 断言 5），且幂等。
      final (statusRecompute, recomputed) = await client.post(
        '/api/subjects/$idA/progress/recompute',
        {},
      );
      expect(statusRecompute, 200);
      expect((recomputed as Map)['ok'], isTrue);
      expect((recomputed)['topics_preserved'], greaterThanOrEqualTo(1));
      final (_, afterRecompute) = await client.get('/api/subjects/$idA/progress');
      final afterTopic = ((afterRecompute as Map)['topics'] as List).single as Map;
      expect((afterTopic['mastery'] as num).toDouble(), 0.8, reason: '重算不得覆盖用户手工值');
      expect(afterTopic['status'], 'mastered');
      final (_, recomputeAgain) = await client.post('/api/subjects/$idA/progress/recompute', {});
      expect((recomputeAgain as Map)['daily_days'], recomputed['daily_days']);

      // 重复事件 → duplicate，不重复计分。
      final (_, dup) = await client.post('/api/subjects/$idA/progress/events', {
        'events': [
          {'kind': 'explain', 'topic': '线性映射', 'message_id': 1201, 'duration_min': 15},
        ],
      });
      expect((dup as Map)['duplicate_events'], 1);
      expect((dup['applied_events']), 0);

      // 分页参数与 404。
      final (statusPage, page) = await client.get('/api/subjects/$idA/progress?limit=1&offset=0');
      expect(statusPage, 200);
      expect((page as Map)['topics'], hasLength(1));
      final (statusBad, _) = await client.get('/api/subjects/999999/progress');
      expect(statusBad, 404);

      // 学科隔离：B 的进度为空，A 的 topic 不出现在 B。
      final (statusB, progressB) = await client.get('/api/subjects/$idB/progress');
      expect(statusB, 200);
      expect(((progressB as Map)['summary'] as Map)['topics_total'], 0);
      expect(jsonEncode(progressB), isNot(contains('线性映射')));

      // 软删知识点：默认列表不再出现，事件保留。
      final (statusDelete, deleted) = await client.delete('/api/subjects/$idA/progress/topics/$topicId');
      expect(statusDelete, 200);
      expect((deleted as Map)['status'], 'archived');
      expect((deleted['events_kept'] as num).toInt(), greaterThanOrEqualTo(1));
      final (_, afterDelete) = await client.get('/api/subjects/$idA/progress');
      expect((afterDelete as Map)['topics'], isEmpty);
      final (_, withArchived) =
          await client.get('/api/subjects/$idA/progress?include_archived=true');
      expect((withArchived as Map)['topics'], hasLength(1));
      expect(((withArchived)['topics'] as List).single as Map, containsPair('status', 'archived'));
      final (statusDeleteMissing, _) =
          await client.delete('/api/subjects/$idA/progress/topics/999999');
      expect(statusDeleteMissing, 404);

      // 归档学科的写操作 409，读取仍可（§3.5）。
      final (_, archived) = await client.post('/api/subjects/$idB/archive');
      expect((archived as Map)['status'], 'archived');
      final (statusWriteArchived, _) = await client.post('/api/subjects/$idB/progress/events', {
        'events': [
          {'kind': 'explain', 'topic': 'x', 'message_id': 9},
        ],
      });
      expect(statusWriteArchived, 409);
      final (statusReadArchived, _) = await client.get('/api/subjects/$idB/progress');
      expect(statusReadArchived, 200);
    });
  });
}

/// 极简 HTTP 客户端（测试内使用，避免依赖 LoopApi 的具体实现）。
class _HttpClient {
  _HttpClient(this.base);

  final String base;

  Future<(int, Object?)> _send(String method, String path, [Object? body]) async {
    final uri = Uri.parse('$base$path');
    final headers = {'Content-Type': 'application/json; charset=utf-8'};
    final encoded = body == null ? null : jsonEncode(body);
    final response = switch (method) {
      'GET' => await http.get(uri),
      'POST' => await http.post(uri, headers: headers, body: encoded),
      'PUT' => await http.put(uri, headers: headers, body: encoded),
      'PATCH' => await http.patch(uri, headers: headers, body: encoded),
      _ => await http.delete(uri),
    };
    final text = utf8.decode(response.bodyBytes);
    final decoded = text.isEmpty ? null : jsonDecode(text);
    return (response.statusCode, decoded);
  }

  Future<(int, Object?)> get(String path) => _send('GET', path);
  Future<(int, Object?)> post(String path, [Object? body]) => _send('POST', path, body);
  Future<(int, Object?)> patch(String path, [Object? body]) => _send('PATCH', path, body);
  Future<(int, Object?)> delete(String path) => _send('DELETE', path);
}