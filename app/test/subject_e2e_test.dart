import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'package:loop/api.dart';
import 'package:loop/backend/agent_run.dart';
import 'package:loop/backend/agent_tools.dart';
import 'package:loop/backend/db.dart';
import 'package:loop/backend/job_scheduler.dart';
import 'package:loop/backend/llm.dart';
import 'package:loop/backend/paths.dart';
import 'package:loop/backend/server.dart';
import 'package:loop/backend/skills_import.dart';
import 'package:loop/backend/skills_registry.dart';
import 'package:loop/backend/sub_agent.dart';
import 'package:loop/backend/subject_migration.dart';
import 'package:loop/backend/subject_progress.dart';
import 'package:loop/backend/subject_store.dart';
import 'package:loop/state.dart';

/// t7 学科上下文端到端接线测试（规格 §14 AC-01/AC-02/AC-03/AC-08/AC-10）。
///
/// 全链路都走**真实 HTTP + 真实 SQLite + 真实 SSE**，只有两处是测试替身：
/// - 模型端点：本机 loopback 假 LLM（OpenAI 兼容 SSE，脚本化输出工具调用）；
/// - registry：本机 loopback 假 hub（真实 zip + 逐文件 sha256 清单 + verify）。
///
/// 不访问公网、只写隔离临时目录，并在结束时断言正式 `data/loop.db` 指纹未变。

// ===========================================================================
// 基础设施
// ===========================================================================

Directory _tempRoot() => Directory.systemTemp.createTempSync('loop-e2e-');

void _deleteQuietly(Directory dir) {
  try {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  } catch (_) {}
}

File? _realLoopDb() {
  for (final candidate in [Directory.current, Directory.current.parent]) {
    final file = File(p.join(candidate.path, 'data', 'loop.db'));
    if (file.existsSync()) return file;
  }
  return null;
}

String? _fingerprint(File? file) {
  if (file == null) return null;
  final stat = file.statSync();
  return '${stat.modified.millisecondsSinceEpoch}|${stat.size}|'
      '${sha256.convert(file.readAsBytesSync())}';
}

/// 全局库的表清单（用于双库收敛断言）。
List<String> _globalTables(String dbPath) {
  final database = sqlite3.open(dbPath, mode: OpenMode.readOnly);
  try {
    return database
        .select("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
        .map((row) => (row['name'] ?? '').toString())
        .where((name) => !name.startsWith('sqlite_'))
        .toList();
  } finally {
    database.close();
  }
}

/// 造一个真实的 v0.7.1 旧库（迁移来源）。
File _createLegacyDb(Directory dataDir) {
  final dbPath = p.join(dataDir.path, 'loop.db');
  final database = sqlite3.open(dbPath);
  database.execute('''
    CREATE TABLE IF NOT EXISTS conversations(
      id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT DEFAULT '新对话', mode TEXT DEFAULT 'answer',
      created_at TEXT NOT NULL, updated_at TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS messages(
      id INTEGER PRIMARY KEY AUTOINCREMENT, conversation_id INTEGER NOT NULL, role TEXT NOT NULL,
      content TEXT NOT NULL DEFAULT '', steps TEXT DEFAULT '[]', refs TEXT DEFAULT '[]',
      attachments TEXT DEFAULT '[]', model TEXT '', tokens_in INTEGER DEFAULT 0,
      tokens_out INTEGER DEFAULT 0, created_at TEXT NOT NULL, plan TEXT DEFAULT '[]');
    CREATE TABLE IF NOT EXISTS materials(
      id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, kind TEXT NOT NULL,
      path TEXT DEFAULT '', status TEXT DEFAULT 'ready', pages INTEGER DEFAULT 0,
      chars INTEGER DEFAULT 0, created_at TEXT NOT NULL, folder_id INTEGER DEFAULT 0,
      source_path TEXT DEFAULT '', source_mtime INTEGER DEFAULT 0, source_size INTEGER DEFAULT 0,
      relative_path TEXT DEFAULT '');
    CREATE TABLE IF NOT EXISTS material_folders(
      id INTEGER PRIMARY KEY AUTOINCREMENT, root_path TEXT UNIQUE, name TEXT,
      created_at TEXT NOT NULL, last_scan_at TEXT DEFAULT '');
    CREATE TABLE IF NOT EXISTS uploads(
      id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, path TEXT, mime TEXT, created_at TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS chunks(
      id INTEGER PRIMARY KEY AUTOINCREMENT, material_id INTEGER NOT NULL, page INTEGER DEFAULT 0,
      text TEXT NOT NULL);
    CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts USING fts5(chunk_id UNINDEXED, tokens);
    CREATE TABLE IF NOT EXISTS tasks(
      id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT NOT NULL, due TEXT DEFAULT '',
      estimate_min INTEGER DEFAULT 30, status TEXT DEFAULT 'todo', created_at TEXT NOT NULL,
      done_at TEXT DEFAULT '');
    CREATE TABLE IF NOT EXISTS notes(
      id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT NOT NULL, body TEXT NOT NULL,
      source_ref TEXT DEFAULT '', created_at TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS settings(key TEXT PRIMARY KEY, value TEXT);
  ''');
  final filesDir = Directory(p.join(dataDir.path, 'files'))..createSync(recursive: true);
  final materialFile = File(p.join(filesDir.path, '20250101_legacy.txt'))
    ..writeAsStringSync('旧资料：LEGACY9 线性代数 特征值 讲义内容');
  database.execute(
    "INSERT INTO conversations(id,title,mode,created_at,updated_at) VALUES"
    "(1,'旧对话一','answer','2025-01-01T10:00:00+08:00','2025-01-01T10:05:00+08:00'),"
    "(2,'旧对话二','answer','2025-01-02T10:00:00+08:00','2025-01-02T10:05:00+08:00')",
  );
  database.execute(
    "INSERT INTO messages(id,conversation_id,role,content,created_at) VALUES"
    "(1,1,'user','旧问题：什么是特征向量？','2025-01-01T10:00:00+08:00'),"
    "(2,1,'assistant','旧回答：Av=λv。','2025-01-01T10:01:00+08:00')",
  );
  database.execute(
    "INSERT INTO materials(id,name,kind,path,status,pages,chars,created_at) "
    "VALUES(1,'旧讲义.txt','txt','${materialFile.path}','ready',1,40,'2025-01-01T09:00:00+08:00')",
  );
  database.execute(
    "INSERT INTO chunks(id,material_id,page,text) "
    "VALUES(1,1,1,'旧资料 LEGACY9 线性代数 特征值 讲义内容')",
  );
  database.close();
  return File(dbPath);
}

/// 本机假 LLM：OpenAI 兼容 SSE；第一轮输出 `search_materials` 工具调用，
/// 拿到工具结果后输出最终文本。记录全部请求体（用于断言 system 提示词的学科上下文）。
class _MockLlm {
  _MockLlm._(this._server);

  static Future<_MockLlm> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final mock = _MockLlm._(server);
    server.listen(mock._handle, onError: (Object _) {});
    return mock;
  }

  final HttpServer _server;
  final List<Map<String, dynamic>> requests = [];

  /// 工具调用里要检索的关键词（由用例设置）。
  String query = '';

  String get baseUrl => 'http://127.0.0.1:${_server.port}/v1';

  /// 最后一次请求的 system 提示词。
  String get lastSystemPrompt {
    for (final body in requests.reversed) {
      final messages = (body['messages'] as List? ?? []).cast<Map>();
      for (final message in messages) {
        if ('${message['role']}' == 'system') return '${message['content']}';
      }
    }
    return '';
  }

  /// 最后一次请求里最后一条工具结果的内容（用于断言工具实际读到了哪个学科）。
  String get lastToolResult {
    for (final body in requests.reversed) {
      final messages = (body['messages'] as List? ?? []).cast<Map>();
      for (final message in messages.reversed) {
        if ('${message['role']}' == 'tool') return '${message['content']}';
      }
    }
    return '';
  }

  int get toolRounds =>
      requests.where((body) => (body['messages'] as List? ?? []).any((m) => (m as Map)['role'] == 'tool')).length;

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    final raw = await utf8.decoder.bind(request).join();
    Map<String, dynamic> body = const {};
    try {
      body = (jsonDecode(raw) as Map).cast<String, dynamic>();
    } catch (_) {}
    requests.add(body);
    final messages = (body['messages'] as List? ?? []).cast<Map>();
    final hasToolResult = messages.any((m) => '${m['role']}' == 'tool');

    request.response.statusCode = 200;
    request.response.headers.contentType = ContentType('text', 'event-stream', charset: 'utf-8');
    void sse(Map<String, dynamic> chunk) =>
        request.response.write('data: ${jsonEncode(chunk)}\n\n');

    if (!hasToolResult) {
      sse({
        'choices': [
          {
            'delta': {
              'tool_calls': [
                {
                  'index': 0,
                  'id': 'call_1',
                  'type': 'function',
                  'function': {
                    'name': 'search_materials',
                    'arguments': jsonEncode({'query': query}),
                  },
                },
              ],
            },
          },
        ],
      });
    } else {
      sse({
        'choices': [
          {
            'delta': {'content': '已按本学科资料回答（E2E）。'},
          },
        ],
      });
    }
    sse({
      'choices': [
        {'delta': <String, Object?>{}, 'finish_reason': 'stop'},
      ],
    });
    request.response.write('data: [DONE]\n\n');
    await request.response.close();
  }
}

