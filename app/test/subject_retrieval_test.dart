import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:loop/backend/agent.dart';
import 'package:loop/backend/agent_run.dart';
import 'package:loop/backend/agent_tools.dart';
import 'package:loop/backend/db.dart';
import 'package:loop/backend/llm.dart';
import 'package:loop/backend/paths.dart';
import 'package:loop/backend/retrieval.dart';
import 'package:loop/backend/subject_store.dart';

/// 学科内资料优先检索测试（t4；规格 docs/subject-feature-spec.md §7 / §14 AC-01·AC-02）。
///
/// 纪律：
/// - 全部使用隔离数据目录（`SubjectStore.initTempForTests`），绝不触碰正式 `data/`；
/// - 只用真实学科库 + 真实 FTS5 + 真实工具入口（`executeTool`），不 mock 检索层；
/// - 用例编号 R1..R8 对应 §7.2/§7.3/§7.6 的可断言项。

Directory _tempRoot() => Directory.systemTemp.createTempSync('loop-subject-retrieval-');

void _deleteQuietly(Directory dir) {
  try {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  } catch (_) {}
}

/// 在指定学科库内插入 1 份资料 + 分块 + FTS 索引（走真实 tokenize）。
int _seedMaterial(
  String key,
  String name,
  List<(int, String)> chunks, {
  int sourceMtime = 0,
}) {
  final handle = SubjectStore.open(key);
  return Db.runScopedSync(
    handle.database,
    () {
      final now = Db.nowIso();
      final id = Db.insert('materials', {
        'name': name,
        'kind': 'txt',
        'path': p.join(AppPaths.subjectFilesDir(key).path, name),
        'status': 'ready',
        'pages': 1,
        'chars': 100,
        'created_at': now,
        'source_mtime': sourceMtime,
      });
      for (final (page, text) in chunks) {
        final chunkId = Db.insert('chunks', {'material_id': id, 'page': page, 'text': text});
        Db.run('INSERT INTO chunks_fts(chunk_id, tokens) VALUES(?,?)', [
          chunkId,
          tokenize(text).join(' '),
        ]);
      }
      return id;
    },
    subjectKey: key,
    filesDir: AppPaths.subjectFilesDir(key).path,
  );
}

class _ToolRun {
  _ToolRun(this.payload, this.detail, this.refs);

  final Map<String, Object?> payload;
  final String detail;
  final List<Map<String, Object?>> refs;

  List<Map<String, Object?>> get payloadRefs =>
      ((payload['refs'] as List?) ?? const []).cast<Map<String, Object?>>();
}

