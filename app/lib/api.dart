import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'models.dart';

class ApiException implements Exception {
  ApiException(this.message, [this.statusCode = 0]);

  final String message;
  final int statusCode;

  @override
  String toString() => message;
}

class SseEvent {
  SseEvent(this.event, this.data);

  final String event;
  final Map<String, dynamic> data;
}

class LoopApi {
  LoopApi({String? baseUrl}) : baseUrl = baseUrl ?? defaultBaseUrl;

  static const String _override = String.fromEnvironment('API_BASE');

  static String get defaultBaseUrl {
    if (_override.isNotEmpty) return _override;
    if (kIsWeb) {
      final origin = Uri.base;
      if (origin.port == 8765) return origin.origin;
      return 'http://127.0.0.1:8765';
    }
    return 'http://127.0.0.1:8765';
  }

  final String baseUrl;
  final http.Client _client = http.Client();

  Map<String, String> get _headers => {'Content-Type': 'application/json; charset=utf-8'};

  Uri _uri(String path, [Map<String, dynamic>? query]) {
    final uri = Uri.parse('$baseUrl$path');
    if (query == null || query.isEmpty) return uri;
    final params = <String, String>{};
    query.forEach((key, value) {
      if (value != null && value != '') params[key] = '$value';
    });
    return uri.replace(queryParameters: {...uri.queryParameters, ...params});
  }

  String _detail(http.Response response) {
    try {
      final data = jsonDecode(utf8.decode(response.bodyBytes));
      if (data is Map && data['detail'] != null) return data['detail'].toString();
      if (data is Map && data['message'] != null) return data['message'].toString();
    } catch (_) {}
    return '请求失败（${response.statusCode}）';
  }

