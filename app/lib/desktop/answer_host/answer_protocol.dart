import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import '../window_mode.dart';

/// 回答浮窗 IPC 协议 v1（冻结接口；规格 §2.6）。
///
/// 传输：`desktop_multi_window` 的 [WindowMethodChannel]（native-mediated 本地
/// IPC，无监听端口）。通道名带 windowId 后缀，避免重开时旧注册冲突：
/// - 主 → 第二：`loop/answer.stream.v1.<windowId>`（第二窗注册 handler）
/// - 第二 → 主：`loop/answer.control.v1.<windowId>`（主窗注册 handler）
///
/// 本文件是纯 Dart（不依赖 Flutter 插件），主/第二引擎与单测共用。
const int answerProtocolVersion = 1;

const String answerStreamChannelPrefix = 'loop/answer.stream.v1.';
const String answerControlChannelPrefix = 'loop/answer.control.v1.';

String answerStreamChannel(String windowId) =>
    '$answerStreamChannelPrefix$windowId';

String answerControlChannel(String windowId) =>
    '$answerControlChannelPrefix$windowId';

/// 回答状态（wire 值见 [AnswerStatus.wire]）。
enum AnswerStatus {
  thinking('thinking'),
  streaming('streaming'),
  tool('tool'),
  waitingApproval('waiting_approval'),
  done('done'),
  stopped('stopped'),
  error('error');

  const AnswerStatus(this.wire);

  final String wire;

  bool get isTerminal => this == done || this == stopped || this == error;

  bool get isBusy =>
      this == thinking || this == streaming || this == tool || this == waitingApproval;

  static AnswerStatus? tryParse(String? value) {
    if (value == null) return null;
    for (final status in AnswerStatus.values) {
      if (status.wire == value) return status;
    }
    return null;
  }
}

// ---------------------------------------------------------------------------
// Launch payload（主引擎 → 第二引擎的 WindowConfiguration.arguments）
// ---------------------------------------------------------------------------

/// 第二引擎启动参数（JSON 字符串放入 `WindowConfiguration.arguments`）。
class AnswerLaunchPayload {
  const AnswerLaunchPayload({
    this.protocol = answerProtocolVersion,
    this.themeMode = 'system',
    this.dark = false,
    this.fontFamily = 'NotoSC',
  });

  final int protocol;

  /// `light` / `dark` / `system`（ThemeMode.name 语义）。
  final String themeMode;

  /// 首帧亮度（第二引擎不读 DB/设置）。
  final bool dark;

  final String fontFamily;

  bool get isCompatible => protocol == answerProtocolVersion;

  Map<String, Object?> toMap() => <String, Object?>{
        'protocol': protocol,
        'themeMode': themeMode,
        'dark': dark,
        'fontFamily': fontFamily,
      };

  String toJsonString() => jsonEncode(toMap());

  /// 解析失败/非回答窗入口（空参数）返回 null。
  static AnswerLaunchPayload? tryParse(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return AnswerLaunchPayload.fromMap(
        decoded.map((key, value) => MapEntry(key.toString(), value)),
      );
    } catch (_) {
      return null;
    }
  }

  factory AnswerLaunchPayload.fromMap(Map<String, Object?> map) {
    final dark = map['dark'];
    return AnswerLaunchPayload(
      protocol: _asInt(map['protocol']) ?? 0,
      themeMode: map['themeMode'] is String ? map['themeMode']! as String : 'system',
      dark: dark is bool ? dark : false,
      fontFamily:
          map['fontFamily'] is String ? map['fontFamily']! as String : 'NotoSC',
    );
  }

  @override
  String toString() =>
      'AnswerLaunchPayload(protocol=$protocol, themeMode=$themeMode, dark=$dark)';
}

// ---------------------------------------------------------------------------
// 快照 / 增量
// ---------------------------------------------------------------------------

/// 当前回答的全量镜像（主窗口唯一数据源；第二窗口只读）。
class AnswerSnapshot {
  const AnswerSnapshot({
    this.conversationId,
    this.runId,
    this.question = '',
    this.answerMarkdown = '',
    this.status = AnswerStatus.thinking,
    this.plan = const <Map<String, Object?>>[],
    this.refs = const <Map<String, Object?>>[],
    this.error,
    this.elapsedMs = 0,
    this.seq = 0,
  });

  final String? conversationId;
  final String? runId;
  final String question;
  final String answerMarkdown;
  final AnswerStatus status;
  final List<Map<String, Object?>> plan;
  final List<Map<String, Object?>> refs;

  /// 错误消息（≤200 字符；无错误为 null）。
  final String? error;

  final int elapsedMs;

  /// 发送该快照时的序号（见 [AnswerSeqTracker]）。
  final int seq;

