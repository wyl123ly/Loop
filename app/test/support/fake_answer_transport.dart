import 'dart:async';

import 'package:loop/desktop/answer_host/answer_protocol.dart';

/// 一条已发送的 IPC 消息。
class SentAnswerMessage {
  const SentAnswerMessage(this.method, this.arguments);

  final String method;
  final Map<String, Object?> arguments;

  Object? operator [](String key) => arguments[key];

  @override
  String toString() => 'SentAnswerMessage($method, $arguments)';
}

/// 可编程的 IPC transport fake（t2 提供，t3 可复用）。
class FakeAnswerTransport implements AnswerTransport {
  final List<SentAnswerMessage> streamMessages = [];
  final List<SentAnswerMessage> controlMessages = [];

  AnswerMessageHandler? _streamHandler;
  AnswerMessageHandler? _controlHandler;

  bool _connected = true;
  bool disposed = false;

  /// 非 null 时 send* 抛出该错误（断线容错测试）。
  Object? sendError;

  /// 每次 send 的统一延迟。
  Duration? sendDelay;

  @override
  bool get connected => _connected;

  void setConnected(bool value) => _connected = value;

  bool get hasStreamHandler => _streamHandler != null;

  bool get hasControlHandler => _controlHandler != null;

  @override
  Future<void> sendStream(
    String method,
    Map<String, Object?> arguments,
  ) async {
    if (sendDelay != null) await Future<void>.delayed(sendDelay!);
    final error = sendError;
    if (error != null) {
      _connected = false;
      throw error;
    }
    streamMessages.add(SentAnswerMessage(method, Map<String, Object?>.of(arguments)));
  }

  @override
  Future<void> sendControl(
    String method,
    Map<String, Object?> arguments,
  ) async {
    if (sendDelay != null) await Future<void>.delayed(sendDelay!);
    final error = sendError;
    if (error != null) {
      _connected = false;
      throw error;
    }
    controlMessages.add(SentAnswerMessage(method, Map<String, Object?>.of(arguments)));
  }

  @override
  Future<void> setStreamHandler(AnswerMessageHandler? handler) async {
    _streamHandler = handler;
  }

  @override
  Future<void> setControlHandler(AnswerMessageHandler? handler) async {
    _controlHandler = handler;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    _streamHandler = null;
    _controlHandler = null;
  }

  /// 模拟第二窗口 → 主窗口的控制消息。
  Future<void> emitControl(
    String method, [
    Map<String, Object?> arguments = const <String, Object?>{},
  ]) async {
    final handler = _controlHandler;
    if (handler == null) {
      throw StateError('no control handler registered');
    }
    await handler(method, arguments);
  }

  /// 模拟主窗口 → 第二窗口的流消息（测试 answer_client 时可用）。
  Future<void> emitStream(
    String method, [
    Map<String, Object?> arguments = const <String, Object?>{},
  ]) async {
    final handler = _streamHandler;
    if (handler == null) {
      throw StateError('no stream handler registered');
    }
    await handler(method, arguments);
  }

  List<SentAnswerMessage> messagesOf(String method) =>
      streamMessages.where((message) => message.method == method).toList();

  SentAnswerMessage? lastOf(String method) {
    final matches = messagesOf(method);
    return matches.isEmpty ? null : matches.last;
  }

  void clear() {
    streamMessages.clear();
    controlMessages.clear();
  }
}
