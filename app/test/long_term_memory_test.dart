import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:loop/backend/agent_run.dart';
import 'package:loop/backend/agent_tools.dart';
import 'package:loop/backend/db.dart';
import 'package:loop/backend/long_term_memory.dart';
import 'package:loop/backend/subject_store.dart';

/// 反馈 #4：每个学科内置长期记忆，跨对话可读；并暴露 memory_* 工具。
void main() {
  late Directory root;
  late SubjectRecord subjectA;
  late SubjectRecord subjectB;

  setUp(() {
    root = Directory.systemTemp.createTempSync('loop-memory-');
    SubjectStore.initTempForTests(root);
    subjectA = SubjectStore.create(name: '记忆甲');
    subjectB = SubjectStore.create(name: '记忆乙');
  });

  tearDown(() {
    SubjectStore.resetForTests();
    try {
      if (root.existsSync()) root.deleteSync(recursive: true);
    } catch (_) {}
  });

  T inScope<T>(String key, T Function() body) {
    final handle = SubjectStore.open(key);
    return Db.runScopedSync(handle.database, body, subjectKey: key);
  }

  Future<ToolResult> call(String key, String name, Map<String, dynamic> args) async {
    final handle = SubjectStore.open(key);
    final run = AgentRuns.start(0, subjectKey: key);
    final ctx = ToolContext(conversationId: 7, run: run, plan: PlanState(), refs: []);
    try {
      return await Db.runScoped(
        handle.database,
        () => executeTool(name, args, ctx),
        subjectKey: key,
        filesDir: SubjectRecord.fromRow(
          Db.globalOne('SELECT * FROM subjects WHERE key=?', [key])!,
        ).filesPath,
      );
    } finally {
      AgentRuns.remove(run.id);
    }
  }

  test('LM1 写入/去重/检索/删除长期记忆', () {
    final created = inScope(subjectA.key, () => LongTermMemory.write(
          title: '讲解偏好',
          body: '喜欢先给结论，再给推导',
          kind: 'preference',
          tags: ['风格'],
          importance: 0.9,
        ));
    expect(created['ok'], isTrue);
    expect(created['mode'], 'created');

    final again = inScope(subjectA.key, () => LongTermMemory.write(
          title: '讲解偏好',
          body: '喜欢先给结论，再给关键推导，最后给例子',
        ));
    expect(again['mode'], 'updated');
    expect(inScope(subjectA.key, () => LongTermMemory.count()), 1);

    final hits = inScope(subjectA.key, () => LongTermMemory.search('结论'));
    expect(hits, hasLength(1));
    expect((hits.first['body'] as String).contains('关键推导'), isTrue);

    final block = inScope(subjectA.key, () => LongTermMemory.promptBlock());
    expect(block.contains('长期记忆'), isTrue);
    expect(block.contains('讲解偏好'), isTrue);

    expect(inScope(subjectA.key, () => LongTermMemory.delete(created['id'] as int)), isTrue);
    expect(inScope(subjectA.key, () => LongTermMemory.count()), 0);
  });

  test('LM2 记忆按学科隔离', () {
    inScope(subjectA.key, () => LongTermMemory.write(
          title: '甲的秘密',
          body: '只属于甲',
          importance: 1,
        ));
    expect(inScope(subjectB.key, () => LongTermMemory.count()), 0);
    expect(inScope(subjectB.key, () => LongTermMemory.promptBlock()), '');
  });

  test('LM3 memory_* 工具可被 Agent 调用', () async {
    final write = await call(subjectA.key, 'memory_write', {
      'title': '易错点：矩阵乘法',
      'body': '总是忘记顺序不可交换',
      'kind': 'error',
      'tags': ['线代'],
      'importance': 0.8,
    });
    expect(write.payload['ok'], isTrue);
    final id = write.payload['memory_id'] as int;

    final search = await call(subjectA.key, 'memory_search', {'query': '矩阵'});
    expect(search.payload['ok'], isTrue);
    expect((search.payload['memories'] as List), hasLength(1));

    final listed = await call(subjectA.key, 'memory_list', {});
    expect(listed.payload['total'], 1);

    final deleted = await call(subjectA.key, 'memory_delete', {'id': id});
    expect(deleted.payload['ok'], isTrue);
    expect(inScope(subjectA.key, () => LongTermMemory.count()), 0);
  });
}