import 'dart:async';
import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart';

import '../desktop/answer_host/answer_protocol.dart';
import '../desktop/window_mode.dart'
    show
        answerHeightEpsilon,
        answerMaxHeightCap,
        answerMinHeight,
        answerStreamThrottle,
        answerWidthMax,
        answerWidthMin;
import '../models.dart';
import 'answer_widgets.dart';

/// 第二引擎（回答窗）IPC 客户端：把主窗口推送的快照/增量解码为只读
/// [AnswerViewState]，并把测高/收起/关闭/拖动等动作经 control 通道发回主窗。
///
/// 规格 §2.5/§2.6/§4.3/§4.4：
/// - 只读：不 import AppState/LoopApi/backend，不做网络/DB；
/// - seq：快照重置、delta 必须连续，断档只请求一次重同步（[AnswerSeqTracker]）；
/// - 节流：流式正文通知 80ms 合并（首条立即），测高上报 80ms ±2px 去抖；
/// - 高度只在 [minHeight, maxHeight] 内上报，窗口改高由主引擎执行。
class AnswerClient extends ChangeNotifier {
  AnswerClient({
    required this.transport,
    required this.payload,
    required this.windowId,
    this.throttle = answerStreamThrottle,
  }) {
    _state = AnswerViewState(
      dark: payload.dark,
      fontFamily: payload.fontFamily,
      minHeight: answerMinHeight,
      maxHeight: answerMaxHeightCap,
    );
    unawaited(transport.setStreamHandler(_onStreamMessage));
    _heightThrottle = AnswerThrottle(onDue: _flushHeightReport, interval: throttle);
  }

  final AnswerTransport transport;
  final AnswerLaunchPayload payload;
  final String windowId;
  final Duration throttle;

  late AnswerThrottle _heightThrottle;
  final AnswerSeqTracker _incoming = AnswerSeqTracker();
  final AnswerSeqTracker _outgoing = AnswerSeqTracker();

  late AnswerViewState _state;

  Timer? _notifyTimer;
  DateTime _lastNotifyAt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _dirty = false;

  /// hello 中的固定宽度（主引擎负责窗口尺寸；UI 只读）。
  double widthLogical = answerWidthMin;

  /// hello 中的回答窗 HWND（第二引擎拖动 FFI 用；不可用时为 null）。
  int? windowHandle;

  /// 最近一次上报的窗口高度（去抖用）。
  double? _lastSentHeight;
  double? _pendingHeight;

  /// 主引擎确认后的高度（resize_ack 可观测）。
  double? appliedHeightLogical;

  /// 传输错误（显式记录，不向 UI 抛异步异常）。
  String? lastTransportError;

  /// 最近一次 ready 是否成功（失败时 UI 显示错误而不是空白窗）。
  bool readySent = false;

  bool _resyncRequested = false;

  /// 最近一次 snapshot 的会话/run 标识，用于区分“替换新问题”与
  /// plan/refs/resync 触发的非替换全量快照（T5-09）。
  String? _snapshotConversationId;
  String? _snapshotRunId;

  AnswerViewState get state => _state;

  /// 第二窗 UI 完成后调用；主窗收到 ready 后才定位/无激活显示。
  ///
  /// 通道注册与 handler 存在极短竞态（主窗 create 返回后才注册 control
  /// handler），因此按 100ms 退避重试 ≤1s（规格 §2.6）。
  Future<bool> sendReady({
    required double dpr,
    required Rect workAreaLogical,
    double contentHeightLogical = answerMinHeight,
    String? buildMode,
  }) async {
    final arguments = <String, Object?>{
      'protocol': answerProtocolVersion,
      'windowId': windowId,
      'dpr': dpr,
      'workAreaLogical': encodeRect(workAreaLogical),
      'contentHeightLogical': contentHeightLogical,
      'buildMode': buildMode ?? (kReleaseMode ? 'release' : 'debug'),
    };
    final deadline = DateTime.now().add(const Duration(seconds: 1));
    var delay = const Duration(milliseconds: 100);
    while (true) {
      try {
        await transport.sendControl('ready', arguments);
        readySent = true;
        return true;
      } catch (error) {
        lastTransportError = error.toString();
        if (!DateTime.now().isBefore(deadline)) break;
        await Future<void>.delayed(delay);
        delay = delay * 2 > const Duration(milliseconds: 200)
            ? const Duration(milliseconds: 200)
            : delay * 2;
      }
    }
    _state = _state.copyWith(
      status: 'error',
      statusLabel: '无法连接主窗口',
      error: '回答浮窗无法连接主窗口，请关闭后重试',
      hasSnapshot: true,
    );
    _notify(immediate: true);
    return false;
  }

