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

/// 进程内 HTTP 服务：绑定 127.0.0.1:8765，和 Flutter UI 同进程，没有子进程。
class Backend {
  static HttpServer? _server;
  static const int port = 8765;

  static bool get running => _server != null;

  static Future<void> start() async {
    AppPaths.init();
    Db.init();
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

  static Future<void> _handle(HttpRequest request) async {
    try {
      await _route(request);
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
        });

      case 'settings':
        if (segments.length >= 3 && segments[2] == 'test' && method == 'POST') {
          return _testSettings(request);
        }
        if (method == 'GET') {
          final key = Db.setting('api_key');
          return _json(request, 200, {
            'api_key': key.length > 8 ? 'sk-${'•' * 8}${key.substring(key.length - 4)}' : (key.isEmpty ? '' : '已配置'),
            'has_key': key.isNotEmpty,
            'base_url': Db.setting('base_url', 'https://api.deepseek.com'),
            'model': Db.setting('model', 'deepseek-flash'),
            'reason_model': Db.setting('reason_model', 'deepseek-v4-pro'),
            'theme': Db.setting('theme', 'system'),
            'custom_modes': Db.setting('custom_modes', '[]'),
            'auto_check_updates': Db.setting('auto_check_updates', 'true') == 'true',
            'sidebar_collapsed': Db.setting('sidebar_collapsed', 'false') == 'true',
          });
        }
        if (method == 'PUT') {
          final body = await _jsonBody(request);
          if (body['api_key'] is String && !body['api_key'].toString().contains('•')) {
            Db.setSetting('api_key', body['api_key'].toString().trim());
          }
          for (final key in ['base_url', 'model', 'reason_model']) {
            if (body[key] is String && body[key].toString().isNotEmpty) {
              Db.setSetting(key, body[key].toString().trim());
            }
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
          if (body['custom_modes'] is String) {
            Db.setSetting('custom_modes', body['custom_modes'].toString());
          }
          request.response.statusCode = 200;
          return _json(request, 200, {
            'has_key': Db.setting('api_key').isNotEmpty,
            'base_url': Db.setting('base_url'),
            'model': Db.setting('model'),
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
            Db.run('DELETE FROM messages WHERE conversation_id=?', [id]);
            Db.run('DELETE FROM conversations WHERE id=?', [id]);
            return _json(request, 200, {'ok': true});
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
          return _json(request, 200, Db.rows('SELECT * FROM materials ORDER BY id DESC'));
        }
        final id = int.tryParse(segments.length > 2 ? segments[2] : '');
        if (id == null) return _json(request, 400, {'detail': 'bad id'});
        if (segments.length == 3 && method == 'DELETE') {
          await deleteMaterialById(id);
          return _json(request, 200, {'ok': true});
        }
        if (segments.length == 4 && segments[3] == 'preview' && method == 'GET') {
          final material = Db.one('SELECT * FROM materials WHERE id=?', [id]);
          if (material == null) return _json(request, 404, {'detail': '资料不存在'});
          final chunks = Db.rows(
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
            'text': text.isEmpty ? '（没有可显示的文字）' : (text.length > 5000 ? text.substring(0, 5000) : text),
          });
        }
        return _json(request, 404, {'detail': 'not found'});

      case 'uploads':
        final id = int.tryParse(segments.length > 2 ? segments[2] : '');
        if (id == null) return _json(request, 400, {'detail': 'bad id'});
        final row = Db.one('SELECT * FROM uploads WHERE id=?', [id]);
        if (row == null) return _json(request, 404, {'detail': '图片不存在'});
        final file = File((row['path'] ?? '').toString());
        if (!file.existsSync()) return _json(request, 404, {'detail': '图片不存在'});
        request.response.headers.contentType = ContentType.parse((row['mime'] ?? 'image/png').toString());
        await request.response.addStream(file.openRead());
        return request.response.close();

      case 'tasks':
        if (segments.length == 2) {
          if (method == 'GET') return _listTasks(request);
          if (method == 'POST') return _createTask(request);
        }
        final id = int.tryParse(segments.length > 2 ? segments[2] : '');
        if (id == null) return _json(request, 400, {'detail': 'bad id'});
        if (method == 'PATCH') return _patchTask(request, id);
        if (method == 'DELETE') {
          Db.run('DELETE FROM tasks WHERE id=?', [id]);
          return _json(request, 200, {'ok': true});
        }
        return _json(request, 404, {'detail': 'not found'});

      case 'today':
        return _today(request);

      case 'notes':
        if (segments.length == 2 && method == 'GET') {
          return _json(request, 200, Db.rows('SELECT * FROM notes ORDER BY id DESC LIMIT 100'));
        }
        final id = int.tryParse(segments.length > 2 ? segments[2] : '');
        if (id != null && method == 'DELETE') {
          Db.run('DELETE FROM notes WHERE id=?', [id]);
          return _json(request, 200, {'ok': true});
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

  static Future<void> _listConversations(HttpRequest request) async {
    final items = Db.rows('SELECT * FROM conversations ORDER BY updated_at DESC LIMIT 100');
    for (final item in items) {
      final id = item['id'];
      final last = Db.one('SELECT content FROM messages WHERE conversation_id=? ORDER BY id DESC LIMIT 1', [id]);
      item['preview'] = (last?['content'] ?? '').toString();
      if ((item['preview'] as String).length > 60) {
        item['preview'] = (item['preview'] as String).substring(0, 60);
      }
      item['messages'] = Db.scalar('SELECT COUNT(*) FROM messages WHERE conversation_id=?', [id]) ?? 0;
    }
    return _json(request, 200, items);
  }

  static Future<void> _createConversation(HttpRequest request) async {
    final body = await _jsonBody(request);
    final now = Db.nowIso();
    final id = Db.insert('conversations', {
      'title': (body['title'] ?? '新对话').toString(),
      'mode': 'answer',
      'created_at': now,
      'updated_at': now,
    });
    return _json(request, 200, {'id': id});
  }

  static Future<void> _listMessages(HttpRequest request, int conversationId) async {
    final items = Db.rows(
      'SELECT * FROM messages WHERE conversation_id=? ORDER BY id',
      [conversationId],
    );
    for (final item in items) {
      item['steps'] = Db.parseList(item['steps']);
      item['refs'] = Db.parseList(item['refs']);
      item['plan'] = Db.parseList(item['plan']);
    }
    return _json(request, 200, items);
  }

  // ------------------------------------------------------------ chat

  static Future<void> _chat(HttpRequest request) async {
    final body = await _jsonBody(request);
    final text = (body['text'] ?? '').toString().trim();
    final attachments = ((body['attachments'] as List?) ?? const [])
        .map((e) => e.toString())
        .where((e) => e.isNotEmpty)
        .toList();
    if (text.isEmpty && attachments.isEmpty) {
      return _json(request, 400, {'detail': '消息不能为空'});
    }

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
    final conversation = Db.one('SELECT * FROM conversations WHERE id=?', [conversationId]);
    if (conversation == null) return _json(request, 404, {'detail': '会话不存在'});

    final userMessageId = Db.insert('messages', {
      'conversation_id': conversationId,
      'role': 'user',
      'content': text,
      'steps': '[]',
      'refs': '[]',
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

    final run = AgentRuns.start(conversationId);
    response.write('event: run\ndata: ${jsonEncode({'run_id': run.id})}\n\n');
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
      final rows = Db.rows('''
        SELECT f.*, (SELECT COUNT(*) FROM materials m WHERE m.folder_id=f.id) AS file_count
        FROM material_folders f ORDER BY f.id DESC
      ''');
      return _json(request, 200, rows);
    }
    if (segments.length == 4 && request.method == 'DELETE') {
      final id = int.tryParse(segments[3]);
      if (id == null) return _json(request, 400, {'detail': 'bad id'});
      await deleteFolderById(id);
      return _json(request, 200, {'ok': true});
    }
    if (segments.length == 5 && segments[4] == 'rescan' && request.method == 'POST') {
      final id = int.tryParse(segments[3]);
      final folder = Db.one('SELECT * FROM material_folders WHERE id=?', [id]);
      if (folder == null) return _json(request, 404, {'detail': '文件夹不存在'});
      return _json(request, 200, {
        'root_path': folder['root_path'],
        'name': folder['name'],
      });
    }
    return _json(request, 404, {'detail': 'not found'});
  }

  static Future<void> _scanFolder(HttpRequest request) async {
    final body = await _jsonBody(request);
    final path = (body['path'] ?? '').toString().trim();
    if (path.isEmpty) return _json(request, 400, {'detail': '缺少文件夹路径'});
    try {
      final scan = scanFolder(path, recursive: body['recursive'] != false);
      return await _json(request, 200, {
        'root': scan.root,
        'name': scan.name,
        'truncated': scan.truncated,
        'files': scan.files.map((file) => file.toJson()).toList(),
        'total': scan.files.length,
        'supported': scan.supported.length,
        'skipped': scan.files.length - scan.supported.length,
        'bytes': scan.totalBytes,
      });
    } catch (error) {
      return _json(request, 400, {'detail': '扫描失败：$error'});
    }
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
    final FolderScanResult scan;
    try {
      scan = scanFolder(path, recursive: recursive);
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
      })}\n\n');
      await response.flush();
    } catch (_) {
      // 客户端断开时停止导入。
    } finally {
      _importCancels.remove(token);
      await response.close();
    }
  }

  // ------------------------------------------------------------ upload / materials

  static const _imageExts = {'.png', '.jpg', '.jpeg', '.webp', '.gif', '.bmp'};

  static Future<void> _upload(HttpRequest request) async {
    final bytes = await _readBytes(request);
    if (bytes.length > 30 * 1024 * 1024) {
      return _json(request, 413, {'detail': '文件太大（上限 30MB），先压缩或截取需要的部分。'});
    }
    final rawName = request.headers.value('x-filename') ?? 'file';
    final name = Uri.decodeComponent(rawName);
    final ext = p.extension(name).toLowerCase();
    final random = Random().nextInt(1 << 31).toRadixString(16);
    final savedPath = p.join(AppPaths.files.path, '${DateTime.now().microsecondsSinceEpoch}_$random$ext');
    final file = File(savedPath);
    await file.writeAsBytes(bytes);

    final mime = request.headers.contentType?.mimeType ?? 'application/octet-stream';
    if (mime.startsWith('image/') || _imageExts.contains(ext)) {
      final id = Db.insert('uploads', {
        'name': name,
        'path': savedPath,
        'mime': mime.startsWith('image/') ? mime : 'image/png',
        'created_at': Db.nowIso(),
      });
      return _json(request, 200, {'kind': 'image', 'id': 'img_$id', 'name': name});
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

    final materialId = Db.insert('materials', {
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
      'preview': pages.isNotEmpty ? pages.first.substring(0, min(200, pages.first.length)) : '',
    });
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
    return _json(request, 200, Db.rows(sql, params));
  }

  static Future<void> _createTask(HttpRequest request) async {
    final body = await _jsonBody(request);
    final title = (body['title'] ?? '').toString().trim();
    if (title.isEmpty) return _json(request, 400, {'detail': '标题不能为空'});
    final id = Db.insert('tasks', {
      'title': title,
      'due': (body['due'] ?? '').toString().trim(),
      'estimate_min': (body['estimate_min'] as num?)?.toInt() ?? 30,
      'status': 'todo',
      'created_at': Db.nowIso(),
    });
    return _json(request, 200, {'id': id});
  }

  static Future<void> _patchTask(HttpRequest request, int id) async {
    final body = await _jsonBody(request);
    final fields = <String, Object?>{};
    for (final key in ['title', 'due', 'status', 'estimate_min']) {
      if (body[key] != null) fields[key] = body[key];
    }
    if (fields.isEmpty) return _json(request, 200, {'ok': true});
    if (fields['status'] == 'done') fields['done_at'] = Db.nowIso();
    final sets = fields.keys.map((key) => '$key=?').join(',');
    Db.run('UPDATE tasks SET $sets WHERE id=?', [...fields.values, id]);
    return _json(request, 200, {'ok': true});
  }

  static Future<void> _today(HttpRequest request) async {
    final today = Db.today();
    final tasks = Db.rows(
      "SELECT * FROM tasks WHERE status='todo' AND (due<=? OR due='') "
      'ORDER BY (due=\'\') ASC, due ASC, id ASC LIMIT 50',
      [today],
    );
    final doneToday = Db.scalar(
      "SELECT COUNT(*) FROM tasks WHERE status='done' AND substr(done_at,1,10)=?",
      [today],
    );
    final openTotal = Db.scalar("SELECT COUNT(*) FROM tasks WHERE status='todo'");
    final overdue = Db.scalar(
      "SELECT COUNT(*) FROM tasks WHERE status='todo' AND due<>'' AND due<?",
      [today],
    );
    return _json(request, 200, {
      'date': today,
      'tasks': tasks,
      'done_today': doneToday ?? 0,
      'open_total': openTotal ?? 0,
      'overdue': overdue ?? 0,
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
        config: LlmConfig.fromDb(),
        messages: [
          {'role': 'user', 'content': prompt},
        ],
        temperature: 0.3,
      );
      final data = extractJson(text);
      if (data is! Map || (data['body'] ?? '').toString().isEmpty) {
        return await _json(request, 400, {'detail': '模型没有返回可解析的笔记，再试一次。'});
      }
      final noteId = Db.insert('notes', {
        'title': (data['title'] ?? '学习笔记').toString(),
        'body': data['body'].toString(),
        'source_ref': 'msg:$messageId',
        'created_at': Db.nowIso(),
      });
      return await _json(request, 200, {'id': noteId});
    } on LlmException catch (error) {
      return await _json(request, 400, {'detail': error.message});
    }
  }

  static Future<void> _generateTask(HttpRequest request) async {
    final body = await _jsonBody(request);
    final messageId = (body['message_id'] as num?)?.toInt() ?? 0;
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
        config: LlmConfig.fromDb(),
        messages: [
          {'role': 'user', 'content': prompt},
        ],
        temperature: 0.3,
      );
      final data = extractJson(text);
      final title = ((data is Map ? data['title'] : null) ?? '').toString().trim();
      final finalTitle = title.isEmpty ? '复习这次对话的内容' : title;
      final taskId = Db.insert('tasks', {
        'title': finalTitle.length > 40 ? finalTitle.substring(0, 40) : finalTitle,
        'due': Db.today(),
        'estimate_min': (data is Map ? (data['estimate_min'] as num?)?.toInt() : null) ?? 30,
        'status': 'todo',
        'created_at': Db.nowIso(),
      });
      return await _json(request, 200, {'id': taskId, 'title': finalTitle});
    } on LlmException catch (error) {
      return await _json(request, 400, {'detail': error.message});
    }
  }

  // ------------------------------------------------------------ helpers

  static Future<void> _testSettings(HttpRequest request) async {
    final config = LlmConfig.fromDb();
    if (!config.ready) {
      return _json(request, 200, {'ok': false, 'message': '还没有填写 API Key'});
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
        'message': '连接正常（${config.model}）：${text.length > 20 ? text.substring(0, 20) : text}',
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
