import 'package:flutter_test/flutter_test.dart';
import 'package:loop/backend/agent_tools.dart';
import 'package:loop/backend/db.dart';

/// 反馈 #3：Agent 权限/审批策略。
/// manual（默认）→ files（工作区文件自动）→ all（全部自动）。
void main() {
  setUp(() {
    Db.initInMemoryForTests();
  });

  tearDown(() {
    Db.resetForTests();
  });

  test('AP1 默认逐次确认', () {
    expect(Db.setting('agent_approval', 'manual'), 'manual');
    expect(requiresApproval('fs_write'), isTrue);
    expect(requiresApproval('fs_delete'), isTrue);
    expect(requiresApproval('shell_run'), isTrue);
    expect(requiresApproval('create_note'), isFalse, reason: '数据库写入类工具本来就无需审批');
  });

  test('AP2 files 模式自动批准工作区文件，Shell 仍需确认', () {
    Db.setSetting('agent_approval', 'files');
    expect(requiresApproval('fs_write'), isFalse);
    expect(requiresApproval('fs_delete'), isFalse);
    expect(requiresApproval('shell_run'), isTrue);
    expect(requiresApproval('browser_open'), isTrue);
  });

  test('AP3 all 模式全部自动批准', () {
    Db.setSetting('agent_approval', 'all');
    expect(requiresApproval('fs_delete'), isFalse);
    expect(requiresApproval('shell_run'), isFalse);
    expect(requiresApproval('browser_click'), isFalse);
    expect(requiresApproval('mcp__demo__tool'), isFalse);
  });
}