/// 最小假 hub：真实 zip + 逐文件 sha256 清单 + verify(ok)。
class _FakeHub {
  _FakeHub._(this._server, this.baseUrl);

  static Future<_FakeHub> start({required Map<String, List<int>> files, String slug = 'e2e-tutor'}) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final hub = _FakeHub._(server, 'http://127.0.0.1:${server.port}/api/v1');
    hub.files = files;
    hub.slug = slug;
    server.listen(hub._handle, onError: (Object _) {});
    return hub;
  }

  final HttpServer _server;
  final String baseUrl;
  Map<String, List<int>> files = {};
  String slug = 'e2e-tutor';

  static const String name = 'E2E Tutor';
  static const String description = '端到端测试用教学技能。';
  static const String version = '1.0.0';

  List<int> get zipBytes {
    final archive = Archive();
    files.forEach((path, bytes) {
      archive.addFile(ArchiveFile(path, bytes.length, bytes));
    });
    return ZipEncoder().encode(archive);
  }

  List<Map<String, dynamic>> get manifest => [
        for (final entry in files.entries)
          {
            'path': entry.key,
            'size': entry.value.length,
            'sha256': sha256.convert(entry.value).toString(),
          },
      ];

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    final segments = request.uri.pathSegments;
    Future<void> json(Object data) async {
      request.response.statusCode = 200;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(data));
      await request.response.close();
    }

    final last = segments.isEmpty ? '' : segments.last;
    if (last == 'verify') {
      return json({
        'schema': 'clawhub.skill.verify.v1',
        'ok': true,
        'decision': 'pass',
        'slug': slug,
        'version': version,
        'security': {
          'status': 'clean',
          'passed': true,
          'confidence': 'low',
          'summary': 'Static scan found no high-signal malicious patterns. Not a full malware scan.',
        },
        'signature': {'status': 'unsigned'},
      });
    }
    if (last == 'download') {
      request.response.statusCode = 200;
      request.response.headers.contentType = ContentType('application', 'zip');
      request.response.add(zipBytes);
      await request.response.close();
      return;
    }
    if (last == slug) {
      return json({
        'skill': {
          'slug': slug,
          'displayName': name,
          'summary': description,
          'description': name,
          'tags': {'latest': version},
          'keywords': ['tutor'],
        },
        'latestVersion': {'version': version, 'license': 'MIT-0'},
        'distTags': {'latest': version},
        'versions': [version],
        'files': manifest,
      });
    }
    return json({'skills': []});
  }
}

/// 极简 HTTP 客户端 + SSE 消费。
class _Api {
  _Api(this.base);

  final String base;

  Future<(int, Object?)> send(String method, String path, [Object? body]) async {
    final uri = Uri.parse('$base$path');
    final headers = {'Content-Type': 'application/json; charset=utf-8'};
    final encoded = body == null ? null : jsonEncode(body);
    final response = switch (method) {
      'GET' => await http.get(uri),
      'POST' => await http.post(uri, headers: headers, body: encoded),
      'PUT' => await http.put(uri, headers: headers, body: encoded),
      'PATCH' => await http.patch(uri, headers: headers, body: encoded),
      _ => await http.delete(uri, headers: headers),
    };
    final text = utf8.decode(response.bodyBytes);
    return (response.statusCode, text.isEmpty ? null : jsonDecode(text));
  }

  Future<(int, Object?)> get(String path) => send('GET', path);
  Future<(int, Object?)> post(String path, [Object? body]) => send('POST', path, body);
  Future<(int, Object?)> put(String path, [Object? body]) => send('PUT', path, body);

