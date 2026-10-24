import 'answer_protocol.dart';

/// Web/非桌面占位：没有第二顶层窗口。
///
/// 与 `answer_transport_io.dart` 保持同签名，主入口可条件导入：
/// ```dart
/// import 'desktop/answer_host/answer_transport_stub.dart'
///     if (dart.library.io) 'desktop/answer_host/answer_transport_io.dart';
/// ```
Future<AnswerEngineSession?> prepareAnswerEngine() async => null;
