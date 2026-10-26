import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:loop/backend/agent.dart';
import 'package:loop/backend/db.dart';
import 'package:loop/backend/subject_store.dart';

/// 反馈 #1：上下文压缩——旧消息滚动折叠成摘要，最近 10 条保留原文。
void main() {
  late Directory root;
  late SubjectRecord subject;

  setUp(() {
    root = Directory.systemTemp.createTempSync('loop-context-');
    SubjectStore.initTempForTests(root);
    subject = SubjectStore.create(name: '上下文测试');
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

  int seedConversation(int messages) => inScope(() {
        final now = Db.nowIso();
        final id = Db.insert('conversations', {
          'title': '压缩测试',
          'mode': 'answer',
          'created_at': now,
          'updated_at': now,
        });
        for (var i = 1; i <= messages; i++) {
          Db.insert('messages', {
            'conversation_id': id,
            'role': i.isOdd ? 'user' : 'assistant',
            'content': '第 $i 条消息：这是一段用于压缩测试的对话内容。',
            'created_at': Db.nowIso(),
          });
        }
        return id;
      });

  test('CC1 超过保留窗口后生成滚动摘要并推进 upto', () {
    final conversationId = seedConversation(30);
    final before = inScope(() => conversationSummary(conversationId));
    expect(before.$1, '');
    expect(before.$2, 0);

    inScope(() {
      updateRollingSummary(conversationId);
      return null;
    });

    final after = inScope(() => conversationSummary(conversationId));
    expect(after.$1.contains('用户：'), isTrue);
    expect(after.$1.contains('助手：'), isTrue);
    expect(after.$2, greaterThan(0));

    final row = inScope(() => Db.one(
          'SELECT upto_message_id FROM conversation_summaries WHERE conversation_id=?',
          [conversationId],
        ));
    final remaining = inScope(() => Db.rows(
          'SELECT id FROM messages WHERE conversation_id=? AND id>?',
          [conversationId, (row!['upto_message_id'] as num).toInt()],
        ));
    expect(remaining.length, 10, reason: '最近 10 条保留原文');
  });

  test('CC2 摘要长度有上限，重复压缩不重复累计同一段', () {
    final conversationId = seedConversation(40);
    inScope(() {
      updateRollingSummary(conversationId);
      return null;
    });
    final first = inScope(() => conversationSummary(conversationId));
    inScope(() {
      updateRollingSummary(conversationId);
      return null;
    });
    final second = inScope(() => conversationSummary(conversationId));
    expect(second.$1.length, lessThanOrEqualTo(4000));
    expect(second.$2, greaterThanOrEqualTo(first.$2));
  });
}