import 'dart:async';

import 'db.dart';

/// 一次 Agent 运行的运行时控制：取消 + 审批等待。
class AgentRun {
  AgentRun({required this.id, required this.conversationId, this.subjectKey = ''});

  final int id;

  /// 会话 id 只在 [subjectKey] 对应的学科库内有意义（§6.4）。
  final int conversationId;
  final String subjectKey;

  bool cancelRequested = false;
  Completer<bool>? _approval;
  Map<String, Object?>? pendingApproval;
  int toolCalls = 0;

  Future<bool> requestApproval(String tool, Map<String, dynamic> args, String risk) {
    if (cancelRequested) return Future<bool>.value(false);
    pendingApproval = {'tool': tool, 'args': args, 'risk': risk};
    _approval = Completer<bool>();
    return _approval!.future;
  }

  void resolveApproval(bool allow) {
    final completer = _approval;
    _approval = null;
    pendingApproval = null;
    if (completer != null && !completer.isCompleted) completer.complete(allow);
  }

  void cancel() {
    cancelRequested = true;
    final completer = _approval;
    _approval = null;
    pendingApproval = null;
    if (completer != null && !completer.isCompleted) completer.complete(false);
  }

  void checkCancelled() {
    if (cancelRequested) throw const AgentCancelled();
  }

  void finish(String status) {
    Db.run(
      'UPDATE agent_runs SET status=?, updated_at=? WHERE id=?',
      [status, Db.nowIso(), id],
    );
  }
}

class AgentCancelled implements Exception {
  const AgentCancelled();
}

class AgentRuns {
  static final Map<int, AgentRun> _runs = {};

  static AgentRun start(int conversationId, {String subjectKey = ''}) {
    final now = Db.nowIso();
    final id = Db.insert('agent_runs', {
      'conversation_id': conversationId,
      'status': 'running',
      'subject_key': subjectKey,
      'created_at': now,
      'updated_at': now,
    });
    final run = AgentRun(id: id, conversationId: conversationId, subjectKey: subjectKey);
    _runs[id] = run;
    return run;
  }

  static AgentRun? byId(int id) => _runs[id];

  static void remove(int id) => _runs.remove(id);
}
