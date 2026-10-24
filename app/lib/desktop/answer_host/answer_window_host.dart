import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';

import '../window_mode.dart';
import 'answer_protocol.dart';
import 'answer_window_platform.dart';

/// 回答窗生命周期（规格 §2.7）。
enum AnswerWindowState { absent, creating, visible, collapsed, closing }

/// 一次非空提问（主窗口唯一数据源 → 回答窗只读镜像）。
@immutable
class AnswerSubmission {
  const AnswerSubmission({
    required this.question,
    this.conversationId,
    this.runId,
    this.inputBarPhysical,
    this.mainWindowPhysical,
    this.themeMode = 'system',
    this.dark = false,
    this.fontFamily = 'NotoSC',
  });

  /// 用户提交的原始文本；`trim().isEmpty` 时不会创建回答窗。
  final String question;

  final String? conversationId;
  final String? runId;

  /// 主窗口输入条在屏幕上的物理矩形（回答窗布局排除区）。
  final Rect? inputBarPhysical;

  /// 主窗口物理矩形（候选放置锚点）。
  final Rect? mainWindowPhysical;

  /// `light` / `dark` / `system`。
  final String themeMode;

  final bool dark;
  final String fontFamily;

  String get trimmedQuestion => question.trim();
}

/// 主引擎的回答窗宿主（规格 §2.5–§2.9）。
///
/// 职责：创建/复用/关闭第二顶层窗口；IPC（hello/snapshot/delta/status/
/// presentation/resize_ack）；高度自适应与钳制；收起/展开；位置记忆/钳制；
/// 主窗口最小化/托盘/截图时隐藏与恢复；主窗口退出前清理（无孤儿）。
///
/// **唯一数据源**仍是主窗口；本类只镜像当前回答，不访问后端/DB/SSE。
class AnswerWindowHost extends ChangeNotifier {
  AnswerWindowHost({
    required this.platform,
    this.createTimeout = answerCreateTimeout,
    this.streamThrottle = answerStreamThrottle,
    this.heightThrottle = answerStreamThrottle,
    this.closeTimeout = const Duration(seconds: 1),
    this.onError,
    this.onPresenceChanged,
  }) {
    _windowsSubscription = platform.windowsChanged.listen((_) {
      unawaited(_checkAlive());
    });
  }

  final AnswerWindowPlatform platform;

  /// 等待第二引擎 `ready` 的超时。
  final Duration createTimeout;

  /// SSE delta 合批窗口（80ms，允许 60–100ms）。
  final Duration streamThrottle;

  /// 测高/改高窗口。
  final Duration heightThrottle;

  /// 关闭窗口后等待销毁的超时（主窗口退出清理用）。
  final Duration closeTimeout;

  /// 用户可见的失败提示（回答窗创建失败等；主聊天不受影响）。
  final void Function(String message)? onError;

  /// 回答窗存在状态变化（主窗口用于 `setPreventClose(true)`）。
  ///
  /// T5-07：创建开始即通知 true（在 createWindow 之前 await），失败/关闭再
  /// 通知 false，保证创建期关主窗也不会留下孤儿。
  final FutureOr<void> Function(bool present)? onPresenceChanged;

  /// 创建后一次性输入焦点补偿（由 UI 注入：主输入框 `requestFocus`）。
  void Function()? onFocusCompensation;

  AnswerWindowState _state = AnswerWindowState.absent;
  AnswerWindowHandle? _handle;
  AnswerTransport? _transport;
  AnswerLaunchPayload? _launch;
  Completer<Map<String, Object?>>? _ready;
  StreamSubscription<void>? _windowsSubscription;

  AnswerSnapshot _snapshot = const AnswerSnapshot();
  final List<Map<String, Object?>> _plan = <Map<String, Object?>>[];
  final List<Map<String, Object?>> _refs = <Map<String, Object?>>[];
  String _answerBuffer = '';
  AnswerStatus _status = AnswerStatus.thinking;
  String? _statusLabel;
  bool _approvalRequired = false;
  String? _error;
  int _seq = 0;
  DateTime? _startedAt;

  AnswerDeltaBatcher? _batcher;
  Timer? _heightTimer;
  Timer? _stabilizeTimer;
  bool _heightPending = false;
  bool _forceNextApply = false;
  bool _applyingHeight = false;
  bool _dragInProgress = false;
  bool _collapsed = false;
  bool _hiddenByOwner = false;
  bool _shuttingDown = false;
  bool _presence = false;
  bool _checkingAlive = false;
  bool _userMoved = false;
  Rect? _userRectPhysical;

  Rect? _inputBarPhysical;
  Rect? _mainWindowPhysical;
  Rect? _workPhysical;
  double _dpr = 1.0;
  bool _hasTargetScale = false;
  double _widthLogical = answerWidthMin;
  double _desiredHeightLogical = answerMinHeight;
  double _appliedHeightLogical = 0;
  double? _lastContentHeight;
  String? _lastTransportError;
  String? _sentThemeMode;
  bool? _sentThemeDark;
  Completer<void>? _createSettled;
  DateTime? _createStartedAt;
  Duration? _lastCreateToReady;
  Duration? _lastCreateToVisible;
  DateTime? _lastOverlapWarningAt;
  int _snapshotCount = 0;
  int _resyncCount = 0;

  AnswerWindowState get state => _state;

  bool get supported => platform.supported;

  /// 回答窗存在（含 creating/closing，用于主窗口 preventClose）。
  bool get hasWindow => _presence || _handle != null;

  bool get visible =>
      _handle != null &&
      !_hiddenByOwner &&
      (_state == AnswerWindowState.visible ||
          _state == AnswerWindowState.collapsed);

  bool get collapsed => _collapsed;

  bool get hiddenByOwner => _hiddenByOwner;

  String? get windowId => _handle?.windowId;

  /// 当前回答快照（窗口不存在时为 null；正文反映已收到的全部增量）。
  AnswerSnapshot? get snapshot {
    if (!hasWindow) return null;
    return _snapshot.copyWith(
      answerMarkdown: _answerBuffer,
      status: _status,
      plan: List<Map<String, Object?>>.of(_plan),
      refs: List<Map<String, Object?>>.of(_refs),
      error: _error,
      elapsedMs: _elapsedMs,
    );
  }

  /// 最近一次失败原因（UI 提示用）。
  String? get lastError => _lastTransportError;

  /// T5-08：最近一次创建耗时（提交→ready / 提交→窗口可见），用于 W10 度量。
  Duration? get lastCreateToReady => _lastCreateToReady;
  Duration? get lastCreateToVisible => _lastCreateToVisible;

  int get seq => _seq;

  // -------------------------------------------------------------------------
  // 创建 / 替换 / 数据推送
  // -------------------------------------------------------------------------