  /// 上报可变正文内容高度（不含标题条/问题/状态/padding）；主窗
  /// `AnswerWindowPlanner` 加固定 chrome 后按 minH/maxH 钳制（规格 §4.3）。
  ///
  /// UI 侧只做 80ms 合并与 ±2px 去抖；不在这里做窗口尺寸钳制，避免与主窗
  /// 的 min/max 重复计算。
  void reportContentHeight(double contentHeight) {
    if (_state.collapsed || !contentHeight.isFinite || contentHeight < 0) return;
    final last = _lastSentHeight;
    if (last != null && (contentHeight - last).abs() < answerHeightEpsilon) return;
    _pendingHeight = contentHeight;
    _heightThrottle.schedule();
  }

  /// 立即发送待上报高度（收起/关闭/测试用）。
  Future<void> flushHeightReport() async {
    _heightThrottle.cancel();
    await _flushHeightReport();
  }

  Future<void> _flushHeightReport() async {
    final height = _pendingHeight;
    if (height == null) return;
    _pendingHeight = null;
    _lastSentHeight = height;
    await _sendControl('content_height', <String, Object?>{
      'seq': _outgoing.next(),
      'heightLogical': height,
    });
  }

  Future<void> requestCollapse() =>
      _sendControl('collapse_requested', const <String, Object?>{});

  Future<void> requestExpand() =>
      _sendControl('expand_requested', const <String, Object?>{});

  Future<void> requestClose() =>
      _sendControl('close_requested', const <String, Object?>{});

  Future<void> reportMoved(Rect physicalRect) => _sendControl(
        'moved',
        <String, Object?>{'physicalRect': encodeRect(physicalRect)},
      );

  Future<void> reportDragStarted() =>
      _sendControl('drag_started', const <String, Object?>{});

  Future<void> reportDragEnded() =>
      _sendControl('drag_ended', const <String, Object?>{});

  Future<void> reportRenderError(String code, String message) =>
      _sendControl('render_error', <String, Object?>{
        'code': code,
        'message': truncateAnswerError(message),
      });

  Future<void> requestResync() async {
    if (_resyncRequested) return;
    _resyncRequested = true;
    await _sendControl('resync_requested', <String, Object?>{
      'lastSeq': _incoming.lastSeq,
    });
  }

  Future<Object?> _onStreamMessage(
    String method,
    Map<String, Object?> arguments,
  ) async {
    switch (method) {
      case 'hello':
        _applyHello(arguments);
      case 'snapshot':
        _applySnapshot(arguments);
      case 'delta':
        _applyDelta(arguments);
      case 'status':
        _applyStatus(arguments);
      case 'presentation':
        _applyPresentation(arguments);
      case 'theme':
        _applyTheme(arguments);
      case 'resize_ack':
        appliedHeightLogical = _asDouble(arguments['heightLogical']);
        return null;
      default:
        // 未知方法忽略（v1 向前兼容；不打印正文）。
        return null;
    }
    return null;
  }

  void _applyHello(Map<String, Object?> arguments) {
    final protocol = _asInt(arguments['protocol']);
    if (protocol != null && protocol != answerProtocolVersion) {
      _state = _state.copyWith(
        status: 'error',
        statusLabel: '版本不兼容',
        error: '回答窗协议不兼容（主窗 $protocol，本窗 $answerProtocolVersion）',
        hasSnapshot: true,
      );
      _notify(immediate: true);
      return;
    }
    widthLogical = _asDouble(arguments['widthLogical']) ??
        (answerWidthMax + answerWidthMin) / 2;
    windowHandle = _asInt(arguments['hwnd']);
    final minH = _asDouble(arguments['minH']) ?? _state.minHeight;
    final maxH = _asDouble(arguments['maxH']) ?? _state.maxHeight;
    final dark = arguments['dark'] is bool
        ? arguments['dark']! as bool
        : arguments['themeMode'] == 'dark';
    final fontFamily = arguments['fontFamily'] is String
        ? arguments['fontFamily']! as String
        : _state.fontFamily;
    _state = _state.copyWith(
      minHeight: minH,
      maxHeight: maxH > minH ? maxH : minH,
      dark: dark,
      fontFamily: fontFamily,
    );
    _notify(immediate: true);
  }

  void _applySnapshot(Map<String, Object?> arguments) {
    final snapshot = AnswerSnapshot.fromMap(arguments);
    _incoming.onSnapshot(snapshot.seq);
    _resyncRequested = false;
    final previous = _state;
    final replacement = _isReplacementSnapshot(snapshot);
    _snapshotConversationId = snapshot.conversationId;
    _snapshotRunId = snapshot.runId;
    _state = AnswerViewState(
      question: snapshot.question,
      answer: snapshot.answerMarkdown,
      status: snapshot.status.wire,
      statusLabel: null,
      approvalRequired: snapshot.status == AnswerStatus.waitingApproval,
      plan: _plans(snapshot.plan),
      refs: _refs(snapshot.refs),
      error: snapshot.error,
      elapsedMs: snapshot.elapsedMs,
      collapsed: previous.collapsed,
      hasSnapshot: true,
      revision: previous.revision + 1,
      scrollResetToken:
          previous.scrollResetToken + (replacement ? 1 : 0),
      minHeight: previous.minHeight,
      maxHeight: previous.maxHeight,
      dark: previous.dark,
      fontFamily: previous.fontFamily,
      resyncing: false,
    );
    _lastSentHeight = null;
    _notify(immediate: true);
  }

