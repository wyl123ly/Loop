import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'agent.dart';
import 'agent_run.dart';
import '../update/app_version.dart';
import 'agent_tools.dart';
import 'folder_import.dart';
import 'job_scheduler.dart';
import 'mcp_manager.dart';
import 'db.dart';
import 'llm.dart';
import 'parsing.dart';
import 'paths.dart';
import 'retrieval.dart';
import 'skills_import.dart';
import 'skills_registry.dart';
import 'subject_migration.dart';
import 'subject_progress.dart';
import 'subject_store.dart';

/// 进程内 HTTP 服务：绑定 127.0.0.1:8765，和 Flutter UI 同进程，没有子进程。
class Backend {
  static HttpServer? _server;
  static const int port = 8765;

  static bool get running => _server != null;

  /// 实际监听端口（测试用随机端口时与 [port] 不同）。
  static int? get boundPort => _server?.port;

  static Future<void> start() async {
    AppPaths.init();
    Db.init();
    // 学科数据层：注册表 + 默认学科 + 旧数据迁移（幂等，§5.1）。
    SubjectStore.init();
    SubjectMigration.ensureApplied();
    ProviderRegistry.ensureMigrated();
    if (_server != null) return;
    try {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
      _server = server;
      server.listen(_handle, onError: (Object _) {});
      JobScheduler.start();
    } on SocketException {
      // 端口已被占用（例如另一个实例），直接复用现有服务。
    }
  }