  /// 非空提问时创建或替换回答窗。
  ///
  /// - `question.trim().isEmpty` → 返回 false，不建窗（附件-only 走主聊天）；
  /// - 已存在 → 复用同一窗口发送全量 `snapshot`（替换语义）；
  /// - `creating/closing` 中 → 返回 false（状态机串行，规格 I-2）；
  /// - 失败 → 清理残留窗口并返回 false（调用方显示一次错误、主聊天继续）。
  Future<bool> showOrReplace(AnswerSubmission submission) async {
    final question = submission.trimmedQuestion;
    if (question.isEmpty) return false;
    if (!platform.supported) {
      _raiseError('回答浮窗不可用');
      return false;
    }
    if (_shuttingDown) return false;

    _themeMode = submission.themeMode;
    _themeDark = submission.dark;
    _fontFamily = submission.fontFamily;
    if (submission.inputBarPhysical != null) {
      _inputBarPhysical = submission.inputBarPhysical;
    }
    if (submission.mainWindowPhysical != null) {
      _mainWindowPhysical = submission.mainWindowPhysical;
    }

    switch (_state) {
      case AnswerWindowState.creating:
      case AnswerWindowState.closing:
        return false;
      case AnswerWindowState.absent:
        return _createAndPresent(submission, question);
      case AnswerWindowState.visible:
      case AnswerWindowState.collapsed:
        await _presentSnapshot(submission, question);
        return true;
    }
  }

  String _themeMode = 'system';
  bool _themeDark = false;
  String _fontFamily = 'NotoSC';

  Future<bool> _createAndPresent(
    AnswerSubmission submission,
    String question,
  ) async {
    _state = AnswerWindowState.creating;
    _collapsed = false;
    _userMoved = false;
    _userRectPhysical = null;
    _hiddenByOwner = false;
    _createStartedAt = DateTime.now();
    _lastCreateToReady = null;
    _lastCreateToVisible = null;
    _resetMirror(submission, question);
    // T5-07：在 createWindow 之前先同步 preventClose（await presence 回调），
    // 创建期即使用户关闭主窗也不会出现“主窗先关、回答窗后到”的孤儿竞态。
    await _notifyPresence(true);
    notifyListeners();

    final settle = Completer<void>();
    _createSettled = settle;
    final ready = Completer<Map<String, Object?>>();
    _ready = ready;
    AnswerWindowHandle? handle;
    AnswerTransport? transport;
    try {
      try {
        _launch = AnswerLaunchPayload(
          themeMode: _themeMode,
          dark: _themeDark,
          fontFamily: _fontFamily,
        );
        final display = await _targetDisplay(
          _inputBarPhysical ?? _mainWindowPhysical,
        );
        if (display != null) {
          _workPhysical = display.physicalWorkArea;
          // F-03：目标显示器 scaleFactor 是唯一权威；第二窗 ready.dpr
          // 只是隐藏窗口首帧 DPI（创建在主屏），不能覆盖它。
          _dpr = FloatingWindowPlanner.normalizedDpr(display.scaleFactor);
          _hasTargetScale = true;
        }
        _widthLogical = AnswerWindowPlanner.widthLogical(_workLogical);

        handle = await platform.create(payload: _launch!);
        if (_shuttingDown) {
          await platform.close(handle);
          handle = null;
          await _finishAbsent();
          return false;
        }
        _handle = handle;
        transport = await platform.openTransport(handle);
        _transport = transport;
        // control handler 必须在第二引擎 ready 到达前/同时注册；第二引擎侧对
        // NO_HANDLER / CHANNEL_NOT_FOUND 有 100ms 退避重试（规格 §2.6）。
        await transport.setControlHandler(_onControlMessage);

        final provisional = _computeRect(heightLogical: answerMinHeight);
        await platform.configure(handle, physical: provisional, topmost: true);
        // T5-08：焦点补偿与 ready 等待并行，不占用首次可见关键路径。
        unawaited(_compensateFocusAfterCreate());

        final readyArgs = await ready.future.timeout(
          createTimeout,
          onTimeout: () => const <String, Object?>{},
        );
        if (readyArgs.isEmpty) {
          await _abortCreate('回答浮窗创建超时');
          return false;
        }
        final protocol = readyArgs['protocol'];
        if (protocol is int && protocol != answerProtocolVersion) {
          await _abortCreate('回答浮窗协议不兼容');
          return false;
        }
        _lastCreateToReady = _elapsedSinceCreate();
        _applyReady(readyArgs);

        final rect = _computeRect(heightLogical: _desiredHeightLogical);
        await platform.setBounds(handle, rect, topmost: true);
        if (!_hiddenByOwner) {
          await platform.showNoActivate(handle, topmost: true);
        }
        _appliedHeightLogical = _desiredHeightLogical;
        _userRectPhysical = rect;
        _lastCreateToVisible = _elapsedSinceCreate();
        debugPrint(
          'answer create timing: ready=${_lastCreateToReady?.inMilliseconds}ms '
          'visible=${_lastCreateToVisible?.inMilliseconds}ms',
        );

        await _send('hello', <String, Object?>{
          'protocol': answerProtocolVersion,
          'windowId': handle.windowId,
          'hwnd': handle.hwnd,
          'widthLogical': _widthLogical,
          'minH': answerMinHeight,
          'maxH': AnswerWindowPlanner.maxHeightLogical(_workLogical),
          'themeMode': _themeMode,
          'dark': _themeDark,
          'fontFamily': _fontFamily,
        });
        // 等待 ready 期间已到达的正文由 snapshot 全量带上；之后只发增量。
        final sentLength = _answerBuffer.length;
        await _sendSnapshot();
        final suffix = _answerBuffer.length > sentLength
            ? _answerBuffer.substring(sentLength)
            : '';
        if (suffix.isNotEmpty) _batcher?.add(suffix);
        _sentThemeMode = _themeMode;
        _sentThemeDark = _themeDark;

        _state = AnswerWindowState.visible;
        unawaited(_notifyPresence(true));
        notifyListeners();
        return true;
      } catch (error) {
        debugPrint('answer window create failed: $error');
        _handle = handle;
        _transport = transport;
        await _abortCreate('回答浮窗创建失败');
        return false;
      }
    } finally {
      if (!settle.isCompleted) settle.complete();
      if (identical(_createSettled, settle)) _createSettled = null;
    }
  }

  Duration _elapsedSinceCreate() {
    final start = _createStartedAt;
    if (start == null) return Duration.zero;
    return DateTime.now().difference(start);
  }

  Future<void> _compensateFocusAfterCreate() async {
    try {
      await platform.focusMainWindow();
      _invokeFocusCompensation();
    } catch (error) {
      debugPrint('answer focus compensation failed: $error');
    }
  }

