import 'dart:async';

import 'agent.dart';
import 'agent_run.dart';
import 'db.dart';
import 'paths.dart';
import 'subject_store.dart';

/// 应用内后台任务调度器：每 30 秒检查一次到期任务，串行执行。
class JobScheduler {
  static Timer? _timer;
  static bool _running = false;

  static void start() {
    _timer ??= Timer.periodic(const Duration(seconds: 30), (_) => _tick());
  }

  /// 停止调度（测试/退出用），可重复调用。
  static void stop() {
    _timer?.cancel();
    _timer = null;
    _running = false;
  }

  static Future<int> runDueNow() async {
    if (_running) return 0;
    var count = 0;
    while (count < 3) {
      final due = Db.one(
        "SELECT * FROM agent_jobs WHERE enabled=1 AND (next_run='' OR next_run<=?) ORDER BY id LIMIT 1",
        [Db.nowIso()],
      );
      if (due == null) break;
      _running = true;
      try {
        await runJob(due);
        count++;
      } finally {
        _running = false;
      }
    }
    return count;
  }

  static Future<void> _tick() async {
    if (_running) return;
    if (Db.setting('agent_background', 'false') != 'true') return;
    final due = Db.one(
      "SELECT * FROM agent_jobs WHERE enabled=1 AND (next_run='' OR next_run<=?) ORDER BY id LIMIT 1",
      [Db.nowIso()],
    );
    if (due == null) return;
    _running = true;
    try {
      await runJob(due);
    } catch (error) {
      Db.run('UPDATE agent_jobs SET last_status=?, last_run=? WHERE id=?', [
        'error: $error',
        Db.nowIso(),
        due['id'],
      ]);
    } finally {
      _running = false;
    }
  }

  static Future<void> runJob(Map<String, Object?> job) async {
    // 后台任务产生的会话/消息属于**当前学科**（§2.4：学习产物归学科库）。
    // 数据目录尚未初始化（纯内存测试）时回退旧行为，避免测试触碰真实目录。
    if (!AppPaths.ready) return _runJob(job);
    final record = SubjectStore.activeSubject();
    final handle = SubjectStore.open(record.key);
    return Db.runScoped(
      handle.database,
      () => _runJob(job),
      subjectKey: record.key,
      filesDir: record.filesPath,
    );
  }

  static Future<void> _runJob(Map<String, Object?> job) async {
    final id = (job['id'] as num).toInt();
    final title = (job['title'] ?? '后台任务').toString();
    final prompt = (job['prompt'] ?? '').toString().trim();
    if (prompt.isEmpty) throw StateError('任务内容为空');
    final now = Db.nowIso();
    final conversationId = Db.insert('conversations', {
      'title': '[后台] $title',
      'mode': (job['mode'] ?? 'answer').toString(),
      'created_at': now,
      'updated_at': now,
    });
    final userMessageId = Db.insert('messages', {
      'conversation_id': conversationId,
      'role': 'user',
      'content': prompt,
      'steps': '[]',
      'refs': '[]',
      'created_at': now,
    });
    final run = AgentRuns.start(conversationId);
    var status = 'done';
    try {
      await for (final event in runAgent(
        conversationId: conversationId,
        userMessageId: userMessageId,
        userText: prompt,
        attachments: const [],
        run: run,
        mode: (job['mode'] ?? 'answer').toString(),
        modePrompt: (job['mode_prompt'] ?? '').toString(),
        thinking: 'medium',
        background: true,
      )) {
        if (event.event == 'cancelled') status = 'cancelled';
        if (event.event == 'error') status = 'error';
      }
    } catch (error) {
      status = 'error: $error';
    } finally {
      run.finish(status.startsWith('error') ? 'error' : status);
      AgentRuns.remove(run.id);
    }
    final next = _nextRun(job['schedule_kind']?.toString() ?? 'interval', job['schedule_value']?.toString() ?? '60');
    Db.run(
      'UPDATE agent_jobs SET last_run=?, next_run=?, last_status=? WHERE id=?',
      [Db.nowIso(), next, status, id],
    );
    Db.run('UPDATE conversations SET updated_at=? WHERE id=?', [Db.nowIso(), conversationId]);
  }

  static String _nextRun(String kind, String value) {
    final now = DateTime.now();
    if (kind == 'daily') {
      final parts = value.split(':');
      final hour = int.tryParse(parts.isNotEmpty ? parts[0] : '') ?? 8;
      final minute = int.tryParse(parts.length > 1 ? parts[1] : '') ?? 0;
      var next = DateTime(now.year, now.month, now.day, hour, minute);
      if (!next.isAfter(now)) next = next.add(const Duration(days: 1));
      return _iso(next);
    }
    final minutes = int.tryParse(value) ?? 60;
    return _iso(now.add(Duration(minutes: minutes.clamp(5, 24 * 60))));
  }

  static String computeNext(String kind, String value) => _nextRun(kind, value);

  static String _iso(DateTime dt) {
    final offset = dt.timeZoneOffset;
    final sign = offset.isNegative ? '-' : '+';
    final abs = offset.abs();
    return '${dt.year.toString().padLeft(4, '0')}-${dt.month.toString().padLeft(2, '0')}-'
        '${dt.day.toString().padLeft(2, '0')}T${dt.hour.toString().padLeft(2, '0')}:'
        '${dt.minute.toString().padLeft(2, '0')}:${dt.second.toString().padLeft(2, '0')}'
        '$sign${abs.inHours.toString().padLeft(2, '0')}:${(abs.inMinutes % 60).toString().padLeft(2, '0')}';
  }
}
