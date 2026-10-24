import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:loop/desktop/answer_host/answer_protocol.dart';

/// t2 回答窗 IPC 协议/编解码/seq/节流测试（规格 §2.6）。
void main() {
  group('AnswerLaunchPayload', () {
    test('U-AP-01 JSON 往返 + 默认值', () {
      const payload = AnswerLaunchPayload(
        themeMode: 'dark',
        dark: true,
        fontFamily: 'NotoSC',
      );
      final parsed = AnswerLaunchPayload.tryParse(payload.toJsonString());
      expect(parsed, isNotNull);
      expect(parsed!.protocol, answerProtocolVersion);
      expect(parsed.themeMode, 'dark');
      expect(parsed.dark, isTrue);
      expect(parsed.fontFamily, 'NotoSC');
      expect(parsed.isCompatible, isTrue);
    });

    test('U-AP-02 空/非法/非 JSON 返回 null（主窗口入口不误判）', () {
      expect(AnswerLaunchPayload.tryParse(null), isNull);
      expect(AnswerLaunchPayload.tryParse(''), isNull);
      expect(AnswerLaunchPayload.tryParse('   '), isNull);
      expect(AnswerLaunchPayload.tryParse('not-json'), isNull);
      expect(AnswerLaunchPayload.tryParse('[1,2]'), isNull);
    });

    test('U-AP-03 协议版本不匹配可判定', () {
      final parsed = AnswerLaunchPayload.tryParse('{"protocol":2}');
      expect(parsed, isNotNull);
      expect(parsed!.isCompatible, isFalse);
    });
  });

  group('AnswerStatus', () {
    test('U-AP-04 wire 值与解析', () {
      expect(AnswerStatus.thinking.wire, 'thinking');
      expect(AnswerStatus.waitingApproval.wire, 'waiting_approval');
      expect(AnswerStatus.tryParse('waiting_approval'), AnswerStatus.waitingApproval);
      expect(AnswerStatus.tryParse('unknown'), isNull);
      expect(AnswerStatus.tryParse(null), isNull);
      expect(AnswerStatus.done.isTerminal, isTrue);
      expect(AnswerStatus.error.isTerminal, isTrue);
      expect(AnswerStatus.streaming.isBusy, isTrue);
      expect(AnswerStatus.stopped.isTerminal, isTrue);
    });
  });

  test('U-AP-05 快照编码/解码往返（含 plan/refs/error）', () {
    const snapshot = AnswerSnapshot(
      conversationId: 'conv-1',
      runId: 'run-1',
      question: '什么是回路？',
      answerMarkdown: '**回路**',
      status: AnswerStatus.streaming,
      plan: <Map<String, Object?>>[
        <String, Object?>{'step': '检索'},
      ],
      refs: <Map<String, Object?>>[
        <String, Object?>{'title': '文档'},
      ],
      error: 'oops',
      elapsedMs: 1234,
      seq: 7,
    );
    final decoded = AnswerSnapshot.fromMap(snapshot.toMap());
    expect(decoded.conversationId, 'conv-1');
    expect(decoded.runId, 'run-1');
    expect(decoded.question, '什么是回路？');
    expect(decoded.answerMarkdown, '**回路**');
    expect(decoded.status, AnswerStatus.streaming);
    expect(decoded.plan.single['step'], '检索');
    expect(decoded.refs.single['title'], '文档');
    expect(decoded.error, 'oops');
    expect(decoded.elapsedMs, 1234);
    expect(decoded.seq, 7);
    // 容错：缺失字段回落默认值。
    final empty = AnswerSnapshot.fromMap(const <String, Object?>{});
    expect(empty.question, '');
    expect(empty.status, AnswerStatus.thinking);
    expect(empty.plan, isEmpty);
  });

  test('U-AP-06 通道名带 windowId v1 后缀', () {
    expect(answerStreamChannel('abc'), 'loop/answer.stream.v1.abc');
    expect(answerControlChannel('abc'), 'loop/answer.control.v1.abc');
    expect(answerStreamChannel('abc'), isNot(answerStreamChannel('def')));
  });

  test('U-AP-07 Rect 编解码（Map/List/非法）', () {
    const rect = Rect.fromLTWH(12, 34, 560, 180);
    final decoded = decodeRect(encodeRect(rect));
    expect(decoded, rect);
    expect(decodeRect(<Object?>[1, 2, 3, 4]), const Rect.fromLTWH(1, 2, 3, 4));
    expect(decodeRect(null), isNull);
    expect(decodeRect('bad'), isNull);
    expect(decodeRect(<String, Object?>{'left': 1}), isNull);
    expect(decodeRect(<String, Object?>{'left': double.nan, 'top': 0, 'width': 1, 'height': 1}), isNull);
  });

  group('AnswerSeqTracker', () {
    test('U-AP-08 snapshot 重置、delta 连续、跳号要求重同步', () {
      final tracker = AnswerSeqTracker();
      // 未收到 snapshot 前的 delta 不能应用。
      expect(tracker.onDelta(1), isFalse);
      expect(tracker.needsResync, isTrue);

      tracker.onSnapshot(10);
      expect(tracker.needsResync, isFalse);
      expect(tracker.lastSeq, 10);
      expect(tracker.onDelta(11), isTrue);
      expect(tracker.lastSeq, 11);
      expect(tracker.onDelta(12), isTrue);
      // 跳号。
      expect(tracker.onDelta(14), isFalse);
      expect(tracker.needsResync, isTrue);

      // 重同步快照后恢复。
      tracker.onSnapshot(20);
      expect(tracker.needsResync, isFalse);
      expect(tracker.onDelta(21), isTrue);
    });

    test('U-AP-09 status 跳号记录重同步但不阻塞后续 delta', () {
      final tracker = AnswerSeqTracker()..onSnapshot(1);
      expect(tracker.onStatus(3), isFalse);
      expect(tracker.needsResync, isTrue);
      expect(tracker.lastSeq, 3);
      expect(tracker.onDelta(4), isTrue);
    });

    test('U-AP-10 next() 单调递增', () {
      final tracker = AnswerSeqTracker();
      expect(tracker.next(), 1);
      expect(tracker.next(), 2);
    });
  });

  group('节流/合批', () {
    test('U-AP-11 delta 合批：首条立即、窗口内合并、flushNow', () async {
      final flushed = <String>[];
      final batcher = AnswerDeltaBatcher(
        onFlush: flushed.add,
        throttle: const Duration(milliseconds: 10),
      );
      batcher.add('a');
      expect(flushed, <String>['a']); // 首条立即
      batcher.add('b');
      batcher.add('c');
      expect(flushed, <String>['a']);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(flushed, <String>['a', 'bc']);

      batcher.add('d');
      batcher.add('e');
      batcher.flushNow();
      expect(flushed, <String>['a', 'bc', 'de']);
      expect(batcher.hasPending, isFalse);
      batcher.dispose();
    });

    test('U-AP-12 高度节流：多次 schedule 合并一次回调', () async {
      var count = 0;
      final throttle = AnswerThrottle(
        onDue: () => count++,
        interval: const Duration(milliseconds: 10),
      );
      throttle.schedule();
      throttle.schedule();
      throttle.schedule();
      expect(count, 0);
      await Future<void>.delayed(const Duration(milliseconds: 25));
      expect(count, 1);
      throttle.schedule();
      await Future<void>.delayed(const Duration(milliseconds: 25));
      expect(count, 2);
      throttle.dispose();
    });
  });

  test('U-AP-13 错误消息截断 ≤200 字符并压缩空白', () {
    final long = 'x' * 500;
    final truncated = truncateAnswerError('  a\n\n b  ');
    expect(truncated, 'a b');
    expect(truncateAnswerError(long).length, 200);
    expect(truncateAnswerError(long).endsWith('…'), isTrue);
  });

  test('U-AP-14 asStringMap 容错', () {
    expect(asStringMap(<Object?, Object?>{'a': 1})['a'], 1);
    expect(asStringMap('bad'), isEmpty);
    expect(asStringMap(null), isEmpty);
  });
}