  Future<void> _presentSnapshot(
    AnswerSubmission submission,
    String question,
  ) async {
    final wasCollapsed = _collapsed;
    _resetMirror(submission, question);
    _state = AnswerWindowState.visible;
    if (wasCollapsed) {
      _collapsed = false;
      await _send('presentation', <String, Object?>{'collapsed': false});
    }
    await _sendSnapshot();
    // F-02：替换/展开时补一次主题，避免主题在窗口打开期间改变后不同步。
    await _syncThemeIfNeeded();
    await _applyHeight(force: true);
    notifyListeners();
  }

  /// 追加正文增量（SSE `delta`）。内部 80ms 合批；窗口不存在时静默忽略。
  void pushTextDelta(String text) {
    if (text.isEmpty) return;
    if (_state == AnswerWindowState.absent ||
        _state == AnswerWindowState.closing) {
      return;
    }
    _answerBuffer += text;
    if (_state == AnswerWindowState.creating) return;
    _batcher?.add(text);
  }

  /// 更新状态（thinking/streaming/tool/waitingApproval/done/stopped/error）。
  void setStatus(
    AnswerStatus status, {
    String? label,
    bool approvalRequired = false,
    String? runId,
  }) {
    if (_state == AnswerWindowState.absent) return;
    _status = status;
    _statusLabel = label;
    _approvalRequired = approvalRequired;
    if (runId != null) _snapshot = _snapshot.copyWith(runId: runId);
    if (_state == AnswerWindowState.creating) {
      notifyListeners();
      return;
    }
    _batcher?.flushNow();
    unawaited(_sendStatus());
    notifyListeners();
  }

  /// 计划更新（低频；以全量 snapshot 同步，保证第二窗只读一致）。
  void setPlan(List<Map<String, Object?>>? plan) {
    if (_state == AnswerWindowState.absent) return;
    _plan..clear()..addAll(plan ?? const <Map<String, Object?>>[]);
    if (_state == AnswerWindowState.creating) return;
    _batcher?.flushNow();
    unawaited(_sendSnapshot());
  }

  /// 引用更新（低频；全量 snapshot）。
  void setRefs(List<Map<String, Object?>>? refs) {
    if (_state == AnswerWindowState.absent) return;
    _refs..clear()..addAll(refs ?? const <Map<String, Object?>>[]);
    if (_state == AnswerWindowState.creating) return;
    _batcher?.flushNow();
    unawaited(_sendSnapshot());
  }

  /// 错误状态（banner；主聊天仍显示 v0.5.0 的提示）。
  void setError(String message) {
    if (_state == AnswerWindowState.absent) return;
    _error = truncateAnswerError(message);
    _status = AnswerStatus.error;
    _statusLabel = null;
    if (_state == AnswerWindowState.creating) {
      notifyListeners();
      return;
    }
    _batcher?.flushNow();
    unawaited(_sendStatus());
    unawaited(_sendSnapshot());
    notifyListeners();
  }

  /// 流结束（done/stopped/error）：保留正文与窗口，状态落定后不再改高。
  void finish(AnswerStatus status, {String? error}) {
    if (_state == AnswerWindowState.absent) return;
    _status = status;
    if (error != null) _error = truncateAnswerError(error);
    if (_state == AnswerWindowState.creating) {
      notifyListeners();
      return;
    }
    _batcher?.flushNow();
    unawaited(_sendStatus());
    unawaited(_sendSnapshot());
    notifyListeners();
  }

  // -------------------------------------------------------------------------
  // 收起 / 展开 / 关闭
  // -------------------------------------------------------------------------

  Future<void> collapse() async {
    final handle = _handle;
    if (handle == null ||
        _state != AnswerWindowState.visible ||
        _collapsed ||
        _hiddenByOwner) {
      return;
    }
    _collapsed = true;
    _state = AnswerWindowState.collapsed;
    _appliedHeightLogical = answerCollapsedHeight;
    final rect = _computeRect(heightLogical: answerCollapsedHeight);
    _userRectPhysical = rect;
    try {
      await platform.setBounds(handle, rect, topmost: true);
      await _send('presentation', <String, Object?>{'collapsed': true});
    } catch (error) {
      debugPrint('answer collapse failed: $error');
    }
    // 用户动作完成后恢复主窗口焦点一次（规格 §2.8）。
    await platform.focusMainWindow();
    _invokeFocusCompensation();
    notifyListeners();
  }

  Future<void> expand() async {
    final handle = _handle;
    if (handle == null ||
        _state != AnswerWindowState.collapsed ||
        _hiddenByOwner) {
      return;
    }
    _collapsed = false;
    _state = AnswerWindowState.visible;
    _appliedHeightLogical = 0;
    await _applyHeight(force: true);
    await _send('presentation', <String, Object?>{'collapsed': false});
    // 用户动作完成后恢复主窗口焦点一次（规格 §2.8）。
    await platform.focusMainWindow();
    _invokeFocusCompensation();
    notifyListeners();
  }

  /// 用户关闭回答窗（主聊天/SSE 不受影响；下一次非空提交重建）。
  Future<void> closeWindow() async {
    final handle = _handle;
    if (handle == null || _state == AnswerWindowState.closing) return;
    _state = AnswerWindowState.closing;
    notifyListeners();
    final transport = _transport;
    _transport = null;
    _handle = null;
    _ready = null;
    _batcher?.dispose();
    _batcher = null;
    _heightTimer?.cancel();
    _heightTimer = null;
    _stabilizeTimer?.cancel();
    _stabilizeTimer = null;
    _heightPending = false;
    await transport?.dispose();
    try {
      await platform.close(handle);
    } catch (error) {
      debugPrint('answer close failed: $error');
    }
    await _waitGone(handle, closeTimeout);
    await _finishAbsent();
    // 用户关闭回答窗后把焦点还给主窗口（规格 §2.8）。
    await platform.focusMainWindow();
    _invokeFocusCompensation();
  }

  /// 主窗口最小化 / 托盘隐藏 / 截图前隐藏（保留引擎与状态）。
  Future<void> hide() async {
    if (_hiddenByOwner ||
        _state == AnswerWindowState.absent ||
        _state == AnswerWindowState.closing) {
      return;
    }
    _hiddenByOwner = true;
    final handle = _handle;
    if (handle != null) {
      try {
        await platform.hide(handle);
      } catch (error) {
        debugPrint('answer hide failed: $error');
      }
    }
    notifyListeners();
  }

  /// 主窗口恢复 / 托盘显示 / 截图后恢复（无激活显示，不抢焦点）。
  Future<void> restoreVisibility() async {
    if (!_hiddenByOwner) return;
    _hiddenByOwner = false;
    final handle = _handle;
    if (handle != null &&
        (_state == AnswerWindowState.visible ||
            _state == AnswerWindowState.collapsed)) {
      try {
        await platform.showNoActivate(handle, topmost: true);
        if (_state == AnswerWindowState.collapsed) {
          // 收起状态保持 36px；重新应用一次，避免恢复时被 DWM 还原。
          await platform.setBounds(
            handle,
            _computeRect(heightLogical: answerCollapsedHeight),
            topmost: true,
          );
        } else {
          await _applyHeight(force: true);
        }
        // 隐藏期间主题可能已变化（F-02）。
        await _syncThemeIfNeeded();
      } catch (error) {
        debugPrint('answer restore failed: $error');
      }
    }
    notifyListeners();
  }