  AnswerSnapshot copyWith({
    String? conversationId,
    String? runId,
    String? question,
    String? answerMarkdown,
    AnswerStatus? status,
    List<Map<String, Object?>>? plan,
    List<Map<String, Object?>>? refs,
    String? error,
    int? elapsedMs,
    int? seq,
    bool clearError = false,
  }) {
    return AnswerSnapshot(
      conversationId: conversationId ?? this.conversationId,
      runId: runId ?? this.runId,
      question: question ?? this.question,
      answerMarkdown: answerMarkdown ?? this.answerMarkdown,
      status: status ?? this.status,
      plan: plan ?? this.plan,
      refs: refs ?? this.refs,
      error: clearError ? null : (error ?? this.error),
      elapsedMs: elapsedMs ?? this.elapsedMs,
      seq: seq ?? this.seq,
    );
  }

  Map<String, Object?> toMap() => <String, Object?>{
        'seq': seq,
        'conversationId': conversationId,
        'runId': runId,
        'question': question,
        'answerMarkdown': answerMarkdown,
        'status': status.wire,
        'plan': plan,
        'refs': refs,
        'error': error,
        'elapsedMs': elapsedMs,
      };

  static AnswerSnapshot fromMap(Map<String, Object?> map) {
    return AnswerSnapshot(
      conversationId: map['conversationId'] is String
          ? map['conversationId']! as String
          : null,
      runId: map['runId'] is String ? map['runId']! as String : null,
      question: map['question'] is String ? map['question']! as String : '',
      answerMarkdown: map['answerMarkdown'] is String
          ? map['answerMarkdown']! as String
          : '',
      status: AnswerStatus.tryParse(map['status'] as String?) ??
          AnswerStatus.thinking,
      plan: _asMapList(map['plan']),
      refs: _asMapList(map['refs']),
      error: map['error'] is String ? map['error']! as String : null,
      elapsedMs: _asInt(map['elapsedMs']) ?? 0,
      seq: _asInt(map['seq']) ?? 0,
    );
  }

  @override
  String toString() => 'AnswerSnapshot(seq=$seq, status=$status, '
      'question=${question.length} chars, answer=${answerMarkdown.length} chars, '
      'error=$error)';
}

// ---------------------------------------------------------------------------
// 第二引擎入口会话
// ---------------------------------------------------------------------------

/// 第二引擎（回答窗）入口会话：窗口 id + 首帧 payload + IPC 传输。
class AnswerEngineSession {
  const AnswerEngineSession({
    required this.windowId,
    required this.payload,
    required this.transport,
  });

  final String windowId;
  final AnswerLaunchPayload payload;
  final AnswerTransport transport;

  @override
  String toString() =>
      'AnswerEngineSession(windowId=$windowId, payload=$payload)';
}

// ---------------------------------------------------------------------------
// 传输抽象（io 用 WindowMethodChannel；测试用 FakeAnswerTransport）
// ---------------------------------------------------------------------------

typedef AnswerMessageHandler = Future<Object?> Function(
  String method,
  Map<String, Object?> arguments,
);

/// 回答窗 IPC 传输。主引擎只用 [sendStream]/[setControlHandler]；
/// 第二引擎只用 [sendControl]/[setStreamHandler]。
abstract class AnswerTransport {
  bool get connected;

  Future<void> sendStream(String method, Map<String, Object?> arguments);

  Future<void> sendControl(String method, Map<String, Object?> arguments);

  Future<void> setStreamHandler(AnswerMessageHandler? handler);

  Future<void> setControlHandler(AnswerMessageHandler? handler);

  Future<void> dispose();
}

// ---------------------------------------------------------------------------
// seq / 重同步
// ---------------------------------------------------------------------------

/// IPC 序号跟踪（接收端）。快照重置；delta 必须连续，否则请求重同步。
class AnswerSeqTracker {
  int _lastSeq = 0;
  bool _hasSnapshot = false;
  bool _needsResync = false;

  int get lastSeq => _lastSeq;

  bool get hasSnapshot => _hasSnapshot;

  bool get needsResync => _needsResync;

  /// 发送端使用：下一条消息序号。
  int next() => ++_lastSeq;

  void onSnapshot(int seq) {
    _lastSeq = seq;
    _hasSnapshot = true;
    _needsResync = false;
  }

  bool onDelta(int seq) {
    if (!_hasSnapshot) {
      _needsResync = true;
      return false;
    }
    if (seq != _lastSeq + 1) {
      _needsResync = true;
      return false;
    }
    _lastSeq = seq;
    return true;
  }