  /// 测试专用：真实 HTTP 服务 + 隔离数据目录（端口 0 = 随机空闲端口）。
  /// 不启动后台任务调度器（避免测试里残留 Timer）。
  static Future<int> startForTests(Directory dataDir, {int listenPort = 0}) async {
    await stopForTests();
    SubjectStore.initTempForTests(dataDir);
    SubjectMigration.ensureApplied();
    ProviderRegistry.ensureMigrated();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, listenPort);
    _server = server;
    server.listen(_handle, onError: (Object _) {});
    return server.port;
  }

  static Future<void> stopForTests() async {
    final server = _server;
    _server = null;
    JobScheduler.stop();
    SubjectStore.closeAll();
    if (server != null) await server.close(force: true);
  }

  static Future<void> _handle(HttpRequest request) async {
    try {
      await _route(request);
    } on SubjectError catch (error) {
      // 学科层错误自带 HTTP 状态码（400/404/409/503，§11.7）。
      try {
        await _json(request, error.status, {'detail': error.message});
      } catch (_) {}
    } on SkillImportError catch (error) {
      // 导入策略拒绝（suspicious / sha256_mismatch / zip_slip …）。
      try {
        await _json(request, error.status, error.toJson());
      } catch (_) {}
    } on SkillRegistryError catch (error) {
      // 网络不可达 → 503 + offline 标记，调用方据此做离线降级。
      try {
        await _json(request, error.offline ? 503 : 502, error.toJson());
      } catch (_) {}
    } catch (error, stack) {
      stderr.writeln('backend error: $error\n$stack');
      try {
        await _json(request, 500, {'detail': '$error'});
      } catch (_) {}
    }
  }

  static Future<void> _route(HttpRequest request) async {
    final segments = request.uri.pathSegments;
    if (segments.length < 2 || segments.first != 'api') {
      return _json(request, 404, {'detail': 'not found'});
    }
    final resource = segments[1];
    final method = request.method;

    switch (resource) {
      case 'health':
        return _json(request, 200, {
          'ok': true,
          'version': AppVersion.current,
          'has_key': Db.setting('api_key').isNotEmpty,
          'active_subject': SubjectStore.activeKey(),
        });

      case 'cloud':
        return _cloud(request, segments);

      case 'subjects':
        return _subjects(request, segments);

      case 'skills':
        return _skills(request, segments);

      case 'migrations':
        return _migrations(request, segments);

      case 'diagnostics':
        return _diagnostics(request, segments);

      case 'settings':
        if (segments.length >= 3 && segments[2] == 'test' && method == 'POST') {
          return _testSettings(request);
        }
        if (segments.length >= 3 && segments[2] == 'models' && method == 'POST') {
          return _fetchProviderModels(request);
        }
        if (method == 'GET') {
          ProviderRegistry.ensureMigrated();
          final active = ProviderRegistry.active();
          final key = active.apiKey;
          return _json(request, 200, {
            'api_key': key.length > 8 ? 'sk-${'•' * 8}${key.substring(key.length - 4)}' : (key.isEmpty ? '' : '已配置'),
            'has_key': key.isNotEmpty,
            'base_url': active.baseUrl,
            'model': active.defaultModel,
            'reason_model': active.reasonModel,
            'active_provider': active.id,
            'providers': jsonEncode([
              for (final profile in ProviderRegistry.all()) profile.toJson(maskKey: true),
            ]),
            'theme': Db.setting('theme', 'system'),
            'custom_modes': Db.setting('custom_modes', '[]'),
            'auto_check_updates': Db.setting('auto_check_updates', 'true') == 'true',
            'sidebar_collapsed': Db.setting('sidebar_collapsed', 'false') == 'true',
            'stream_output': Db.setting('stream_output', 'true') == 'true',
            // v0.8.0 学科作用域（§4.2）：前端启动时同步当前学科。
            'active_subject': SubjectStore.activeKey(),
            'cross_subject_search': Db.setting('cross_subject_search', 'false') == 'true',
            // F-18：hub 恒等于后端白名单（DB 里的历史值可能是被改过的旧值）。
            'skill_hub_url': SkillHubAllowlist.hubs[SkillHubAllowlist.defaultHub]!.baseUrl,
            'skill_hub_url_readonly': true,
            'skill_hub_note': '教学技能来源由后端白名单固定（仅 EduHub），不可在前端修改。',
            'skill_inject_max': int.tryParse(Db.setting('skill_inject_max', '3')) ?? 3,
            // F-11：迁移后一次性提示是否已看过（UI 只提示一次）。
            'subject_migration_notice_seen':
                Db.setting('subject_migration_notice_seen', 'false') == 'true',
          });
        }
        if (method == 'PUT') {
          final body = await _jsonBody(request);
          ProviderRegistry.ensureMigrated();

          // 新格式：providers_v1 全量列表 + active_provider。Key 为空或掩码
          // 时保留旧 Key，避免设置页留空保存把 Key 清掉。
          final incoming = ProviderRegistry.mergeIncoming(
            body['providers'],
            ProviderRegistry.all(),
          );
          if (incoming.isNotEmpty) ProviderRegistry.saveAll(incoming);
          if (body['active_provider'] is String) {
            ProviderRegistry.setActive(body['active_provider'].toString());
          }

          // 旧格式兼容：api_key/base_url/model/reason_model 写入当前供应商。
          var active = ProviderRegistry.active();
          var changed = false;
          if (body['api_key'] is String && !body['api_key'].toString().contains('•')) {
            final value = body['api_key'].toString().trim();
            Db.setSetting('api_key', value);
            active = active.copyWith(apiKey: value);
            changed = true;
          }
          for (final key in ['base_url', 'model', 'reason_model']) {
            if (body[key] is String && body[key].toString().isNotEmpty) {
              final value = body[key].toString().trim();
              Db.setSetting(key, value);
              if (key == 'base_url') active = active.copyWith(baseUrl: value);
              if (key == 'model') active = active.copyWith(defaultModel: value);
              if (key == 'reason_model') active = active.copyWith(reasonModel: value);
              changed = true;
            }
          }
          if (changed) {
            final profiles = ProviderRegistry.all();
            final index = profiles.indexWhere((item) => item.id == active.id);
            if (index >= 0) profiles[index] = active;
            ProviderRegistry.saveAll(profiles);
          }
          final theme = body['theme']?.toString();
          if (theme == 'system' || theme == 'light' || theme == 'dark') {
            Db.setSetting('theme', theme!);
          }
          if (body['sidebar_collapsed'] is bool) {
            Db.setSetting('sidebar_collapsed', body['sidebar_collapsed'] == true ? 'true' : 'false');
          }
          if (body['auto_check_updates'] is bool) {
            Db.setSetting('auto_check_updates', body['auto_check_updates'] == true ? 'true' : 'false');
          }
          if (body['stream_output'] is bool) {
            Db.setSetting('stream_output', body['stream_output'] == true ? 'true' : 'false');
          }
          if (body['custom_modes'] is String) {
            Db.setSetting('custom_modes', body['custom_modes'].toString());
          }
          if (body['active_subject'] is String && body['active_subject'].toString().isNotEmpty) {
            // 当前学科：非法 key 直接 404（不回退他科）。
            SubjectStore.setActive(body['active_subject'].toString());
          }
          if (body['cross_subject_search'] is bool) {
            Db.setSetting(
              'cross_subject_search',
              body['cross_subject_search'] == true ? 'true' : 'false',
            );
          }
          if (body['subject_migration_notice_seen'] is bool) {
            Db.setSetting(
              'subject_migration_notice_seen',
              body['subject_migration_notice_seen'] == true ? 'true' : 'false',
            );
          }
          // F-18：skill_hub_url 只读——非法值直接 400，合法的白名单值可写但会被
          // 上面的 GET 覆盖为白名单真值（前端不再提供可编辑入口）。
          if (body['skill_hub_url'] is String) {
            final requested = body['skill_hub_url'].toString().trim();
            final allowed = SkillHubAllowlist.hubUrls.any(
              (url) => url.toLowerCase() == requested.toLowerCase(),
            );
            if (!allowed) {
              throw SkillImportError(
                'hub_readonly',
                '教学技能来源由后端白名单固定（${SkillHubAllowlist.hubUrls.join(' / ')}），不接受前端修改：$requested',
                status: 400,
              );
            }
            Db.setSetting('skill_hub_url', requested);
          }
          request.response.statusCode = 200;
          final saved = ProviderRegistry.active();
          return _json(request, 200, {
            'has_key': saved.apiKey.isNotEmpty,
            'base_url': saved.baseUrl,
            'model': saved.defaultModel,
            'reason_model': saved.reasonModel,
            'active_provider': saved.id,
            'active_subject': SubjectStore.activeKey(),
          });
        }
        return _json(request, 405, {'detail': 'method not allowed'});

      case 'conversations':
        if (segments.length == 2) {
          if (method == 'GET') return _listConversations(request);
          if (method == 'POST') return _createConversation(request);
        } else {
          final id = int.tryParse(segments[2]);
          if (id == null) return _json(request, 400, {'detail': 'bad id'});
          if (segments.length == 3 && method == 'DELETE') {
            return _scopedWrite(request, (record, db) async {
              db.run('DELETE FROM messages WHERE conversation_id=?', [id]);
              db.run('DELETE FROM conversations WHERE id=?', [id]);
              return _json(request, 200, {'ok': true});
            });
          }
          if (segments.length == 4 && segments[3] == 'messages' && method == 'GET') {
            return _listMessages(request, id);
          }
        }
        return _json(request, 404, {'detail': 'not found'});

      case 'chat':
        if (method == 'POST') return _chat(request);
        return _json(request, 405, {'detail': 'method not allowed'});

      case 'agent':
        if (method == 'POST' && segments.length == 3) return _agentControl(request, segments[2]);
        if (method == 'GET' && segments.length == 3 && segments[2] == 'settings') return _agentSettings(request);
        if ((method == 'PUT' || method == 'POST') && segments.length == 3 && segments[2] == 'settings') return _agentSettings(request);
        return _json(request, 404, {'detail': 'not found'});

      case 'mcp':
        if (segments.length >= 3 && segments[2] == 'servers') return _mcp(request, segments);
        return _json(request, 404, {'detail': 'not found'});

      case 'jobs':
        return _jobs(request, segments);

      case 'audit':
        if (method == 'GET') {
          final limit = int.tryParse(request.uri.queryParameters['limit'] ?? '100') ?? 100;
          return _json(request, 200, Db.rows('SELECT * FROM agent_audit ORDER BY id DESC LIMIT ?', [limit.clamp(1, 500)]));
        }
        return _json(request, 405, {'detail': 'method not allowed'});

      case 'upload':
        if (method == 'POST') return _upload(request);
        return _json(request, 405, {'detail': 'method not allowed'});

      case 'materials':
        if (segments.length >= 3 && segments[2] == 'folders') return _materialFolders(request, segments);
        if (segments.length == 3 && segments[2] == 'scan' && method == 'POST') return _scanFolder(request);
        if (segments.length == 3 && segments[2] == 'import' && method == 'POST') return _importFolder(request);
        if (segments.length == 3 && segments[2] == 'import-cancel' && method == 'POST') {
          final body = await _jsonBody(request);
          final token = (body['token'] ?? '').toString();
          if (_importCancels.containsKey(token)) _importCancels[token] = true;
          return _json(request, 200, {'ok': true});
        }
        if (segments.length == 2 && method == 'GET') {
          return _scoped(request, (record, db) async {
            final items = db.rows('SELECT * FROM materials ORDER BY id DESC');
            for (final item in items) {
              item['subject_key'] = record.key;
            }
            return _json(request, 200, items);
          });
        }
        final id = int.tryParse(segments.length > 2 ? segments[2] : '');
        if (id == null) return _json(request, 400, {'detail': 'bad id'});
        if (segments.length == 3 && method == 'DELETE') {
          return _scopedWrite(request, (record, db) async {
            await deleteMaterialById(id);
            return _json(request, 200, {'ok': true});
          });
        }
        if (segments.length == 4 && segments[3] == 'preview' && method == 'GET') {
          return _scoped(request, (record, db) async {
            // ID 只在其学科库内有意义：找不到即 404，不回退到他科（§6.4）。
            final material = db.one('SELECT * FROM materials WHERE id=?', [id]);
            if (material == null) return _json(request, 404, {'detail': '资料不存在'});
            final chunks = db.rows(
              'SELECT page, text FROM chunks WHERE material_id=? ORDER BY id LIMIT 4',
              [id],
            );
            final text = chunks.map((c) => 'p.${c['page']}\n${c['text']}').join('\n\n');
            return _json(request, 200, {
              'id': id,
              'name': material['name'],
              'kind': material['kind'],
              'pages': material['pages'],
              'chars': material['chars'],
              'subject_key': record.key,
              'text': text.isEmpty ? '（没有可显示的文字）' : (text.length > 5000 ? text.substring(0, 5000) : text),
            });
          });
        }
        return _json(request, 404, {'detail': 'not found'});

      case 'uploads':
        final id = int.tryParse(segments.length > 2 ? segments[2] : '');
        if (id == null) return _json(request, 400, {'detail': 'bad id'});
        // 图片也按学科取：先查当前（或指定）学科库，再回退全局兼容库的旧图片。
        return _serveUpload(request, id);

      case 'tasks':
        if (segments.length == 2) {
          if (method == 'GET') return _listTasks(request);
          if (method == 'POST') return _createTask(request);
        }
        final id = int.tryParse(segments.length > 2 ? segments[2] : '');
        if (id == null) return _json(request, 400, {'detail': 'bad id'});
        if (method == 'PATCH') return _patchTask(request, id);
        if (method == 'DELETE') {
          return _scopedWrite(request, (record, db) async {
            db.run('DELETE FROM tasks WHERE id=?', [id]);
            return _json(request, 200, {'ok': true});
          });
        }
        return _json(request, 404, {'detail': 'not found'});

      case 'today':
        return _today(request);

      case 'notes':
        if (segments.length == 2 && method == 'GET') {
          return _scoped(request, (record, db) async => _json(
                request,
                200,
                db.rows('SELECT * FROM notes ORDER BY id DESC LIMIT 100'),
              ));
        }
        final id = int.tryParse(segments.length > 2 ? segments[2] : '');
        if (id != null && method == 'DELETE') {
          return _scopedWrite(request, (record, db) async {
            db.run('DELETE FROM notes WHERE id=?', [id]);
            return _json(request, 200, {'ok': true});
          });
        }
        return _json(request, 404, {'detail': 'not found'});

      case 'generate':
        if (method == 'POST' && segments.length == 3) {
          if (segments[2] == 'note') return _generateNote(request);
          if (segments[2] == 'task') return _generateTask(request);
        }
        return _json(request, 404, {'detail': 'not found'});
    }
    return _json(request, 404, {'detail': 'not found'});
  }

  // ------------------------------------------------------------ conversations

  /// 缺省 = 当前学科；`?subject=<key|id>` 显式指定（§6.1）。学科间不串库。
  static Future<void> _listConversations(HttpRequest request) async {
    return _scoped(request, (record, db) async {
      final items = db.rows('SELECT * FROM conversations ORDER BY updated_at DESC LIMIT 100');
      for (final item in items) {
        final id = item['id'];
        final last =
            db.one('SELECT content FROM messages WHERE conversation_id=? ORDER BY id DESC LIMIT 1', [id]);
        item['preview'] = (last?['content'] ?? '').toString();
        if ((item['preview'] as String).length > 60) {
          item['preview'] = (item['preview'] as String).substring(0, 60);
        }
        item['messages'] = db.scalar('SELECT COUNT(*) FROM messages WHERE conversation_id=?', [id]) ?? 0;
        item['subject_key'] = record.key;
      }
      return _json(request, 200, items);
    });
  }

  static Future<void> _createConversation(HttpRequest request) async {
    final body = await _jsonBody(request);
    return _scopedWrite(request, (record, db) async {
      final now = Db.nowIso();
      final id = db.insert('conversations', {
        'title': (body['title'] ?? '新对话').toString(),
        'mode': 'answer',
        'created_at': now,
        'updated_at': now,
      });
      return _json(request, 200, {'id': id, 'subject_key': record.key});
    }, jsonBody: body);
  }

  static Future<void> _listMessages(HttpRequest request, int conversationId) async {
    return _scoped(request, (record, db) async {
      final conversation = db.one('SELECT id FROM conversations WHERE id=?', [conversationId]);
      if (conversation == null) return _json(request, 404, {'detail': '会话不存在'});
      final items = db.rows(
        'SELECT * FROM messages WHERE conversation_id=? ORDER BY id',
        [conversationId],
      );
      for (final item in items) {
        item['steps'] = Db.parseList(item['steps']);
        item['refs'] = Db.parseList(item['refs']);
        item['plan'] = Db.parseList(item['plan']);
        item['attachments'] = Db.parseList(item['attachments']);
      }
      return _json(request, 200, items);
    });
  }

  // ------------------------------------------------------------ chat

  static Future<void> _chat(HttpRequest request) async {
    final body = await _jsonBody(request);
    // 学科作用域：body.subject → ?subject= → settings.active_subject（§11.1）。
    final subject = _subjectScope(request, body: body, write: true);
    final subjectDb = SubjectStore.open(subject.key);
    final text = (body['text'] ?? '').toString().trim();
    // 请求级快照：本次 run 使用进入请求时的设置；运行中切换只影响下一条消息。
    final streamOutput = Db.setting('stream_output', 'true') == 'true';
    final attachments = ((body['attachments'] as List?) ?? const [])
        .map((e) => e.toString())
        .where((e) => e.isNotEmpty)
        .toList();
    if (text.isEmpty && attachments.isEmpty) {
      return _json(request, 400, {'detail': '消息不能为空'});
    }

    return Db.runScoped(
      subjectDb.database,
      () async {
        var conversationId = (body['conversation_id'] as num?)?.toInt();
        if (conversationId == null) {
          final now = Db.nowIso();
          conversationId = Db.insert('conversations', {
            'title': '新对话',
            'mode': (body['mode'] ?? 'answer').toString(),
            'created_at': now,
            'updated_at': now,
          });
        }
        // 会话必须存在于**本学科库**：找不到即 404，不回退到他科（§6.4 防串库）。
        final conversation = Db.one('SELECT * FROM conversations WHERE id=?', [conversationId]);
        if (conversation == null) return _json(request, 404, {'detail': '会话不存在'});

        final attachmentMeta = <Map<String, Object?>>[];
        for (final attachment in attachments) {
          if (attachment.startsWith('img_')) {
            final id = int.tryParse(attachment.substring(4));
            final row = id == null ? null : Db.one('SELECT name FROM uploads WHERE id=?', [id]);
            if (row != null) {
              attachmentMeta.add({
                'id': attachment,
                'name': (row['name'] ?? '').toString(),
                'is_image': true,
              });
            }
          } else if (attachment.startsWith('mat_')) {
            final id = int.tryParse(attachment.substring(4));
            final row = id == null ? null : Db.one('SELECT name FROM materials WHERE id=?', [id]);
            if (row != null) {
              attachmentMeta.add({
                'id': attachment,
                'name': (row['name'] ?? '').toString(),
                'is_image': false,
              });
            }
          }
        }
        final userMessageId = Db.insert('messages', {
          'conversation_id': conversationId,
          'role': 'user',
          'content': text,
          'steps': '[]',
          'refs': '[]',
          'attachments': jsonEncode(attachmentMeta),
          'created_at': Db.nowIso(),
        });
        if ((conversation['title'] ?? '') == '' || conversation['title'] == '新对话') {
          Db.run('UPDATE conversations SET title=? WHERE id=?', [
            text.isEmpty ? '新对话' : (text.length > 20 ? text.substring(0, 20) : text),
            conversationId,
          ]);
        }
        Db.run('UPDATE conversations SET updated_at=? WHERE id=?', [Db.nowIso(), conversationId]);

        final response = request.response;
        response.statusCode = 200;
        response.headers.contentType = ContentType('text', 'event-stream', charset: 'utf-8');
        response.headers.set('Cache-Control', 'no-cache');
        response.headers.set('X-Accel-Buffering', 'no');
        response.bufferOutput = false;

        final run = AgentRuns.start(conversationId, subjectKey: subject.key);
        response.write('event: run\ndata: ${jsonEncode({'run_id': run.id, 'subject_key': subject.key})}\n\n');
        await response.flush();

        final events = runAgent(
          conversationId: conversationId,
          userMessageId: userMessageId,
          userText: text.isEmpty ? '（见附件）' : text,
          attachments: attachments,
          run: run,
          mode: (body['mode'] ?? 'answer').toString(),
          modePrompt: (body['mode_prompt'] ?? '').toString(),
          thinking: (body['thinking'] ?? 'medium').toString(),
          streamOutput: streamOutput,
        );
        var status = 'done';
        try {
          await for (final event in events) {
            if (event.event == 'cancelled') status = 'cancelled';
            if (event.event == 'error') status = 'error';
            response.write('event: ${event.event}\ndata: ${jsonEncode(event.data)}\n\n');
            await response.flush();
          }
        } catch (_) {
          status = 'cancelled';
          run.cancel();
        } finally {
          run.finish(status);
          AgentRuns.remove(run.id);
        }
        Db.run('UPDATE conversations SET updated_at=? WHERE id=?', [Db.nowIso(), conversationId]);
        await response.close();
      },
      subjectKey: subject.key,
      filesDir: subject.filesPath,
    );
  }

  static Future<void> _agentSettings(HttpRequest request) async {
    if (request.method == 'GET') {
      return _json(request, 200, {
        'workspace_path': workspacePath,
        'shell': Db.setting('agent_shell', 'true') == 'true',
        'browser': Db.setting('agent_browser', 'true') == 'true',
        'mcp': Db.setting('agent_mcp', 'true') == 'true',
        'background': Db.setting('agent_background', 'false') == 'true',
      });
    }
    final body = await _jsonBody(request);
    if (body['workspace_path'] is String && (body['workspace_path'] as String).trim().isNotEmpty) {
      final dir = Directory((body['workspace_path'] as String).trim());
      if (!dir.existsSync()) dir.createSync(recursive: true);
      Db.setSetting('workspace_path', dir.path);
    }
    for (final entry in {
      'agent_shell': body['shell'],
      'agent_browser': body['browser'],
      'agent_mcp': body['mcp'],
      'agent_background': body['background'],
    }.entries) {
      if (entry.value is bool) Db.setSetting(entry.key, entry.value == true ? 'true' : 'false');
    }
    return _json(request, 200, {'ok': true});
  }

  static Future<void> _mcp(HttpRequest request, List<String> segments) async {
    final method = request.method;
    if (segments.length == 3) {
      if (method == 'GET') return _json(request, 200, McpManager.servers());
      if (method == 'POST') {
        final body = await _jsonBody(request);
        final name = (body['name'] ?? '').toString().trim();
        if (name.isEmpty) return _json(request, 400, {'detail': '名称不能为空'});
        final transport = (body['transport'] ?? 'stdio').toString() == 'http' ? 'http' : 'stdio';
        final command = (body['command'] ?? '').toString().trim();
        final url = (body['url'] ?? '').toString().trim();
        if (transport == 'stdio' && command.isEmpty) return _json(request, 400, {'detail': 'stdio 需要命令'});
        if (transport == 'http' && url.isEmpty) return _json(request, 400, {'detail': 'HTTP 需要 URL'});
        final args = body['args'];
        final env = body['env'];
        final id = Db.insert('mcp_servers', {
          'name': name,
          'transport': transport,
          'command': command,
          'args': args is String ? args : jsonEncode(args ?? []),
          'env': env is String ? env : jsonEncode(env ?? {}),
          'working_directory': (body['working_directory'] ?? '').toString(),
          'url': url,
          'enabled': body['enabled'] == false ? 0 : 1,
          'created_at': Db.nowIso(),
        });
        return _json(request, 200, {'id': id});
      }
      return _json(request, 405, {'detail': 'method not allowed'});
    }
    final id = int.tryParse(segments[3]);
    if (id == null) return _json(request, 400, {'detail': 'bad id'});
    final row = Db.one('SELECT * FROM mcp_servers WHERE id=?', [id]);
    if (row == null) return _json(request, 404, {'detail': '服务器不存在'});
    if (segments.length == 5 && segments[4] == 'test' && method == 'POST') {
      return _json(request, 200, await McpManager.test(row));
    }
    if (method == 'PATCH') {
      final body = await _jsonBody(request);
      final fields = <String, Object?>{};
      for (final key in ['name', 'transport', 'command', 'url', 'working_directory']) {
        if (body[key] is String) fields[key] = body[key];
      }
      if (body['args'] is String || body['args'] is List) {
        fields['args'] = body['args'] is String ? body['args'] : jsonEncode(body['args']);
      }
      if (body['env'] is String || body['env'] is Map) {
        fields['env'] = body['env'] is String ? body['env'] : jsonEncode(body['env']);
      }
      if (body['enabled'] is bool) {
        fields['enabled'] = body['enabled'] == true ? 1 : 0;
        if (body['enabled'] == false) await McpManager.closeServer(id);
      }
      if (fields.isNotEmpty) {
        final sets = fields.keys.map((key) => '$key=?').join(',');
        Db.run('UPDATE mcp_servers SET $sets WHERE id=?', [...fields.values, id]);
      }
      return _json(request, 200, {'ok': true});
    }
    if (method == 'DELETE') {
      await McpManager.closeServer(id);
      Db.run('DELETE FROM mcp_servers WHERE id=?', [id]);
      return _json(request, 200, {'ok': true});
    }
    return _json(request, 405, {'detail': 'method not allowed'});
  }

  static Future<void> _jobs(HttpRequest request, List<String> segments) async {
    if (segments.length == 2) {
      if (request.method == 'GET') return _json(request, 200, Db.rows('SELECT * FROM agent_jobs ORDER BY id DESC'));
      if (request.method == 'POST') {
        final body = await _jsonBody(request);
        final title = (body['title'] ?? '').toString().trim();
        final prompt = (body['prompt'] ?? '').toString().trim();
        if (title.isEmpty || prompt.isEmpty) return _json(request, 400, {'detail': '标题和内容不能为空'});
        final kind = (body['schedule_kind'] ?? 'interval').toString() == 'daily' ? 'daily' : 'interval';
        final value = (body['schedule_value'] ?? (kind == 'daily' ? '08:00' : '60')).toString();
        final id = Db.insert('agent_jobs', {
          'title': title,
          'prompt': prompt,
          'mode': 'answer',
          'schedule_kind': kind,
          'schedule_value': value,
          'next_run': JobScheduler.computeNext(kind, value),
          'enabled': body['enabled'] == false ? 0 : 1,
          'created_at': Db.nowIso(),
        });
        return _json(request, 200, {'id': id});
      }
      return _json(request, 405, {'detail': 'method not allowed'});
    }
    final id = int.tryParse(segments[2]);
    if (id == null) return _json(request, 400, {'detail': 'bad id'});
    final row = Db.one('SELECT * FROM agent_jobs WHERE id=?', [id]);
    if (row == null) return _json(request, 404, {'detail': '任务不存在'});
    if (segments.length == 4 && segments[3] == 'run' && request.method == 'POST') {
      unawaited(JobScheduler.runJob(row));
      return _json(request, 200, {'ok': true});
    }
    if (request.method == 'PATCH') {
      final body = await _jsonBody(request);
      final fields = <String, Object?>{};
      if (body['title'] is String) fields['title'] = body['title'];
      if (body['prompt'] is String) fields['prompt'] = body['prompt'];
      if (body['schedule_kind'] is String) fields['schedule_kind'] = body['schedule_kind'];
      if (body['schedule_value'] is String) fields['schedule_value'] = body['schedule_value'];
      if (body['enabled'] is bool) fields['enabled'] = body['enabled'] == true ? 1 : 0;
      if (fields.isNotEmpty) {
        final sets = fields.keys.map((key) => '$key=?').join(',');
        Db.run('UPDATE agent_jobs SET $sets WHERE id=?', [...fields.values, id]);
      }
      return _json(request, 200, {'ok': true});
    }
    if (request.method == 'DELETE') {
      Db.run('DELETE FROM agent_jobs WHERE id=?', [id]);
      return _json(request, 200, {'ok': true});
    }
    return _json(request, 405, {'detail': 'method not allowed'});
  }

  static Future<void> _agentControl(HttpRequest request, String action) async {
    if (action == 'open-workspace') {
      unawaited(Process.start('explorer.exe', [workspacePath]));
      return _json(request, 200, {'ok': true});
    }
    final body = await _jsonBody(request);
    final runId = (body['run_id'] as num?)?.toInt();
    if (runId == null) return _json(request, 400, {'detail': '缺少 run_id'});
    final run = AgentRuns.byId(runId);
    if (run == null) return _json(request, 404, {'detail': '运行不存在或已结束'});
    if (action == 'approve') {
      run.resolveApproval(body['allow'] == true);
      return _json(request, 200, {'ok': true});
    }
    if (action == 'cancel') {
      run.cancel();
      return _json(request, 200, {'ok': true});
    }
    return _json(request, 404, {'detail': 'not found'});
  }

  static final Map<String, bool> _importCancels = {};

  static Future<void> _materialFolders(HttpRequest request, List<String> segments) async {
    if (segments.length == 3 && request.method == 'GET') {
      return _scoped(request, (record, db) async {
        final rows = db.rows('''
          SELECT f.*, (SELECT COUNT(*) FROM materials m WHERE m.folder_id=f.id) AS file_count
          FROM material_folders f ORDER BY f.id DESC
        ''');
        return _json(request, 200, rows);
      });
    }
    if (segments.length == 4 && request.method == 'DELETE') {
      final id = int.tryParse(segments[3]);
      if (id == null) return _json(request, 400, {'detail': 'bad id'});
      return _scopedWrite(request, (record, db) async {
        await deleteFolderById(id);
        return _json(request, 200, {'ok': true});
      });
    }
    if (segments.length == 5 && segments[4] == 'rescan' && request.method == 'POST') {
      final id = int.tryParse(segments[3]);
      return _scoped(request, (record, db) async {
        final folder = db.one('SELECT * FROM material_folders WHERE id=?', [id]);
        if (folder == null) return _json(request, 404, {'detail': '文件夹不存在'});
        return _json(request, 200, {
          'root_path': folder['root_path'],
          'name': folder['name'],
        });
      });
    }
    return _json(request, 404, {'detail': 'not found'});
  }

  static Future<void> _scanFolder(HttpRequest request) async {
    final body = await _jsonBody(request);
    final path = (body['path'] ?? '').toString().trim();
    if (path.isEmpty) return _json(request, 400, {'detail': '缺少文件夹路径'});
    return _scoped(request, (record, db) async {
      try {
        // scanFolder 会查 materials.source_path 判重 → 必须在本学科作用域内执行。
        final scan = Db.runScopedSync(
          db.database,
          () => scanFolder(path, recursive: body['recursive'] != false),
          subjectKey: record.key,
          filesDir: record.filesPath,
        );
        return await _json(request, 200, {
          'root': scan.root,
          'name': scan.name,
          'truncated': scan.truncated,
          'files': scan.files.map((file) => file.toJson()).toList(),
          'total': scan.files.length,
          'supported': scan.supported.length,
          'skipped': scan.files.length - scan.supported.length,
          'bytes': scan.totalBytes,
          'subject_key': record.key,
        });
      } catch (error) {
        return _json(request, 400, {'detail': '扫描失败：$error'});
      }
    }, jsonBody: body);
  }

  static Future<void> _importFolder(HttpRequest request) async {
    final body = await _jsonBody(request);
    final path = (body['path'] ?? '').toString().trim();
    if (path.isEmpty) return _json(request, 400, {'detail': '缺少文件夹路径'});
    final recursive = body['recursive'] != false;
    final duplicate = (body['duplicate'] ?? 'skip').toString() == 'update' ? 'update' : 'skip';
    final token = (body['token'] ?? '').toString().isEmpty
        ? DateTime.now().microsecondsSinceEpoch.toString()
        : body['token'].toString();
    return _scopedWrite(request, (record, db) async {
      final FolderScanResult scan;
      try {
        scan = Db.runScopedSync(
          db.database,
          () => scanFolder(path, recursive: recursive),
          subjectKey: record.key,
          filesDir: record.filesPath,
        );
      } catch (error) {
        return _json(request, 400, {'detail': '扫描失败：$error'});
      }
      _importCancels[token] = false;

      final response = request.response;
      response.statusCode = 200;
      response.headers.contentType = ContentType('text', 'event-stream', charset: 'utf-8');
      response.headers.set('Cache-Control', 'no-cache');
      response.bufferOutput = false;

      final folderId = ensureFolder(scan.root, scan.name);
      final supported = scan.supported;
      final files = supported;
      const skippedByLimit = 0;
      response.write('event: start\ndata: ${jsonEncode({
        'token': token,
        'folder_id': folderId,
        'root': scan.root,
        'name': scan.name,
        'total': files.length,
        'subject_key': record.key,
      })}\n\n');
      await response.flush();

      var imported = 0;
      var skipped = skippedByLimit;
      var failed = 0;
      var done = 0;
      try {
        for (final file in files) {
          if (_importCancels[token] == true) break;
          final result = await importFolderFile(file, folderId, duplicate);
          final status = (result['status'] ?? 'failed').toString();
          if (status == 'imported') imported++;
          if (status == 'skipped') skipped++;
          if (status == 'failed') failed++;
          done++;
          response.write('event: file\ndata: ${jsonEncode({
            'name': file.name,
            'relative': file.relative,
            'status': status,
            'reason': result['reason'] ?? '',
            'pages': result['pages'] ?? 0,
            'chars': result['chars'] ?? 0,
          })}\n\n');
          response.write('event: progress\ndata: ${jsonEncode({'done': done, 'total': files.length})}\n\n');
          await response.flush();
        }
        final cancelled = _importCancels[token] == true;
        Db.run('UPDATE material_folders SET last_scan_at=? WHERE id=?', [Db.nowIso(), folderId]);
        response.write('event: done\ndata: ${jsonEncode({
          'cancelled': cancelled,
          'imported': imported,
          'skipped': skipped,
          'failed': failed,
          'folder_id': folderId,
          'subject_key': record.key,
        })}\n\n');
        await response.flush();
      } catch (_) {
        // 客户端断开时停止导入。
      } finally {
        _importCancels.remove(token);
        await response.close();
      }
    }, jsonBody: body);
  }

  // ------------------------------------------------------------ upload / materials

  static const _imageExts = {'.png', '.jpg', '.jpeg', '.webp', '.gif', '.bmp'};

  static Future<void> _cloud(
    HttpRequest request,
    List<String> segments,
  ) async {
    if (segments.length != 3 || segments[2] != 'config') {
      return _json(request, 404, {'detail': 'not found'});
    }
    if (request.method == 'GET') {
      return _json(request, 200, {
        'url': Db.setting('cloud_url', ''),
        'key': Db.setting('cloud_key', ''),
        'device_id': Db.setting('cloud_device_id', ''),
        'device_name': Db.setting(
          'cloud_device_name',
          Platform.localHostname,
        ),
        'auto_sync': Db.setting('cloud_auto_sync', 'true') == 'true',
        'refresh_token': Db.setting('cloud_refresh_token', ''),
        'last_snapshot': Db.setting('cloud_last_snapshot', ''),
      });
    }
    if (request.method != 'PUT') {
      return _json(request, 405, {'detail': 'method not allowed'});
    }
    final body = await _jsonBody(request);
    final url = (body['url'] ?? '').toString().trim();
    if (url.isNotEmpty) {
      final parsed = Uri.tryParse(url);
      if (parsed == null ||
          parsed.scheme != 'https' ||
          parsed.host.isEmpty) {
        return _json(request, 400, {
          'detail': 'Supabase URL 必须是 https://xxx.supabase.co',
        });
      }
      Db.setSetting('cloud_url', url.replaceAll(RegExp(r'/+$'), ''));
    }
    if (body['key'] is String) {
      final key = body['key'].toString().trim();
      if (key.toLowerCase().contains('service_role')) {
        return _json(request, 400, {
          'detail': '不能使用 service_role key，请用 anon/publishable key。',
        });
      }
      Db.setSetting('cloud_key', key);
    }
    if (body['device_id'] is String) {
      Db.setSetting('cloud_device_id', body['device_id'].toString().trim());
    }
    if (body['device_name'] is String) {
      Db.setSetting(
        'cloud_device_name',
        body['device_name'].toString().trim(),
      );
    }
    if (body['auto_sync'] is bool) {
      Db.setSetting('cloud_auto_sync', body['auto_sync'] == true ? 'true' : 'false');
    }
    if (body['refresh_token'] is String) {
      Db.setSetting('cloud_refresh_token', body['refresh_token'].toString());
    }
    if (body['last_snapshot'] is String) {
      Db.setSetting('cloud_last_snapshot', body['last_snapshot'].toString());
    }
    return _json(request, 200, {'ok': true});
  }

  static Future<void> _upload(HttpRequest request) async {
    final bytes = await _readBytes(request);
    if (bytes.length > 30 * 1024 * 1024) {
      return _json(request, 413, {'detail': '文件太大（上限 30MB），先压缩或截取需要的部分。'});
    }
    final rawName = request.headers.value('x-filename') ?? 'file';
    final name = Uri.decodeComponent(rawName);
    final ext = p.extension(name).toLowerCase();
    // 上传落盘到**当前学科**的资料目录（§5.3：迁移后不再写 data/files）。
    return _scopedWrite(request, (record, db) async {
      final random = Random().nextInt(1 << 31).toRadixString(16);
      final targetDir = Directory(record.filesPath)..createSync(recursive: true);
      final savedPath = p.join(targetDir.path, '${DateTime.now().microsecondsSinceEpoch}_$random$ext');
      final file = File(savedPath);
      await file.writeAsBytes(bytes);

      final mime = request.headers.contentType?.mimeType ?? 'application/octet-stream';
      if (mime.startsWith('image/') || _imageExts.contains(ext)) {
        final id = db.insert('uploads', {
          'name': name,
          'path': savedPath,
          'mime': mime.startsWith('image/') ? mime : 'image/png',
          'created_at': Db.nowIso(),
        });
        return _json(request, 200, {
          'kind': 'image',
          'id': 'img_$id',
          'name': name,
          'subject_key': record.key,
        });
      }

      List<String> pages;
      try {
        pages = await extractPages(savedPath, ext);
      } catch (error) {
        if (file.existsSync()) file.deleteSync();
        return _json(request, 400, {'detail': '解析失败：$error'});
      }
      final total = pages.fold<int>(0, (sum, page) => sum + page.length);
      if (total < 10) {
        if (file.existsSync()) file.deleteSync();
        return _json(request, 400, {'detail': '这个文件里几乎抽不到文字（可能是扫描件）。可以先截图，再用图片提问。'});
      }

    final materialId = db.insert('materials', {
        'name': name,
        'kind': ext.replaceFirst('.', ''),
        'path': savedPath,
        'status': 'ready',
        'pages': pages.length,
        'chars': total,
        'created_at': Db.nowIso(),
      });
      final chunks = indexMaterial(materialId, pages);

      return _json(request, 200, {
        'kind': 'material',
        'id': 'mat_$materialId',
        'name': name,
        'pages': pages.length,
        'chars': total,
        'chunks': chunks,
        'subject_key': record.key,
        'preview': pages.isNotEmpty ? pages.first.substring(0, min(200, pages.first.length)) : '',
      });
    });
  }

  /// 图片按学科取；找不到时回退全局兼容库（迁移前遗留的 `data/files` 图片）。
  static Future<void> _serveUpload(HttpRequest request, int id) async {
    Map<String, Object?>? row;
    try {
      row = SubjectStore.db().one('SELECT * FROM uploads WHERE id=?', [id]);
    } catch (_) {
      row = null;
    }
    row ??= Db.one('SELECT * FROM uploads WHERE id=?', [id]);
    if (row == null) return _json(request, 404, {'detail': '图片不存在'});
    final file = File((row['path'] ?? '').toString());
    if (!file.existsSync()) return _json(request, 404, {'detail': '图片不存在'});
    request.response.headers.contentType = ContentType.parse((row['mime'] ?? 'image/png').toString());
    await request.response.addStream(file.openRead());
    return request.response.close();
  }

  // ------------------------------------------------------------ tasks / today

  static Future<void> _listTasks(HttpRequest request) async {
    final date = request.uri.queryParameters['date_str'];
    final status = request.uri.queryParameters['status'];
    var sql = 'SELECT * FROM tasks WHERE 1=1';
    final params = <Object?>[];
    if (date != null && date.isNotEmpty) {
      sql += " AND (due=? OR due='')";
      params.add(date);
    }
    if (status != null && status.isNotEmpty) {
      sql += ' AND status=?';
      params.add(status);
    }
    sql += " ORDER BY (due='') ASC, due ASC, id ASC LIMIT 200";
    return _scoped(request, (record, db) async {
      final rows = db.rows(sql, params);
      for (final row in rows) {
        row['subject_key'] = record.key;
      }
      return _json(request, 200, rows);
    });
  }

  static Future<void> _createTask(HttpRequest request) async {
    final body = await _jsonBody(request);
    final title = (body['title'] ?? '').toString().trim();
    if (title.isEmpty) return _json(request, 400, {'detail': '标题不能为空'});
    return _scopedWrite(request, (record, db) async {
      final id = db.insert('tasks', {
        'title': title,
        'due': (body['due'] ?? '').toString().trim(),
        'estimate_min': (body['estimate_min'] as num?)?.toInt() ?? 30,
        'status': 'todo',
        'created_at': Db.nowIso(),
      });
      return _json(request, 200, {'id': id, 'subject_key': record.key});
    }, jsonBody: body);
  }

  static Future<void> _patchTask(HttpRequest request, int id) async {
    final body = await _jsonBody(request);
    final fields = <String, Object?>{};
    for (final key in ['title', 'due', 'status', 'estimate_min']) {
      if (body[key] != null) fields[key] = body[key];
    }
    if (fields.isEmpty) return _json(request, 200, {'ok': true});
    if (fields['status'] == 'done') fields['done_at'] = Db.nowIso();
    return _scopedWrite(request, (record, db) async {
      final existing = db.one('SELECT id FROM tasks WHERE id=?', [id]);
      if (existing == null) return _json(request, 404, {'detail': '待办不存在'});
      final sets = fields.keys.map((key) => '$key=?').join(',');
      db.run('UPDATE tasks SET $sets WHERE id=?', [...fields.values, id]);
      return _json(request, 200, {'ok': true});
    }, jsonBody: body);
  }

  static Future<void> _today(HttpRequest request) async {
    final today = Db.today();
    return _scoped(request, (record, db) async {
      final tasks = db.rows(
        "SELECT * FROM tasks WHERE status='todo' AND (due<=? OR due='') "
        'ORDER BY (due=\'\') ASC, due ASC, id ASC LIMIT 50',
        [today],
      );
      final doneToday = db.scalar(
        "SELECT COUNT(*) FROM tasks WHERE status='done' AND substr(done_at,1,10)=?",
        [today],
      );
      final openTotal = db.scalar("SELECT COUNT(*) FROM tasks WHERE status='todo'");
      final overdue = db.scalar(
        "SELECT COUNT(*) FROM tasks WHERE status='todo' AND due<>'' AND due<?",
        [today],
      );
      return _json(request, 200, {
        'date': today,
        'tasks': tasks,
        'done_today': doneToday ?? 0,
        'open_total': openTotal ?? 0,
        'overdue': overdue ?? 0,
        'subject_key': record.key,
      });
    });
  }

  // ------------------------------------------------------------ generate

  static Future<String> _messageContent(int messageId) async {
    final row = Db.one('SELECT content FROM messages WHERE id=?', [messageId]);
    if (row == null) throw _HttpError(404, '消息不存在');
    final content = (row['content'] ?? '').toString().trim();
    if (content.isEmpty) throw _HttpError(400, '这条消息没有可用的正文');
    return content;
  }

  static Future<void> _generateNote(HttpRequest request) async {
    final body = await _jsonBody(request);
    final messageId = (body['message_id'] as num?)?.toInt() ?? 0;
    return _scopedWrite(request, (record, db) async {
      final String content;
      try {
        content = await _messageContent(messageId);
      } on _HttpError catch (error) {
        return _json(request, error.status, {'detail': error.message});
      }
      final prompt = '''把下面的内容整理成一页 Markdown 学习笔记。
只输出 JSON：{"title":"标题","body":"Markdown 正文"}
要求：有二级标题、要点列表、公式用 \$...\$；不要重复原话。
内容：
${content.length > 6000 ? content.substring(0, 6000) : content}''';
      try {
        final (text, _) = await complete(
          config: ProviderRegistry.config(),
          messages: [
            {'role': 'user', 'content': prompt},
          ],
          temperature: 0.3,
        );
        final data = extractJson(text);
        if (data is! Map || (data['body'] ?? '').toString().isEmpty) {
          return await _json(request, 400, {'detail': '模型没有返回可解析的笔记，再试一次。'});
        }
        final noteId = db.insert('notes', {
          'title': (data['title'] ?? '学习笔记').toString(),
          'body': data['body'].toString(),
          'source_ref': 'msg:$messageId',
          'created_at': Db.nowIso(),
        });
        return await _json(request, 200, {'id': noteId, 'subject_key': record.key});
      } on LlmException catch (error) {
        return await _json(request, 400, {'detail': error.message});
      }
    }, jsonBody: body);
  }

  static Future<void> _generateTask(HttpRequest request) async {
    final body = await _jsonBody(request);
    final messageId = (body['message_id'] as num?)?.toInt() ?? 0;
    return _scopedWrite(request, (record, db) async {
      final String content;
      try {
        content = await _messageContent(messageId);
      } on _HttpError catch (error) {
        return _json(request, error.status, {'detail': error.message});
      }
      final prompt = '''根据下面的学习内容，生成 1 个可以执行的复习待办。
只输出 JSON：{"title":"不超过 20 字","estimate_min":30}
内容：
${content.length > 4000 ? content.substring(0, 4000) : content}''';
      try {
        final (text, _) = await complete(
          config: ProviderRegistry.config(),
          messages: [
            {'role': 'user', 'content': prompt},
          ],
          temperature: 0.3,
        );
        final data = extractJson(text);
        final title = ((data is Map ? data['title'] : null) ?? '').toString().trim();
        final finalTitle = title.isEmpty ? '复习这次对话的内容' : title;
        final taskId = db.insert('tasks', {
          'title': finalTitle.length > 40 ? finalTitle.substring(0, 40) : finalTitle,
          'due': Db.today(),
          'estimate_min': (data is Map ? (data['estimate_min'] as num?)?.toInt() : null) ?? 30,
          'status': 'todo',
          'created_at': Db.nowIso(),
        });
        return await _json(request, 200, {'id': taskId, 'title': finalTitle, 'subject_key': record.key});
      } on LlmException catch (error) {
        return await _json(request, 400, {'detail': error.message});
      }
    }, jsonBody: body);
  }

  // ------------------------------------------------------------ 学科作用域

  /// 解析请求的学科作用域：`?subject=` → body.subject → `settings.active_subject`（§11.1）。
  /// 解析失败（不存在）抛 404，**不回退到他科**；归档学科只允许读（§3.5：
  /// "仍可被显式打开"），写操作抛 409。
  static SubjectRecord _subjectScope(
    HttpRequest request, {
    Map<String, dynamic>? body,
    bool write = false,
  }) {
    final query = request.uri.queryParameters['subject'];
    final fromQuery = (query != null && query.trim().isNotEmpty) ? query.trim() : null;
    final rawBody = body?['subject'];
    final fromBody =
        (rawBody != null && rawBody.toString().trim().isNotEmpty) ? rawBody.toString().trim() : null;
    final ref = fromQuery ?? fromBody;
    if (ref == null) return SubjectStore.activeSubject();
    final record = SubjectStore.require(ref);
    if (record.archived && write) throw SubjectError(409, '学科已归档：${record.name}');
    return record;
  }

  /// 只读请求：在本学科库作用域内执行 [body]（`Db.*` 自动路由到该库）。
  static Future<void> _scoped(
    HttpRequest request,
    Future<void> Function(SubjectRecord record, SubjectDb db) body, {
    Map<String, dynamic>? jsonBody,
  }) async {
    final record = _subjectScope(request, body: jsonBody);
    final db = SubjectStore.open(record.key);
    await Db.runScoped(
      db.database,
      () => body(record, db),
      subjectKey: record.key,
      filesDir: record.filesPath,
    );
  }

  /// 写请求：额外拒绝"已归档学科的写操作"（409）。
  static Future<void> _scopedWrite(
    HttpRequest request,
    Future<void> Function(SubjectRecord record, SubjectDb db) body, {
    Map<String, dynamic>? jsonBody,
  }) async {
    final record = _subjectScope(request, body: jsonBody, write: true);
    final db = SubjectStore.open(record.key);
    await Db.runScoped(
      db.database,
      () => body(record, db),
      subjectKey: record.key,
      filesDir: record.filesPath,
    );
  }

  // ------------------------------------------------------------ /api/skills（§9 教学技能）

  /// hub 白名单：只有后端登记过的 registry 能被访问。**前端即便伪造 hub
  /// 参数也无法指向任意 URL**（防 SSRF）——非白名单值直接 400。
  static String _skillHub(String? requested) {
    final hub = (requested ?? SkillHubAllowlist.defaultHub).trim().toLowerCase();
    if (!SkillHubAllowlist.contains(hub)) {
      throw SkillImportError('blocked', '不支持的 registry：$hub（仅允许 eduhub）', status: 400);
    }
    return hub;
  }

  static SkillImporter _skillImporter(String subjectKey, String hub) =>
      SkillImporter(subjectKey: subjectKey, registry: SkillRegistry.forHub(hub));

  static String _skillSlug(String raw) {
    final slug = raw.trim();
    if (slug.isEmpty) {
      throw SkillImportError('invalid_slug', '缺少 slug', status: 400);
    }
    if (!SkillRegistry.isValidSlug(slug)) {
      throw SkillImportError('invalid_slug', '非法 slug：$slug', status: 400);
    }
    return slug;
  }

  /// 对外的策略声明。**不把 verify 说成安全扫描**（research §4.3/§7.2）。
  static Map<String, dynamic> _skillPolicy() => {
        'hub_allowlist': SkillHubAllowlist.hubs.keys.toList(),
        'languages': SkillRegistry.languages,
        'auto_update': false,
        'auto_install': false,
        'verify_is_security_guarantee': false,
        'verify_note': 'registry 的静态扫描只覆盖已知高危模式，置信度通常为 low，'
            '且技能包没有签名——它不代表"安全"，只表示没有被规则命中。',
        'limits': {
          'max_file_bytes': SkillImportLimits.maxFileBytes,
          'max_total_bytes': SkillImportLimits.maxTotalBytes,
          'max_files': SkillImportLimits.maxFiles,
        },
      };

  static Future<void> _skills(HttpRequest request, List<String> segments) async {
    final method = request.method;

    // GET /api/skills —— 默认视图是「已安装」，纯本地读取，离线可用。
    if (segments.length == 2) {
      if (method != 'GET') return _json(request, 405, {'detail': 'method not allowed'});
      return _scoped(request, (record, db) async {
        final importer = _skillImporter(record.key, SkillHubAllowlist.defaultHub);
        final installed = [for (final item in importer.list()) item.toJson()];
        return _json(request, 200, {
          'ok': true,
          'subject_key': record.key,
          'hub': importer.registry.hub.name,
          'hub_label': importer.registry.hub.label,
          'web_url': importer.registry.hub.webUrl,
          'count': installed.length,
          'installed': installed,
          'policy': _skillPolicy(),
        });
      });
    }

    final action = segments[2];

    // F-13/AC-05 断言 7：以 lock 为权威重建索引，返回是否确实重建过。
    if (action == 'installed') {
      if (method != 'GET') return _json(request, 405, {'detail': 'method not allowed'});
      return _scoped(request, (record, db) async {
        final importer = _skillImporter(record.key, SkillHubAllowlist.defaultHub);
        final rebuilt = importer.rebuildIndex();
        final installed = [for (final item in importer.list()) item.toJson()];
        return _json(request, 200, {
          'ok': true,
          'subject_key': record.key,
          'hub': importer.registry.hub.name,
          'count': installed.length,
          'installed': installed,
          'index_rebuilt': rebuilt,
          'pinned': [for (final item in importer.list()) if (item.pinned) item.slug],
          'policy': _skillPolicy(),
        });
      });
    }

    // GET /api/skills/status —— 本地状态 + 缓存的联网探测结果（?probe=true 才真探）。
    if (action == 'status') {
      if (method != 'GET') return _json(request, 405, {'detail': 'method not allowed'});
      final probe = request.uri.queryParameters['probe'] == 'true';
      return _scoped(request, (record, db) async {
        final importer = _skillImporter(record.key, SkillHubAllowlist.defaultHub);
        var online = Db.setting('skill_hub_last_ok', 'false') == 'true';
        String? probeError;
        if (probe) {
          try {
            await importer.registry.search('', limit: 1);
            online = true;
            Db.setSetting('skill_hub_last_ok', 'true');
          } catch (error) {
            online = false;
            probeError = '$error';
            Db.setSetting('skill_hub_last_ok', 'false');
          }
          Db.setSetting('skill_hub_last_check_at', Db.nowIso());
        }
        final installed = importer.list();
        return _json(request, 200, {
          'ok': true,
          'subject_key': record.key,
          'online': online,
          'hub': importer.registry.hub.name,
          'hub_url': importer.registry.hub.baseUrl,
          'hub_allowlist': SkillHubAllowlist.hubUrls,
          'last_sync_at': Db.setting('skill_hub_last_check_at', ''),
          'stale': true,
          'installed_count': installed.length,
          'pinned_count': installed.where((item) => item.pinned).length,
          'probe_error': ?probeError,
        });
      });
    }

    // POST /api/skills/check-updates —— 只查不装（F-5）。离线时逐个标 offline。
    if (action == 'check-updates') {
      if (method != 'POST') return _json(request, 405, {'detail': 'method not allowed'});
      final body = await _jsonBody(request);
      final hub = _skillHub((body['hub'] ?? '').toString().trim().isEmpty
          ? null
          : body['hub'].toString());
      return _scopedWrite(request, (record, db) async {
        final importer = _skillImporter(record.key, hub);
        final items = <Map<String, dynamic>>[];
        for (final item in importer.list()) {
          if (item.pinned) {
            items.add({
              'slug': item.slug,
              'installed': item.version,
              'latest': item.version,
              'update_available': false,
              'pinned': true,
            });
            continue;
          }
          try {
            final detail = await importer.registry.detail(item.slug, files: false);
            items.add({
              'slug': item.slug,
              'installed': item.version,
              'latest': detail.version,
              'update_available': detail.version.isNotEmpty && detail.version != item.version,
              'pinned': false,
            });
          } catch (error) {
            final code = error is SkillRegistryError ? error.code : 'error';
            items.add({
              'slug': item.slug,
              'installed': item.version,
              'latest': '',
              'update_available': false,
              'offline': code == 'offline',
              'error': code,
            });
          }
        }
        Db.setSetting('skill_hub_last_check_at', Db.nowIso());
        return _json(request, 200, {
          'ok': true,
          'subject_key': record.key,
          'stale': false,
          'items': items,
        });
      }, jsonBody: body);
    }

    if (action == 'catalog') {
      if (method != 'GET') return _json(request, 405, {'detail': 'method not allowed'});
      final hub = _skillHub(request.uri.queryParameters['hub']);
      final query = request.uri.queryParameters['q'] ?? '';
      final language = (request.uri.queryParameters['language'] ?? '').trim();
      if (language.isNotEmpty && !SkillRegistry.isSupportedLanguage(language)) {
        throw SkillImportError(
            'unsupported_language', '只支持 zh / en 两种语言：$language', status: 400);
      }
      final limit = int.tryParse(request.uri.queryParameters['limit'] ?? '') ?? 30;
      return _scoped(request, (record, db) async {
        final importer = _skillImporter(record.key, hub);
        final skills = await importer.registry.search(query, limit: limit);
        return _json(request, 200, {
          'ok': true,
          'hub': importer.registry.hub.name,
          'web_url': importer.registry.hub.webUrl,
          'subject_key': record.key,
          'query': query,
          'languages': SkillRegistry.languages,
          'installed_slugs': [for (final item in importer.list()) item.slug],
          'skills': [for (final item in skills) item.toJson()],
        });
      });
    }

    if (action == 'detail') {
      if (method != 'GET') return _json(request, 405, {'detail': 'method not allowed'});
      final hub = _skillHub(request.uri.queryParameters['hub']);
      final slug = _skillSlug(request.uri.queryParameters['slug'] ?? '');
      final version = (request.uri.queryParameters['version'] ?? '').trim();
      return _scoped(request, (record, db) async {
        final importer = _skillImporter(record.key, hub);
        final detail = await importer.registry
            .detail(slug, version: version.isEmpty ? null : version, files: true);
        return _json(request, 200, {
          'ok': true,
          'subject_key': record.key,
          'hub': importer.registry.hub.name,
          'skill': detail.toJson(),
        });
      });
    }

    if (action == 'verify') {
      if (method != 'GET') return _json(request, 405, {'detail': 'method not allowed'});
      final hub = _skillHub(request.uri.queryParameters['hub']);
      final slug = _skillSlug(request.uri.queryParameters['slug'] ?? '');
      final version = (request.uri.queryParameters['version'] ?? '').trim();
      return _scoped(request, (record, db) async {
        final importer = _skillImporter(record.key, hub);
        final verdict = await importer.registry
            .verify(slug, version: version.isEmpty ? null : version);
        return _json(request, 200, {
          'ok': true,
          'subject_key': record.key,
          'slug': slug,
          'verdict': verdict.toJson(),
        });
      });
    }

    if (action == 'playbooks') {
      if (method != 'GET') return _json(request, 405, {'detail': 'method not allowed'});
      return _scoped(request, (record, db) async {
        final importer = _skillImporter(record.key, SkillHubAllowlist.defaultHub);
        final items = importer.enabledPlaybooks();
        return _json(request, 200, {
          'ok': true,
          'subject_key': record.key,
          'count': items.length,
          'skills': items,
        });
      });
    }

    if (action == 'install') {
      if (method != 'POST') return _json(request, 405, {'detail': 'method not allowed'});
      final body = await _jsonBody(request);
      final hub = _skillHub((body['hub'] ?? '').toString().trim().isEmpty
          ? null
          : body['hub'].toString());
      final slug = _skillSlug((body['slug'] ?? '').toString());
      final version = (body['version'] ?? '').toString().trim();
      final language = (body['language'] ?? '').toString().trim();
      if (language.isNotEmpty && !SkillRegistry.isSupportedLanguage(language)) {
        throw SkillImportError(
            'unsupported_language', '只支持 zh / en 两种语言：$language', status: 400);
      }
      // 默认允许"裁决不可得时降级安装"，但会明确标注 unverified。
      final allowUnverified = body['allow_unverified'] != false;
      final allowSuspicious = body['allow_suspicious'] == true;
      return _scopedWrite(request, (record, db) async {
        final importer = _skillImporter(record.key, hub);
        try {
          final installed = await importer.install(
            slug,
            version: version.isEmpty ? null : version,
            allowUnverified: allowUnverified,
            allowSuspicious: allowSuspicious,
          );
          _skillAudit(
            action: installed.already ? 'skill_reinstall' : 'skill_install',
            subjectKey: record.key,
            detail: {'slug': slug, 'version': installed.version, 'hub': hub},
          );
          return await _json(request, 200, {
            'ok': true,
            'subject_key': record.key,
            'hub': importer.registry.hub.name,
            'skill': installed.toJson(),
            'already': installed.already,
            'auto_update': false,
          });
        } on SkillNeedsConfirm catch (confirm) {
          // F-8 / AC-04 断言 2：不是错误，而是"需要一次显式确认"。
          _skillAudit(
            action: 'skill_install_needs_confirm',
            subjectKey: record.key,
            detail: {'slug': slug, 'decision': confirm.verdict.decision},
            risk: 'review',
          );
          return _json(request, 200, {
            'ok': false,
            'subject_key': record.key,
            'slug': slug,
            'needs_confirm': true,
            'stage': 'verify',
            'verdict': confirm.verdict.toJson(),
            'message': confirm.detail,
            'install_url': importer.registry.hub.skillWebUrl(slug),
          });
        }
      }, jsonBody: body);
    }

    // {slug} 级操作：enable / disable / rollback / pin / update（POST）、raw（GET）、DELETE。
    if (segments.length == 4) {
      final slug = _skillSlug(segments[2]);
      final op = segments[3];

      // GET /api/skills/{slug}/raw —— 只读文本（白名单文件 + 目录内防穿越）。
      if (op == 'raw') {
        if (method != 'GET') return _json(request, 405, {'detail': 'method not allowed'});
        final rel = (request.uri.queryParameters['path'] ?? 'SKILL.md').trim();
        return _scoped(request, (record, db) async {
          final importer = _skillImporter(record.key, SkillHubAllowlist.defaultHub);
          final item = importer.require(slug);
          final target = p.normalize(p.join(item.pkgDir, rel));
          if (!p.isWithin(p.normalize(item.pkgDir), target)) {
            throw SkillImportError('bad_path', '路径必须在该技能目录内：$rel', status: 400);
          }
          if (!SkillImportLimits.allowedSuffixes
              .contains(SkillImportLimits.suffixOf(rel))) {
            throw SkillImportError('suffix_not_allowed', '该文件类型不提供读取：$rel', status: 400);
          }
          final file = File(target);
          if (!file.existsSync()) {
            throw SkillImportError('not_found', '文件不存在：$rel', status: 404);
          }
          if (file.lengthSync() > 200000) {
            throw SkillImportError('too_large', '文件过大（>200KB）：$rel', status: 413);
          }
          return _json(request, 200, {
            'ok': true,
            'subject_key': record.key,
            'slug': slug,
            'path': rel,
            'text': file.readAsStringSync(),
          });
        });
      }

      // POST /api/skills/{slug}/update —— 同 install 语义（F-5）。
      if (op == 'update') {
        if (method != 'POST') return _json(request, 405, {'detail': 'method not allowed'});
        final body = await _jsonBody(request);
        final version = (body['version'] ?? '').toString().trim();
        return _scopedWrite(request, (record, db) async {
          final importer = _skillImporter(record.key, SkillHubAllowlist.defaultHub);
          final before = importer.require(slug);
          if (before.pinned && body['unpin'] != true) {
            throw SkillImportError(
                'pinned', '该技能已锁定版本，先解锁才能更新：$slug', status: 409);
          }
          final installed = await importer.install(
            slug,
            version: version.isEmpty ? null : version,
            allowUnverified: body['allow_unverified'] != false,
            allowSuspicious: body['allow_suspicious'] == true,
          );
          _skillAudit(
            action: 'skill_update',
            subjectKey: record.key,
            detail: {
              'slug': slug,
              'from': before.version,
              'to': installed.version,
            },
          );
          return _json(request, 200, {
            'ok': true,
            'subject_key': record.key,
            'previous_version': before.version,
            'skill': installed.toJson(),
          });
        }, jsonBody: body);
      }

      if (op != 'enable' &&
          op != 'disable' &&
          op != 'rollback' &&
          op != 'pin') {
        return _json(request, 404, {'detail': 'not found'});
      }
      if (method != 'POST') return _json(request, 405, {'detail': 'method not allowed'});
      final body = op == 'pin' ? await _jsonBody(request) : const <String, dynamic>{};
      return _scopedWrite(request, (record, db) async {
        final importer = _skillImporter(record.key, SkillHubAllowlist.defaultHub);
        final InstalledSkill skill;
        switch (op) {
          case 'enable':
            skill = importer.setEnabled(slug, true);
          case 'disable':
            skill = importer.setEnabled(slug, false);
          case 'pin':
            skill = importer.setPinned(slug, body['pinned'] != false);
          default:
            skill = importer.rollback(slug);
        }
        _skillAudit(
          action: 'skill_$op',
          subjectKey: record.key,
          detail: {'slug': slug, 'version': skill.version},
        );
        return _json(request, 200, {
          'ok': true,
          'subject_key': record.key,
          'action': op,
          'skill': skill.toJson(),
        });
      }, jsonBody: op == 'pin' ? body : null);
    }

    if (segments.length == 3 && method == 'DELETE') {
      final slug = _skillSlug(segments[2]);
      // F-5：DELETE 必须带 confirm（= slug 或 1）。
      final confirm = request.uri.queryParameters['confirm'] ?? '';
      if (confirm.isEmpty) {
        throw SkillImportError('confirm_required', '删除技能需要二次确认（confirm=$slug）', status: 400);
      }
      if (confirm != slug && confirm != '1' && confirm != 'true') {
        throw SkillImportError('confirm_mismatch', 'confirm 与 slug 不符：$confirm', status: 400);
      }
      return _scopedWrite(request, (record, db) async {
        final importer = _skillImporter(record.key, SkillHubAllowlist.defaultHub);
        final result = importer.remove(slug);
        _skillAudit(
          action: 'skill_remove',
          subjectKey: record.key,
          detail: {'slug': slug, 'dir_delete_pending': result['dir_delete_pending'] == true},
        );
        return _json(request, 200, {...result, 'subject_key': record.key});
      });
    }

    return _json(request, 404, {'detail': 'not found'});
  }

  /// F-3 / AC-09 断言 6：技能操作写 `agent_audit`（带 subject_key、approval=user）。
  static void _skillAudit({
    required String action,
    required String subjectKey,
    required Map<String, dynamic> detail,
    String risk = 'low',
  }) {
    try {
      Db.globalRun(
        'INSERT INTO agent_audit(tool, args, result, risk, approval, subject_key, created_at) '
        'VALUES(?,?,?,?,?,?,?)',
        [
          action,
          jsonEncode(detail),
          'ok',
          risk,
          'user',
          subjectKey,
          Db.nowIso(),
        ],
      );
    } catch (error) {
      stderr.writeln('skill audit failed: $action $error');
    }
  }

  // ------------------------------------------------------------ /api/subjects

  static Future<void> _subjects(HttpRequest request, List<String> segments) async {
    final method = request.method;
    SubjectStore.init();

    if (segments.length == 2) {
      if (method == 'GET') {
        final includeArchived = request.uri.queryParameters['include_archived'] == 'true';
        final withCounts = request.uri.queryParameters['counts'] == 'true';
        final items = [
          for (final record in SubjectStore.list(includeArchived: includeArchived))
            record.toJson(counts: withCounts ? SubjectStore.counts(record.key) : null),
        ];
        return _json(request, 200, items);
      }
      if (method == 'POST') {
        final body = await _jsonBody(request);
        final record = SubjectStore.create(
          name: (body['name'] ?? '').toString(),
          description: (body['description'] ?? '').toString(),
          icon: (body['icon'] ?? '').toString(),
          color: (body['color'] ?? '').toString(),
          goal: (body['goal'] ?? '').toString(),
          examDate: (body['exam_date'] ?? '').toString(),
          dailyMinutes: (body['daily_minutes'] as num?)?.toInt() ?? 0,
          level: (body['level'] ?? '').toString(),
        );
        return _json(request, 200, record.toJson());
      }
      return _json(request, 405, {'detail': 'method not allowed'});
    }

    if (segments[2] == 'active') {
      if (method == 'GET') return _json(request, 200, SubjectStore.activeSubject().toJson());
      if (method == 'PUT' || method == 'POST') {
        final body = await _jsonBody(request);
        final record = SubjectStore.setActive((body['subject'] ?? body['key'] ?? '').toString());
        return _json(request, 200, {'ok': true, 'active_subject': record.key, 'subject': record.toJson()});
      }
      return _json(request, 405, {'detail': 'method not allowed'});
    }

    // {id} 可以是数字主键，也可以是学科 key（§3.1）；都找不到即 404。
    final resolved = SubjectStore.resolve(segments[2]);
    if (resolved == null) throw SubjectError(404, '学科不存在：${segments[2]}');
    final id = resolved.id;
    final record = resolved;

    // /api/subjects/{id}/progress*（§11.4）：作用域来自**路径 id**，不看他科。
    if (segments.length >= 4 && segments[3] == 'progress') {
      return _subjectProgress(request, segments, record);
    }

    if (segments.length == 4) {
      switch (segments[3]) {
        case 'archive':
          if (method != 'POST') return _json(request, 405, {'detail': 'method not allowed'});
          return _json(request, 200, SubjectStore.archive(id).toJson());
        case 'restore':
          if (method != 'POST') return _json(request, 405, {'detail': 'method not allowed'});
          return _json(request, 200, SubjectStore.restore(id).toJson());
        case 'rebuild-empty':
          if (method != 'POST') return _json(request, 405, {'detail': 'method not allowed'});
          return _json(request, 200, SubjectStore.rebuildEmpty(id).toJson());
        case 'remove-registry':
          if (method != 'POST') return _json(request, 405, {'detail': 'method not allowed'});
          SubjectStore.removeRegistryRow(id);
          return _json(request, 200, {'ok': true, 'removed': record.key});
        case 'path':
          if (method != 'GET') return _json(request, 405, {'detail': 'method not allowed'});
          return _json(request, 200, {
            'key': record.key,
            'data_dir': AppPaths.data.path,
            'db_path': record.dbPath,
            'files_dir': record.filesPath,
            'skills_dir': record.skillsPath,
          });
      }
      return _json(request, 404, {'detail': 'not found'});
    }

    if (segments.length == 3) {
      if (method == 'PATCH') {
        final body = await _jsonBody(request);
        return _json(request, 200, SubjectStore.patch(id, body).toJson());
      }
      if (method == 'GET') return _json(request, 200, record.toJson());
      if (method == 'DELETE') {
        final confirm = request.uri.queryParameters['confirm'] ?? '';
        return _json(request, 200, SubjectStore.delete(id, confirm));
      }
      return _json(request, 405, {'detail': 'method not allowed'});
    }

    return _json(request, 404, {'detail': 'not found'});
  }

  // ------------------------------------------------------------ 学习进度（§11.4）

  /// `/api/subjects/{id}/progress`（GET/PATCH）、`/progress/events`（POST）、
  /// `/progress/recompute`（POST）、`/progress/topics/{topicId}`（DELETE）。
  /// 作用域来自路径上的学科 id/key：**绝不回退到他科**；归档学科只读。
  static Future<void> _subjectProgress(
    HttpRequest request,
    List<String> segments,
    SubjectRecord record,
  ) async {
    final method = request.method;
    final handle = SubjectStore.open(record.key);

    Future<T> run<T>(Future<T> Function() body, {bool write = false}) {
      if (write && record.archived) {
        throw SubjectError(409, '学科已归档：${record.name}');
      }
      return Db.runScoped(
        handle.database,
        body,
        subjectKey: record.key,
        filesDir: record.filesPath,
      );
    }

    if (segments.length == 4) {
      if (method == 'GET') {
        final query = request.uri.queryParameters;
        final limit = int.tryParse(query['limit'] ?? '') ?? 50;
        final offset = int.tryParse(query['offset'] ?? '') ?? 0;
        final days = int.tryParse(query['days'] ?? '') ?? 30;
        final includeArchived = query['include_archived'] == 'true';
        final data = await run(() async => ProgressModel.snapshot(
              topicLimit: limit.clamp(1, 200),
              topicOffset: offset < 0 ? 0 : offset,
              dailyDays: days.clamp(1, 180),
              includeArchivedTopics: includeArchived,
            ));
        data['subject_id'] = record.id;
        return _json(request, 200, data);
      }
      if (method == 'PATCH') {
        final body = await _jsonBody(request);
        final data = await run(() async => ProgressModel.patch(body), write: true);
        data['subject_id'] = record.id;
        return _json(request, 200, data);
      }
      return _json(request, 405, {'detail': 'method not allowed'});
    }

    if (segments.length == 5) {
      final action = segments[4];
      if (action == 'events' && method == 'POST') {
        final body = await _jsonBody(request);
        final data = await run(
          () async => ProgressModel.recordEvents(
            (body['events'] as List?) ?? const [],
            messageId: (body['message_id'] as num?)?.toInt() ?? 0,
            materialId: (body['material_id'] as num?)?.toInt() ?? 0,
          ),
          write: true,
        );
        data['subject_id'] = record.id;
        return _json(request, 200, data);
      }
      if (action == 'recompute' && method == 'POST') {
        final data = await run(() async => ProgressModel.recompute(), write: true);
        data['subject_id'] = record.id;
        return _json(request, 200, data);
      }
      return _json(request, 405, {'detail': 'method not allowed'});
    }

    if (segments.length == 6 && segments[4] == 'topics' && method == 'DELETE') {
      final topicId = int.tryParse(segments[5]);
      if (topicId == null) return _json(request, 400, {'detail': 'bad topic id'});
      final data = await run(() async => ProgressModel.archiveTopic(topicId), write: true);
      if (data == null) return _json(request, 404, {'detail': '知识点不存在：$topicId'});
      data['subject_id'] = record.id;
      return _json(request, 200, data);
    }

    return _json(request, 404, {'detail': 'not found'});
  }

  // ------------------------------------------------------------ /api/migrations

  static Future<void> _migrations(HttpRequest request, List<String> segments) async {
    if (segments.length == 3 && segments[2] == 'status' && request.method == 'GET') {
      return _json(request, 200, SubjectMigration.status());
    }
    if (segments.length == 3 && segments[2] == 'run' && request.method == 'POST') {
      return _json(request, 200, SubjectMigration.ensureApplied());
    }
    return _json(request, 404, {'detail': 'not found'});
  }

  // ------------------------------------------------------------ /api/diagnostics

  static Future<void> _diagnostics(HttpRequest request, List<String> segments) async {
    if (segments.length == 4 && segments[2] == 'subject' && request.method == 'GET') {
      final id = int.tryParse(segments[3]);
      if (id == null) return _json(request, 400, {'detail': 'bad id'});
      return _json(request, 200, SubjectStore.diagnostics(id));
    }
    return _json(request, 404, {'detail': 'not found'});
  }

  // ------------------------------------------------------------ helpers

  static Future<void> _fetchProviderModels(HttpRequest request) async {
    final body = await _jsonBody(request);
    ProviderRegistry.ensureMigrated();
    final providerId = body['provider_id']?.toString();
    final config = ProviderRegistry.config(
      providerId: (providerId == null || providerId.isEmpty) ? null : providerId,
    );
    try {
      final models = await fetchModels(config);
      return await _json(request, 200, {
        'ok': true,
        'provider_id': config.providerId,
        'models': [for (final item in models) item.id],
        'message': models.isEmpty
            ? '${config.providerName} 端点没有返回模型'
            : '拉取到 ${models.length} 个模型',
      });
    } on LlmException catch (error) {
      return _json(request, 200, {'ok': false, 'message': error.message});
    } catch (error) {
      return _json(request, 200, {'ok': false, 'message': '拉取失败：$error'});
    }
  }

  static Future<void> _testSettings(HttpRequest request) async {
    final body = await _jsonBody(request);
    ProviderRegistry.ensureMigrated();
    final providerId = body['provider_id']?.toString();
    final modelOverride = body['model']?.toString().trim();
    final config = ProviderRegistry.config(
      providerId: (providerId == null || providerId.isEmpty) ? null : providerId,
      modelOverride: (modelOverride == null || modelOverride.isEmpty) ? null : modelOverride,
    );
    if (!config.ready) {
      return _json(request, 200, {
        'ok': false,
        'message': '还没有填写 ${config.providerName} API Key',
      });
    }
    try {
      final (text, _) = await complete(
        config: config,
        messages: [
          {'role': 'user', 'content': '只回复两个字：可用'},
        ],
        temperature: 0,
        maxTokens: 8,
      );
      return await _json(request, 200, {
        'ok': true,
        'message':
            '连接正常（${config.providerName} · ${config.model}）：${text.length > 20 ? text.substring(0, 20) : text}',
      });
    } on LlmException catch (error) {
      return _json(request, 200, {'ok': false, 'message': error.message});
    } catch (error) {
      return _json(request, 200, {'ok': false, 'message': '连接失败：$error'});
    }
  }

  static Future<String> _body(HttpRequest request) =>
      utf8.decoder.bind(request).join();

  static Future<Map<String, dynamic>> _jsonBody(HttpRequest request) async {
    final raw = await _body(request);
    if (raw.trim().isEmpty) return <String, dynamic>{};
    final data = jsonDecode(raw);
    return data is Map ? data.cast<String, dynamic>() : <String, dynamic>{};
  }

  static Future<List<int>> _readBytes(HttpRequest request) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in request) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  static Future<void> _json(HttpRequest request, int status, Object? data) async {
    final response = request.response;
    response.statusCode = status;
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode(data));
    await response.close();
  }
}

class _HttpError implements Exception {
  _HttpError(this.status, this.message);
  final int status;
  final String message;
}