  Future<dynamic> _request(
    String method,
    String path, {
    Object? body,
    Map<String, dynamic>? query,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final uri = _uri(path, query);
    http.Response response;
    try {
      final encoded = body == null ? null : jsonEncode(body);
      switch (method) {
        case 'GET':
          response = await _client.get(uri).timeout(timeout);
          break;
        case 'POST':
          response = await _client.post(uri, headers: _headers, body: encoded).timeout(timeout);
          break;
        case 'PUT':
          response = await _client.put(uri, headers: _headers, body: encoded).timeout(timeout);
          break;
        case 'PATCH':
          response = await _client.patch(uri, headers: _headers, body: encoded).timeout(timeout);
          break;
        default:
          response = await _client.delete(uri, headers: _headers).timeout(timeout);
      }
    } on TimeoutException {
      throw ApiException('请求超时了，稍后再试。');
    } catch (error) {
      throw ApiException('连不上本地服务（$baseUrl）。确认 start.bat 还开着，然后刷新页面。');
    }
    if (response.statusCode >= 400) {
      throw ApiException(_detail(response), response.statusCode);
    }
    if (response.bodyBytes.isEmpty) return null;
    return jsonDecode(utf8.decode(response.bodyBytes));
  }

  Future<Map<String, dynamic>> health() async =>
      (await _request('GET', '/api/health')) as Map<String, dynamic>;

  Future<SettingsData> settings() async =>
      SettingsData.fromJson((await _request('GET', '/api/settings')) as Map<String, dynamic>);

  Future<SettingsData> saveSettings({
    String? apiKey,
    String? baseUrl,
    String? model,
    String? reasonModel,
    String? activeProvider,
    String? providersJson,
    String? theme,
    String? customModes,
    bool? autoCheckUpdates,
    bool? sidebarCollapsed,
    bool? streamOutput,
  }) async {
    final payload = <String, dynamic>{};
    if (apiKey != null && apiKey.isNotEmpty) payload['api_key'] = apiKey;
    if (baseUrl != null && baseUrl.isNotEmpty) payload['base_url'] = baseUrl;
    if (model != null && model.isNotEmpty) payload['model'] = model;
    if (reasonModel != null && reasonModel.isNotEmpty) payload['reason_model'] = reasonModel;
    if (activeProvider != null && activeProvider.isNotEmpty) {
      payload['active_provider'] = activeProvider;
    }
    if (providersJson != null && providersJson.isNotEmpty) {
      payload['providers'] = providersJson;
    }
    if (theme != null && theme.isNotEmpty) payload['theme'] = theme;
    if (customModes != null) payload['custom_modes'] = customModes;
    if (autoCheckUpdates != null) payload['auto_check_updates'] = autoCheckUpdates;
    if (sidebarCollapsed != null) payload['sidebar_collapsed'] = sidebarCollapsed;
    if (streamOutput != null) payload['stream_output'] = streamOutput;
    return SettingsData.fromJson(
      (await _request('PUT', '/api/settings', body: payload)) as Map<String, dynamic>,
    );
  }

  Future<AgentSettingsData> agentSettings() async =>
      AgentSettingsData.fromJson((await _request('GET', '/api/agent/settings')) as Map<String, dynamic>);

  Future<void> saveAgentSettings({
    String? workspacePath,
    bool? shell,
    bool? browser,
    bool? mcp,
    bool? background,
  }) async {
    await _request('POST', '/api/agent/settings', body: {
      'workspace_path': ?workspacePath,
      'shell': ?shell,
      'browser': ?browser,
      'mcp': ?mcp,
      'background': ?background,
    });
  }

  Future<void> openWorkspace() async {
    await _request('POST', '/api/agent/open-workspace', body: {});
  }

  Future<List<McpServerItem>> mcpServers() async {
    final data = (await _request('GET', '/api/mcp/servers') as List)
        .whereType<Map>()
        .map((e) => McpServerItem.fromJson(Map<String, dynamic>.from(e)))
        .toList();
    return data;
  }

  Future<void> addMcpServer({
    required String name,
    required String transport,
    String command = '',
    String args = '[]',
    String url = '',
    String env = '{}',
    String workingDirectory = '',
  }) async {
    await _request('POST', '/api/mcp/servers', body: {
      'name': name,
      'transport': transport,
      'command': command,
      'args': args,
      'env': env,
      'working_directory': workingDirectory,
      'url': url,
    });
  }

  Future<void> setMcpEnabled(int id, bool enabled) async {
    await _request('PATCH', '/api/mcp/servers/$id', body: {'enabled': enabled});
  }

  Future<void> deleteMcpServer(int id) async {
    await _request('DELETE', '/api/mcp/servers/$id');
  }

  Future<Map<String, dynamic>> testMcpServer(int id) async =>
      (await _request('POST', '/api/mcp/servers/$id/test', body: {})) as Map<String, dynamic>;

  Future<List<AgentJob>> jobs() async {
    final data = (await _request('GET', '/api/jobs') as List)
        .whereType<Map>()
        .map((e) => AgentJob.fromJson(Map<String, dynamic>.from(e)))
        .toList();
    return data;
  }

  Future<void> addJob({
    required String title,
    required String prompt,
    required String scheduleKind,
    required String scheduleValue,
  }) async {
    await _request('POST', '/api/jobs', body: {
      'title': title,
      'prompt': prompt,
      'schedule_kind': scheduleKind,
      'schedule_value': scheduleValue,
    });
  }

  Future<void> setJobEnabled(int id, bool enabled) async {
    await _request('PATCH', '/api/jobs/$id', body: {'enabled': enabled});
  }

  Future<void> deleteJob(int id) async {
    await _request('DELETE', '/api/jobs/$id');
  }

  Future<void> runJob(int id) async {
    await _request('POST', '/api/jobs/$id/run', body: {});
  }

  Future<List<AuditItem>> audits() async {
    final data = (await _request('GET', '/api/audit?limit=100') as List)
        .whereType<Map>()
        .map((e) => AuditItem.fromJson(Map<String, dynamic>.from(e)))
        .toList();
    return data;
  }

  Future<void> approveRun(int runId, bool allow) async {
    await _request('POST', '/api/agent/approve', body: {'run_id': runId, 'allow': allow});
  }

  Future<void> cancelRun(int runId) async {
    await _request('POST', '/api/agent/cancel', body: {'run_id': runId});
  }

  Future<Map<String, dynamic>> testSettings({String? providerId, String? model}) async =>
      (await _request('POST', '/api/settings/test', body: {
        'provider_id': ?providerId,
        'model': ?model,
      })) as Map<String, dynamic>;

  Future<List<Conversation>> conversations() async {
    final data = (await _request('GET', '/api/conversations') as List)
        .whereType<Map>()
        .map((e) => Conversation.fromJson(Map<String, dynamic>.from(e)))
        .toList();
    return data;
  }

  Future<int> createConversation({String title = '新对话'}) async {
    final data = await _request('POST', '/api/conversations',
        body: {'title': title}) as Map<String, dynamic>;
    return data['id'] as int;
  }

  Future<void> deleteConversation(int id) async {
    await _request('DELETE', '/api/conversations/$id');
  }

  Future<List<Message>> messages(int conversationId) async {
    final data = (await _request('GET', '/api/conversations/$conversationId/messages') as List)
        .whereType<Map>()
        .map((e) => Message.fromJson(Map<String, dynamic>.from(e)))
        .toList();
    return data;
  }

  Stream<SseEvent> chat({
    required int conversationId,
    required String text,
    List<String> attachments = const [],
    String mode = 'answer',
    String modePrompt = '',
    String thinking = 'medium',
  }) async* {
    final request = http.Request('POST', Uri.parse('$baseUrl/api/chat'));
    request.headers.addAll(_headers);
    request.body = jsonEncode({
      'conversation_id': conversationId,
      'text': text,
      'attachments': attachments,
      'mode': mode,
      'mode_prompt': modePrompt,
      'thinking': thinking,
    });

    http.StreamedResponse response;
    try {
      response = await _client.send(request);
    } catch (_) {
      throw ApiException('连不上本地服务（$baseUrl）。');
    }
    if (response.statusCode >= 400) {
      final body = await response.stream.bytesToString();
      String message = '请求失败（${response.statusCode}）';
      try {
        final data = jsonDecode(body);
        if (data is Map && data['detail'] != null) message = data['detail'].toString();
      } catch (_) {}
      throw ApiException(message, response.statusCode);
    }

    String event = '';
    final buffer = StringBuffer();
    await for (final line
        in response.stream.transform(utf8.decoder).transform(const LineSplitter())) {
      if (line.isEmpty) {
        if (buffer.isNotEmpty) {
          try {
            yield SseEvent(
              event.isEmpty ? 'message' : event,
              jsonDecode(buffer.toString()) as Map<String, dynamic>,
            );
          } catch (_) {}
        }
        event = '';
        buffer.clear();
        continue;
      }
      if (line.startsWith('event:')) {
        event = line.substring(6).trim();
      } else if (line.startsWith('data:')) {
        if (buffer.isNotEmpty) buffer.write('\n');
        buffer.write(line.substring(5).trim());
      }
    }
    if (buffer.isNotEmpty) {
      try {
        yield SseEvent(
          event.isEmpty ? 'message' : event,
          jsonDecode(buffer.toString()) as Map<String, dynamic>,
        );
      } catch (_) {}
    }
  }

  String imageUrl(String attachmentId) {
    final numeric = attachmentId.startsWith('img_')
        ? attachmentId.substring(4)
        : attachmentId;
    return '$baseUrl/api/uploads/$numeric';
  }

  Future<Map<String, dynamic>> upload(Uint8List bytes, String filename) async {
    http.Response response;
    try {
      response = await _client
          .post(
            Uri.parse('$baseUrl/api/upload'),
            headers: {
              'Content-Type': 'application/octet-stream',
              'X-Filename': Uri.encodeComponent(filename),
            },
            body: bytes,
          )
          .timeout(const Duration(minutes: 3));
    } on TimeoutException {
      throw ApiException('文件解析超时，换个小一点的文件试试。');
    } catch (_) {
      throw ApiException('上传失败：连不上本地服务。');
    }
    if (response.statusCode >= 400) {
      throw ApiException(_detail(response), response.statusCode);
    }
    return jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
  }

  Future<List<MaterialFolder>> materialFolders() async {
    final data = (await _request('GET', '/api/materials/folders') as List)
        .whereType<Map>()
        .map((e) => MaterialFolder.fromJson(Map<String, dynamic>.from(e)))
        .toList();
    return data;
  }

  Future<void> deleteMaterialFolder(int id) async {
    await _request('DELETE', '/api/materials/folders/$id');
  }

  Future<Map<String, dynamic>> scanFolder(String path, {bool recursive = true}) async =>
      (await _request('POST', '/api/materials/scan', body: {
        'path': path,
        'recursive': recursive,
      })) as Map<String, dynamic>;

  Future<void> cancelFolderImport(String token) async {
    await _request('POST', '/api/materials/import-cancel', body: {'token': token});
  }

  Stream<SseEvent> importFolder({
    required String path,
    required bool recursive,
    required String duplicate,
    required String token,
  }) async* {
    final request = http.Request('POST', Uri.parse('$baseUrl/api/materials/import'));
    request.headers.addAll(_headers);
    request.body = jsonEncode({
      'path': path,
      'recursive': recursive,
      'duplicate': duplicate,
      'token': token,
    });
    http.StreamedResponse response;
    try {
      response = await _client.send(request);
    } catch (_) {
      throw ApiException('连不上本地服务（$baseUrl）。');
    }
    if (response.statusCode >= 400) {
      final body = await response.stream.bytesToString();
      String message = '导入失败（${response.statusCode}）';
      try {
        final data = jsonDecode(body);
        if (data is Map && data['detail'] != null) message = data['detail'].toString();
      } catch (_) {}
      throw ApiException(message, response.statusCode);
    }
    var event = '';
    final buffer = StringBuffer();
    await for (final line
        in response.stream.transform(utf8.decoder).transform(const LineSplitter())) {
      if (line.isEmpty) {
        if (buffer.isNotEmpty) {
          try {
            yield SseEvent(
              event.isEmpty ? 'message' : event,
              jsonDecode(buffer.toString()) as Map<String, dynamic>,
            );
          } catch (_) {}
        }
        event = '';
        buffer.clear();
        continue;
      }
      if (line.startsWith('event:')) {
        event = line.substring(6).trim();
      } else if (line.startsWith('data:')) {
        if (buffer.isNotEmpty) buffer.write('\n');
        buffer.write(line.substring(5).trim());
      }
    }
    if (buffer.isNotEmpty) {
      try {
        yield SseEvent(event.isEmpty ? 'message' : event,
            jsonDecode(buffer.toString()) as Map<String, dynamic>);
      } catch (_) {}
    }
  }

  Future<List<MaterialItem>> materials() async {
    final data = (await _request('GET', '/api/materials') as List)
        .whereType<Map>()
        .map((e) => MaterialItem.fromJson(Map<String, dynamic>.from(e)))
        .toList();
    return data;
  }

  Future<Map<String, dynamic>> materialPreview(int id) async =>
      (await _request('GET', '/api/materials/$id/preview')) as Map<String, dynamic>;

  Future<void> deleteMaterial(int id) async {
    await _request('DELETE', '/api/materials/$id');
  }

  Future<TodayData> today() async {
    return TodayData.fromJson(
      (await _request('GET', '/api/today')) as Map<String, dynamic>,
    );
  }

  Future<List<TaskItem>> tasks({String? date, String? status}) async {
    final data = (await _request('GET', '/api/tasks', query: {
      'date_str': date,
      'status': status,
    }) as List)
        .whereType<Map>()
        .map((e) => TaskItem.fromJson(Map<String, dynamic>.from(e)))
        .toList();
    return data;
  }

  Future<int> createTask({
    required String title,
    String due = '',
    int estimateMin = 30,
  }) async {
    final data = await _request('POST', '/api/tasks', body: {
      'title': title,
      'due': due,
      'estimate_min': estimateMin,
    }) as Map<String, dynamic>;
    return data['id'] as int;
  }

  Future<void> patchTask(int id, Map<String, dynamic> fields) async {
    await _request('PATCH', '/api/tasks/$id', body: fields);
  }

  Future<void> deleteTask(int id) async {
    await _request('DELETE', '/api/tasks/$id');
  }

  Future<Map<String, dynamic>> generate(String kind, int messageId) async {
    return (await _request('POST', '/api/generate/$kind',
        body: {'message_id': messageId},
        timeout: const Duration(minutes: 2))) as Map<String, dynamic>;
  }

  Future<List<NoteItem>> notes() async {
    return (await _request('GET', '/api/notes') as List)
        .whereType<Map>()
        .map((e) => NoteItem.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  Future<void> deleteNote(int id) async {
    await _request('DELETE', '/api/notes/$id');
  }
}