/// 在**指定学科作用域**内调用工具（与 HTTP chat 的作用域路径一致）。
Future<_ToolRun> _callTool(String key, String name, Map<String, dynamic> args) async {
  final handle = SubjectStore.open(key);
  final run = AgentRuns.start(0);
  final ctx = ToolContext(conversationId: 0, run: run, plan: PlanState(), refs: []);
  try {
    final result = await Db.runScoped(
      handle.database,
      () => executeTool(name, args, ctx),
      subjectKey: key,
      filesDir: AppPaths.subjectFilesDir(key).path,
    );
    return _ToolRun(result.payload, result.detail, List.of(ctx.refs));
  } finally {
    AgentRuns.remove(run.id);
  }
}

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
  late Directory root;
  late SubjectRecord subjectA;
  late SubjectRecord subjectB;

  setUp(() {
    root = _tempRoot();
    SubjectStore.initTempForTests(root);
    subjectA = SubjectStore.create(name: '甲学科');
    subjectB = SubjectStore.create(name: '乙学科');
  });

  tearDown(() {
    SubjectStore.resetForTests();
    _deleteQuietly(root);
  });

  test('R1 学科内检索只命中本学科资料；B 学科资料/A 学科资料互不泄漏', () async {
    final matA = _seedMaterial(subjectA.key, '甲讲义.pdf', [
      (2, '特征向量 EIGEN4711 的分解方法 ZQA7319'),
    ]);
    _seedMaterial(subjectB.key, '乙讲义.pdf', [
      (5, '概率分布 ZQB8821 的期望与方差'),
    ]);

    final a = await _callTool(subjectA.key, 'search_materials', {'query': 'EIGEN4711'});
    expect(a.payload['ok'], isTrue);
    expect(a.payload['hits'], 1);
    expect(a.payload['subject_key'], subjectA.key);
    expect(a.detail, contains('本学科'));

    final ref = a.payloadRefs.single;
    expect(ref['name'], '甲讲义.pdf', reason: '片段必须带资料名');
    expect(ref['page'], 2, reason: '片段必须带页码');
    expect(ref['material_id'], matA);
    expect(ref['subject_key'], subjectA.key);
    expect(a.payload['context'], contains('[甲讲义.pdf p.2]'));
    expect(a.payload['context'], contains('EIGEN4711'));
    expect(a.payload['context'], isNot(contains('乙讲义')));
    expect(a.refs.single['material_id'], matA);

    // 只有 B 含有的 token：在 A 学科内检索为空，且不泄漏 B 的任何内容。
    final aMiss = await _callTool(subjectA.key, 'search_materials', {'query': 'ZQB8821'});
    expect(aMiss.payload['hits'], 0);
    expect(aMiss.payload['context'], '');
    expect(aMiss.refs, isEmpty);
    expect(aMiss.detail, contains('本学科资料中没有相关内容'));
    expect(aMiss.payload['message'], contains('本学科资料中没有相关内容'));

    // 隔离是双向的：B 查得到自己的，也看不到 A 的。
    final b = await _callTool(subjectB.key, 'search_materials', {'query': 'ZQB8821'});
    expect(b.payload['hits'], 1);
    expect(b.payloadRefs.single['name'], '乙讲义.pdf');
    expect(b.payloadRefs.single['subject_key'], subjectB.key);
    expect(b.payload['context'], isNot(contains('EIGEN4711')));
    final bMiss = await _callTool(subjectB.key, 'search_materials', {'query': 'EIGEN4711'});
    expect(bMiss.payload['hits'], 0);
    expect(bMiss.refs, isEmpty);
  });

  test('R2 同一 token 存在于两个学科：本学科占 100% 预算，他科不进上下文', () async {
    _seedMaterial(subjectA.key, '甲资料.pdf', [(3, 'EIGEN4711 属于本学科的关键内容')], sourceMtime: 100);
    _seedMaterial(subjectB.key, '乙资料.pdf', [(4, 'EIGEN4711 是乙学科的内容')], sourceMtime: 200);

    final a = await _callTool(subjectA.key, 'search_materials', {'query': 'EIGEN4711'});
    expect(a.payload['hits'], 1);
    expect(a.payload['cross_hits'], 0);
    expect(a.payload['scope'], 'subject');
    expect(a.payloadRefs.single['name'], '甲资料.pdf');
    expect(a.payloadRefs.single['page'], 3);
    expect(a.payload['context'], contains('[甲资料.pdf p.3]'));
    expect(a.payload['context'], isNot(contains('乙资料')));
    expect(a.payloadRefs.map((e) => e['subject_key']).toSet(), {subjectA.key});
  });

  test('R3 稳定排序：同输入连续 10 次检索结果完全一致（AC-02 断言 4）', () async {
    _seedMaterial(subjectA.key, '甲一.pdf', [(1, 'STABLE9 分块一')], sourceMtime: 10);
    _seedMaterial(subjectA.key, '甲二.pdf', [(1, 'STABLE9 分块二'), (2, 'STABLE9 分块三')]);
    _seedMaterial(subjectA.key, '甲三.pdf', [(3, 'STABLE9 分块四')], sourceMtime: 99);

    final runs = <String>[];
    for (var i = 0; i < 10; i++) {
      final r = await _callTool(subjectA.key, 'search_materials', {'query': 'STABLE9'});
      runs.add(jsonEncode(r.payloadRefs.map((e) => [e['material_id'], e['page']]).toList()));
    }
    expect(runs.toSet(), hasLength(1), reason: '同输入必须同输出（禁止依赖插入顺序）');

    final ordered = (jsonDecode(runs.first) as List).cast<List>();
    expect(ordered.length, greaterThan(1));
    final byMaterial = <int, List<int>>{};
    for (final item in ordered) {
      byMaterial.putIfAbsent(item[0] as int, () => []).add(item[1] as int);
    }
    for (final pages in byMaterial.values) {
      final sorted = [...pages]..sort();
      expect(pages, sorted, reason: '同一资料内页码必须升序稳定');
    }
    // 去重：同 material_id + page 只保留一条。
    final keys = ordered.map((e) => '${e[0]}#${e[1]}').toList();
    expect(keys.toSet(), hasLength(keys.length));
  });

  test('R4 跨学科默认关闭：scope=all 被忽略并说明，B 内容不进入上下文', () async {
    Db.setSetting('cross_subject_search', 'false');
    _seedMaterial(subjectA.key, '甲资料.pdf', [(3, 'EIGEN4711 本学科内容')]);
    _seedMaterial(subjectB.key, '乙资料.pdf', [(5, 'ZQB8821 乙学科独有内容')]);

    final r = await _callTool(subjectA.key, 'search_materials', {
      'query': 'ZQB8821',
      'scope': 'all',
    });
    expect(r.payload['scope'], 'subject');
    expect(r.payload['hits'], 0);
    expect(r.payload['cross_hits'], 0);
    expect(r.payload['context'], '');
    expect(r.refs, isEmpty);
    expect((r.payload['warnings'] as List).single, contains('跨学科检索未启用'));
    expect(jsonEncode(r.payload), isNot(contains('乙学科独有内容')));
  });

  test('R5 开启跨学科后仅作兜底：带学科标注、预算 ≤ 600、本学科优先', () async {
    Db.setSetting('cross_subject_search', 'true');
    _seedMaterial(subjectA.key, '甲资料.pdf', [(3, 'EIGEN4711 本学科内容')]);
    _seedMaterial(subjectB.key, '乙资料.pdf', [(5, 'ZQB8821 乙学科独有内容')]);

    // 默认 scope=subject：即使开关打开也不跨学科。
    final strict = await _callTool(subjectA.key, 'search_materials', {'query': 'ZQB8821'});
    expect(strict.payload['scope'], 'subject');
    expect(strict.payload['hits'], 0);
    expect(strict.payload['cross_hits'], 0);
    expect(strict.refs, isEmpty);

    // scope=all 且本学科 0 命中 → 跨学科兜底，命中必须标注学科。
    final cross = await _callTool(subjectA.key, 'search_materials', {
      'query': 'ZQB8821',
      'scope': 'all',
    });
    expect(cross.payload['scope'], 'all');
    expect(cross.payload['hits'], 0);
    expect(cross.payload['cross_hits'], 1);
    final ref = cross.payloadRefs.single;
    expect(ref['subject_key'], subjectB.key);
    expect(ref['subject_name'], '乙学科');
    expect(ref['cross_subject'], isTrue);
    expect(ref['name'], '乙资料.pdf');
    expect(ref['page'], 5);
    expect(cross.payload['context'], contains('乙资料.pdf p.5'));
    expect(cross.payload['context'], contains('· 乙学科'));
    expect((cross.payload['context'] as String).length, lessThanOrEqualTo(600));

    // 本学科有命中时不启用兜底（L0 独占预算）。
    final local = await _callTool(subjectA.key, 'search_materials', {
      'query': 'EIGEN4711',
      'scope': 'all',
    });
    expect(local.payload['hits'], 1);
    expect(local.payload['cross_hits'], 0);
    expect(local.payload['context'], contains('甲资料.pdf'));
    expect(local.payload['context'], isNot(contains('乙资料')));
  });

  test('R6 list_materials 只列当前学科资料并带 subject 信息', () async {
    _seedMaterial(subjectA.key, '甲一.pdf', [(1, 'A1')]);
    _seedMaterial(subjectA.key, '甲二.pdf', [(1, 'A2')]);
    _seedMaterial(subjectB.key, '乙一.pdf', [(1, 'B1')]);

    final a = await _callTool(subjectA.key, 'list_materials', {});
    final namesA = (a.payload['materials'] as List)
        .cast<Map<String, Object?>>()
        .map((e) => e['name'])
        .toSet();
    expect(namesA, {'甲一.pdf', '甲二.pdf'});
    expect(a.payload['subject_key'], subjectA.key);
    expect((a.payload['subject'] as Map)['name'], '甲学科');
    expect(a.payload['scope'], 'subject');

    final b = await _callTool(subjectB.key, 'list_materials', {});
    final namesB = (b.payload['materials'] as List)
        .cast<Map<String, Object?>>()
        .map((e) => e['name'])
        .toSet();
    expect(namesB, {'乙一.pdf'});
  });

  test('R7 检索性能：2000 分块下单次检索 P95 ≤ 100ms（AC-02 断言 5）', () async {
    final handle = SubjectStore.open(subjectA.key);
    Db.runScopedSync(
      handle.database,
      () {
        final now = Db.nowIso();
        final materialId = Db.insert('materials', {
          'name': '压测资料.pdf',
          'kind': 'txt',
          'path': 'large.pdf',
          'status': 'ready',
          'pages': 1,
          'chars': 1,
          'created_at': now,
        });
        for (var i = 0; i < 2000; i++) {
          final text = '性能压测关键词 分块 $i 学习内容 PERF$i 线性代数';
          final chunkId = Db.insert('chunks', {
            'material_id': materialId,
            'page': 1 + (i % 20),
            'text': text,
          });
          Db.run('INSERT INTO chunks_fts(chunk_id, tokens) VALUES(?,?)', [
            chunkId,
            tokenize(text).join(' '),
          ]);
        }
      },
      subjectKey: subjectA.key,
      filesDir: AppPaths.subjectFilesDir(subjectA.key).path,
    );
    expect(SubjectStore.open(subjectA.key).count('chunks'), 2000);

    final durations = <int>[];
    for (var i = 0; i < 60; i++) {
      final r = await _callTool(subjectA.key, 'search_materials', {'query': '性能压测关键词'});
      expect(r.payload['hits'], greaterThan(0));
      durations.add(r.payload['duration_ms'] as int);
    }
    durations.sort();
    final p95Index = ((durations.length * 0.95).floor()).clamp(0, durations.length - 1);
    expect(durations[p95Index], lessThanOrEqualTo(100),
        reason: 'P95=${durations[p95Index]}ms，样本=${durations.join(",")}');
  });

  test('R8 端到端：学科内对话的 system 提示与工具结果只含本学科资料', () async {
    final matA = _seedMaterial(subjectA.key, '甲讲义.pdf', [
      (2, '特征向量 EIGEN4711 的分解方法'),
    ]);
    _seedMaterial(subjectB.key, '乙讲义.pdf', [
      (7, 'EIGEN4711 属于乙学科专属内容'),
    ]);

    final captured = <List<Map<String, dynamic>>>[];
    Stream<Map<String, dynamic>> chat(
      LlmConfig config,
      List<Map<String, dynamic>> messages,
      List<Map<String, dynamic>>? tools,
      String thinking,
    ) {
      captured.add(List.of(messages));
      final round = captured.length == 1
          ? [_toolCall('c1', 'search_materials', {'query': 'EIGEN4711'})]
          : [_text('按资料，特征向量见 [甲讲义.pdf p.2]。')];
      return Stream.fromIterable(round);
    }

    final handle = SubjectStore.open(subjectA.key);
    final (conversationId, userMessageId) = Db.runScopedSync(
      handle.database,
      () {
        final now = Db.nowIso();
        final id = Db.insert('conversations', {
          'title': '学科内对话',
          'mode': 'answer',
          'created_at': now,
          'updated_at': now,
        });
        final mid = Db.insert('messages', {
          'conversation_id': id,
          'role': 'user',
          'content': '特征向量在哪里讲的？',
          'steps': '[]',
          'refs': '[]',
          'created_at': now,
        });
        return (id, mid);
      },
      subjectKey: subjectA.key,
      filesDir: AppPaths.subjectFilesDir(subjectA.key).path,
    );

    final run = AgentRuns.start(conversationId, subjectKey: subjectA.key);
    final events = <AgentEvent>[];
    await Db.runScoped(
      handle.database,
      () async {
        await for (final event in runAgent(
          conversationId: conversationId,
          userMessageId: userMessageId,
          userText: '特征向量在哪里讲的？',
          attachments: const [],
          run: run,
          chatStream: chat,
        )) {
          events.add(event);
        }
      },
      subjectKey: subjectA.key,
      filesDir: AppPaths.subjectFilesDir(subjectA.key).path,
    );
    AgentRuns.remove(run.id);

    expect(events.map((e) => e.event), contains('done'));

    // 1) system 提示注入：带当前学科 + 进度摘要 + 资料规则；不含他科。
    final system = (captured.first.first['content'] as String);
    expect(system, contains('当前学科：甲学科（${subjectA.key}）'));
    expect(system, contains('学科进度摘要：'));
    expect(system, contains('资料与进度规则：'));
    expect(system, isNot(contains('乙学科')));

    // 2) 工具结果只含本学科资料与页码；不含他科唯一内容。
    final toolMessages = captured.last.where((m) => m['role'] == 'tool').toList();
    expect(toolMessages, isNotEmpty);
    final toolPayload = toolMessages.map((m) => '${m['content']}').join();
    expect(toolPayload, contains('甲讲义.pdf'));
    expect(toolPayload, contains('p.2'));
    expect(toolPayload, isNot(contains('乙讲义')));
    expect(toolPayload, isNot(contains('乙学科专属内容')));

    // 3) refs 落库只含本学科资料；B 学科库完全没有这次对话。
    final assistant = Db.runScopedSync(
      handle.database,
      () => Db.one(
        "SELECT * FROM messages WHERE conversation_id=? AND role='assistant' ORDER BY id DESC LIMIT 1",
        [conversationId],
      ),
      subjectKey: subjectA.key,
      filesDir: AppPaths.subjectFilesDir(subjectA.key).path,
    );
    final refs = (jsonDecode((assistant?['refs'] ?? '[]').toString()) as List)
        .whereType<Map>()
        .toList();
    expect(refs, isNotEmpty);
    expect(refs.map((e) => e['material_id']).toSet(), {matA});
    expect(refs.map((e) => e['subject_key']).toSet(), {subjectA.key});
    expect(jsonEncode(refs), isNot(contains('乙讲义')));

    final bMessages = SubjectStore.open(subjectB.key).count('messages');
    expect(bMessages, 0, reason: 'A 学科对话不得在 B 学科库留下任何消息');
    expect(SubjectStore.open(subjectA.key).count('messages'), 2);
    expect(SubjectStore.open(subjectA.key).count('conversations'), 1);
  });
}