  /// 主窗口重新激活时把回答窗无激活抬到最上层（不改变焦点）。
  Future<void> bringToFront() async {
    final handle = _handle;
    if (handle == null || _hiddenByOwner) return;
    if (_state != AnswerWindowState.visible &&
        _state != AnswerWindowState.collapsed) {
      return;
    }
    try {
      await platform.bringToTop(handle);
    } catch (error) {
      debugPrint('answer bringToFront failed: $error');
    }
  }

  // -------------------------------------------------------------------------
  // 布局锚点
  // -------------------------------------------------------------------------

  /// 输入条/主窗口矩形更新（主窗口移动、缩放、形态切换、极简条拖动）。
  ///
  /// 80ms 节流、无激活；auto 模式跟随，user 模式仅在覆盖输入条时轻推。
  Future<void> updateAnchors({
    required Rect inputBarPhysical,
    Rect? mainWindowPhysical,
  }) async {
    if (!inputBarPhysical.width.isFinite ||
        !inputBarPhysical.height.isFinite) {
      return;
    }
    // 幂等：几何未变化时不重复 SetWindowPos（周期性 anchor 同步/F-05）。
    if (_rectAlmostEqual(_inputBarPhysical, inputBarPhysical) &&
        (mainWindowPhysical == null ||
            _rectAlmostEqual(_mainWindowPhysical, mainWindowPhysical))) {
      return;
    }
    _inputBarPhysical = inputBarPhysical;
    if (mainWindowPhysical != null) _mainWindowPhysical = mainWindowPhysical;
    if (_state != AnswerWindowState.visible &&
        _state != AnswerWindowState.collapsed) {
      return;
    }
    if (_hiddenByOwner) return;
    // T5-06/t12/t14：用户手动放置的回答窗不跑 auto 布局；但主窗形态/位置
    // 变化后必须用真实输入条矩形重新检查遮挡，仅在重叠时最小位移/压缩。
    if (_userMoved) {
      await ensureOnScreen();
      await _reconcileUserMovedWithInputBar();
      return;
    }
    // t12：自动模式（未手动拖动回答窗）必须跟随输入条/主窗所在显示器。
    // 程序化 SetWindowPos 不触发 window_manager move 事件时，由 500ms
    // anchor sync 走到这里重定向 target display/dpr。
    if (!_userMoved) {
      final display = await _targetDisplay(
        inputBarPhysical,
        fallback: mainWindowPhysical,
      );
      if (display != null) {
        final scale = FloatingWindowPlanner.normalizedDpr(display.scaleFactor);
        final changed = (scale - _dpr).abs() > 0.001 ||
            _workPhysical != display.physicalWorkArea;
        _workPhysical = display.physicalWorkArea;
        _dpr = scale;
        _hasTargetScale = true;
        if (changed) {
          debugPrint(
            'answer auto-follow display ${display.id} dpr=$scale',
          );
          _scheduleGeometryStabilize();
        }
      }
    }
    debugPrint(
      'answer anchors updated: input=(${inputBarPhysical.left.round()},'
      '${inputBarPhysical.top.round()},${inputBarPhysical.width.round()},'
      '${inputBarPhysical.height.round()})',
    );
    _scheduleHeightApply(force: true);
  }

  static bool _rectAlmostEqual(Rect? a, Rect b, {double tolerance = 0.5}) {
    if (a == null) return false;
    return (a.left - b.left).abs() <= tolerance &&
        (a.top - b.top).abs() <= tolerance &&
        (a.width - b.width).abs() <= tolerance &&
        (a.height - b.height).abs() <= tolerance;
  }

  /// 主窗口物理矩形变化（由 WindowController 的 move/resize 监听调用）。
  Future<void> onMainWindowMoved(Rect mainWindowPhysical) async {
    final previous = _mainWindowPhysical;
    _mainWindowPhysical = mainWindowPhysical;
    if (previous != null && _inputBarPhysical != null) {
      final delta = mainWindowPhysical.topLeft - previous.topLeft;
      if (delta != Offset.zero) {
        _inputBarPhysical = _inputBarPhysical!.shift(delta);
      }
    }
    if (_state != AnswerWindowState.visible &&
        _state != AnswerWindowState.collapsed) {
      return;
    }
    if (_hiddenByOwner) return;
    // T5-06/t12/t14：userMoved 回答窗不跟随主窗重排；但主窗形态/位置变化后
    // 必须用真实输入条矩形重查遮挡，重叠时最小位移。
    if (_userMoved) {
      await ensureOnScreen();
      await _reconcileUserMovedWithInputBar();
      return;
    }
    // T5-06：用户把回答窗拖到别的显示器后，回答窗所在显示器/DPI 是权威，
    // 主窗移动不得把它 clamp 回主屏。auto 模式才跟随主窗显示器。
    if (!_userMoved) {
      try {
        final display = await _targetDisplay(mainWindowPhysical);
        if (display != null) {
          final scale =
              FloatingWindowPlanner.normalizedDpr(display.scaleFactor);
          final changed = (scale - _dpr).abs() > 0.001 ||
              _workPhysical != display.physicalWorkArea;
          _workPhysical = display.physicalWorkArea;
          _dpr = scale;
          _hasTargetScale = true;
          if (changed) {
            debugPrint('answer auto-follow display ${display.id} dpr=$scale');
            // t12：DPI/显示器切换后 500ms 再强制写一次最终 physical rect，
            // 抵消 Windows WM_DPICHANGED 可能造成的二次缩放。
            _scheduleGeometryStabilize();
          }
        }
      } catch (error) {
        debugPrint('answer display refresh failed: $error');
      }
    }
    _scheduleHeightApply(force: true);
  }

  void _scheduleGeometryStabilize() {
    _stabilizeTimer?.cancel();
    _stabilizeTimer = Timer(
      const Duration(milliseconds: 500),
      () {
        _stabilizeTimer = null;
        unawaited(syncGeometryToAnchors());
      },
    );
  }

