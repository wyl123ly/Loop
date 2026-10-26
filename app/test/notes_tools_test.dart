import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:loop/backend/agent_run.dart';
import 'package:loop/backend/agent_tools.dart';
import 'package:loop/backend/db.dart';
import 'package:loop/backend/subject_store.dart';

/// 反馈 #3：AI 需要能删除笔记（原实现只有 create/update/read）。
/// 通过真实学科库 + 真实工具入口验证 delete_note / delete_notes。
void main() {
  late Directory root;
  late SubjectRecord subject;

  setUp(() {
    root = Directory.systemTemp.createTempSync('loop-notes-tools-');
    SubjectStore.initTempForTests(root);
    subject = SubjectStore.create(name: '笔记权限测试');
  });

  tearDown(() {
    SubjectStore.resetForTests();
    try {
      if (root.existsSync()) root.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<ToolResult> call(String name, Map<String, dynamic> args) async {
    final handle = SubjectStore.open(subject.key);
    final run = AgentRuns.start(0, subjectKey: subject.key);
    final ctx = ToolContext(conversationId: 0, run: run, plan: PlanState(), refs: []);
    try {
      return await Db.runScoped(
        handle.database,
        () => executeTool(name, args, ctx),
        subjectKey: subject.key,
        filesDir: SubjectRecord.fromRow(
          Db.globalOne('SELECT * FROM subjects WHERE key=?', [subject.key])!,
        ).filesPath,
      );
    } finally {
      AgentRuns.remove(run.id);
    }
  }

  test('NT1 delete_note 删除单篇笔记', () async {
    final created = await call('create_note', {
      'title': '临时笔记',
      'body': '# 内容\n\n待删除',
    });
    final id = created.payload['note_id'] as int;
    expect(created.payload['ok'], isTrue);

    final listed = await call('list_notes', {});
    expect((listed.payload['notes'] as List), hasLength(1));

    final deleted = await call('delete_note', {'id': id});
    expect(deleted.payload['ok'], isTrue);
    expect(deleted.payload['deleted'], id);

    final after = await call('list_notes', {});
    expect((after.payload['notes'] as List), isEmpty);
  });

  test('NT2 delete_note 对不存在 id 返回错误且不误删', () async {
    final missing = await call('delete_note', {'id': 999999});
    expect(missing.payload['ok'], isFalse);
  });

  test('NT3 delete_notes 批量删除并报告缺失 id', () async {
    final ids = <int>[];
    for (var i = 0; i < 3; i++) {
      final created = await call('create_note', {
        'title': '批量 $i',
        'body': '内容 $i',
      });
      ids.add(created.payload['note_id'] as int);
    }

    final deleted = await call('delete_notes', {
      'ids': [...ids, 999999],
    });
    expect(deleted.payload['ok'], isTrue);
    expect(deleted.payload['deleted'], 3);
    expect((deleted.payload['missing'] as List), [999999]);

    final after = await call('list_notes', {});
    expect((after.payload['notes'] as List), isEmpty);
  });
}