  /// 只有新问题/新会话/新 run（或主窗替换语义的“空正文+thinking”快照）
  /// 才算替换；同一问题的 plan/refs/重同步快照必须保留用户滚动位置。
  bool _isReplacementSnapshot(AnswerSnapshot snapshot) {
    final previous = _state;
    if (!previous.hasSnapshot) return false;
    final questionChanged =
        previous.question.trim() != snapshot.question.trim();
    final conversationChanged = _snapshotConversationId != null &&
        snapshot.conversationId != null &&
        _snapshotConversationId != snapshot.conversationId;
    final runChanged = _snapshotRunId != null &&
        snapshot.runId != null &&
        _snapshotRunId != snapshot.runId;
    final looksLikeNewRun = snapshot.answerMarkdown.trim().isEmpty &&
        snapshot.status == AnswerStatus.thinking &&
        (previous.answer.trim().isNotEmpty || previous.status != 'thinking');
    return questionChanged ||
        conversationChanged ||
        runChanged ||
        looksLikeNewRun;
  }

  void _applyDelta(Map<String, Object?> arguments) {
    final seq = _asInt(arguments['seq']) ?? 0;
    final text = arguments['text'] is String ? arguments['text']! as String : '';
    if (!_incoming.onDelta(seq)) {
      _markResync();
      return;
    }
    if (text.isEmpty) return;
    _state = _state.copyWith(
      answer: _state.answer + text,
      status: _state.status == 'thinking' ? 'streaming' : _state.status,
      resyncing: false,
    );
    _notify();
  }

  void _applyStatus(Map<String, Object?> arguments) {
    final seq = _asInt(arguments['seq']) ?? 0;
    final status = AnswerStatus.tryParse(arguments['state'] as String?);
    final label = arguments['label'] is String ? arguments['label']! as String : null;
    final approvalRequired = arguments['approvalRequired'] == true;
    final accepted = _incoming.onStatus(seq);
    if (status == null) return;
    _state = _state.copyWith(
      status: status.wire,
      statusLabel: label,
      approvalRequired: approvalRequired || status == AnswerStatus.waitingApproval,
      resyncing: !accepted,
      elapsedMs: _asInt(arguments['elapsedMs']) ?? _state.elapsedMs,
    );
    if (!accepted) _markResync();
    _notify(immediate: true);
  }

  void _applyPresentation(Map<String, Object?> arguments) {
    final collapsed = arguments['collapsed'] == true;
    if (collapsed == _state.collapsed) return;
    _state = _state.copyWith(collapsed: collapsed);
    if (!collapsed) {
      // 展开后重新测高（收起期间窗口高度由主窗控制为 36）。
      _lastSentHeight = null;
    }
    _notify(immediate: true);
  }

  void _applyTheme(Map<String, Object?> arguments) {
    final dark = arguments['dark'] is bool
        ? arguments['dark']! as bool
        : arguments['themeMode'] == 'dark';
    if (dark == _state.dark) return;
    _state = _state.copyWith(dark: dark);
    _notify(immediate: true);
  }

  void _markResync() {
    if (!_state.resyncing) {
      _state = _state.copyWith(resyncing: true);
      _notify(immediate: true);
    }
    unawaited(requestResync());
  }

  Future<void> _sendControl(String method, Map<String, Object?> arguments) async {
    try {
      await transport.sendControl(method, arguments);
    } catch (error) {
      lastTransportError = error.toString();
    }
  }

  /// 流式增量 80ms 合并通知；首条/状态/快照立即通知。
  void _notify({bool immediate = false}) {
    _dirty = true;
    if (immediate) {
      _notifyTimer?.cancel();
      _notifyTimer = null;
      _flushNotify();
      return;
    }
    final elapsed = DateTime.now().difference(_lastNotifyAt);
    if (elapsed >= throttle) {
      _flushNotify();
      return;
    }
    _notifyTimer ??= Timer(throttle - elapsed, () {
      _notifyTimer = null;
      _flushNotify();
    });
  }

  void _flushNotify() {
    if (!_dirty) return;
    _dirty = false;
    _lastNotifyAt = DateTime.now();
    notifyListeners();
  }

  @override
  void dispose() {
    _notifyTimer?.cancel();
    _notifyTimer = null;
    _heightThrottle.dispose();
    unawaited(transport.setStreamHandler(null));
    unawaited(transport.dispose());
    super.dispose();
  }

  static List<PlanItem> _plans(List<Map<String, Object?>> raw) {
    return [
      for (final item in raw) PlanItem.fromJson(Map<String, dynamic>.from(item)),
    ];
  }

  static List<RefItem> _refs(List<Map<String, Object?>> raw) {
    return [
      for (final item in raw) RefItem.fromJson(Map<String, dynamic>.from(item)),
    ];
  }

  static int? _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return null;
  }

  static double? _asDouble(Object? value) {
    if (value is num) return value.toDouble();
    return null;
  }
}