  /// t12：按当前 anchor/用户位置重算 target display、dpr 与最终 physical rect
  /// 并强制写回（不占用正文 seq、不抢焦点）。
  ///
  /// - auto（未手动拖动）：跟随输入条所在显示器；
  /// - userMoved：保持回答窗所在显示器，仅 clamp（T5-06）。
  Future<void> syncGeometryToAnchors() async {
    if (_hiddenByOwner ||
        _dragInProgress ||
        _state == AnswerWindowState.absent ||
        _state == AnswerWindowState.creating ||
        _state == AnswerWindowState.closing) {
      return;
    }
    final handle = _handle;
    if (handle == null) return;
    List<DisplayInfo> displays;
    try {
      displays = await platform.displays();
    } catch (error) {
      debugPrint('answer geometry sync displays failed: $error');
      return;
    }
    if (displays.isEmpty) return;

    final currentHeight =
        _collapsed ? answerCollapsedHeight : _computeDesiredHeight();
    final anchor = _userMoved
        ? (_userRectPhysical ?? _computeRect(heightLogical: currentHeight))
        : (_inputBarPhysical ?? _mainWindowPhysical);
    final target = FloatingWindowPlanner.chooseDisplay(
          displays,
          anchor ?? Rect.zero,
        ) ??
        displays.firstWhere(
          (display) => display.isPrimary,
          orElse: () => displays.first,
        );
    _workPhysical = target.physicalWorkArea;
    _dpr = FloatingWindowPlanner.normalizedDpr(target.scaleFactor);
    _hasTargetScale = true;
    final height =
        _collapsed ? answerCollapsedHeight : _computeDesiredHeight();
    _desiredHeightLogical = height;
    final placed = AnswerWindowPlanner.place(
      workPhysical: target.physicalWorkArea,
      inputBarPhysical: _userMoved ? Rect.zero : (_inputBarPhysical ?? Rect.zero),
      mainWindowPhysical: _mainWindowPhysical ?? Rect.zero,
      dpr: _dpr,
      widthLogical: _widthLogical,
      heightLogical: height,
      userMoved: _userMoved,
      userRect: _userMoved ? anchor : null,
    );
    _userRectPhysical = placed;
    _appliedHeightLogical = height;
    try {
      await platform.setBounds(handle, placed, topmost: true);
      debugPrint(
        'answer geometry stabilized: display=${target.id} dpr=$_dpr '
        'rect=(${placed.left.round()},${placed.top.round()},'
        '${placed.width.round()},${placed.height.round()})',
      );
    } catch (error) {
      debugPrint('answer geometry stabilize failed: $error');
    }
    if (_userMoved) await _reconcileUserMovedWithInputBar();
    notifyListeners();
  }

  /// T9-01：userMoved 回答窗在主窗形态/位置变化后用真实输入条矩形重查遮挡。
  ///
  /// 仅当与输入条（含 gap）相交时，才按 planner 的最小位移候选（上/下/左/右）
  /// 移动或压缩高度；保持回答窗所在显示器/dpr 与宽度，不无故改变用户位置。
  Future<void> _reconcileUserMovedWithInputBar() async {
    if (!_userMoved ||
        _hiddenByOwner ||
        _dragInProgress ||
        _state == AnswerWindowState.absent ||
        _state == AnswerWindowState.creating ||
        _state == AnswerWindowState.closing) {
      return;
    }
    final handle = _handle;
    final input = _inputBarPhysical;
    if (handle == null || input == null || input.width < 1 || input.height < 1) {
      return;
    }
    final height =
        _collapsed ? answerCollapsedHeight : _computeDesiredHeight();
    final current = _userRectPhysical ?? _computeRect(heightLogical: height);
    if (!AnswerWindowPlanner.overlapsInputBar(
      answerPhysical: current,
      inputBarPhysical: input,
      dpr: _dpr,
    )) {
      return;
    }
    final work = _workPhysical ?? _fallbackWorkArea();
    final placed = AnswerWindowPlanner.place(
      workPhysical: work,
      inputBarPhysical: input,
      mainWindowPhysical: _mainWindowPhysical ?? input,
      dpr: _dpr,
      widthLogical: _widthLogical,
      heightLogical: height,
      userMoved: true,
      userRect: current,
    );
    if (_rectAlmostEqual(current, placed, tolerance: 0.8)) {
      final now = DateTime.now();
      final last = _lastOverlapWarningAt;
      if (last == null || now.difference(last) > const Duration(seconds: 2)) {
        _lastOverlapWarningAt = now;
        debugPrint(
          'answer userMoved still overlaps input bar: '
          'answer=(${current.left.round()},${current.top.round()},'
          '${current.width.round()},${current.height.round()}) '
          'input=(${input.left.round()},${input.top.round()},'
          '${input.width.round()},${input.height.round()})',
        );
      }
      return;
    }
    _userRectPhysical = placed;
    _desiredHeightLogical = height;
    _appliedHeightLogical = placed.height / _dpr;
    try {
      await platform.setBounds(handle, placed, topmost: true);
      debugPrint(
        'answer userMoved nudged for input bar: '
        'rect=(${placed.left.round()},${placed.top.round()},'
        '${placed.width.round()},${placed.height.round()}) '
        'input=(${input.left.round()},${input.top.round()},'
        '${input.width.round()},${input.height.round()})',
      );
    } catch (error) {
      debugPrint('answer userMoved nudge failed: $error');
    }
    notifyListeners();
  }

  /// T5-10：显示器移除/DPI 变化后把回答窗钳制到有效工作区。
  ///
  /// 以回答窗自身位置选显示器（用户拖动过的窗口不会被主窗拉回）；若当前
  /// 工作区不可用或 DPI 变化，重新 clamp 并保持宽度/收起状态，不抢焦点。
  Future<void> ensureOnScreen() async {
    if (_hiddenByOwner ||
        _state == AnswerWindowState.absent ||
        _state == AnswerWindowState.creating ||
        _state == AnswerWindowState.closing) {
      return;
    }
    final handle = _handle;
    if (handle == null) return;
    List<DisplayInfo> displays;
    try {
      displays = await platform.displays();
    } catch (error) {
      debugPrint('answer ensureOnScreen displays failed: $error');
      return;
    }
    if (displays.isEmpty) return;

    // t12：auto 模式下显示器/DPI 变化不能按回答窗旧位置 clamp（会把回答窗
    // 钉在主屏并误标 userMoved，破坏跨屏 auto-follow）。交给 500ms 稳定
    // 同步按输入条 anchor 重算；只有 userMoved 才按回答窗自身位置 clamp。
    if (!_userMoved) {
      _scheduleGeometryStabilize();
      return;
    }

    final height = _collapsed ? answerCollapsedHeight : _computeDesiredHeight();
    final current = _userRectPhysical ?? _computeRect(heightLogical: height);
    final target = FloatingWindowPlanner.chooseDisplay(displays, current) ??
        displays.firstWhere(
          (display) => display.isPrimary,
          orElse: () => displays.first,
        );
    final scale = FloatingWindowPlanner.normalizedDpr(target.scaleFactor);
    final scaleChanged = (scale - _dpr).abs() > 0.001;
    final inside = FloatingWindowPlanner.isInsideWorkArea(
      current,
      target.physicalWorkArea,
    );
    if (inside && !scaleChanged) {
      await _reconcileUserMovedWithInputBar();
      return;
    }

    _workPhysical = target.physicalWorkArea;
    _dpr = scale;
    _hasTargetScale = true;
    _desiredHeightLogical = height;
    final placed = AnswerWindowPlanner.place(
      workPhysical: target.physicalWorkArea,
      inputBarPhysical: Rect.zero,
      mainWindowPhysical: _mainWindowPhysical ?? Rect.zero,
      dpr: _dpr,
      widthLogical: _widthLogical,
      heightLogical: height,
      userMoved: true,
      userRect: current,
    );
    _userRectPhysical = placed;
    _appliedHeightLogical = height;
    try {
      await platform.setBounds(handle, placed, topmost: true);
      debugPrint(
        'answer clamped to display ${target.id}: '
        'rect=(${placed.left.round()},${placed.top.round()},'
        '${placed.width.round()},${placed.height.round()})',
      );
    } catch (error) {
      debugPrint('answer ensureOnScreen setBounds failed: $error');
    }
    await _reconcileUserMovedWithInputBar();
    notifyListeners();
  }