  bool onStatus(int seq) {
    if (!_hasSnapshot) {
      _needsResync = true;
      return false;
    }
    if (seq != _lastSeq + 1) {
      // 状态不是正文增量，允许跳号后继续（但记录需要一次快照对齐）。
      if (seq > _lastSeq) _lastSeq = seq;
      _needsResync = true;
      return false;
    }
    _lastSeq = seq;
    return true;
  }

  void requestResync() {
    _needsResync = true;
  }

  void reset() {
    _lastSeq = 0;
    _hasSnapshot = false;
    _needsResync = false;
  }
}

// ---------------------------------------------------------------------------
// 节流 / 合批
// ---------------------------------------------------------------------------

/// 通用节流器：同一时间最多一个定时器，到期回调一次（默认 80ms）。
class AnswerThrottle {
  AnswerThrottle({
    required this.onDue,
    this.interval = answerStreamThrottle,
  });

  final void Function() onDue;
  final Duration interval;

  Timer? _timer;
  bool _running = false;
  bool _pending = false;

  bool get isScheduled => _timer != null;

  void schedule() {
    if (_running) {
      _pending = true;
      return;
    }
    if (_timer != null) return;
    _timer = Timer(interval, () {
      _timer = null;
      _running = true;
      try {
        onDue();
      } finally {
        _running = false;
      }
      if (_pending) {
        _pending = false;
        schedule();
      }
    });
  }

  void cancel() {
    _timer?.cancel();
    _timer = null;
    _running = false;
    _pending = false;
  }

  void dispose() => cancel();
}

/// SSE delta 合批器（80ms；首条立即发送，后续同窗口合并）。
class AnswerDeltaBatcher {
  AnswerDeltaBatcher({
    required this.onFlush,
    this.throttle = answerStreamThrottle,
    this.sendFirstImmediately = true,
  });

  final void Function(String text) onFlush;
  final Duration throttle;
  final bool sendFirstImmediately;

  final StringBuffer _buffer = StringBuffer();
  Timer? _timer;
  bool _sentAny = false;

  bool get hasPending => _buffer.isNotEmpty;

  void add(String text) {
    if (text.isEmpty) return;
    _buffer.write(text);
    if (_timer != null) return;
    if (sendFirstImmediately && !_sentAny) {
      _sentAny = true;
      _flush();
      // 立即发送后仍保留一个合批窗口，避免逐字刷新。
      _timer = Timer(throttle, () {
        _timer = null;
        _flush();
      });
      return;
    }
    _timer = Timer(throttle, () {
      _timer = null;
      _flush();
    });
  }

  void flushNow() {
    _timer?.cancel();
    _timer = null;
    _flush();
  }

  void reset() {
    _timer?.cancel();
    _timer = null;
    _buffer.clear();
    _sentAny = false;
  }

  void dispose() => reset();

  void _flush() {
    if (_buffer.isEmpty) return;
    final text = _buffer.toString();
    _buffer.clear();
    onFlush(text);
  }
}

// ---------------------------------------------------------------------------
// 编解码 helper
// ---------------------------------------------------------------------------

Map<String, Object?> encodeRect(Rect rect) => <String, Object?>{
      'left': rect.left,
      'top': rect.top,
      'width': rect.width,
      'height': rect.height,
    };

Rect? decodeRect(Object? value) {
  if (value is Map) {
    final left = _asDouble(value['left']);
    final top = _asDouble(value['top']);
    final width = _asDouble(value['width']);
    final height = _asDouble(value['height']);
    if (left != null && top != null && width != null && height != null) {
      return Rect.fromLTWH(left, top, width, height);
    }
    return null;
  }
  if (value is List && value.length == 4) {
    final left = _asDouble(value[0]);
    final top = _asDouble(value[1]);
    final width = _asDouble(value[2]);
    final height = _asDouble(value[3]);
    if (left != null && top != null && width != null && height != null) {
      return Rect.fromLTWH(left, top, width, height);
    }
  }
  return null;
}

Map<String, Object?> asStringMap(Object? value) {
  if (value is Map) {
    return value.map((key, value) => MapEntry(key.toString(), value));
  }
  return const <String, Object?>{};
}

/// 截断错误消息（规格 §4.6：≤200 字符）。
String truncateAnswerError(String message) {
  final normalized = message.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (normalized.length <= 200) return normalized;
  return '${normalized.substring(0, 199)}…';
}

int? _asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return null;
}

double? _asDouble(Object? value) {
  if (value is num) {
    final result = value.toDouble();
    return result.isFinite ? result : null;
  }
  return null;
}

List<Map<String, Object?>> _asMapList(Object? value) {
  if (value is List) {
    return value
        .whereType<Map>()
        .map((entry) => entry.map((key, value) => MapEntry(key.toString(), value)))
        .toList();
  }
  return const <Map<String, Object?>>[];
}
