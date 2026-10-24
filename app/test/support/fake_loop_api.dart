import 'dart:async';
import 'dart:typed_data';

import 'package:loop/api.dart';
import 'package:loop/models.dart';
import 'package:loop/state.dart';

/// 假后端：不访问网络；chat() 返回可控的 SSE 事件流，upload() 返回 img_ 附件。
class FakeLoopApi extends LoopApi {
  FakeLoopApi() : super(baseUrl: 'http://127.0.0.1:1');

  final StreamController<SseEvent> events = StreamController<SseEvent>();
  final List<int> cancelledRuns = [];
  final List<(int, bool)> approvals = [];
  final List<Uint8List> uploads = [];
  int chatCalls = 0;
  int uploadCalls = 0;
  int createConversationCalls = 0;
  int messagesCalls = 0;

  /// 下一次 upload 抛错（模拟上传失败）。
  Object? uploadError;

  @override
  Future<List<Conversation>> conversations() async => [];

  @override
  Future<int> createConversation({String title = '新对话'}) async {
    createConversationCalls++;
    return 1;
  }

  @override
  Future<List<Message>> messages(int conversationId) async {
    messagesCalls++;
    return [];
  }

  @override
  Stream<SseEvent> chat({
    required int conversationId,
    required String text,
    List<String> attachments = const [],
    String mode = 'answer',
    String modePrompt = '',
    String thinking = 'medium',
  }) {
    chatCalls++;
    return events.stream;
  }

  @override
  Future<Map<String, dynamic>> upload(Uint8List bytes, String filename) async {
    final error = uploadError;
    if (error != null) throw error;
    uploadCalls++;
    uploads.add(bytes);
    return {
      'kind': 'image',
      'id': 'img_$uploadCalls',
      'name': filename,
    };
  }

  @override
  String imageUrl(String id) =>
      'http://127.0.0.1:1/api/uploads/${id.replaceFirst('img_', '')}';

  @override
  Future<void> cancelRun(int runId) async {
    cancelledRuns.add(runId);
  }

  @override
  Future<void> approveRun(int runId, bool allow) async {
    approvals.add((runId, allow));
  }
}

/// 构造带流式开关的 AppState（与 streaming_chat_test 一致的最小设置）。
AppState fakeAppState(FakeLoopApi api, {bool streamOutput = true}) {
  return AppState(api: api)
    ..settings = SettingsData(
      apiKeyMasked: '',
      hasKey: false,
      baseUrl: 'https://api.deepseek.com',
      model: 'deepseek-flash',
      reasonModel: 'deepseek-v4-pro',
      streamOutput: streamOutput,
    );
}