  /// 主题变化：只需通知第二窗重算 palette，不改尺寸（F-02）。
  ///
  /// 窗口未打开时只记录，创建时由 hello/payload 带上；窗口打开时同步一次；
  /// 重复相同主题不发送（避免 build 高频调用产生 IPC）。
  Future<void> setTheme({
    required String themeMode,
    required bool dark,
  }) async {
    final changed = _themeMode != themeMode || _themeDark != dark;
    _themeMode = themeMode;
    _themeDark = dark;
    if (!hasWindow || _hiddenByOwner) return;
    if (!changed &&
        _sentThemeMode == themeMode &&
        _sentThemeDark == dark) {
      return;
    }
    await _syncThemeIfNeeded();
  }

  Future<void> _syncThemeIfNeeded() async {
    if (!hasWindow || _hiddenByOwner) return;
    if (_sentThemeMode == _themeMode && _sentThemeDark == _themeDark) {
      return;
    }
    _sentThemeMode = _themeMode;
    _sentThemeDark = _themeDark;
    await _send('theme', <String, Object?>{
      'themeMode': _themeMode,
      'dark': _themeDark,
    });
  }

  // -------------------------------------------------------------------------
  // 主窗口退出清理（无孤儿）
  // -------------------------------------------------------------------------

  /// 先关回答窗再退主窗（规格 §2.9；主窗侧由 WindowController 保证顺序）。
  Future<void> shutdown() async {
    if (!hasWindow && _handle == null && _state == AnswerWindowState.absent) {
      return;
    }
    _shuttingDown = true;
    // T5-07：创建中关主窗时，先等 create 流程收敛（handle 已建或已失败），
    // 避免 main 先退出、第二引擎随后启动成孤儿。presence 已在 create 前置 true，
    // 主窗 preventClose 保证此等待期间不会被原生关闭。
    if (_state == AnswerWindowState.creating) {
      final settle = _createSettled;
      if (settle != null) {
        try {
          await settle.future.timeout(
            createTimeout + const Duration(milliseconds: 500),
          );
        } catch (error) {
          debugPrint('answer shutdown wait create settled: $error');
        }
      }
    }
    final handle = _handle;
    final transport = _transport;
    _handle = null;
    _transport = null;
    _ready = null;
    _state = AnswerWindowState.closing;
    _batcher?.dispose();
    _batcher = null;
    _heightTimer?.cancel();
    _heightTimer = null;
    _stabilizeTimer?.cancel();
    _stabilizeTimer = null;
    _heightPending = false;
    notifyListeners();
    try {
      await transport?.dispose();
      if (handle != null) {
        try {
          await platform.close(handle);
        } catch (error) {
          debugPrint('answer shutdown close failed: $error');
        }
        final gone = await _waitGone(handle, closeTimeout);
        if (!gone) {
          try {
            await platform.close(handle);
          } catch (_) {}
          await _waitGone(handle, const Duration(milliseconds: 500));
        }
      }
    } finally {
      _shuttingDown = false;
      await _finishAbsent(notifyPresence: true);
    }
  }

  @override
  void dispose() {
    _ready = null;
    _windowsSubscription?.cancel();
    _windowsSubscription = null;
    _batcher?.dispose();
    _batcher = null;
    _heightTimer?.cancel();
    _heightTimer = null;
    _stabilizeTimer?.cancel();
    _stabilizeTimer = null;
    super.dispose();
  }

  // -------------------------------------------------------------------------
  // IPC 处理
  // -------------------------------------------------------------------------

  Future<Object?> _onControlMessage(
    String method,
    Map<String, Object?> arguments,
  ) async {
    switch (method) {
      case 'ready':
        _handleReady(arguments);
        return null;
      case 'content_height':
        _handleContentHeight(arguments);
        return null;
      case 'moved':
        unawaited(_handleMoved(arguments));
        return null;
      case 'drag_started':
        _dragInProgress = true;
        _heightTimer?.cancel();
        _heightTimer = null;
        _stabilizeTimer?.cancel();
        _stabilizeTimer = null;
        return null;
      case 'drag_ended':
        _dragInProgress = false;
        _heightPending = false;
        unawaited(_applyHeight(force: true));
        return null;
      case 'collapse_requested':
        unawaited(collapse());
        return null;
      case 'expand_requested':
        unawaited(expand());
        return null;
      case 'close_requested':
        unawaited(closeWindow());
        return null;
      case 'resync_requested':
        _resyncCount++;
        debugPrint(
          'answer resync_requested (#$_resyncCount, snapshots=$_snapshotCount)',
        );
        unawaited(_sendSnapshot());
        return null;
      case 'render_error':
        final message = arguments['message'];
        debugPrint(
          'answer render_error: ${arguments['code']} '
          '${message is String ? truncateAnswerError(message) : ''}',
        );
        return null;
      case 'activated':
        return null;
      default:
        debugPrint('answer ipc: unknown control method $method');
        return null;
    }
  }

  void _handleReady(Map<String, Object?> arguments) {
    final ready = _ready;
    if (ready == null || ready.isCompleted) return;
    final windowId = arguments['windowId'];
    final handle = _handle;
    if (windowId is String && handle != null && windowId != handle.windowId) {
      debugPrint('answer ready ignored: windowId mismatch');
      return;
    }
    ready.complete(arguments);
  }

  void _applyReady(Map<String, Object?> arguments) {
    // F-03：目标显示器 scaleFactor 优先；仅当创建时拿不到显示器信息
    // （display API 失败）才用第二窗首帧 dpr 兜底。
    final dpr = arguments['dpr'];
    if (!_hasTargetScale &&
        dpr is num &&
        dpr.isFinite &&
        dpr >= 0.5 &&
        dpr <= 4.0) {
      _dpr = dpr.toDouble();
    }
    final content = arguments['contentHeightLogical'];
    _lastContentHeight =
        content is num && content > 0 ? content.toDouble() : null;
    _desiredHeightLogical = _computeDesiredHeight();
    _widthLogical = AnswerWindowPlanner.widthLogical(_workLogical);
  }

