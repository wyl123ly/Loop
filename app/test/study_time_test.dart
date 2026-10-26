import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:loop/backend/db.dart';
import 'package:loop/backend/subject_progress.dart';
import 'package:loop/backend/subject_store.dart';

/// 反馈 #6：学习时长改为真实活跃会话统计。
/// 规则：15 分钟间隔内连续；单次最多计 5 分钟；新会话起步 1 分钟。
void main() {
  late Directory root;
  late SubjectRecord subject;

  setUp(() {
    root = Directory.systemTemp.createTempSync('loop-study-time-');
    SubjectStore.initTempForTests(root);
    subject = SubjectStore.create(name: '时长测试');
  });

  tearDown(() {
    SubjectStore.resetForTests();
    try {
      if (root.existsSync()) root.deleteSync(recursive: true);
    } catch (_) {}
  });

  T inScope<T>(T Function() body) {
    final handle = SubjectStore.open(subject.key);
    return Db.runScopedSync(handle.database, body, subjectKey: subject.key);
  }

  Map<String, Object?> touch() =>
      inScope(() => ProgressModel.touchStudyActivity());

  int sessionCount() =>
      inScope(() => Db.rows('SELECT id FROM study_sessions').length);

  void setLastAt(int minutesAgo) {
    final at = DateTime.now().subtract(Duration(minutes: minutesAgo)).toIso8601String();
    inScope(() {
      Db.run(
        'UPDATE study_sessions SET last_at=? WHERE id='
        '(SELECT id FROM study_sessions ORDER BY id DESC LIMIT 1)',
        [at],
      );
      return null;
    });
  }

  test('ST1 首次活跃起步 1 分钟并写入当天汇总', () {
    final result = touch();
    expect(result['ok'], isTrue);
    expect(result['credited_seconds'], 60);
    expect(result['session_seconds'], 60);
    expect(result['today_minutes'], 1);
    expect(sessionCount(), 1);
  });

  test('ST2 连续活跃按间隔累计，单次封顶 5 分钟', () {
    touch();
    setLastAt(5);
    final result = touch();
    expect(result['credited_seconds'], 300);
    expect(result['session_seconds'], 360);
    expect(result['today_minutes'], 6);
    expect(sessionCount(), 1);
  });

  test('ST3 超过 15 分钟空闲开启新会话', () {
    touch();
    setLastAt(30);
    final result = touch();
    expect(result['credited_seconds'], 60);
    expect(sessionCount(), 2);
  });

  test('ST4 当天分钟数取真实活跃与模型自报的较大值', () {
    touch();
    setLastAt(5);
    touch();
    final minutes = inScope(() => Db.one(
          'SELECT minutes FROM progress_daily WHERE day=?',
          [DateTime.now().toIso8601String().substring(0, 10)],
        )?['minutes']);
    expect(minutes, 6);

    // 模型自报离线学习 40 分钟时应补足，而不是叠加成 46。
    inScope(() {
      Db.run(
        'INSERT INTO study_events(ts,kind,topic,result,duration_min,message_id,'
        'material_id,note,created_at) VALUES(?,?,?,?,?,?,?,?,?)',
        [
          Db.nowIso(),
          'read',
          '离线阅读',
          '',
          40,
          0,
          0,
          '',
          Db.nowIso(),
        ],
      );
      return null;
    });
    final refreshed = inScope(() {
      // 触发一次日汇总刷新（等同于新事件写入路径）。
      return ProgressModel.touchStudyActivity()['today_minutes'];
    });
    expect(refreshed, 40);
  });
}