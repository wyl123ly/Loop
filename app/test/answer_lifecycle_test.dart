import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:loop/desktop/answer_host/answer_protocol.dart';
import 'package:loop/desktop/answer_host/answer_window_host.dart';
import 'package:loop/desktop/window_mode.dart';

import 'support/fake_answer_platform.dart';

/// t2 回答窗生命周期/IPC 集成测试（fake platform + fake transport）。
///
/// 覆盖规格 §2.7 生命周期、§2.9 退出清理、§4.3 高度自适应、§4.5 位置、
/// §4.7 替换、§6 失败矩阵。
void main() {
  const submission = AnswerSubmission(
    question: '你好，回路',
    conversationId: 'conv-1',
    runId: 'run-1',
    inputBarPhysical: Rect.fromLTWH(200, 900, 1400, 80),
    mainWindowPhysical: Rect.fromLTWH(100, 100, 1200, 800),
    themeMode: 'dark',
    dark: true,
  );

  AnswerWindowHost makeHost(
    FakeAnswerWindowPlatform platform, {
    List<String>? errors,
    List<bool>? presence,
    Duration createTimeout = const Duration(milliseconds: 500),
    Duration streamThrottle = const Duration(milliseconds: 5),
    Duration heightThrottle = const Duration(milliseconds: 5),
    Duration closeTimeout = const Duration(milliseconds: 200),
  }) {
    return AnswerWindowHost(
      platform: platform,
      createTimeout: createTimeout,
      streamThrottle: streamThrottle,
      heightThrottle: heightThrottle,
      closeTimeout: closeTimeout,
      onError: errors?.add,
      onPresenceChanged: presence?.add,
    );
  }

  /// 启动创建流程并在 ready 后返回结果。
  Future<bool> createAndReady(
    AnswerWindowHost host,
    FakeAnswerWindowPlatform platform, {
    double contentHeight = 0,
    int protocol = answerProtocolVersion,
    bool awaitReady = true,
  }) async {
    final future = host.showOrReplace(submission);
    await pumpEventQueue();
    if (awaitReady) {
      await platform.ready(
        contentHeightLogical: contentHeight,
        protocol: protocol,
      );
    }
    return future;
  }

  void expectRect(Rect actual, Rect expected, {double tolerance = 0.6}) {
    expect(actual.left, closeTo(expected.left, tolerance), reason: 'left');
    expect(actual.top, closeTo(expected.top, tolerance), reason: 'top');
    expect(actual.width, closeTo(expected.width, tolerance), reason: 'width');
    expect(actual.height, closeTo(expected.height, tolerance), reason: 'height');
  }

  bool overlaps(Rect a, Rect b) {
    final intersection = a.intersect(b);
    return intersection.width > 0 && intersection.height > 0;
  }

  test('U-AL-01 空文本/纯空白不建窗', () async {
    final platform = FakeAnswerWindowPlatform();
    final errors = <String>[];
    final host = makeHost(platform, errors: errors);
    expect(await host.showOrReplace(const AnswerSubmission(question: '   ')),
        isFalse);
    expect(platform.createCount, 0);
    expect(host.state, AnswerWindowState.absent);
    expect(errors, isEmpty);
    host.dispose();
    await platform.dispose();
  });

  test('U-AL-02 首次非空提交：创建/ready/hello/snapshot/显示/焦点补偿', () async {
    final platform = FakeAnswerWindowPlatform();
    final errors = <String>[];
    final presence = <bool>[];
    var focusHook = 0;
    final host = makeHost(
      platform,
      errors: errors,
      presence: presence,
    );
    host.onFocusCompensation = () => focusHook++;

    expect(await createAndReady(host, platform, contentHeight: 100), isTrue);

    expect(platform.createCount, 1);
    expect(
      platform.calls,
      containsAllInOrder(<String>[
        'create',
        'openTransport',
        'configure',
        'focusMainWindow',
        'showNoActivate',
      ]),
    );
    expect(platform.focusMainCount, 1);
    expect(platform.visible, isTrue);
    expect(platform.topmost, isTrue);
    expect(platform.launchPayloads.single.themeMode, 'dark');
    expect(platform.launchPayloads.single.dark, isTrue);
    expect(focusHook, 1);
    expect(presence, <bool>[true]);
    expect(errors, isEmpty);

    expect(host.state, AnswerWindowState.visible);
    expect(host.hasWindow, isTrue);
    expect(host.visible, isTrue);
    expect(host.windowId, 'answer-1');

    final hello = platform.transport.lastOf('hello');
    expect(hello, isNotNull);
    expect(hello!.arguments['protocol'], answerProtocolVersion);
    expect(hello.arguments['windowId'], 'answer-1');
    expect(hello.arguments['hwnd'], 1001);
    expect(hello.arguments['widthLogical'], closeTo(672, 0.01));
    expect(hello.arguments['minH'], answerMinHeight);
    expect(hello.arguments['maxH'], closeTo(728, 0.01));
    expect(hello.arguments['fontFamily'], 'NotoSC');

    final snapshot = platform.transport.lastOf('snapshot');
    expect(snapshot, isNotNull);
    expect(snapshot!.arguments['seq'], 1);
    expect(snapshot.arguments['question'], '你好，回路');
    expect(snapshot.arguments['status'], 'thinking');
    expect(snapshot.arguments['conversationId'], 'conv-1');
    expect(snapshot.arguments['runId'], 'run-1');

    // 高度 = chrome(92) + 正文(100) = 192；输入条上方、右对齐。
    expectRect(
      platform.appliedBounds.last,
      const Rect.fromLTWH(928, 700, 672, 192),
    );
    expect(
      overlaps(platform.appliedBounds.last, submission.inputBarPhysical!),
      isFalse,
    );

    host.dispose();
    await platform.dispose();
  });

  test('U-AL-03 ready 超时：清理窗口、显式错误、状态 absent', () async {
    final platform = FakeAnswerWindowPlatform();
    final errors = <String>[];
    final presence = <bool>[];
    final host = makeHost(
      platform,
      errors: errors,
      presence: presence,
      createTimeout: const Duration(milliseconds: 60),
    );
    final future = host.showOrReplace(submission);
    await pumpEventQueue();
    expect(await future, isFalse);
    expect(host.state, AnswerWindowState.absent);
    expect(host.hasWindow, isFalse);
    expect(platform.closeCount, greaterThanOrEqualTo(1));
    expect(errors.single, contains('超时'));
    // T5-07：创建开始即 presence=true（preventClose），超时失败后释放。
    expect(presence, <bool>[true, false]);
    host.dispose();
    await platform.dispose();
  });

  test('U-AL-04 创建失败：显式错误、无残留窗口、可重试', () async {
    final platform = FakeAnswerWindowPlatform()..failCreate = true;
    final errors = <String>[];
    final host = makeHost(platform, errors: errors);
    expect(await host.showOrReplace(submission), isFalse);
    expect(host.state, AnswerWindowState.absent);
    expect(errors, hasLength(1));
    expect(platform.visible, isFalse);

    platform.failCreate = false;
    expect(await createAndReady(host, platform), isTrue);
    expect(host.state, AnswerWindowState.visible);
    host.dispose();
    await platform.dispose();
  });

  test('U-AL-05 协议不匹配拒绝并清理', () async {
    final platform = FakeAnswerWindowPlatform();
    final errors = <String>[];
    final host = makeHost(platform, errors: errors);
    expect(
      await createAndReady(host, platform, protocol: 2),
      isFalse,
    );
    expect(host.state, AnswerWindowState.absent);
    expect(platform.closeCount, greaterThanOrEqualTo(1));
    expect(errors.single, contains('协议'));
    host.dispose();
    await platform.dispose();
  });

  test('U-AL-06 delta 合批（首条立即/后续 80ms 窗口）与 seq 连续', () async {
    final platform = FakeAnswerWindowPlatform();
    final host = makeHost(platform);
    expect(await createAndReady(host, platform), isTrue);
    platform.transport.clear();

    host.pushTextDelta('a');
    host.pushTextDelta('b');
    host.pushTextDelta('c');
    await pumpEventQueue();
    // 首条立即。
    expect(platform.transport.messagesOf('delta').single.arguments['text'], 'a');
    await Future<void>.delayed(const Duration(milliseconds: 25));
    expect(platform.transport.messagesOf('delta'), hasLength(2));
    expect(
      platform.transport.messagesOf('delta').last.arguments['text'],
      'bc',
    );

    final deltas = platform.transport.messagesOf('delta');
    expect(deltas[0].arguments['seq'], 2);
    expect(deltas[1].arguments['seq'], 3);
    expect(host.snapshot?.answerMarkdown, 'abc');
    host.dispose();
    await platform.dispose();
  });

  test('U-AL-07 状态/计划/结束/错误消息', () async {
    final platform = FakeAnswerWindowPlatform();
    final host = makeHost(platform);
    expect(await createAndReady(host, platform), isTrue);
    platform.transport.clear();

    host.setStatus(
      AnswerStatus.streaming,
      label: '生成中',
      runId: 'run-2',
    );
    await pumpEventQueue();
    var status = platform.transport.lastOf('status');
    expect(status!.arguments['state'], 'streaming');
    expect(status.arguments['label'], '生成中');
    expect(status.arguments['approvalRequired'], isFalse);
    expect(status.arguments['runId'], 'run-2');

    host.setStatus(AnswerStatus.waitingApproval, approvalRequired: true);
    await pumpEventQueue();
    status = platform.transport.lastOf('status');
    expect(status!.arguments['approvalRequired'], isTrue);
    expect(status.arguments['state'], 'waiting_approval');

    host.setPlan(<Map<String, Object?>>[
      <String, Object?>{'step': '检索'},
    ]);
    await pumpEventQueue();
    final planSnapshot = platform.transport.lastOf('snapshot');
    expect(planSnapshot!['plan'], isNotEmpty);

    host.finish(AnswerStatus.done);
    await pumpEventQueue();
    expect(platform.transport.lastOf('status')!.arguments['state'], 'done');
    expect(host.state, AnswerWindowState.visible); // 结束不关窗

    host.setError('模型不可用');
    await pumpEventQueue();
    expect(platform.transport.lastOf('status')!.arguments['state'], 'error');
    final errorSnapshot = platform.transport.lastOf('snapshot');
    expect(errorSnapshot!['error'], '模型不可用');
    host.dispose();
    await platform.dispose();
  });

  test('U-AL-08 测高：节流/±2px 去抖/钳制 maxH/resize_ack', () async {
    final platform = FakeAnswerWindowPlatform();
    final host = makeHost(platform);
    expect(await createAndReady(host, platform, contentHeight: 100), isTrue);
    expect(platform.appliedBounds.last.height, closeTo(192, 0.6));

    platform.transport.clear();
    await platform.contentHeight(300);
    await Future<void>.delayed(const Duration(milliseconds: 25));
    expect(platform.appliedBounds.last.height, closeTo(392, 0.6));
    expect(platform.transport.lastOf('resize_ack')!['heightLogical'], 392);
    expect(
      overlaps(platform.appliedBounds.last, submission.inputBarPhysical!),
      isFalse,
    );

    // 1px 抖动忽略。
    final before = platform.appliedBounds.length;
    await platform.contentHeight(301);
    await Future<void>.delayed(const Duration(milliseconds: 25));
    expect(platform.appliedBounds.length, before);

    // 超长正文钳制 maxH=728。
    await platform.contentHeight(5000);
    await Future<void>.delayed(const Duration(milliseconds: 25));
    expect(platform.appliedBounds.last.height, closeTo(728, 0.6));
    expect(platform.appliedBounds.last.top, closeTo(892 - 728, 0.6));
    host.dispose();
    await platform.dispose();
  });

  test('U-AL-09 收起 36px / 展开恢复原高度', () async {
    final platform = FakeAnswerWindowPlatform();
    final host = makeHost(platform);
    expect(await createAndReady(host, platform, contentHeight: 300), isTrue);
    expect(platform.appliedBounds.last.height, closeTo(392, 0.6));

    await host.collapse();
    expect(host.collapsed, isTrue);
    expect(host.state, AnswerWindowState.collapsed);
    expect(platform.appliedBounds.last.height, closeTo(36, 0.6));
    expect(platform.transport.lastOf('presentation')!['collapsed'], isTrue);

    await host.expand();
    expect(host.collapsed, isFalse);
    expect(host.state, AnswerWindowState.visible);
    expect(platform.appliedBounds.last.height, closeTo(392, 0.6));
    expect(platform.transport.lastOf('presentation')!['collapsed'], isFalse);
    host.dispose();
    await platform.dispose();
  });

  test('U-AL-10 拖动：尊重位置、覆盖输入条时轻推、越界钳制', () async {
    final platform = FakeAnswerWindowPlatform();
    final host = makeHost(platform);
    expect(await createAndReady(host, platform, contentHeight: 300), isTrue);

    await platform.moved(const Rect.fromLTWH(1000, 200, 672, 392));
    await pumpEventQueue();
    expectRect(platform.appliedBounds.last, const Rect.fromLTWH(1000, 200, 672, 392));

    await platform.moved(const Rect.fromLTWH(300, 850, 672, 392));
    await pumpEventQueue();
    expect(host.state, AnswerWindowState.visible);
    expect(
      overlaps(platform.appliedBounds.last, submission.inputBarPhysical!),
      isFalse,
    );
    expect(platform.appliedBounds.last.top, lessThanOrEqualTo(500.6));

    await platform.moved(const Rect.fromLTWH(1800, 1000, 672, 392));
    await pumpEventQueue();
    final work = platform.displaysValue.first.physicalWorkArea;
    expect(platform.appliedBounds.last.right, lessThanOrEqualTo(work.right + 0.5));
    expect(
      platform.appliedBounds.last.bottom,
      lessThanOrEqualTo(work.bottom + 0.5),
    );
    host.dispose();
    await platform.dispose();
  });

  test('U-AL-11 主窗最小化/托盘/截图隐藏与无激活恢复', () async {
    final platform = FakeAnswerWindowPlatform();
    final host = makeHost(platform);
    expect(await createAndReady(host, platform, contentHeight: 300), isTrue);
    final shownBefore = platform.showCount;

    await host.hide();
    expect(host.hiddenByOwner, isTrue);
    expect(host.visible, isFalse);
    expect(platform.visible, isFalse);
    expect(platform.hideCount, 1);

    // 隐藏期间测高不改窗口。
    await platform.contentHeight(500);
    await Future<void>.delayed(const Duration(milliseconds: 25));
    expect(platform.appliedBounds.length, lessThanOrEqualTo(3));

    await host.restoreVisibility();
    expect(host.hiddenByOwner, isFalse);
    expect(host.visible, isTrue);
    expect(platform.visible, isTrue);
    expect(platform.showCount, shownBefore + 1);
    host.dispose();
    await platform.dispose();
  });

  test('U-AL-12 关闭后重建：close_requested → absent → 新提交新窗口', () async {
    final platform = FakeAnswerWindowPlatform();
    final presence = <bool>[];
    final host = makeHost(platform, presence: presence);
    expect(await createAndReady(host, platform), isTrue);
    expect(presence, <bool>[true]);

    await platform.control('close_requested');
    await pumpEventQueue();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(host.state, AnswerWindowState.absent);
    expect(host.hasWindow, isFalse);
    expect(platform.closeCount, 1);
    expect(presence, <bool>[true, false]);
    expect(platform.transport.disposed, isTrue);

    final future = host.showOrReplace(submission);
    await pumpEventQueue();
    await platform.ready();
    expect(await future, isTrue);
    expect(platform.createCount, 2);
    expect(host.windowId, 'answer-2');
    expect(presence, <bool>[true, false, true]);
    host.dispose();
    await platform.dispose();
  });

  test('U-AL-13 第二窗被外部关闭：检测 absent、主聊天不受影响、可重建', () async {
    final platform = FakeAnswerWindowPlatform();
    final presence = <bool>[];
    final host = makeHost(platform, presence: presence);
    expect(await createAndReady(host, platform), isTrue);

    platform.alive = false;
    await platform.emitWindowsChanged();
    await pumpEventQueue();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(host.state, AnswerWindowState.absent);
    expect(host.hasWindow, isFalse);
    expect(presence, <bool>[true, false]);

    final future = host.showOrReplace(submission);
    await pumpEventQueue();
    await platform.ready();
    expect(await future, isTrue);
    host.dispose();
    await platform.dispose();
  });

  test('U-AL-14 shutdown：先关窗、幂等、无残留', () async {
    final platform = FakeAnswerWindowPlatform();
    final presence = <bool>[];
    final host = makeHost(platform, presence: presence);
    expect(await createAndReady(host, platform), isTrue);
    final closeBefore = platform.closeCount;

    await host.shutdown();
    expect(host.state, AnswerWindowState.absent);
    expect(host.hasWindow, isFalse);
    expect(platform.closeCount, closeBefore + 1);
    expect(platform.transport.disposed, isTrue);
    expect(presence.last, isFalse);

    await host.shutdown();
    expect(platform.closeCount, closeBefore + 1, reason: '幂等，不重复关窗');
    host.dispose();
    await platform.dispose();
  });

  test('U-AL-15 替换语义：同一窗口 snapshot 替换；收起时先展开', () async {
    final platform = FakeAnswerWindowPlatform();
    final host = makeHost(platform);
    expect(await createAndReady(host, platform, contentHeight: 300), isTrue);
    host.pushTextDelta('上一轮回答');
    await Future<void>.delayed(const Duration(milliseconds: 20));

    await host.collapse();
    expect(host.collapsed, isTrue);
    platform.transport.clear();

    final replaced = await host.showOrReplace(
      const AnswerSubmission(
        question: '新问题',
        conversationId: 'conv-2',
        inputBarPhysical: Rect.fromLTWH(200, 900, 1400, 80),
        mainWindowPhysical: Rect.fromLTWH(100, 100, 1200, 800),
      ),
    );
    expect(replaced, isTrue);
    expect(platform.createCount, 1, reason: '复用同一窗口，不新建');
    expect(host.collapsed, isFalse);
    expect(
      platform.transport.streamMessages.map((message) => message.method),
      containsAllInOrder(<String>['presentation', 'snapshot']),
    );
    final snapshot = platform.transport.lastOf('snapshot');
    expect(snapshot!['question'], '新问题');
    expect(snapshot['conversationId'], 'conv-2');
    expect(snapshot['answerMarkdown'], '');
    expect(platform.appliedBounds.last.height, lessThan(answerMinHeight + 1));
    host.dispose();
    await platform.dispose();
  });

  test('U-AL-16 creating 中再次提交被拒绝；发送失败不崩', () async {
    final platform = FakeAnswerWindowPlatform();
    final host = makeHost(platform);
    final first = host.showOrReplace(submission);
    await pumpEventQueue();
    expect(await host.showOrReplace(submission), isFalse); // creating 串行
    await platform.ready();
    expect(await first, isTrue);

    platform.transport.sendError = StateError('ipc down');
    host.pushTextDelta('x');
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(host.state, AnswerWindowState.visible);
    expect(platform.transport.connected, isFalse);

    platform.transport.sendError = null;
    platform.transport.setConnected(true);
    host.pushTextDelta('y');
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(host.state, AnswerWindowState.visible);
    host.dispose();
    await platform.dispose();
  });

  test('U-AL-17 锚点更新：输入条移动后 auto 跟随且不遮挡', () async {
    final platform = FakeAnswerWindowPlatform();
    final host = makeHost(platform);
    expect(await createAndReady(host, platform, contentHeight: 300), isTrue);

    await host.updateAnchors(
      inputBarPhysical: const Rect.fromLTWH(200, 20, 1400, 80),
      mainWindowPhysical: const Rect.fromLTWH(100, 0, 1200, 120),
    );
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(
      platform.appliedBounds.last.top,
      closeTo(108, 0.6),
      reason: '输入条上方空间不足 → 放到下方',
    );
    expect(
      overlaps(
        platform.appliedBounds.last,
        const Rect.fromLTWH(200, 20, 1400, 80),
      ),
      isFalse,
    );
    host.dispose();
    await platform.dispose();
  });

  test('U-AL-18 主题/置顶抬升/无焦点变化', () async {
    final platform = FakeAnswerWindowPlatform();
    final host = makeHost(platform);
    expect(await createAndReady(host, platform), isTrue);
    final focusBefore = platform.focusMainCount;

    await host.setTheme(themeMode: 'light', dark: false);
    expect(platform.transport.lastOf('theme')!['themeMode'], 'light');

    await host.bringToFront();
    expect(platform.bringToTopCount, 1);
    expect(platform.focusMainCount, focusBefore, reason: '抬升不抢焦点');

    host.dispose();
    await platform.dispose();
  });

  // -------------------------------------------------------------------------
  // t4 findings 回归：F-02 主题同步 / F-03 目标显示器 DPI / F-05 anchor
  // -------------------------------------------------------------------------

  test('U-AL-19/F-02 运行时主题同步：去重、未打开记录、重建首帧生效', () async {
    final platform = FakeAnswerWindowPlatform();
    final host = makeHost(platform);
    expect(await createAndReady(host, platform), isTrue);
    platform.transport.clear();

    await host.setTheme(themeMode: 'light', dark: false);
    expect(platform.transport.messagesOf('theme').length, 1);
    expect(
      platform.transport.lastOf('theme')!.arguments['themeMode'],
      'light',
    );
    expect(platform.transport.lastOf('theme')!.arguments['dark'], isFalse);

    // 相同主题不重复发送（build 高频调用）。
    await host.setTheme(themeMode: 'light', dark: false);
    expect(platform.transport.messagesOf('theme').length, 1);

    await host.setTheme(themeMode: 'dark', dark: true);
    expect(platform.transport.messagesOf('theme').length, 2);
    expect(platform.transport.lastOf('theme')!.arguments['dark'], isTrue);

    // 关闭后仅记录，不产生 IPC；重建时 launch payload/hello 带新主题。
    await host.closeWindow();
    await pumpEventQueue();
    await host.setTheme(themeMode: 'light', dark: false);
    final themeCountBeforeRecreate =
        platform.transport.messagesOf('theme').length;
    expect(themeCountBeforeRecreate, 2);

    final future = host.showOrReplace(
      const AnswerSubmission(
        question: '主题重建',
        inputBarPhysical: Rect.fromLTWH(200, 900, 1400, 80),
        mainWindowPhysical: Rect.fromLTWH(100, 100, 1200, 800),
        themeMode: 'light',
        dark: false,
      ),
    );
    await pumpEventQueue();
    await platform.ready();
    expect(await future, isTrue);
    expect(platform.launchPayloads.last.themeMode, 'light');
    expect(platform.launchPayloads.last.dark, isFalse);
    expect(
      platform.transport.messagesOf('theme').length,
      themeCountBeforeRecreate,
      reason: '创建时 hello/snapshot 已带首帧主题，无需额外 theme',
    );
    host.dispose();
    await platform.dispose();
  });

  test('U-AL-20/F-03 目标显示器 scaleFactor 优先于第二窗首帧 dpr', () async {
    // 主屏 125%，副屏 150%（t4 run2 环境）；第二窗隐藏创建在主屏，首帧 dpr=1.25。
    const primary = DisplayInfo(
      id: r'\\.\DISPLAY1',
      physicalBounds: Rect.fromLTWH(0, 0, 2560, 1440),
      physicalWorkArea: Rect.fromLTWH(0, 0, 2560, 1440),
      scaleFactor: 1.25,
      isPrimary: true,
    );
    const secondary = DisplayInfo(
      id: r'\\.\DISPLAY2',
      physicalBounds: Rect.fromLTWH(-2560, -58, 2560, 1600),
      physicalWorkArea: Rect.fromLTWH(-2560, -58, 2560, 1600),
      scaleFactor: 1.5,
    );
    final platform = FakeAnswerWindowPlatform(
      displays: const <DisplayInfo>[primary, secondary],
      dprValue: 1.25,
    );
    final host = makeHost(platform);

    // 输入条位于副屏：工作区逻辑宽 1706.7、高 1066.7。
    final future = host.showOrReplace(
      const AnswerSubmission(
        question: '副屏 DPI',
        inputBarPhysical: Rect.fromLTWH(-2400, 1100, 2000, 120),
        mainWindowPhysical: Rect.fromLTWH(-2500, 100, 2400, 1200),
      ),
    );
    await pumpEventQueue();
    await platform.ready(contentHeightLogical: 0, dpr: 1.25);
    expect(await future, isTrue);

    // 宽度：0.35×1706.7×1.5 = 896 phys（与 dpr 来源无关）。
    expect(platform.appliedBounds.last.width, closeTo(896, 0.6));

    await platform.contentHeight(5000);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    final rect = platform.appliedBounds.last;
    // F-03：maxH=min(1066.7×0.7,760)=746.7 逻辑 → 1120 phys（不是 950）。
    expect(rect.height, closeTo(1120, 0.6));
    // gap=8 逻辑×1.5=12 phys（输入条 top=1100）。
    expect(rect.bottom, closeTo(1088, 0.6));
    host.dispose();
    await platform.dispose();
  });

  test('U-AL-21/F-05 程序化主窗移动：updateAnchors 幂等且跟随后重算高度', () async {
    final platform = FakeAnswerWindowPlatform();
    final host = makeHost(platform);
    expect(await createAndReady(host, platform, contentHeight: 300), isTrue);
    final before = platform.appliedBounds.length;

    // 同一锚点重复同步不产生额外 SetWindowPos（500ms 轮询不会抖动）。
    await host.updateAnchors(
      inputBarPhysical: const Rect.fromLTWH(200, 900, 1400, 80),
      mainWindowPhysical: const Rect.fromLTWH(100, 100, 1200, 800),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(platform.appliedBounds.length, before);

    // 程序化移动主窗/输入条 → 下一次同步重新定位（不遮挡输入条）。
    await host.updateAnchors(
      inputBarPhysical: const Rect.fromLTWH(600, 500, 1400, 80),
      mainWindowPhysical: const Rect.fromLTWH(500, 0, 1200, 600),
    );
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(platform.appliedBounds.length, greaterThan(before));
    expect(
      overlaps(
        platform.appliedBounds.last,
        const Rect.fromLTWH(600, 500, 1400, 80),
      ),
      isFalse,
    );
    host.dispose();
    await platform.dispose();
  });

  // -------------------------------------------------------------------------
  // t5 findings 回归：T5-04 seq / T5-06 跨屏 / T5-07 创建竞态 / T5-08 耗时 /
  // T5-10 显示器移除
  // -------------------------------------------------------------------------

  test('U-AL-22/T5-04 resize_ack 不占正文 seq，改高后 delta 仍连续且无全量风暴',
      () async {
    final platform = FakeAnswerWindowPlatform();
    final host = makeHost(platform);
    expect(await createAndReady(host, platform, contentHeight: 100), isTrue);
    final snapshot = platform.transport.lastOf('snapshot')!;
    final snapshotSeq = snapshot['seq'] as int;
    platform.transport.clear();

    await platform.contentHeight(300);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    final ack = platform.transport.lastOf('resize_ack');
    expect(ack, isNotNull);
    expect(ack!['seq'], snapshotSeq, reason: 'resize_ack 不得推进正文 seq');

    host.pushTextDelta('a');
    await pumpEventQueue();
    final delta = platform.transport.lastOf('delta');
    expect(delta, isNotNull);
    expect(delta!['seq'], snapshotSeq + 1);

    // 第二窗 client 的 seq 语义：snapshot 后忽略 resize_ack，delta 连续。
    final tracker = AnswerSeqTracker()..onSnapshot(snapshotSeq);
    expect(tracker.onDelta(delta['seq'] as int), isTrue);

    // 多次改高只发 resize_ack，不应反复全量 snapshot。
    for (var i = 0; i < 3; i++) {
      await platform.contentHeight(400 + i * 120);
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(platform.transport.messagesOf('snapshot'), isEmpty);
    host.dispose();
    await platform.dispose();
  });

  test('U-AL-23/T5-06 回答窗拖到副屏后，主窗移动不拉回主屏、不丢副屏 dpr', () async {
    const primary = DisplayInfo(
      id: r'\\.\DISPLAY1',
      physicalBounds: Rect.fromLTWH(0, 0, 2560, 1440),
      physicalWorkArea: Rect.fromLTWH(0, 0, 2560, 1440),
      scaleFactor: 1.25,
      isPrimary: true,
    );
    const secondary = DisplayInfo(
      id: r'\\.\DISPLAY2',
      physicalBounds: Rect.fromLTWH(-2560, -58, 2560, 1600),
      physicalWorkArea: Rect.fromLTWH(-2560, -58, 2560, 1600),
      scaleFactor: 1.5,
    );
    final platform = FakeAnswerWindowPlatform(
      displays: const <DisplayInfo>[primary, secondary],
      dprValue: 1.25,
    );
    final host = makeHost(platform);
    expect(await createAndReady(host, platform), isTrue);
    expect(platform.appliedBounds.last.width, closeTo(896, 0.6));

    // 用户把回答窗拖到 150% 副屏。
    await platform.moved(const Rect.fromLTWH(-2300, 200, 1050, 700));
    await pumpEventQueue();
    final onSecondary = platform.appliedBounds.last;
    expect(onSecondary.left, lessThan(-2000));
    expect(onSecondary.width, closeTo(716.8 * 1.5, 1));

    // 主窗仍在主屏移动：不得把回答窗 clamp 回主屏或改回 1.25 dpr。
    await host.onMainWindowMoved(const Rect.fromLTWH(120, 120, 1200, 800));
    await Future<void>.delayed(const Duration(milliseconds: 30));
    final afterMainMove = platform.appliedBounds.last;
    expect(afterMainMove.left, lessThan(-2000));

    await platform.contentHeight(5000);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(
      platform.appliedBounds.last.height,
      closeTo(1120, 1),
      reason: '副屏 1.5 dpr：maxH 746.7 逻辑 → 1120 物理',
    );
    host.dispose();
    await platform.dispose();
  });

  test('U-AL-24/T5-07 创建前 await presence(preventClose)，失败/关闭释放', () async {
    final platform = FakeAnswerWindowPlatform();
    final events = <String>[];
    final host = AnswerWindowHost(
      platform: platform,
      createTimeout: const Duration(milliseconds: 300),
      streamThrottle: const Duration(milliseconds: 5),
      heightThrottle: const Duration(milliseconds: 5),
      closeTimeout: const Duration(milliseconds: 100),
      onPresenceChanged: (present) async {
        events.add('presence:$present:start');
        await Future<void>.delayed(const Duration(milliseconds: 30));
        events.add('presence:$present:end');
      },
    );
    final future = host.showOrReplace(submission);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(platform.createCount, 0, reason: 'presence 回调完成前不得 create');
    for (var i = 0; i < 20 && platform.createCount == 0; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(platform.createCount, 1);
    await pumpEventQueue();
    await platform.ready();
    expect(await future, isTrue);
    expect(events.first, 'presence:true:start');

    await host.closeWindow();
    await pumpEventQueue();
    expect(events, contains('presence:false:end'));
    host.dispose();
    await platform.dispose();
  });

  test('U-AL-25/T5-07 创建中 shutdown：等待 create 收敛并清理，无孤儿', () async {
    final platform = FakeAnswerWindowPlatform()..createDelay = const Duration(milliseconds: 80);
    final presence = <bool>[];
    final host = makeHost(
      platform,
      presence: presence,
      createTimeout: const Duration(milliseconds: 400),
      closeTimeout: const Duration(milliseconds: 100),
    );
    final showFuture = host.showOrReplace(submission);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(host.state, AnswerWindowState.creating);

    final watch = Stopwatch()..start();
    await host.shutdown();
    watch.stop();
    expect(await showFuture, isFalse);
    expect(host.state, AnswerWindowState.absent);
    expect(platform.closeCount, greaterThanOrEqualTo(1));
    expect(presence.last, isFalse);
    expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
    host.dispose();
    await platform.dispose();
  });

  test('U-AL-26/T5-10 显示器移除后把回答窗 clamp 到有效工作区', () async {
    const primary = DisplayInfo(
      id: r'\\.\DISPLAY1',
      physicalBounds: Rect.fromLTWH(0, 0, 2560, 1440),
      physicalWorkArea: Rect.fromLTWH(0, 0, 2560, 1440),
      scaleFactor: 1.25,
      isPrimary: true,
    );
    const secondary = DisplayInfo(
      id: r'\\.\DISPLAY2',
      physicalBounds: Rect.fromLTWH(-2560, -58, 2560, 1600),
      physicalWorkArea: Rect.fromLTWH(-2560, -58, 2560, 1600),
      scaleFactor: 1.5,
    );
    final platform = FakeAnswerWindowPlatform(
      displays: const <DisplayInfo>[primary, secondary],
      dprValue: 1.25,
    );
    final host = makeHost(platform);
    expect(await createAndReady(host, platform), isTrue);
    await platform.moved(const Rect.fromLTWH(-2300, 200, 1050, 700));
    await pumpEventQueue();
    expect(platform.appliedBounds.last.left, lessThan(-2000));

    // 副屏被移除，只剩主屏。
    platform.displaysValue = const <DisplayInfo>[primary];
    await host.ensureOnScreen();
    final clamped = platform.appliedBounds.last;
    expect(FloatingWindowPlanner.isInsideWorkArea(clamped, primary.physicalWorkArea), isTrue);
    expect(clamped.width, closeTo(716.8 * 1.25, 1));
    host.dispose();
    await platform.dispose();
  });

  test('U-AL-27/T5-08 记录创建耗时（ready / 首次可见）', () async {
    final platform = FakeAnswerWindowPlatform();
    final host = makeHost(platform);
    expect(await createAndReady(host, platform), isTrue);
    expect(host.lastCreateToReady, isNotNull);
    expect(host.lastCreateToVisible, isNotNull);
    expect(host.lastCreateToVisible!.inMilliseconds, greaterThanOrEqualTo(0));
    host.dispose();
    await platform.dispose();
  });

  // -------------------------------------------------------------------------
  // t12：跨屏 auto-follow 目标显示器/DPI 重算（程序化 + 强制稳定写回）
  // -------------------------------------------------------------------------

  const primary125 = DisplayInfo(
    id: r'\\.\DISPLAY1',
    physicalBounds: Rect.fromLTWH(0, 0, 2560, 1440),
    physicalWorkArea: Rect.fromLTWH(0, 0, 2560, 1440),
    scaleFactor: 1.25,
    isPrimary: true,
  );
  const secondary150 = DisplayInfo(
    id: r'\\.\DISPLAY2',
    physicalBounds: Rect.fromLTWH(-2560, -58, 2560, 1600),
    physicalWorkArea: Rect.fromLTWH(-2560, -58, 2560, 1600),
    scaleFactor: 1.5,
  );
  const tertiary100 = DisplayInfo(
    id: r'\\.\DISPLAY3',
    physicalBounds: Rect.fromLTWH(2560, 0, 1920, 1080),
    physicalWorkArea: Rect.fromLTWH(2560, 0, 1920, 1080),
    scaleFactor: 1.0,
  );

  test('U-AL-28/T12 程序化跨屏（125→150）：updateAnchors 重定向显示器并修正尺寸',
      () async {
    final platform = FakeAnswerWindowPlatform(
      displays: const <DisplayInfo>[primary125, secondary150],
      dprValue: 1.25,
    );
    final host = makeHost(platform);
    expect(await createAndReady(host, platform), isTrue);
    expect(platform.appliedBounds.last.width, closeTo(896, 0.6));

    await host.updateAnchors(
      inputBarPhysical: const Rect.fromLTWH(-2400, 1100, 2000, 120),
      mainWindowPhysical: const Rect.fromLTWH(-2500, 100, 2400, 1200),
    );
    await Future<void>.delayed(const Duration(milliseconds: 80));
    final moved = platform.appliedBounds.last;
    expect(moved.left, lessThan(-1000), reason: 'auto 应跟随输入条到副屏');
    expect(moved.width, closeTo(716.8 * 1.5, 1));
    expect(moved.bottom, closeTo(1100 - 8 * 1.5, 1));

    await platform.contentHeight(5000);
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(platform.appliedBounds.last.height, closeTo(1120, 1));
    host.dispose();
    await platform.dispose();
  });

  test('U-AL-29/T12 程序化跨屏（150→125）：固定逻辑宽按新 dpr 换算', () async {
    final platform = FakeAnswerWindowPlatform(
      displays: const <DisplayInfo>[primary125, secondary150],
      dprValue: 1.25,
    );
    final host = makeHost(platform);
    final future = host.showOrReplace(
      const AnswerSubmission(
        question: '副屏创建',
        inputBarPhysical: Rect.fromLTWH(-2400, 1100, 2000, 120),
        mainWindowPhysical: Rect.fromLTWH(-2500, 100, 2400, 1200),
      ),
    );
    await pumpEventQueue();
    await platform.ready();
    expect(await future, isTrue);
    expect(platform.appliedBounds.last.width, closeTo(896, 0.6));

    await host.updateAnchors(
      inputBarPhysical: const Rect.fromLTWH(200, 1300, 1400, 80),
      mainWindowPhysical: const Rect.fromLTWH(100, 100, 1200, 1200),
    );
    await Future<void>.delayed(const Duration(milliseconds: 80));
    final moved = platform.appliedBounds.last;
    expect(moved.left, greaterThanOrEqualTo(0));
    expect(moved.width, closeTo(597.33 * 1.25, 1));

    await platform.contentHeight(5000);
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(platform.appliedBounds.last.height, closeTo(950, 1));
    host.dispose();
    await platform.dispose();
  });

  test('U-AL-30/T12 100% DPI：auto-follow 后按 1.0 换算', () async {
    final platform = FakeAnswerWindowPlatform(
      displays: const <DisplayInfo>[primary125, secondary150, tertiary100],
      dprValue: 1.25,
    );
    final host = makeHost(platform);
    expect(await createAndReady(host, platform), isTrue);

    await host.updateAnchors(
      inputBarPhysical: const Rect.fromLTWH(2700, 800, 1600, 80),
      mainWindowPhysical: const Rect.fromLTWH(2600, 100, 900, 600),
    );
    await Future<void>.delayed(const Duration(milliseconds: 80));
    final moved = platform.appliedBounds.last;
    expect(moved.left, greaterThanOrEqualTo(2560));
    expect(moved.width, closeTo(716.8, 1));
    await platform.contentHeight(5000);
    await Future<void>.delayed(const Duration(milliseconds: 80));
    // 100% 屏工作区高 1080 → maxH=min(1080×0.7,760)=756 逻辑 → 756 物理。
    expect(platform.appliedBounds.last.height, closeTo(756, 1));
    host.dispose();
    await platform.dispose();
  });

  test('U-AL-31/T12 syncGeometryToAnchors 强制重写最终 physical rect', () async {
    final platform = FakeAnswerWindowPlatform(
      displays: const <DisplayInfo>[primary125, secondary150],
      dprValue: 1.25,
    );
    final host = makeHost(platform);
    expect(await createAndReady(host, platform), isTrue);
    final before = platform.appliedBounds.length;

    await host.syncGeometryToAnchors();
    expect(platform.appliedBounds.length, before + 1);
    final rect = platform.appliedBounds.last;
    expect(rect.width, closeTo(896, 0.6));
    expect(rect.height, closeTo(180 * 1.25, 0.6));
    host.dispose();
    await platform.dispose();
  });

  test('U-AL-32/T12 userMoved 跨屏后：主窗移动/sync 保持副屏与 dpr（T5-06 回归）',
      () async {
    final platform = FakeAnswerWindowPlatform(
      displays: const <DisplayInfo>[primary125, secondary150],
      dprValue: 1.25,
    );
    final host = makeHost(platform);
    expect(await createAndReady(host, platform), isTrue);
    await platform.moved(const Rect.fromLTWH(-2300, 200, 1050, 700));
    await pumpEventQueue();
    final onSecondary = platform.appliedBounds.last;
    expect(onSecondary.left, lessThan(-2000));

    await host.updateAnchors(
      inputBarPhysical: const Rect.fromLTWH(200, 900, 1400, 80),
      mainWindowPhysical: const Rect.fromLTWH(100, 100, 1200, 800),
    );
    await host.onMainWindowMoved(const Rect.fromLTWH(120, 120, 1200, 800));
    await host.syncGeometryToAnchors();
    await Future<void>.delayed(const Duration(milliseconds: 80));
    final after = platform.appliedBounds.last;
    expect(after.left, lessThan(-2000), reason: 'userMoved 不得被拉回主屏');
    expect(after.width, closeTo(716.8 * 1.5, 1));
    host.dispose();
    await platform.dispose();
  });

  // -------------------------------------------------------------------------
  // t14 / T9-01：userMoved 回答窗在主窗形态变化后重新检查输入条遮挡
  // -------------------------------------------------------------------------

  test('U-AL-33/T9-01 userMoved 遇浮窗输入条遮挡：最小位移/压缩，保持 dpr',
      () async {
    final platform = FakeAnswerWindowPlatform(dprValue: 1.0);
    final host = makeHost(platform);
    expect(await createAndReady(host, platform, contentHeight: 5000), isTrue);
    final auto = platform.appliedBounds.last;
    expect(auto.bottom, lessThanOrEqualTo(900));
    // 用户轻拖标题（位置基本不变，但 userMoved=true）。
    await platform.moved(
      Rect.fromLTWH(auto.left, auto.top, auto.width, auto.height),
    );
    await pumpEventQueue();

    // 进入浮窗后输入条移到回答窗下方并进入其矩形 → 必须重查遮挡。
    const floatingInput = Rect.fromLTWH(1450, 760, 430, 60);
    await host.updateAnchors(
      inputBarPhysical: floatingInput,
      mainWindowPhysical: const Rect.fromLTWH(1436, 220, 460, 600),
    );
    await Future<void>.delayed(const Duration(milliseconds: 80));
    final nudged = platform.appliedBounds.last;
    expect(
      overlaps(nudged, floatingInput),
      isFalse,
      reason: 'userMoved 回答窗不得覆盖浮窗输入条',
    );
    expect(nudged.width, closeTo(auto.width, 0.6));
    expect(nudged.height, lessThanOrEqualTo(auto.height + 0.6));
    expect(nudged.right, closeTo(auto.right, 1));

    // 输入条回到不遮挡位置：用户位置保持不变（不无故移动）。
    await host.updateAnchors(
      inputBarPhysical: const Rect.fromLTWH(200, 1180, 1400, 80),
      mainWindowPhysical: const Rect.fromLTWH(100, 100, 1200, 800),
    );
    await Future<void>.delayed(const Duration(milliseconds: 80));
    final stable = platform.appliedBounds.last;
    expect(stable.left, closeTo(nudged.left, 0.6));
    expect(stable.top, closeTo(nudged.top, 0.6));
    host.dispose();
    await platform.dispose();
  });

  test('U-AL-34/T9-01 极简条遮挡同样最小位移，保持主屏/dpr', () async {
    final platform = FakeAnswerWindowPlatform(
      displays: const <DisplayInfo>[primary125, secondary150],
      dprValue: 1.25,
    );
    final host = makeHost(platform);
    expect(await createAndReady(host, platform), isTrue);
    await platform.moved(const Rect.fromLTWH(1200, 700, 672, 500));
    await pumpEventQueue();
    final userRect = platform.appliedBounds.last;
    expect(userRect.left, greaterThanOrEqualTo(0));

    const minimalInput = Rect.fromLTWH(1210, 760, 500, 63);
    await host.updateAnchors(
      inputBarPhysical: minimalInput,
      mainWindowPhysical: const Rect.fromLTWH(1200, 700, 520, 65),
    );
    await Future<void>.delayed(const Duration(milliseconds: 80));
    final nudged = platform.appliedBounds.last;
    expect(overlaps(nudged, minimalInput), isFalse);
    // 仍在主屏（未被拉到副屏）、宽度仍按主屏 dpr 1.25。
    expect(nudged.left, greaterThanOrEqualTo(0));
    expect(nudged.width, closeTo(716.8 * 1.25, 1));
    host.dispose();
    await platform.dispose();
  });
}