  /// 以当前目标显示器工作区重新计算期望高度（F-03：DPI/跨屏后重算）。
  double _computeDesiredHeight() => AnswerWindowPlanner.desiredHeightLogical(
        _lastContentHeight ?? 0,
        workLogical: _workLogical,
      );

  void _handleContentHeight(Map<String, Object?> arguments) {
    final value = arguments['heightLogical'];
    if (value is! num || !value.isFinite || value <= 0) return;
    final height = value.toDouble();
    final previous = _lastContentHeight;
    if (previous != null && (height - previous).abs() < answerHeightEpsilon) {
      return;
    }
    _lastContentHeight = height;
    final desired = _computeDesiredHeight();
    if ((desired - _desiredHeightLogical).abs() < answerHeightEpsilon &&
        _appliedHeightLogical > 0) {
      return;
    }
    _desiredHeightLogical = desired;
    _scheduleHeightApply();
  }

  Future<void> _handleMoved(Map<String, Object?> arguments) async {
    _stabilizeTimer?.cancel();
    _stabilizeTimer = null;
    final rect = decodeRect(arguments['physicalRect']);
    final handle = _handle;
    if (rect == null || handle == null) return;
    DisplayInfo? display;
    try {
      display = await _targetDisplay(rect);
    } catch (error) {
      debugPrint('answer moved display lookup failed: $error');
    }
    if (display != null) {
      _workPhysical = display.physicalWorkArea;
      _dpr = FloatingWindowPlanner.normalizedDpr(display.scaleFactor);
      _hasTargetScale = true;
    }
    _desiredHeightLogical = _computeDesiredHeight();
    final work = _workLogical;
    final maxWidth = (work.width - 2 * answerGap + 0.5);
    if (_widthLogical > maxWidth) {
      _widthLogical = maxWidth < answerWidthMin
          ? work.width
          : math.max(answerWidthMin, maxWidth);
    }
    _userMoved = true;
    final heightLogical =
        _collapsed ? answerCollapsedHeight : _desiredHeightLogical;
    final placed = AnswerWindowPlanner.place(
      workPhysical: _workPhysical ?? _fallbackWorkArea(),
      inputBarPhysical: _inputBarPhysical ?? Rect.zero,
      mainWindowPhysical: _mainWindowPhysical ?? Rect.zero,
      dpr: _dpr,
      widthLogical: _widthLogical,
      heightLogical: heightLogical,
      userMoved: true,
      userRect: rect,
    );
    _userRectPhysical = placed;
    try {
      await platform.setBounds(handle, placed, topmost: true);
    } catch (error) {
      debugPrint('answer moved apply failed: $error');
    }
  }

  // -------------------------------------------------------------------------
  // 发送
  // -------------------------------------------------------------------------

  Future<void> _sendChain = Future<void>.value();

  Future<void> _send(String method, Map<String, Object?> arguments) {
    final transport = _transport;
    if (transport == null) return Future<void>.value();
    final chain = _sendChain.then((_) => transport.sendStream(method, arguments));
    _sendChain = chain.catchError((Object error) {
      _lastTransportError = truncateAnswerError(error.toString());
      debugPrint('answer ipc send $method failed: $error');
    });
    return _sendChain;
  }

  Future<void> _sendDelta(String text) async {
    if (text.isEmpty) return;
    if (_state == AnswerWindowState.absent ||
        _state == AnswerWindowState.creating ||
        _state == AnswerWindowState.closing) {
      return;
    }
    final seq = ++_seq;
    await _send('delta', <String, Object?>{'seq': seq, 'text': text});
  }

  Future<void> _sendStatus() async {
    if (_state == AnswerWindowState.absent) return;
    final seq = ++_seq;
    await _send('status', <String, Object?>{
      'seq': seq,
      'state': _status.wire,
      'label': _statusLabel,
      'approvalRequired': _approvalRequired,
      'runId': _snapshot.runId,
      'elapsedMs': _elapsedMs,
    });
  }

  Future<void> _sendSnapshot() async {
    if (_state == AnswerWindowState.absent) return;
    final seq = ++_seq;
    _snapshotCount++;
    _snapshot = _snapshot.copyWith(
      answerMarkdown: _answerBuffer,
      status: _status,
      plan: List<Map<String, Object?>>.of(_plan),
      refs: List<Map<String, Object?>>.of(_refs),
      error: _error,
      elapsedMs: _elapsedMs,
      seq: seq,
      clearError: _error == null,
    );
    await _send('snapshot', _snapshot.toMap());
  }

  // -------------------------------------------------------------------------
  // 高度 / 几何
  // -------------------------------------------------------------------------

  Future<void> _applyHeight({bool force = false}) async {
    final handle = _handle;
    if (handle == null || _applyingHeight) return;
    if (_state == AnswerWindowState.absent ||
        _state == AnswerWindowState.creating ||
        _state == AnswerWindowState.closing ||
        _hiddenByOwner) {
      return;
    }
    if (_dragInProgress) {
      _heightPending = true;
      return;
    }
    // F-03：按当前目标显示器工作区重算期望高度（DPI/跨屏后 maxH 会变）。
    _desiredHeightLogical = _computeDesiredHeight();
    final target = _collapsed ? answerCollapsedHeight : _desiredHeightLogical;
    if (!force &&
        _appliedHeightLogical > 0 &&
        (target - _appliedHeightLogical).abs() < answerHeightEpsilon) {
      return;
    }
    _applyingHeight = true;
    try {
      final rect = _computeRect(heightLogical: target);
      final input = _inputBarPhysical;
      if (input != null &&
          AnswerWindowPlanner.overlapsInputBar(
            answerPhysical: rect,
            inputBarPhysical: input,
            dpr: _dpr,
          )) {
        final now = DateTime.now();
        final last = _lastOverlapWarningAt;
        if (last == null ||
            now.difference(last) > const Duration(seconds: 2)) {
          _lastOverlapWarningAt = now;
          debugPrint('answer overlaps input bar: $rect vs $input');
        }
      }
      _appliedHeightLogical = target;
      _userRectPhysical = rect;
      await platform.setBounds(handle, rect, topmost: true);
      // T5-04：resize_ack 不占用正文流 seq（否则客户端 lastSeq 不推进，
      // 下一条 delta 会被判漏档并触发全量 snapshot 风暴）。
      await _send('resize_ack', <String, Object?>{
        'seq': _seq,
        'heightLogical': target,
      });
    } catch (error) {
      debugPrint('answer resize failed: $error');
    } finally {
      _applyingHeight = false;
      if (_heightPending) {
        _heightPending = false;
        _scheduleHeightApply();
      }
    }
  }

