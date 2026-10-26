import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'models.dart';

class ApiException implements Exception {
  ApiException(this.message, [this.statusCode = 0, this.code = '']);

  final String message;
  final int statusCode;

  /// 结构化错误码（技能类接口用；缺省空串，不影响既有调用方）。
  final String code;

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

  /// 显式学科作用域（§11.1）：非空时本实例所有请求都带 `?subject=<key>`。
  /// 缺省 `null` → 后端按 `settings.active_subject` 解析，即"当前学科"。
  /// 用 [AppState.switchSubject] 切换学科，或直接设置本字段做显式取数。
  String? subjectScope;

  Map<String, String> get _headers => {'Content-Type': 'application/json; charset=utf-8'};

  Uri _uri(String path, [Map<String, dynamic>? query]) {
    final uri = Uri.parse('$baseUrl$path');
    final merged = <String, dynamic>{};
    final scope = subjectScope;
    if (scope != null && scope.isNotEmpty) merged['subject'] = scope;
    if (query != null) merged.addAll(query);
    if (merged.isEmpty) return uri;
    final params = <String, String>{};
    merged.forEach((key, value) {
      if (value != null && value != '') params[key] = '$value';
    });
    if (params.isEmpty) return uri;
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

  /// 后端结构化错误码（`{ok:false, code:…}`）；取不到返回空串。
  String _errorCode(http.Response response) {
    try {
      final data = jsonDecode(utf8.decode(response.bodyBytes));
      if (data is Map && data['code'] != null) return data['code'].toString();
    } catch (_) {}
    return '';
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
      throw ApiException(_detail(response), response.statusCode, _errorCode(response));
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
    String? activeSubject,
    bool? crossSubjectSearch,
    bool? subjectMigrationNoticeSeen,
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
    if (activeSubject != null && activeSubject.isNotEmpty) {
      payload['active_subject'] = activeSubject;
    }
    if (crossSubjectSearch != null) payload['cross_subject_search'] = crossSubjectSearch;
    if (subjectMigrationNoticeSeen != null) {
      payload['subject_migration_notice_seen'] = subjectMigrationNoticeSeen;
    }
    return SettingsData.fromJson(
      (await _request('PUT', '/api/settings', body: payload)) as Map<String, dynamic>,
    );
  }

  /// F-11：设置页「数据与迁移」用——把迁移状态 + 一次性提示标记一次取回。
  Future<MigrationOverview> migrationOverview() async {
    final status = await migrationStatus();
    final settings = await this.settings();
    return MigrationOverview.fromJson(status, settings);
  }

  Future<AgentSettingsData> agentSettings() async =>
      AgentSettingsData.fromJson((await _request('GET', '/api/agent/settings')) as Map<String, dynamic>);

  Future<void> saveAgentSettings({
    String? workspacePath,
    bool? shell,
    bool? browser,
    bool? mcp,
    bool? background,
    String? approval,
  }) async {
    await _request('POST', '/api/agent/settings', body: {
      'workspace_path': ?workspacePath,
      'shell': ?shell,
      'browser': ?browser,
      'mcp': ?mcp,
      'background': ?background,
      'approval': ?approval,
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

  Future<Map<String, dynamic>> fetchModels({String? providerId}) async =>
      (await _request('POST', '/api/settings/models', body: {
        'provider_id': ?providerId,
      })) as Map<String, dynamic>;

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
    final request = http.Request('POST', _uri('/api/chat'));
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
            _uri('/api/upload'),
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
    final request = http.Request('POST', _uri('/api/materials/import'));
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

  Future<List<MaterialItem>> materials({String? subject}) async {
    final data = (await _request('GET', '/api/materials', query: {'subject': subject}) as List)
        .whereType<Map>()
        .map((e) => MaterialItem.fromJson(Map<String, dynamic>.from(e)))
        .toList();
    return data;
  }

  Future<Map<String, dynamic>> materialPreview(int id, {String? subject}) async =>
      (await _request('GET', '/api/materials/$id/preview', query: {'subject': subject}))
          as Map<String, dynamic>;

  Future<void> deleteMaterial(int id, {String? subject}) async {
    await _request('DELETE', '/api/materials/$id', query: {'subject': subject});
  }

  Future<TodayData> today({String? subject}) async {
    return TodayData.fromJson(
      (await _request('GET', '/api/today', query: {'subject': subject})) as Map<String, dynamic>,
    );
  }

  Future<List<TaskItem>> tasks({String? date, String? status, String? subject}) async {
    final data = (await _request('GET', '/api/tasks', query: {
      'date_str': date,
      'status': status,
      'subject': subject,
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

  Future<List<NoteItem>> notes({String? subject}) async {
    return (await _request('GET', '/api/notes', query: {'subject': subject}) as List)
        .whereType<Map>()
        .map((e) => NoteItem.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  Future<void> deleteNote(int id, {String? subject}) async {
    await _request('DELETE', '/api/notes/$id', query: {'subject': subject});
  }

  // ---------------------------------------------------------------- 学科（§11.2）

  /// 学科列表；`includeArchived` 为真时含归档学科。
  Future<List<Subject>> subjects({bool includeArchived = false, bool counts = false}) async {
    final data = (await _request('GET', '/api/subjects', query: {
      'include_archived': includeArchived ? 'true' : null,
      'counts': counts ? 'true' : null,
    }) as List)
        .whereType<Map>()
        .map((e) => Subject.fromJson(Map<String, dynamic>.from(e)))
        .toList();
    return data;
  }

  Future<Subject> createSubject({
    required String name,
    String description = '',
    String goal = '',
    String examDate = '',
    int dailyMinutes = 0,
    String icon = '',
    String color = '',
    String level = '',
  }) async {
    final body = <String, dynamic>{
      'name': name,
      'description': description,
      'goal': goal,
      'exam_date': examDate,
      'daily_minutes': dailyMinutes,
      'icon': icon,
      'color': color,
      'level': level,
    };
    return Subject.fromJson(
      (await _request('POST', '/api/subjects', body: body)) as Map<String, dynamic>,
    );
  }

  Future<Subject> patchSubject(int id, Map<String, dynamic> fields) async {
    return Subject.fromJson(
      (await _request('PATCH', '/api/subjects/$id', body: fields)) as Map<String, dynamic>,
    );
  }

  Future<Subject> archiveSubject(int id) async {
    return Subject.fromJson(
      (await _request('POST', '/api/subjects/$id/archive', body: {})) as Map<String, dynamic>,
    );
  }

  Future<Subject> restoreSubject(int id) async {
    return Subject.fromJson(
      (await _request('POST', '/api/subjects/$id/restore', body: {})) as Map<String, dynamic>,
    );
  }

  Future<Map<String, dynamic>> deleteSubject(int id, {required String confirm}) async {
    return (await _request('DELETE', '/api/subjects/$id', query: {'confirm': confirm}))
        as Map<String, dynamic>;
  }

  /// 重建空库 / 移除注册记录（`integrity` 异常时的显式操作，§4.8）。
  Future<Subject> rebuildEmptySubject(int id) async {
    return Subject.fromJson(
      (await _request('POST', '/api/subjects/$id/rebuild-empty', body: {})) as Map<String, dynamic>,
    );
  }

  Future<void> removeSubjectRegistryRow(int id) async {
    await _request('POST', '/api/subjects/$id/remove-registry', body: {});
  }

  Future<Subject> activeSubject() async =>
      Subject.fromJson((await _request('GET', '/api/subjects/active')) as Map<String, dynamic>);

  Future<Subject> setActiveSubject(String subject) async {
    final data = await _request('PUT', '/api/subjects/active', body: {'subject': subject})
        as Map<String, dynamic>;
    if (data['subject'] is Map) {
      return Subject.fromJson(Map<String, dynamic>.from(data['subject'] as Map));
    }
    return activeSubject();
  }

  /// 学科目录（设置页"打开目录"用；仅本机回环）。
  Future<Map<String, dynamic>> subjectPath(int id) async =>
      (await _request('GET', '/api/subjects/$id/path')) as Map<String, dynamic>;

  Future<Map<String, dynamic>> subjectDiagnostics(int id) async =>
      (await _request('GET', '/api/diagnostics/subject/$id')) as Map<String, dynamic>;

  // ---------------------------------------------------------------- 学习进度（§11.4）

  Future<SubjectProgress> subjectProgress(int id, {int? limit, int? offset}) async =>
      SubjectProgress.fromJson((await _request('GET', '/api/subjects/$id/progress', query: {
        'limit': limit,
        'offset': offset,
      })) as Map<String, dynamic>);

  Future<SubjectProgress> patchSubjectProgress(int id, Map<String, dynamic> payload) async =>
      SubjectProgress.fromJson(
        (await _request('PATCH', '/api/subjects/$id/progress', body: payload))
            as Map<String, dynamic>,
      );

  Future<Map<String, dynamic>> subjectProgressEvents(int id, List<Map<String, dynamic>> events) async =>
      (await _request('POST', '/api/subjects/$id/progress/events', body: {'events': events}))
          as Map<String, dynamic>;

  Future<Map<String, dynamic>> recomputeSubjectProgress(int id) async =>
      (await _request('POST', '/api/subjects/$id/progress/recompute', body: {}))
          as Map<String, dynamic>;

  Future<void> deleteTopic(int id, int topicId) async {
    await _request('DELETE', '/api/subjects/$id/progress/topics/$topicId');
  }

  // ---------------------------------------------------------------- 迁移（§11.6）

  Future<Map<String, dynamic>> migrationStatus() async =>
      (await _request('GET', '/api/migrations/status')) as Map<String, dynamic>;

  Future<Map<String, dynamic>> runMigration() async =>
      (await _request('POST', '/api/migrations/run', body: {})) as Map<String, dynamic>;

  // ---------------------------------------------------------------- 教学技能（§9）

  /// 本学科「已安装」视图：**纯本地读取，离线可用**。
  Future<SkillLibraryData> skillLibrary() async => SkillLibraryData.fromJson(
      (await _request('GET', '/api/skills')) as Map<String, dynamic>);

  /// 浏览 registry。仅在用户主动打开「从 EduHub 添加」时调用——不存在
  /// 自动拉取/后台更新。`hub` 由后端白名单固定，前端传非法值会被 400 拒绝。
  Future<SkillCatalogData> skillCatalog({
    String query = '',
    int limit = 30,
    String? language,
  }) async =>
      SkillCatalogData.fromJson(
        (await _request('GET', '/api/skills/catalog', query: {
          'q': query,
          'limit': limit,
          if (language != null && language.isNotEmpty) 'language': language,
        })) as Map<String, dynamic>,
      );

  /// hub 详情（含 SKILL.md 正文与逐文件 sha256 清单）。
  Future<Map<String, dynamic>> skillDetail(String slug, {String? version}) async =>
      (await _request('GET', '/api/skills/detail', query: {
        'slug': slug,
        if (version != null && version.isNotEmpty) 'version': version,
      })) as Map<String, dynamic>;

  /// 安全裁决。**请求失败时后端降级为 unknown 并正常返回**，不抛错；
  /// 只有 slug/hub 非法才会抛 [ApiException]。
  Future<SkillVerdictInfo> skillVerdict(String slug, {String? version}) async {
    final data = await _request('GET', '/api/skills/verify', query: {
      'slug': slug,
      if (version != null && version.isNotEmpty) 'version': version,
    }) as Map<String, dynamic>;
    final verdict = data['verdict'];
    return verdict is Map
        ? SkillVerdictInfo.fromJson(Map<String, dynamic>.from(verdict))
        : const SkillVerdictInfo();
  }

  /// 用户显式安装/升级。
  ///
  /// - `allowUnverified`（默认 true）：裁决不可得（离线）时降级安装并标注"未验证"；
  ///   传 false 则拒绝。
  /// - `allowSuspicious`（默认 false）：registry 未认可的包默认拒绝，
  ///   只有用户在 UI 上显式确认"仍然安装"后才传 true。
  Future<InstalledSkillInfo> installSkill(
    String slug, {
    String? version,
    bool allowUnverified = true,
    bool allowSuspicious = false,
  }) async {
    final data = await _request(
      'POST',
      '/api/skills/install',
      body: {
        'slug': slug,
        if (version != null && version.isNotEmpty) 'version': version,
        'allow_unverified': allowUnverified,
        'allow_suspicious': allowSuspicious,
      },
      timeout: const Duration(seconds: 120),
    ) as Map<String, dynamic>;
    final skill = data['skill'];
    return skill is Map
        ? InstalledSkillInfo.fromJson(Map<String, dynamic>.from(skill))
        : InstalledSkillInfo(slug: slug);
  }

  Future<InstalledSkillInfo> setSkillEnabled(String slug, bool enabled) async {
    final data = await _request(
      'POST',
      '/api/skills/${Uri.encodeComponent(slug)}/${enabled ? 'enable' : 'disable'}',
      body: const {},
    ) as Map<String, dynamic>;
    return _skillFromAction(data, slug);
  }

  /// 一键本地回退（离线可用，不联网）。
  Future<InstalledSkillInfo> rollbackSkill(String slug) async {
    final data = await _request(
      'POST',
      '/api/skills/${Uri.encodeComponent(slug)}/rollback',
      body: const {},
    ) as Map<String, dynamic>;
    return _skillFromAction(data, slug);
  }

  /// 版本锁定开关（F-5）：pinned=1 时跳过更新检查提示，也不允许直接覆盖更新。
  Future<InstalledSkillInfo> setSkillPinned(String slug, bool pinned) async {
    final data = await _request(
      'POST',
      '/api/skills/${Uri.encodeComponent(slug)}/pin',
      body: {'pinned': pinned},
    ) as Map<String, dynamic>;
    return _skillFromAction(data, slug);
  }

  /// 只查不装的更新检查（F-5）。离线时逐条标 `offline:true`，不抛错。
  Future<List<Map<String, dynamic>>> checkSkillUpdates() async {
    final data = await _request('POST', '/api/skills/check-updates', body: const {})
        as Map<String, dynamic>;
    return (data['items'] as List? ?? [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  /// 更新到 registry 最新版（或指定版本）；失败保持旧版本可用（F-5）。
  Future<Map<String, dynamic>> updateSkill(String slug, {String? version}) async =>
      (await _request(
        'POST',
        '/api/skills/${Uri.encodeComponent(slug)}/update',
        body: {if (version != null && version.isNotEmpty) 'version': version},
        timeout: const Duration(seconds: 120),
      )) as Map<String, dynamic>;

  /// 技能本地状态（F-5）：`{online, hub, hub_allowlist, last_sync_at, installed_count,
  /// pinned_count}`。`probe=false`（默认）时**不触网**，只报缓存的探测结果。
  Future<Map<String, dynamic>> skillStatus({bool probe = false}) async =>
      (await _request('GET', '/api/skills/status',
          query: {'probe': probe ? 'true' : 'false'})) as Map<String, dynamic>;

  /// 只读技能包内文本（默认 SKILL.md，≤200KB，路径必须在技能目录内）。
  Future<Map<String, dynamic>> skillRaw(String slug, {String path = 'SKILL.md'}) async =>
      (await _request('GET', '/api/skills/${Uri.encodeComponent(slug)}/raw',
          query: {'path': path})) as Map<String, dynamic>;

  /// 卸载（只影响本学科，不动 registry）。
  Future<Map<String, dynamic>> removeSkill(String slug) async =>
      (await _request('DELETE', '/api/skills/${Uri.encodeComponent(slug)}',
          query: {'confirm': slug})) as Map<String, dynamic>;

  /// 本学科**启用中**技能的纯文本 playbook（用于提示词注入，不执行任何文件）。
  Future<List<Map<String, dynamic>>> skillPlaybooks() async {
    final data =
        await _request('GET', '/api/skills/playbooks') as Map<String, dynamic>;
    return (data['skills'] as List? ?? [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  InstalledSkillInfo _skillFromAction(Map<String, dynamic> data, String slug) {
    final skill = data['skill'];
    return skill is Map
        ? InstalledSkillInfo.fromJson(Map<String, dynamic>.from(skill))
        : InstalledSkillInfo(slug: slug);
  }
}