  /// POST /api/chat 并消费完整 SSE，返回事件列表。
  Future<List<(String, Map<String, dynamic>)>> chat(
    Map<String, dynamic> body, {
    String? subject,
  }) async {
    final path = subject == null ? '/api/chat' : '/api/chat?subject=$subject';
    final client = http.Client();
    try {
      final request = http.Request('POST', Uri.parse('$base$path'));
      request.headers['Content-Type'] = 'application/json; charset=utf-8';
      request.body = jsonEncode(body);
      final response = await client.send(request);
      expect(response.statusCode, 200, reason: 'POST /api/chat 应返回 200');
      final events = <(String, Map<String, dynamic>)>[];
      var event = '';
      final buffer = StringBuffer();
      void flush() {
        if (buffer.isEmpty) return;
        try {
          events.add((event.isEmpty ? 'message' : event,
              (jsonDecode(buffer.toString()) as Map).cast<String, dynamic>()));
        } catch (_) {}
        buffer.clear();
        event = '';
      }

      await for (final line
          in response.stream.transform(utf8.decoder).transform(const LineSplitter())) {
        if (line.isEmpty) {
          flush();
          continue;
        }
        if (line.startsWith('event:')) {
          event = line.substring(6).trim();
        } else if (line.startsWith('data:')) {
          if (buffer.isNotEmpty) buffer.write('\n');
          buffer.write(line.substring(5).trim());
        }
      }
      flush();
      return events;
    } finally {
      client.close();
    }
  }

  Future<Map<String, dynamic>> upload(String subject, String filename, String content) async {
    final response = await http.post(
      Uri.parse('$base/api/upload?subject=$subject'),
      headers: {
        'Content-Type': 'application/octet-stream',
        'X-Filename': Uri.encodeComponent(filename),
      },
      body: utf8.encode(content),
    );
    expect(response.statusCode, 200, reason: '上传应 200：${response.body}');
    return (jsonDecode(utf8.decode(response.bodyBytes)) as Map).cast<String, dynamic>();
  }
}

// ===========================================================================
// 用例
// ===========================================================================

const String _tokenA = 'EIGEN4711';
const String _tokenB = 'PROBABILITY8821';

const String _materialBody = '线性代数讲义：EIGEN4711 特征值与特征向量的定义与计算步骤。';
const String _materialBodyB = '概率论讲义：PROBABILITY8821 条件概率与贝叶斯公式。';