  void _scheduleHeightApply({bool force = false}) {
    if (force) _forceNextApply = true;
    if (_heightTimer != null) {
      _heightPending = true;
      return;
    }
    _heightTimer = Timer(heightThrottle, () {
      _heightTimer = null;
      final again = _heightPending;
      final forceNow = _forceNextApply;
      _heightPending = false;
      _forceNextApply = false;
      unawaited(_applyHeight(force: forceNow));
      if (again) _scheduleHeightApply();
    });
  }

  Rect _computeRect({required double heightLogical}) {
    final work = _workPhysical ?? _fallbackWorkArea();
    final input = _inputBarPhysical ?? _fallbackInputBar(work);
    final main = _mainWindowPhysical ?? input;
    return AnswerWindowPlanner.place(
      workPhysical: work,
      inputBarPhysical: input,
      mainWindowPhysical: main,
      dpr: _dpr,
      widthLogical: _widthLogical,
      heightLogical: heightLogical,
      userMoved: _userMoved,
      userRect: _userRectPhysical,
    );
  }

  Rect get _workLogical {
    final work = _workPhysical;
    if (work == null || _dpr <= 0) {
      return const Rect.fromLTWH(0, 0, 1920, 1080);
    }
    return Rect.fromLTWH(
      work.left / _dpr,
      work.top / _dpr,
      work.width / _dpr,
      work.height / _dpr,
    );
  }

  Rect _fallbackWorkArea() {
    final main = _mainWindowPhysical;
    if (main != null && main.width >= 1 && main.height >= 1) {
      return Rect.fromLTWH(
        0,
        0,
        main.right < 1920 ? 1920 : main.right,
        main.bottom < 1080 ? 1080 : main.bottom,
      );
    }
    return const Rect.fromLTWH(0, 0, 1920, 1080);
  }

  Rect _fallbackInputBar(Rect work) {
    final main = _mainWindowPhysical;
    final bandHeight = 120 * _dpr;
    if (main != null && main.height >= 1) {
      return Rect.fromLTWH(
        main.left,
        main.bottom - bandHeight,
        main.width,
        bandHeight,
      );
    }
    return Rect.fromLTWH(
      work.left,
      work.bottom - bandHeight,
      work.width,
      bandHeight,
    );
  }

  Future<DisplayInfo?> _targetDisplay(
    Rect? anchorPhysical, {
    Rect? fallback,
  }) async {
    List<DisplayInfo> displays;
    try {
      displays = await platform.displays();
    } catch (error) {
      debugPrint('answer displays failed: $error');
      return null;
    }
    if (displays.isEmpty) return null;
    final anchor = anchorPhysical ??
        fallback ??
        _inputBarPhysical ??
        _mainWindowPhysical;
    if (anchor == null || anchor.width < 1 || anchor.height < 1) {
      for (final display in displays) {
        if (display.isPrimary) return display;
      }
      return displays.first;
    }
    return FloatingWindowPlanner.chooseDisplay(displays, anchor) ??
        displays.first;
  }

  // -------------------------------------------------------------------------
  // 可观察性 / 生命周期工具
  // -------------------------------------------------------------------------

  int get _elapsedMs {
    final start = _startedAt;
    if (start == null) return 0;
    return DateTime.now().difference(start).inMilliseconds;
  }

  void _resetMirror(AnswerSubmission submission, String question) {
    _snapshot = AnswerSnapshot(
      conversationId: submission.conversationId,
      runId: submission.runId,
      question: question,
      status: AnswerStatus.thinking,
    );
    _answerBuffer = '';
    _status = AnswerStatus.thinking;
    _statusLabel = null;
    _approvalRequired = false;
    _plan.clear();
    _refs.clear();
    _error = null;
    _seq = 0;
    _startedAt = DateTime.now();
    _desiredHeightLogical = answerMinHeight;
    _appliedHeightLogical = 0;
    _lastContentHeight = null;
    _batcher?.dispose();
    _batcher = AnswerDeltaBatcher(
      onFlush: (text) => unawaited(_sendDelta(text)),
      throttle: streamThrottle,
    );
  }

  void _invokeFocusCompensation() {
    try {
      onFocusCompensation?.call();
    } catch (error) {
      debugPrint('answer focus compensation hook failed: $error');
    }
  }

  Future<void> _checkAlive() async {
    if (_checkingAlive) return;
    final handle = _handle;
    if (handle == null ||
        _state == AnswerWindowState.absent ||
        _state == AnswerWindowState.closing) {
      return;
    }
    _checkingAlive = true;
    try {
      final alive = await platform.isAlive(handle);
      if (!alive) {
        debugPrint('answer window closed externally (windowId=${handle.windowId})');
        _handle = null;
        final transport = _transport;
        _transport = null;
        _ready = null;
        _batcher?.dispose();
        _batcher = null;
        _heightTimer?.cancel();
        _heightTimer = null;
        _stabilizeTimer?.cancel();
        _stabilizeTimer = null;
        await transport?.dispose();
        await _finishAbsent();
      }
    } catch (error) {
      debugPrint('answer alive check failed: $error');
    } finally {
      _checkingAlive = false;
    }
  }

  Future<bool> _waitGone(AnswerWindowHandle handle, Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    var alive = true;
    while (DateTime.now().isBefore(deadline)) {
      try {
        alive = await platform.isAlive(handle);
      } catch (_) {
        alive = false;
      }
      if (!alive) return true;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    return !alive;
  }

  Future<void> _finishAbsent({bool notifyPresence = true}) async {
    _state = AnswerWindowState.absent;
    _collapsed = false;
    _hiddenByOwner = false;
    _userMoved = false;
    _userRectPhysical = null;
    _status = AnswerStatus.thinking;
    _statusLabel = null;
    _approvalRequired = false;
    _sentThemeMode = null;
    _sentThemeDark = null;
    if (notifyPresence) await _notifyPresence(false);
    notifyListeners();
  }

  Future<void> _abortCreate(String message) async {
    final handle = _handle;
    final transport = _transport;
    _handle = null;
    _transport = null;
    _ready = null;
    _batcher?.dispose();
    _batcher = null;
    _heightTimer?.cancel();
    _heightTimer = null;
    _stabilizeTimer?.cancel();
    _stabilizeTimer = null;
    _heightPending = false;
    await transport?.dispose();
    if (handle != null) {
      try {
        await platform.close(handle);
      } catch (_) {}
      await _waitGone(handle, closeTimeout);
    }
    await _finishAbsent();
    _raiseError(message);
  }

  Future<void> _notifyPresence(bool present) async {
    if (_presence == present) return;
    _presence = present;
    final callback = onPresenceChanged;
    if (callback != null) await callback(present);
  }

  void _raiseError(String message) {
    _lastTransportError = truncateAnswerError(message);
    onError?.call(message);
  }
}