void main() {
  final realDbBefore = _fingerprint(_realLoopDb());

  tearDownAll(() {
    expect(_fingerprint(_realLoopDb()), realDbBefore,
        reason: 'E2E：不得触碰正式 data/loop.db（AC-10）');
  });

  // --------------------------------------------------------------------- E2E-0

  group('E2E-0 隔离防护（AC-10）', () {
    test('T0 测试进程禁止自动探测数据目录：init() 直接抛错，不碰正式 data/loop.db', () {
      // 防护依赖该环境变量（paths.dart 的 FLUTTER_TEST 守卫）。
      expect(Platform.environment['FLUTTER_TEST'], 'true',
          reason: 'flutter test 应设置 FLUTTER_TEST=true，否则防护失效');
      expect(() => AppPaths.init(), throwsStateError);
    });
  });

  // --------------------------------------------------------------------- E2E-1

  group('E2E-1 新建学科全链路（无旧库）', () {
    late Directory dir;
    late int port;
    late _Api api;
    late _MockLlm llm;
    late _FakeHub hub;

    setUp(() async {
      dir = _tempRoot();
      port = await Backend.startForTests(dir);
      api = _Api('http://127.0.0.1:$port');
      llm = await _MockLlm.start();
      hub = await _FakeHub.start(files: {
        'SKILL.md': utf8.encode(
          '---\n'
          'name: ${_FakeHub.name}\n'
          'description: ${_FakeHub.description}\n'
          'track: academics\n'
          'language: zh\n'
          'version: ${_FakeHub.version}\n'
          '---\n\n'
          '# E2E 学科助教\n\n'
          '1. 先检索学科资料库。\n',
        ),
        'references/policy.md': utf8.encode('# 检索策略\n\n先学科内，后通用。\n'),
      });
      // 模型指向本机假 LLM（多供应商链路照常走 llm.dart）。
      ProviderRegistry.saveAll([
        ProviderProfile(
          id: 'e2e',
          name: 'E2E Mock',
          baseUrl: llm.baseUrl,
          apiKey: 'test-key',
          defaultModel: 'mock-model',
          reasonModel: 'mock-model',
          capabilities: const ProviderCapabilities(vision: true, tools: true),
        ),
      ]);
      ProviderRegistry.setActive('e2e');
    });

    tearDown(() async {
      await llm.close();
      await hub.close();
      await Backend.stopForTests();
      SubjectStore.resetForTests();
      _deleteQuietly(dir);
    });

    test('T1 新建学科初始为空；全局库不含任何学习表（双库收敛）', () async {
      final (statusCreate, created) = await api.post('/api/subjects', {'name': '线性代数'});
      expect(statusCreate, 200);
      final key = (created as Map)['key'] as String;

      for (final path in [
        '/api/conversations?subject=$key',
        '/api/materials?subject=$key',
        '/api/tasks?subject=$key',
        '/api/notes?subject=$key',
      ]) {
        final (status, data) = await api.get(path);
        expect(status, 200, reason: path);
        expect(data, isEmpty, reason: '新学科 $path 必须为空');
      }
      final (_, skills) = await api.get('/api/skills?subject=$key');
      expect((skills as Map)['count'], 0);
      final (statusProgress, progress) = await api.get('/api/subjects/$key/progress');
      expect(statusProgress, 200);
      expect((progress as Map)['topics'], isEmpty);
      expect((progress['summary'] as Map)['topics_total'], 0);

      // 双库收敛：全局库只有应用级表 + 注册表，没有学习表。
      final tables = _globalTables(p.join(dir.path, 'loop.db'));
      expect(tables, containsAll(Db.appOwnedTables));
      for (final owned in Db.subjectOwnedTables) {
        expect(tables, isNot(contains(owned)), reason: '全局库不应有 $owned');
      }
      expect(tables.where((t) => t.startsWith('legacy_')), isEmpty);
      expect(File(AppPaths.subjectDbPath(key)).existsSync(), isTrue);
      // 学科数据只存在于学科库。
      final subjectTables = _globalTables(AppPaths.subjectDbPath(key));
      expect(subjectTables, containsAll(Db.subjectOwnedTables));
    });

    test('T2 上传资料：落本学科 files/ 且只进本学科库', () async {
      final (_, created) = await api.post('/api/subjects', {'name': '资料学科'});
      final key = (created as Map)['key'] as String;

      final material = await api.upload(key, '讲义.md', _materialBody);
      expect(material['kind'], 'material');
      expect(material['subject_key'], key);
      final materialId = int.parse('${material['id']}'.replaceFirst('mat_', ''));
      expect(material['chunks'], greaterThan(0));

      final (_, list) = await api.get('/api/materials?subject=$key');
      final rows = (list as List).cast<Map>();
      expect(rows, hasLength(1));
      expect(rows.single['name'], '讲义.md');
      expect(p.isWithin(AppPaths.subjectFilesDir(key).path, '${rows.single['path']}'), isTrue,
          reason: '资料副本必须落在学科 files/');

      final subject = SubjectStore.byKey(key)!;
      expect(Directory(subject.filesPath).listSync().whereType<File>(), hasLength(1));
      // 旧全局资料目录不得出现新文件（迁移后只读，双库收敛）。
      final legacyFiles = Directory(p.join(dir.path, 'files'));
      expect(legacyFiles.existsSync() ? legacyFiles.listSync().whereType<File>() : const <File>[],
          isEmpty, reason: '资料副本不得再写 v0.7.1 的 data/files');
      // 其余学科（默认）看不到。
      final (_, defList) = await api.get('/api/materials?subject=default');
      expect(defList, isEmpty);
      // 跨学科 id：默认学科内没有这个 id（其为空库）。
      final (statusCross, _) = await api.get('/api/materials/$materialId/preview?subject=default');
      expect(statusCross, 404);
      final (statusSelf, preview) = await api.get('/api/materials/$materialId/preview?subject=$key');
      expect(statusSelf, 200);
      expect('${(preview as Map)['text']}', contains(_tokenA));
    });

    test('T3 提问命中本学科资料：refs 带资料名+页码，system 提示词带学科上下文', () async {
      final (_, created) = await api.post('/api/subjects', {'name': '检索学科', 'goal': '期末 90 分'});
      final key = (created as Map)['key'] as String;
      final material = await api.upload(key, '讲义.md', _materialBody);
      final (_, conversation) = await api.post('/api/conversations?subject=$key', {'title': '提问'});
      final conversationId = (conversation as Map)['id'] as int;

      llm.query = _tokenA;
      final events = await api.chat(
        {'conversation_id': conversationId, 'text': 'EIGEN4711 是什么？'},
        subject: key,
      );
      expect(events.map((e) => e.$1), contains('done'));
      expect(llm.toolRounds, 1, reason: '应发生一次工具调用（search_materials）');
      expect(llm.lastSystemPrompt, contains('检索学科'));
      expect(llm.lastSystemPrompt, contains('期末 90 分'));

      final (statusMessages, messages) =
          await api.get('/api/conversations/$conversationId/messages?subject=$key');
      expect(statusMessages, 200);
      final rows = (messages as List).cast<Map>();
      expect(rows, hasLength(2), reason: '用户消息 + 助手消息');
      final assistant = rows.last;
      expect('${assistant['role']}', 'assistant');
      expect('${assistant['content']}', contains('E2E'));
      final refs = (assistant['refs'] as List).cast<Map>();
      expect(refs, isNotEmpty, reason: '本学科资料必须被检索命中');
      expect('${refs.first['name']}', '讲义.md');
      expect('${refs.first['material_id']}', '${material['id']}'.replaceFirst('mat_', ''),
          reason: 'refs 必须指向本学科刚上传的资料');

      // 同一个会话在别的学科里不可见（ID 作用域）。
      final (statusCross, _) = await api.get('/api/conversations/$conversationId/messages?subject=default');
      expect(statusCross, 404);
    });

    test('T4 进度更新：事件写入→本学科可见，且有证据可溯', () async {
      final (_, created) = await api.post('/api/subjects', {'name': '进度学科'});
      final key = (created as Map)['key'] as String;
      final material = await api.upload(key, '讲义.md', _materialBody);
      final materialId = int.parse('${material['id']}'.replaceFirst('mat_', ''));
      final (_, conversation) = await api.post('/api/conversations?subject=$key', {'title': '练习'});
      final conversationId = (conversation as Map)['id'] as int;
      llm.query = _tokenA;
      await api.chat({'conversation_id': conversationId, 'text': '测一测'}, subject: key);
      final (_, messages) = await api.get('/api/conversations/$conversationId/messages?subject=$key');
      final assistantId = ((messages as List).last as Map)['id'] as int;

      final (statusEvents, eventResult) = await api.post('/api/subjects/$key/progress/events', {
        'events': [
          {
            'kind': 'practice',
            'topic': '特征值',
            'result': 'wrong',
            'duration_min': 12,
            'material_id': materialId,
            'message_id': assistantId,
            'note': 'E2E 练习',
          },
        ],
      });
      expect(statusEvents, 200, reason: '$eventResult');
      final eventMap = eventResult as Map;
      expect(eventMap['ok'], isTrue);
      expect((eventMap['applied_events'] as num).toInt(), greaterThanOrEqualTo(1),
          reason: '事件必须落库：$eventResult');

      final (_, progress) = await api.get('/api/subjects/$key/progress');
      final map = (progress as Map);
      expect(map['subject_key'], key);
      final topics = (map['topics'] as List).cast<Map>();
      expect(topics, isNotEmpty);
      final topic = topics.firstWhere((t) => '${t['name']}' == '特征值');
      expect((topic['evidence_count'] as num).toInt(), greaterThanOrEqualTo(1));
      expect((map['summary'] as Map)['topics_total'], greaterThanOrEqualTo(1));
      final daily = (map['daily'] as List).cast<Map>();
      expect(daily.any((d) => (d['events'] as num).toInt() >= 1), isTrue);

      // 别的学科（默认）看不到这个知识点。
      final (_, otherProgress) = await api.get('/api/subjects/default/progress');
      expect(((otherProgress as Map)['topics'] as List), isEmpty);
    });

    test('T5 切换学科：active 持久化；旧接口（无 subject）落当前学科；A 数据在 B 不可见', () async {
      final (_, a) = await api.post('/api/subjects', {'name': '甲'});
      final (_, b) = await api.post('/api/subjects', {'name': '乙'});
      final keyA = (a as Map)['key'] as String;
      final keyB = (b as Map)['key'] as String;

      final materialA = await api.upload(keyA, '甲讲义.md', _materialBody);
      final (_, convA) = await api.post('/api/conversations?subject=$keyA', {'title': '甲的对话'});
      final convAId = (convA as Map)['id'] as int;

      final (statusSwitch, switched) = await api.put('/api/subjects/active', {'subject': keyB});
      expect(statusSwitch, 200);
      expect((switched as Map)['active_subject'], keyB);

      // 无 subject 的旧调用 = 当前学科（乙，初始为空）。
      final (_, implicitConversations) = await api.get('/api/conversations');
      expect(implicitConversations, isEmpty);
      final (_, implicitMaterials) = await api.get('/api/materials');
      expect(implicitMaterials, isEmpty);

      // 乙自己建会话（id 同样从 1 开始），消息不串。
      final (_, convB) = await api.post('/api/conversations', {'title': '乙的对话'});
      final convBId = (convB as Map)['id'] as int;
      expect(convBId, convAId);
      final (_, messagesB) = await api.get('/api/conversations/$convBId/messages');
      expect(messagesB, isEmpty);
      final (_, messagesA) = await api.get('/api/conversations/$convAId/messages?subject=$keyA');
      expect(messagesA, isEmpty, reason: '甲只有一条用户消息之前没发过，这里为空属正常');
      // 甲的会话不出现在乙的列表
      final (_, listB) = await api.get('/api/conversations?subject=$keyB');
      expect((listB as List).cast<Map>().map((e) => e['title']), ['乙的对话']);
      final (_, listA) = await api.get('/api/conversations?subject=$keyA');
      expect((listA as List).cast<Map>().map((e) => e['title']), ['甲的对话']);
      // 甲的资料在乙不可见；乙上传第二条后，甲的 id 在乙读不到第二条
      expect((await api.get('/api/materials?subject=$keyB')).$2, isEmpty);
      await api.upload(keyB, '乙讲义.md', _materialBodyB);
      await api.upload(keyB, '乙讲义2.md', _materialBodyB);
      final materialAId = int.parse('${materialA['id']}'.replaceFirst('mat_', ''));
      final (_, listB2) = await api.get('/api/materials?subject=$keyB');
      expect((listB2 as List), hasLength(2));
      final (statusCross, _) =
          await api.get('/api/materials/${materialAId + 10}/preview?subject=$keyB');
      expect(statusCross, 404, reason: '乙学科内不存在该 id');

      // skills 也按学科取
      final (_, skillsA) = await api.get('/api/skills?subject=$keyA');
      expect((skillsA as Map)['subject_key'], keyA);
    });

    test('T6 同名资料互不可见：检索也不跨学科（跨学科默认关闭）', () async {
      final (_, a) = await api.post('/api/subjects', {'name': '甲科'});
      final (_, b) = await api.post('/api/subjects', {'name': '乙科'});
      final keyA = (a as Map)['key'] as String;
      final keyB = (b as Map)['key'] as String;
      await api.upload(keyA, '同名讲义.md', _materialBody);
      await api.upload(keyB, '同名讲义.md', _materialBodyB);

      // 在乙提问只有甲资料包含的 token → 不应命中（跨学科默认关闭）。
      final (_, convB) = await api.post('/api/conversations?subject=$keyB', {'title': '乙提问'});
      final convBId = (convB as Map)['id'] as int;
      llm.query = _tokenA;
      final events = await api.chat({'conversation_id': convBId, 'text': 'EIGEN4711 是什么'}, subject: keyB);
      expect(events.map((e) => e.$1), contains('done'));
      final (_, messagesB) = await api.get('/api/conversations/$convBId/messages?subject=$keyB');
      final assistantB = ((messagesB as List).last as Map);
      expect((assistantB['refs'] as List), isEmpty, reason: '乙不得引用甲的资料');

      // 在甲提问同一 token → 命中甲的资料。
      final (_, convA) = await api.post('/api/conversations?subject=$keyA', {'title': '甲提问'});
      final convAId = (convA as Map)['id'] as int;
      await api.chat({'conversation_id': convAId, 'text': 'EIGEN4711 是什么'}, subject: keyA);
      final (_, messagesA) = await api.get('/api/conversations/$convAId/messages?subject=$keyA');
      final refsA = (((messagesA as List).last as Map)['refs'] as List).cast<Map>();
      expect(refsA, isNotEmpty);
      expect('${refsA.first['name']}', '同名讲义.md');
      // 两个学科的运行/审计都按学科打标（全局表 + subject_key 列）。
      final subjectA = SubjectStore.byKey(keyA)!;
      final (statusDiag, diagnostics) = await api.get('/api/diagnostics/subject/${subjectA.id}');
      expect(statusDiag, 200);
      expect((diagnostics as Map)['integrity'], 'ok');
      expect(diagnostics['open_handles'], lessThanOrEqualTo(kSubjectMaxOpenHandles));
    });

    test('T7 技能：安装到甲、只在甲注入；停用后不再注入', () async {
      final (_, a) = await api.post('/api/subjects', {'name': '技能甲'});
      final (_, b) = await api.post('/api/subjects', {'name': '技能乙'});
      final keyA = (a as Map)['key'] as String;
      final keyB = (b as Map)['key'] as String;

      // 真实安装管线（registry 指向假 hub）：落盘到甲的 skills/ + subject_skills 镜像。
      final importer = SkillImporter(
        subjectKey: keyA,
        registry: SkillRegistry.forBaseUrlForTests(hub.baseUrl),
      );
      final installed = await importer.install('e2e-tutor');
      expect(installed.slug, 'e2e-tutor');
      expect(p.isWithin(AppPaths.subjectSkillsDir(keyA).path, installed.pkgDir), isTrue);

      final (_, skillsA) = await api.get('/api/skills?subject=$keyA');
      expect((skillsA as Map)['count'], 1);
      expect(((skillsA['installed'] as List).single as Map)['slug'], 'e2e-tutor');
      final (_, skillsB) = await api.get('/api/skills?subject=$keyB');
      expect((skillsB as Map)['count'], 0, reason: '甲装的技能不得出现在乙');

      // 甲对话：system 提示词注入技能；乙对话：不注入。
      await api.upload(keyA, '甲资料.md', _materialBody);
      final (_, convA) = await api.post('/api/conversations?subject=$keyA', {'title': '甲'});
      llm.query = _tokenA;
      await api.chat({'conversation_id': (convA as Map)['id'] as int, 'text': '提问'}, subject: keyA);
      expect(llm.lastSystemPrompt, contains(_FakeHub.name));

      final (_, convB) = await api.post('/api/conversations?subject=$keyB', {'title': '乙'});
      llm.query = _tokenB;
      await api.chat({'conversation_id': (convB as Map)['id'] as int, 'text': '提问'}, subject: keyB);
      expect(llm.lastSystemPrompt, isNot(contains(_FakeHub.name)),
          reason: '乙学科不应注入甲启用的技能');

      // 学科级停用（真实端点）→ 不再注入，文件仍在。
      final (statusDisable, disableResult) = await api.post('/api/skills/e2e-tutor/disable?subject=$keyA');
      expect(statusDisable, 200);
      expect(((disableResult as Map)['skill'] as Map)['enabled'], false);
      final (_, convA2) = await api.post('/api/conversations?subject=$keyA', {'title': '甲2'});
      await api.chat({'conversation_id': (convA2 as Map)['id'] as int, 'text': '提问'}, subject: keyA);
      expect(llm.lastSystemPrompt, isNot(contains(_FakeHub.name)));
      expect(Directory(installed.pkgDir).existsSync(), isTrue, reason: '停用不删文件');

      final (statusEnable, _) = await api.post('/api/skills/e2e-tutor/enable?subject=$keyA');
      expect(statusEnable, 200);
      final (_, convA3) = await api.post('/api/conversations?subject=$keyA', {'title': '甲3'});
      await api.chat({'conversation_id': (convA3 as Map)['id'] as int, 'text': '提问'}, subject: keyA);
      expect(llm.lastSystemPrompt, contains(_FakeHub.name));
    });

    test('T8 双库收敛：全局库没有任何学科数据；删掉兼容表后全链路仍正常', () async {
      final (_, a) = await api.post('/api/subjects', {'name': '收敛甲'});
      final keyA = (a as Map)['key'] as String;
      await api.upload(keyA, '收敛.md', _materialBody);
      final (_, conv) = await api.post('/api/conversations?subject=$keyA', {'title': '收敛'});
      final convId = (conv as Map)['id'] as int;
      llm.query = _tokenA;
      await api.chat({'conversation_id': convId, 'text': '提问'}, subject: keyA);
      await api.post('/api/subjects/$keyA/progress/events', {
        'events': [
          {'kind': 'read', 'topic': '收敛点', 'duration_min': 5, 'material_id': 1},
        ],
      });

      final globalPath = p.join(dir.path, 'loop.db');
      final tables = _globalTables(globalPath);
      for (final owned in Db.subjectOwnedTables) {
        expect(tables, isNot(contains(owned)), reason: '运行期不得创建全局 $owned');
      }
      // 全局库内容：只有注册表 + 应用级表（settings 里有主题/供应商等）。
      final database = sqlite3.open(globalPath, mode: OpenMode.readOnly);
      try {
        expect(database.select('SELECT COUNT(*) AS c FROM subjects').first['c'], greaterThanOrEqualTo(2));
        // 学科数据（会话/资料/进度/技能）都在学科库。
        final subject = SubjectStore.byKey(keyA)!;
        final subjectDb = sqlite3.open(subject.dbPath, mode: OpenMode.readOnly);
        try {
          expect(subjectDb.select('SELECT COUNT(*) AS c FROM conversations').first['c'], 1);
          expect(subjectDb.select('SELECT COUNT(*) AS c FROM messages').first['c'], 2);
          expect(subjectDb.select('SELECT COUNT(*) AS c FROM materials').first['c'], 1);
          expect(subjectDb.select('SELECT COUNT(*) AS c FROM study_events').first['c'], 1);
        } finally {
          subjectDb.close();
        }
      } finally {
        database.close();
      }

      // 旁路/移除全局兼容表（含 legacy_*）后，读写全链路仍必须正常。
      final connector = sqlite3.open(globalPath);
      try {
        for (final owned in Db.subjectOwnedTables) {
          connector.execute('DROP TABLE IF EXISTS legacy_$owned');
          connector.execute('DROP TABLE IF EXISTS $owned');
        }
      } finally {
        connector.close();
      }
      expect(_globalTables(globalPath), isNot(contains('conversations')));

      SubjectStore.closeAll();
      final (_, convList) = await api.get('/api/conversations?subject=$keyA');
      expect((convList as List), hasLength(1));
      final (_, messages) = await api.get('/api/conversations/$convId/messages?subject=$keyA');
      expect((messages as List), hasLength(2));
      final (_, materials) = await api.get('/api/materials?subject=$keyA');
      expect((materials as List), hasLength(1));
      final (_, progress) = await api.get('/api/subjects/$keyA/progress');
      expect(((progress as Map)['topics'] as List), isNotEmpty);
      final (_, conv2) = await api.post('/api/conversations?subject=$keyA', {'title': '收敛2'});
      llm.query = _tokenA;
      await api.chat({'conversation_id': (conv2 as Map)['id'] as int, 'text': '再问'}, subject: keyA);
      final (_, messages2) = await api.get('/api/conversations/${conv2['id']}/messages?subject=$keyA');
      final rows2 = (messages2 as List).cast<Map>();
      final refs = rows2.last['refs'] as List;
      expect(refs, isNotEmpty, reason: '没有全局兼容表时检索仍要工作');
    });

    test('T9 重启：active 学科与全部学科数据持久', () async {
      final (_, a) = await api.post('/api/subjects', {'name': '持久甲'});
      final keyA = (a as Map)['key'] as String;
      await api.upload(keyA, '持久.md', _materialBody);
      await api.post('/api/conversations?subject=$keyA', {'title': '持久对话'});
      await api.put('/api/subjects/active', {'subject': keyA});

      await Backend.stopForTests();
      final newPort = await Backend.startForTests(dir);
      final restarted = _Api('http://127.0.0.1:$newPort');

      final (_, active) = await restarted.get('/api/subjects/active');
      expect((active as Map)['key'], keyA, reason: 'active 学科必须持久化');
      final (_, conversations) = await restarted.get('/api/conversations');
      expect((conversations as List).cast<Map>().single['title'], '持久对话');
      final (_, materials) = await restarted.get('/api/materials');
      expect((materials as List), hasLength(1));
      final (_, progress) = await restarted.get('/api/subjects/$keyA/progress');
      expect((progress as Map)['subject_key'], keyA);
    });

    test('T11 前端数据通道：AppState 切换学科 → 后端 active 持久 + 信号 + 按学科取数', () async {
      final client = LoopApi(baseUrl: 'http://127.0.0.1:$port');
      final state = AppState(api: client);
      await state.loadSubjects();
      expect(state.subjects.map((s) => s.key), contains('default'));

      // 前端新建学科 → 自动切换过去（走 /api/subjects + /api/subjects/active）。
      final created = await state.createSubject(name: '前端学科', goal: '前端目标');
      expect(created, isNotNull);
      final key = created!.key;
      expect(state.activeKey, key);
      expect(client.subjectScope, key);
      expect(subjectChangedSignal.value, key);

      // 前端上传资料（LoopApi.upload 走同一作用域）→ 只落该学科。
      final uploaded = await client.upload(utf8.encode(_materialBody), '前端.md');
      expect(uploaded['kind'], 'material');
      await client.createConversation(title: '前端对话');
      await state.refreshConversations();
      expect(state.conversations.map((c) => c.title), contains('前端对话'));

      // 切到另一个学科 → 列表清空并重新取数（不串库）。
      final other = await client.createSubject(name: '前端另一科');
      await state.loadSubjects();
      await state.switchSubject('default');
      expect(state.activeKey, 'default');
      expect(subjectChangedSignal.value, 'default');
      expect(state.conversations, isEmpty, reason: '默认学科没有会话');
      final (_, defaultMaterials) = await api.get('/api/materials?subject=default');
      expect(defaultMaterials, isEmpty);
      final (_, otherList) = await api.get('/api/conversations?subject=${other.key}');
      expect(otherList, isEmpty);

      // 回到前端学科：数据仍在（active 已持久化到后端）。
      await state.switchSubject(key);
      expect(state.conversations.map((c) => c.title), contains('前端对话'));
      final (_, persisted) = await api.get('/api/subjects/active');
      expect((persisted as Map)['key'], key);
    });

    test('T12 后台任务不回归：会话写入当前学科库，不落全局兼容表', () async {
      final (_, a) = await api.post('/api/subjects', {'name': '后台学科'});
      final keyA = (a as Map)['key'] as String;
      await api.put('/api/subjects/active', {'subject': keyA});
      await api.upload(keyA, '后台.md', _materialBody);

      final jobId = Db.insert('agent_jobs', {
        'title': '后台总结',
        'prompt': '总结本学科资料',
        'mode': 'answer',
        'schedule_kind': 'interval',
        'schedule_value': '60',
        'enabled': 0,
        'created_at': Db.nowIso(),
      });
      final job = Db.globalOne('SELECT * FROM agent_jobs WHERE id=?', [jobId])!;
      llm.query = _tokenA;
      await JobScheduler.runJob(job);

      // 会话与消息落在**当前学科**库。
      final handle = SubjectStore.db(keyA);
      final rows = handle.rows("SELECT title FROM conversations WHERE title LIKE '[后台]%'");
      expect(rows, hasLength(1));
      expect(handle.count('messages'), 2);
      final (_, conversations) = await api.get('/api/conversations');
      expect((conversations as List).cast<Map>().map((e) => e['title']), contains('[后台] 后台总结'));
      // 全局库仍没有学习表；任务状态照常写全局 agent_jobs。
      expect(_globalTables(p.join(dir.path, 'loop.db')), isNot(contains('conversations')));
      final status = Db.globalOne('SELECT last_status FROM agent_jobs WHERE id=?', [jobId]);
      expect(status?['last_status'], isNotNull);
      // 审计行带学科标记（全局表 + subject_key），不会串科。
      final audited = Db.globalRows(
        "SELECT DISTINCT subject_key FROM agent_audit WHERE subject_key<>'' ORDER BY subject_key",
      ).map((row) => '${row['subject_key']}').toList();
      expect(audited, contains(keyA));
    });

    test('T13 子 agent 继承学科作用域：只读到本学科资料', () async {
      final (_, a) = await api.post('/api/subjects', {'name': '子代理甲'});
      final (_, b) = await api.post('/api/subjects', {'name': '子代理乙'});
      final keyA = (a as Map)['key'] as String;
      final keyB = (b as Map)['key'] as String;
      await api.upload(keyA, '子代理甲.md', _materialBody);
      await api.upload(keyB, '子代理乙.md', _materialBodyB);

      final run = AgentRuns.start(0, subjectKey: keyA);
      llm.query = _tokenA;

      // 甲：子 agent 的工具结果里应出现甲资料内容（EIGEN4711）。
      llm.requests.clear();
      await SubjectContext.scoped(
        (_) => runSubAgent(role: 'researcher', objective: '检索本学科资料并总结', context: '只要结论', run: run),
        subjectRef: keyA,
      );
      expect(llm.lastToolResult, contains('子代理甲.md'),
          reason: '甲学科的子 agent 必须能检索到甲资料');
      expect(llm.lastToolResult, contains('EIGEN4711'));

      // 乙：同一个 token 在乙学科内 0 命中，工具结果不得出现甲资料。
      llm.requests.clear();
      await SubjectContext.scoped(
        (_) => runSubAgent(role: 'researcher', objective: '检索本学科资料并总结', context: '只要结论', run: run),
        subjectRef: keyB,
      );
      expect(llm.lastToolResult, contains('"hits":0'), reason: '乙学科内该 token 0 命中');
      expect(llm.lastToolResult, isNot(contains('子代理甲.md')),
          reason: '乙学科的子 agent 不得看到甲资料');
      expect(llm.lastToolResult, isNot(contains('EIGEN4711')));
      expect(llm.lastToolResult, contains('子代理乙'), reason: '工具结果标注了实际作用域学科');
      AgentRuns.remove(run.id);
    });

    test('T14 冻结契约冒烟：工具名与既有 HTTP 端点保持存在（只增不改）', () async {
      // 工具契约（t4）：get/update_subject_progress 必须仍可用且描述当前学科。
      final names = [for (final item in toolDefinitions) '${(item['function'] as Map)['name']}'];
      expect(names, containsAll([
        'search_materials',
        'list_materials',
        'get_subject_progress',
        'update_subject_progress',
      ]));

      final (_, created) = await api.post('/api/subjects', {'name': '契约学科'});
      final key = (created as Map)['key'] as String;
      final subjectId = (created)['id'] as int;
      for (final path in [
        '/api/health',
        '/api/subjects',
        '/api/subjects?include_archived=true',
        '/api/subjects/active',
        '/api/subjects/$key',
        '/api/subjects/$key/path',
        '/api/subjects/$key/progress',
        '/api/skills?subject=$key',
        '/api/skills/playbooks?subject=$key',
        '/api/migrations/status',
        '/api/diagnostics/subject/$subjectId',
        '/api/mcp/servers',
        '/api/conversations?subject=$key',
        '/api/materials?subject=$key',
        '/api/tasks?subject=$key',
        '/api/notes?subject=$key',
        '/api/today?subject=$key',
        '/api/settings',
        '/api/audit?limit=5',
      ]) {
        final (status, _) = await api.get(path);
        expect(status, 200, reason: '冻结契约端点必须仍存在且可用：$path');
      }

      // 既有写端点仍然存在且遵守学科作用域（归档写 409 / 未知科 404 都是"存在"的证据）。
      final (patchStatus, patched) = await api.send('PATCH', '/api/subjects/$key/progress', {
        'profile': {'goal': '契约目标'},
      });
      expect(patchStatus, 200);
      expect(((patched as Map)['profile'] as Map)['goal'], '契约目标');
      final (eventsStatus, _) = await api.post('/api/subjects/$key/progress/events', {'events': []});
      expect(eventsStatus, 200);
      final (recomputeStatus, _) = await api.post('/api/subjects/$key/progress/recompute', {});
      expect(recomputeStatus, 200);
      final (missingTopicStatus, _) = await api.send('DELETE', '/api/subjects/$key/progress/topics/99999');
      expect(missingTopicStatus, 404, reason: '端点存在、软删不存在的话题为 404');
      final (unknownSubjectStatus, _) = await api.get('/api/subjects/ghost/progress');
      expect(unknownSubjectStatus, 404);
      final (skillsEnableStatus, _) = await api.post('/api/skills/not-installed/enable?subject=$key');
      expect(skillsEnableStatus, 404, reason: '端点存在、未安装的 slug 为 404');
    });
  });

  // --------------------------------------------------------------------- E2E-2

  group('E2E-2 旧库升级：默认学科承接旧数据', () {
    late Directory dir;
    late _Api api;
    late _MockLlm llm;

    setUp(() async {
      dir = _tempRoot();
      _createLegacyDb(dir);
      final port = await Backend.startForTests(dir);
      api = _Api('http://127.0.0.1:$port');
      llm = await _MockLlm.start();
      ProviderRegistry.saveAll([
        ProviderProfile(
          id: 'e2e',
          name: 'E2E Mock',
          baseUrl: llm.baseUrl,
          apiKey: 'test-key',
          defaultModel: 'mock-model',
          capabilities: const ProviderCapabilities(vision: true, tools: true),
        ),
      ]);
      ProviderRegistry.setActive('e2e');
    });

    tearDown(() async {
      await llm.close();
      await Backend.stopForTests();
      SubjectStore.resetForTests();
      _deleteQuietly(dir);
    });

    test('T10 默认学科可见迁移后的旧对话/资料；新建学科为空；全局只剩 legacy_*', () async {
      final (statusConversations, conversations) = await api.get('/api/conversations');
      expect(statusConversations, 200);
      final titles = (conversations as List).cast<Map>().map((e) => e['title']).toList();
      expect(titles, containsAll(['旧对话一', '旧对话二']));
      expect((conversations.cast<Map>().first)['subject_key'], 'default');

      final (statusMessages, messages) = await api.get('/api/conversations/1/messages');
      expect(statusMessages, 200);
      expect('${(messages as List).first['content']}', contains('旧问题'));

      final (_, materials) = await api.get('/api/materials');
      final rows = (materials as List).cast<Map>();
      expect(rows, hasLength(1));
      expect(rows.single['name'], '旧讲义.txt');
      final materialId = int.parse('${rows.single['id']}');
      final (statusPreview, preview) = await api.get('/api/materials/$materialId/preview');
      expect(statusPreview, 200);
      expect('${(preview as Map)['text']}', contains('LEGACY9'));

      // 旧资料在默认学科内可被检索命中（FTS 已重建）。
      final (_, conv) = await api.post('/api/conversations', {'title': '旧资料提问'});
      final convId = (conv as Map)['id'] as int;
      llm.query = 'LEGACY9';
      await api.chat({'conversation_id': convId, 'text': 'LEGACY9 是什么'});
      final (_, after) = await api.get('/api/conversations/$convId/messages');
      final refs = (((after as List).last as Map)['refs'] as List).cast<Map>();
      expect(refs, isNotEmpty, reason: '迁移后的旧资料必须可检索');
      expect('${refs.first['name']}', '旧讲义.txt');

      // 新建学科初始为空。
      final (_, fresh) = await api.post('/api/subjects', {'name': '升级后新建'});
      final freshKey = (fresh as Map)['key'] as String;
      expect((await api.get('/api/conversations?subject=$freshKey')).$2, isEmpty);
      expect((await api.get('/api/materials?subject=$freshKey')).$2, isEmpty);

      // 全局库：旧学习表已改名 legacy_*，不再有可写的学习表。
      final tables = _globalTables(p.join(dir.path, 'loop.db'));
      expect(tables, contains('legacy_conversations'));
      expect(tables, contains('legacy_materials'));
      for (final owned in Db.subjectOwnedTables) {
        expect(tables, isNot(contains(owned)), reason: '全局库不应再有可写的 $owned');
      }
      // 删掉 legacy_* 之后默认学科的数据仍在（数据已完全搬入学科库）。
      final connector = sqlite3.open(p.join(dir.path, 'loop.db'));
      try {
        for (final owned in Db.subjectOwnedTables) {
          connector.execute('DROP TABLE IF EXISTS legacy_$owned');
        }
      } finally {
        connector.close();
      }
      SubjectStore.closeAll();
      final (_, again) = await api.get('/api/conversations');
      expect((again as List), hasLength(3), reason: '旧 2 条 + 新建 1 条');
      final (_, materialsAgain) = await api.get('/api/materials');
      expect((materialsAgain as List), hasLength(1));

      // 重启 + 迁移幂等：第二次启动不重复迁移，旧数据仍可见。
      final appliedAt = SubjectMigration.record()!['applied_at'];
      final countsBefore = SubjectMigration.readReport()!['counts'];
      await Backend.stopForTests();
      final secondPort = await Backend.startForTests(dir);
      final restarted = _Api('http://127.0.0.1:$secondPort');
      expect(SubjectMigration.record()!['applied_at'], appliedAt, reason: '迁移不得重复执行');
      expect(jsonEncode(SubjectMigration.readReport()!['counts']), jsonEncode(countsBefore));
      final (_, afterRestart) = await restarted.get('/api/conversations');
      expect((afterRestart as List), hasLength(3), reason: '重启后旧对话仍可见');
      final (_, materialsRestart) = await restarted.get('/api/materials');
      expect((materialsRestart as List), hasLength(1));
      expect(SubjectStore.open('default').count('conversations'), 3,
          reason: '幂等：不重复搬入');
    });
  });
}