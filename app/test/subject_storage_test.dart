import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'package:loop/backend/db.dart';
import 'package:loop/backend/paths.dart';
import 'package:loop/backend/retrieval.dart';
import 'package:loop/backend/server.dart';
import 'package:loop/backend/subject_migration.dart';
import 'package:loop/backend/subject_store.dart';

/// 学科数据层测试（t3；规格 docs/subject-feature-spec.md §14 AC-01/AC-06/AC-08/AC-10）。
///
/// 纪律：
/// - 全部使用**隔离数据目录**（`AppPaths.initAt` + `SubjectStore.initTempForTests`），
///   并在 S0/S1 断言正式 `data/loop.db` 的 mtime + sha256 完全不变；
/// - 迁移类用例使用真实文件 + 真实 SQLite（要断文件搬迁与 sha256）；
/// - 用例编号 S1..S25，与 §15.1 的覆盖点对应。

Directory _tempRoot() {
  final base = Directory.systemTemp.createTempSync('loop-subject-test-');
  return base;
}

void _deleteQuietly(Directory dir) {
  try {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  } catch (_) {}
}

/// 正式库位置（`<repo>/data/loop.db`；`flutter test` 的 cwd 是 app/）。
File? _realLoopDb() {
  for (final candidate in [Directory.current, Directory.current.parent]) {
    final file = File(p.join(candidate.path, 'data', 'loop.db'));
    if (file.existsSync()) return file;
  }
  return null;
}

String _fingerprint(File file) {
  final stat = file.statSync();
  final digest = sha256.convert(file.readAsBytesSync());
  return '${stat.modified.millisecondsSinceEpoch}|${stat.size}|$digest';
}

/// 建一个真实的 v0.7.1 旧库（含 8 张学习表 + 数据），用于迁移测试。
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
      attachments TEXT DEFAULT '[]', model TEXT DEFAULT '', tokens_in INTEGER DEFAULT 0,
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
  final materialFile = File(p.join(filesDir.path, '20250101_mat.txt'))
    ..writeAsStringSync('eigenvector decomposition ZQ-A-7319 linear algebra notes');
  final uploadFile = File(p.join(filesDir.path, '20250101_img.png'))
    ..writeAsBytesSync(List<int>.generate(64, (i) => i));

  database.execute(
    "INSERT INTO conversations(id,title,mode,created_at,updated_at) "
    "VALUES(1,'旧对话一','answer','2025-01-01T10:00:00+08:00','2025-01-01T10:05:00+08:00'),"
    "(2,'旧对话二','answer','2025-01-02T10:00:00+08:00','2025-01-02T10:05:00+08:00')",
  );
  database.execute(
    "INSERT INTO messages(id,conversation_id,role,content,steps,refs,plan,created_at) VALUES"
    "(1,1,'user','什么是特征向量？','[]','[]','[]','2025-01-01T10:00:00+08:00'),"
    "(2,1,'assistant','特征向量满足 Av=λv。','[]','[]','[]','2025-01-01T10:01:00+08:00'),"
    "(3,2,'user','矩阵的对角化','[]','[]','[]','2025-01-02T10:00:00+08:00')",
  );
  database.execute(
    "INSERT INTO materials(id,name,kind,path,status,pages,chars,created_at,folder_id,source_path,"
    "relative_path) VALUES(1,'线性代数讲义.pdf','pdf','${materialFile.path}','ready',2,120,"
    "'2025-01-01T09:00:00+08:00',0,'','')",
  );
  database.execute(
    "INSERT INTO material_folders(id,root_path,name,created_at) "
    "VALUES(1,'D:/materials','materials','2025-01-01T09:00:00+08:00')",
  );
  database.execute(
    "INSERT INTO uploads(id,name,path,mime,created_at) VALUES"
    "(1,'图片.png','${uploadFile.path}','image/png','2025-01-01T09:30:00+08:00')",
  );
  database.execute(
    "INSERT INTO chunks(id,material_id,page,text) VALUES"
    "(1,1,1,'eigenvector decomposition 特征向量的分解方法 ZQ-A-7319'),"
    "(2,1,2,'matrix diagonalization 矩阵对角化的步骤')",
  );
  database.execute(
    "INSERT INTO tasks(id,title,due,estimate_min,status,created_at) "
    "VALUES(1,'复习特征值','2025-01-05',30,'todo','2025-01-01T09:10:00+08:00')",
  );
  database.execute(
    "INSERT INTO notes(id,title,body,created_at) "
    "VALUES(1,'特征值笔记','# 特征值\n要点…','2025-01-01T09:20:00+08:00')",
  );
  database.close();
  return File(dbPath);
}

/// 直接读某个库文件的逐表行数（迁移用例的前置计数，不依赖全局句柄）。
Map<String, int> _countsOf(String dbPath, List<String> tables) {
  final database = sqlite3.open(dbPath);
  try {
    return {
      for (final table in tables)
        table: database.select('SELECT COUNT(*) AS c FROM $table').first['c'] as int,
    };
  } finally {
    database.close();
  }
}

void main() {
  final realDbFingerprintBefore = _realLoopDb() == null ? '' : _fingerprint(_realLoopDb()!);

  group('S0/S1 LOOP_DATA_DIR 隔离（paths.dart 回归，AC-10）', () {
    test('S1 设置 LOOP_DATA_DIR 时它就是唯一数据目录，即使 cwd/data 里有 loop.db', () {
      final root = _tempRoot();
      addTearDown(() => _deleteQuietly(root));
      final cwd = Directory(p.join(root.path, 'repo'))..createSync(recursive: true);
      Directory(p.join(cwd.path, 'data')).createSync(recursive: true);
      File(p.join(cwd.path, 'data', 'loop.db')).writeAsStringSync('fake');
      final iso = Directory(p.join(root.path, 'iso'))..createSync(recursive: true);

      // 未设置 env：沿用旧探测顺序，选中已存在 loop.db 的 cwd/data。
      final detected = AppPaths.resolveDataDir(
        environment: const {},
        executablePath: p.join(root.path, 'no-such-exe'),
        currentDir: cwd,
      );
      expect(p.normalize(detected.path), p.normalize(p.join(cwd.path, 'data')));

      // 设置了 env（即使目录里没有 loop.db）：直接命中隔离目录，不回退。
      final isolated = AppPaths.resolveDataDir(
        environment: {'LOOP_DATA_DIR': iso.path},
        executablePath: p.join(root.path, 'no-such-exe'),
        currentDir: cwd,
      );
      expect(p.normalize(isolated.path), p.normalize(iso.path));

      // 空白 env 视为未设置。
      final blank = AppPaths.resolveDataDir(
        environment: const {'LOOP_DATA_DIR': '   '},
        executablePath: p.join(root.path, 'no-such-exe'),
        currentDir: cwd,
      );
      expect(p.normalize(blank.path), p.normalize(p.join(cwd.path, 'data')));
    });

    test('S2 AppPaths.initAt 把 data/dbPath/files/subjectsDir 都放到隔离目录下', () {
      final root = _tempRoot();
      addTearDown(() => _deleteQuietly(root));
      AppPaths.initAt(root);
      expect(p.normalize(AppPaths.data.path), p.normalize(root.path));
      expect(p.normalize(AppPaths.dbPath), p.normalize(p.join(root.path, 'loop.db')));
      expect(p.isWithin(root.path, AppPaths.files.path), isTrue);
      expect(p.isWithin(root.path, AppPaths.subjectsDir.path), isTrue);
      expect(p.isWithin(root.path, AppPaths.subjectDbPath('default')), isTrue);
      expect(AppPaths.subjectDbPath('default'), endsWith(p.join('subjects', 'default', 'loop.db')));
    });
  });

  group('S3 学科注册表（AC-01/AC-08）', () {
    late Directory root;

    setUp(() {
      root = _tempRoot();
      SubjectStore.initTempForTests(root);
    });

    tearDown(() {
      Backend.stopForTests();
      SubjectStore.resetForTests();
      _deleteQuietly(root);
    });

    test('S3 首次启动自动存在唯一默认学科，注册表元数据齐全', () {
      final items = SubjectStore.list();
      expect(items, hasLength(1));
      final def = items.single;
      expect(def.key, 'default');
      expect(def.name, '通用');
      expect(def.isDefault, isTrue);
      expect(def.status, 'active');
      expect(def.createdAt, isNotEmpty);
      expect(def.archivedAt, isEmpty);
      expect(def.sortOrder, 0);
      expect(File(def.dbPath).existsSync(), isTrue);
      expect(def.dbPath, endsWith(p.join('subjects', 'default', 'loop.db')));
      // 注册行落在全局库 subjects 表，且 id/key/created/archived/order 字段可读。
      final row = Db.globalOne('SELECT * FROM subjects WHERE key=?', ['default'])!;
      expect((row['id'] as num).toInt(), greaterThan(0));
      expect(row['db_rel_path'], 'subjects/default/loop.db');
      expect(row['files_rel_path'], 'subjects/default/files');
      expect(row['skills_rel_path'], 'subjects/default/skills');
      expect((row['archived_at'] ?? '').toString(), '');
    });

    test('S4 每学科一个独立 SQLite 文件，且两库不是同一个文件', () {
      final a = SubjectStore.create(name: '线性代数');
      final b = SubjectStore.create(name: '概率论');
      expect(a.key, isNot(b.key));
      expect(a.key, matches(RegExp(r'^s_[a-z0-9]+$')));
      expect(File(a.dbPath).existsSync(), isTrue);
      expect(File(b.dbPath).existsSync(), isTrue);
      expect(p.normalize(a.dbPath), isNot(p.normalize(b.dbPath)));
      expect(p.isWithin(AppPaths.subjectsDir.path, a.dbPath), isTrue);
      expect(a.dbPath, endsWith(p.join('subjects', a.key, 'loop.db')));

      // 学科库 schema：§4.3 全部表 + meta.schema_version。
      final db = SubjectStore.open(a.key);
      for (final table in [
        'conversations',
        'messages',
        'materials',
        'material_folders',
        'uploads',
        'chunks',
        'chunks_fts',
        'tasks',
        'notes',
        'meta',
        'subject_profile',
        'topics',
        'study_events',
        'progress_daily',
        'subject_skills',
      ]) {
        expect(Db.tableExistsIn(db.database, table), isTrue, reason: '缺表 $table');
      }
      expect(SubjectStore.readSchemaVersion(db.database), kSubjectSchemaVersion);
    });

    test('S5 创建/重命名/归档/恢复：改名不改 key 与目录，归档不删数据', () {
      final a = SubjectStore.create(name: '  线性 代数  ');
      expect(a.name, '线性 代数');
      final before = File(a.dbPath).readAsBytesSync();
      final renamed = SubjectStore.patch(a.id, {'name': '高等代数', 'goal': '期末 90 分'});
      expect(renamed.name, '高等代数');
      expect(renamed.key, a.key);
      expect(renamed.goal, '期末 90 分');
      expect(File(renamed.dbPath).existsSync(), isTrue);
      expect(File(renamed.dbPath).readAsBytesSync(), before);

      final archived = SubjectStore.archive(a.id);
      expect(archived.archived, isTrue);
      expect(archived.archivedAt, isNotEmpty);
      expect(SubjectStore.list().map((s) => s.key), isNot(contains(a.key)));
      expect(SubjectStore.list(includeArchived: true).map((s) => s.key), contains(a.key));
      expect(File(archived.dbPath).existsSync(), isTrue);

      final restored = SubjectStore.restore(a.id);
      expect(restored.archived, isFalse);
      expect(restored.archivedAt, isEmpty);
      expect(SubjectStore.list().map((s) => s.key), contains(a.key));
    });

    test('S6 重名 409、默认学科不可归档/删除、删除需归档 + confirm', () {
      SubjectStore.create(name: '线性代数');
      expect(
        () => SubjectStore.create(name: '线性代数'),
        throwsA(isA<SubjectError>().having((e) => e.status, 'status', 409)),
      );
      expect(
        () => SubjectStore.create(name: '  LINUX  '),
        returnsNormally,
      );

      final def = SubjectStore.defaultSubject;
      expect(
        () => SubjectStore.archive(def.id),
        throwsA(isA<SubjectError>().having((e) => e.status, 'status', 409)),
      );
      expect(
        () => SubjectStore.delete(def.id, 'default'),
        throwsA(isA<SubjectError>().having((e) => e.status, 'status', 409)),
      );

      final a = SubjectStore.create(name: '待删学科');
      expect(
        () => SubjectStore.delete(a.id, a.key),
        throwsA(isA<SubjectError>().having((e) => e.status, 'status', 409)),
      );
      SubjectStore.archive(a.id);
      expect(
        () => SubjectStore.delete(a.id, 'wrong-key'),
        throwsA(isA<SubjectError>().having((e) => e.status, 'status', 400)),
      );
      final result = SubjectStore.delete(a.id, a.key);
      expect(result['ok'], isTrue);
      expect(SubjectStore.byKey(a.key), isNull);
      expect(File(a.dbPath).existsSync(), isFalse);
      expect(Directory((result['trashed_to'] as String)).existsSync(), isTrue);
      expect(SubjectStore.activeKey(), 'default');
    });

    test('S7 路径白名单：非法 key 直接抛错，不降级不猜测', () {
      expect(() => AppPaths.subjectDir('../../evil'), throwsArgumentError);
      expect(() => AppPaths.subjectDir('a/b'), throwsArgumentError);
      expect(() => AppPaths.subjectDir('CON'), throwsArgumentError);
      expect(() => AppPaths.subjectDir('ab'), throwsArgumentError);
      expect(AppPaths.isValidSubjectKey('s_1a2b3c'), isTrue);
      expect(AppPaths.isValidSubjectKey('default'), isTrue);
      expect(() => SubjectStore.require('not-a-subject'),
          throwsA(isA<SubjectError>().having((e) => e.status, 'status', 404)));
    });

    test('S8 重启后学科仍存在、数据仍可读（db.dart DROP subjects 回归）', () {
      final a = SubjectStore.create(name: '重启学科');
      final db = SubjectStore.open(a.key);
      db.insert('conversations', {
        'title': '重启前的对话',
        'mode': 'answer',
        'created_at': Db.nowIso(),
        'updated_at': Db.nowIso(),
      });

      // 模拟第二次启动：全局库重新打开 + 迁移重跑（不得清空注册表）。
      SubjectStore.reopenForTests();
      SubjectMigration.ensureApplied();
      final after = SubjectStore.list(includeArchived: true);
      expect(after.map((s) => s.key), contains(a.key));
      expect(after.map((s) => s.key), contains('default'));
      final stillThere = SubjectStore.open(a.key).one('SELECT title FROM conversations');
      expect(stillThere?['title'], '重启前的对话');
    });

    test('S9 active 学科：设置/纠正/归档回退', () {
      final a = SubjectStore.create(name: '当前学科');
      expect(SubjectStore.setActive(a.key).key, a.key);
      expect(SubjectStore.activeKey(), a.key);
      expect(SubjectStore.activeSubject().key, a.key);
      expect(Db.setting('active_subject'), a.key);
      expect(SubjectStore.byKey(a.key)!.lastOpenedAt, isNotEmpty);

      SubjectStore.archive(a.id);
      expect(SubjectStore.activeKey(), 'default');
      expect(SubjectStore.activeSubject().key, 'default');

      Db.setSetting('active_subject', 'ghost-key');
      SubjectStore.normalizeActiveSubject();
      expect(Db.setting('active_subject'), 'default');
    });
  });

  group('S10 学科内数据隔离（AC-01）', () {
    late Directory root;

    setUp(() {
      root = _tempRoot();
      SubjectStore.initTempForTests(root);
    });

    tearDown(() {
      Backend.stopForTests();
      SubjectStore.resetForTests();
      _deleteQuietly(root);
    });

    test('S10 两个学科可建同名对话与同名资料，互不可见', () {
      final a = SubjectStore.create(name: '甲学科');
      final b = SubjectStore.create(name: '乙学科');
      final dbA = SubjectStore.open(a.key);
      final dbB = SubjectStore.open(b.key);
      final now = Db.nowIso();

      final convA = dbA.insert('conversations',
          {'title': '同名对话', 'mode': 'answer', 'created_at': now, 'updated_at': now});
      final convB = dbB.insert('conversations',
          {'title': '同名对话', 'mode': 'answer', 'created_at': now, 'updated_at': now});
      expect(convA, convB, reason: '各自库内 id 都从 1 开始');

      dbA.insert('messages', {
        'conversation_id': convA,
        'role': 'user',
        'content': 'A 学科的问题 ZQ-A-7319',
        'created_at': now,
      });
      dbB.insert('messages', {
        'conversation_id': convB,
        'role': 'user',
        'content': 'B 学科的问题 ZQ-B-8821',
        'created_at': now,
      });

      dbA.insert('materials', {
        'name': '同名资料.pdf',
        'kind': 'pdf',
        'path': p.join(a.filesPath, '同名资料.pdf'),
        'created_at': now,
      });
      dbB.insert('materials', {
        'name': '同名资料.pdf',
        'kind': 'pdf',
        'path': p.join(b.filesPath, '同名资料.pdf'),
        'created_at': now,
      });

      // 断言 1：文件级——两库各自只含自己的行。
      expect(dbA.rows('SELECT title FROM conversations'), hasLength(1));
      expect(dbB.rows('SELECT title FROM conversations'), hasLength(1));
      expect(dbA.rows('SELECT content FROM messages'), hasLength(1));
      expect(dbB.rows('SELECT content FROM messages'), hasLength(1));
      expect(dbA.one('SELECT content FROM messages WHERE conversation_id=?', [convA])?['content'],
          contains('ZQ-A-7319'));
      expect(dbA.scalar('SELECT COUNT(*) FROM messages'), 1,
          reason: 'A 库不得出现 B 的消息（即使会话 id 相同）');
      expect(dbB.one('SELECT content FROM messages WHERE conversation_id=?', [convB])?['content'],
          contains('ZQ-B-8821'));
      expect(dbB.scalar('SELECT COUNT(*) FROM messages'), 1);

      final matA = dbA.one('SELECT id, path FROM materials')!;
      final matB = dbB.one('SELECT id, path FROM materials')!;
      expect(matA['path'], isNot(matB['path']));
      expect(p.isWithin(a.filesPath, matA['path']! as String), isTrue);
      expect(p.isWithin(b.filesPath, matB['path']! as String), isTrue);
      // 断言 2：ID 作用域——B 库用同一个 id 查到的是 B 自己的资料（无跨库回退）。
      final bById = dbB.one('SELECT * FROM materials WHERE id=?', [matA['id']])!;
      expect(bById['path'], matB['path']);
      expect(bById['path'], isNot(matA['path']));

      // 断言 3：检索不越界（本学科 FTS 只含本学科分块）。
      dbA.insert('chunks', {'material_id': matA['id'], 'page': 1, 'text': 'ZQ-A-7319 甲学科内容'});
      dbA.run('INSERT INTO chunks_fts(chunk_id, tokens) VALUES(?, ?)', [
        dbA.scalar('SELECT MAX(id) FROM chunks'),
        tokenize('ZQ-A-7319 甲学科内容').join(' '),
      ]);
      expect(dbB.scalar('SELECT COUNT(*) FROM chunks_fts'), 0);
    });

    test('S11 按学科访问对话/消息/资料：查询不跨学科、缺库即 503', () {
      final a = SubjectStore.create(name: '有库学科');
      final b = SubjectStore.create(name: '空库学科');
      final now = Db.nowIso();
      SubjectStore.open(a.key).insert('conversations',
          {'title': 'A 会话', 'mode': 'answer', 'created_at': now, 'updated_at': now});
      SubjectStore.open(b.key).insert('conversations',
          {'title': 'B 会话', 'mode': 'answer', 'created_at': now, 'updated_at': now});

      expect(SubjectStore.db(a.key).rows('SELECT title FROM conversations').single['title'], 'A 会话');
      expect(SubjectStore.db(b.key).rows('SELECT title FROM conversations').single['title'], 'B 会话');
      // 缺省作用域 = active（此时是默认学科，两科数据都不应出现）。
      expect(SubjectStore.db().key, 'default');
      expect(SubjectStore.db().scalar('SELECT COUNT(*) FROM conversations'), 0);
      SubjectStore.setActive(a.key);
      expect(SubjectStore.db().one('SELECT title FROM conversations')?['title'], 'A 会话');

      // 手工删掉学科库文件：integrity=missing，且访问报 503（不自动重建）。
      SubjectStore.close(b.key);
      File(b.dbPath).deleteSync();
      final missing = SubjectStore.byKey(b.key)!;
      expect(missing.integrity, 'missing');
      expect(
        () => SubjectStore.open(b.key),
        throwsA(isA<SubjectError>().having((e) => e.status, 'status', 503)),
      );
    });

    test('S12 句柄 LRU ≤ 4：连续切换 50 次不泄漏', () {
      final keys = <String>[];
      for (var i = 0; i < 6; i++) {
        keys.add(SubjectStore.create(name: '学科$i').key);
      }
      for (var i = 0; i < 50; i++) {
        final handle = SubjectStore.open(keys[i % keys.length]);
        expect(handle.closed, isFalse);
      }
      expect(SubjectStore.openHandles, lessThanOrEqualTo(kSubjectMaxOpenHandles));
      final last = SubjectStore.open(keys.last);
      expect(last.rows('SELECT 1'), hasLength(1));
      SubjectStore.closeAll();
      expect(SubjectStore.openHandles, 0);
    });

    test('S13 同名资料但库内 id 相同也互不可见（跨库 preview/delete 语义）', () {
      final a = SubjectStore.create(name: '库甲');
      final b = SubjectStore.create(name: '库乙');
      final now = Db.nowIso();
      SubjectStore.open(a.key).insert('materials',
          {'name': 'same.txt', 'kind': 'txt', 'path': 'a.txt', 'created_at': now});
      SubjectStore.open(b.key).insert('materials',
          {'name': 'same.txt', 'kind': 'txt', 'path': 'b.txt', 'created_at': now});

      final idA = SubjectStore.db(a.key).scalar('SELECT id FROM materials');
      final idB = SubjectStore.db(b.key).scalar('SELECT id FROM materials');
      expect(idA, idB);
      expect(SubjectStore.db(a.key).one('SELECT path FROM materials WHERE id=?', [idA])?['path'], 'a.txt');
      expect(SubjectStore.db(b.key).one('SELECT path FROM materials WHERE id=?', [idB])?['path'], 'b.txt');
      expect(SubjectStore.db(b.key).one('SELECT path FROM materials WHERE id=?', [idA])?['path'], 'b.txt',
          reason: 'B 库的同 id 资料是 B 自己的资料，绝不指向 A 的文件');
    });
  });

  group('S14 旧库迁移（AC-06）', () {
    late Directory root;

    setUp(() {
      root = _tempRoot();
      _createLegacyDb(root);
    });

    tearDown(() {
      Backend.stopForTests();
      SubjectStore.resetForTests();
      _deleteQuietly(root);
    });

    test('S14 旧数据自动迁入默认学科：逐表计数与内容不丢，旧表保留为 legacy_*', () {
      final legacyCounts =
          _countsOf(p.join(root.path, 'loop.db'), SubjectMigration.legacyTables);
      // 迁移前先确认旧库确实有数据（防止用例假通过）。
      expect(legacyCounts['conversations'], 2);
      expect(legacyCounts['messages'], 3);
      expect(legacyCounts['materials'], 1);
      expect(legacyCounts['chunks'], 2);

      SubjectStore.initTempForTests(root);
      final result = SubjectMigration.ensureApplied();
      expect(result['ok'], isTrue, reason: '${result['error']}');
      expect(result['skipped'], isNull);

      final def = SubjectStore.byKey('default')!;
      final db = SubjectStore.open(def.key);
      for (final table in SubjectMigration.legacyTables) {
        expect(db.count(table), legacyCounts[table], reason: '$table 计数不一致');
      }
      // 内容级校验（不只看数量）。
      expect(db.one('SELECT title FROM conversations WHERE id=2')?['title'], '旧对话二');
      expect(db.one('SELECT content FROM messages WHERE id=2')?['content'], '特征向量满足 Av=λv。');
      expect(db.one('SELECT name FROM materials WHERE id=1')?['name'], '线性代数讲义.pdf');
      expect(db.one('SELECT title FROM notes')?['title'], '特征值笔记');
      expect(db.one('SELECT title FROM tasks')?['title'], '复习特征值');
      expect(db.one('SELECT root_path FROM material_folders')?['root_path'], 'D:/materials');

      // FTS 重建可检索（tokenize 规则与 retrieval.dart 一致）。
      final tokens = tokenize('eigenvector decomposition').take(4).map((t) => '"$t"').join(' OR ');
      final hits = db.rows(
        'SELECT c.text, m.name AS material_name FROM chunks_fts '
        'JOIN chunks c ON c.id = chunks_fts.chunk_id '
        'JOIN materials m ON m.id = c.material_id WHERE chunks_fts MATCH ?',
        [tokens],
      );
      expect(hits, isNotEmpty);
      expect(hits.first['material_name'], '线性代数讲义.pdf');

      // 旧表保留（降级/取证），且行数未变。
      for (final table in SubjectMigration.legacyTables) {
        final legacy = 'legacy_$table';
        expect(Db.tableExists(legacy), isTrue, reason: '缺 $legacy');
        expect(Db.tableRowCount(legacy), legacyCounts[table]);
      }

      // 幂等标记 + 迁移报告 + 备份。
      expect(SubjectMigration.applied, isTrue);
      final record = SubjectMigration.record()!;
      expect(record['id'], kAppSubjectMigrationId);
      final report = SubjectMigration.readReport()!;
      expect(report['result'], 'ok');
      expect((report['counts'] as Map)['files_moved'], 2);
      expect(File(SubjectMigration.backupPath).existsSync(), isTrue);
      expect(report['backup_sha256'], SubjectMigration.sha256File(SubjectMigration.backupPath));
      expect(Db.setting('active_subject'), 'default');
    });

    test('S15 文件搬迁：复制校验后删源，materials.path 指向学科目录', () {
      SubjectStore.initTempForTests(root);
      SubjectMigration.ensureApplied();
      final def = SubjectStore.byKey('default')!;
      final db = SubjectStore.open(def.key);

      final material = db.one('SELECT name, path FROM materials WHERE id=1')!;
      final newPath = material['path']! as String;
      expect(p.isWithin(def.filesPath, newPath), isTrue, reason: 'materials.path 必须指向学科 files/');
      expect(File(newPath).existsSync(), isTrue);
      expect(File(newPath).readAsStringSync(), contains('ZQ-A-7319'));
      expect(SubjectMigration.sha256File(newPath),
          SubjectMigration.sha256File(File(newPath).path));
      expect(Directory(p.join(root.path, 'files')).listSync().whereType<File>(), isEmpty,
          reason: '搬迁后旧 data/files 不再有副本');

      final upload = db.one('SELECT path FROM uploads WHERE id=1')!;
      expect(p.isWithin(def.filesPath, upload['path']! as String), isTrue);
      expect(File(upload['path']! as String).existsSync(), isTrue);
    });

    test('S16 幂等：第二次启动不再迁移，报告 at/计数不变', () {
      SubjectStore.initTempForTests(root);
      final first = SubjectMigration.ensureApplied();
      expect(first['ok'], isTrue);
      final reportAfterFirst = SubjectMigration.readReport()!;
      final countsAfterFirst = jsonEncode(reportAfterFirst['counts']);
      final appliedAt = SubjectMigration.record()!['applied_at'];

      SubjectStore.reopenForTests();
      final second = SubjectMigration.ensureApplied();
      expect(second['skipped'], isTrue);
      expect(second['reason'], 'already-applied');
      expect(SubjectMigration.record()!['applied_at'], appliedAt);
      expect(jsonEncode(SubjectMigration.readReport()!['counts']), countsAfterFirst);
      // 默认学科数据未被重复搬入。
      expect(SubjectStore.open('default').count('conversations'), 2);
    });

    test('S17 无遗留数据时不迁移：只保证默认学科存在', () {
      final clean = _tempRoot();
      addTearDown(() => _deleteQuietly(clean));
      SubjectStore.initTempForTests(clean);
      final result = SubjectMigration.ensureApplied();
      expect(result['skipped'], isTrue);
      expect(result['reason'], 'no-legacy-data');
      expect(SubjectMigration.applied, isFalse);
      expect(SubjectStore.list(), hasLength(1));
      expect(SubjectStore.list().single.key, 'default');
    });

    test('S18 迁移后 legacy 表与学科库并存，新学科与旧数据互不影响', () {
      SubjectStore.initTempForTests(root);
      SubjectMigration.ensureApplied();
      final fresh = SubjectStore.create(name: '新建学科');
      expect(SubjectStore.open(fresh.key).count('conversations'), 0);
      expect(SubjectStore.open('default').count('conversations'), 2);
      expect(SubjectStore.open(fresh.key).count('materials'), 0);
      expect(Db.tableRowCount('legacy_conversations'), 2);
      // 幂等迁移记录不会被新学科影响。
      expect(SubjectMigration.ensureApplied()['skipped'], isTrue);
    });
  });

  group('S19 HTTP API：/api/subjects 与作用域隔离（AC-01/AC-08/AC-10）', () {
    late Directory root;
    late int port;
    late String base;
    late LoopApiHttp client;

    setUp(() async {
      root = _tempRoot();
      port = await Backend.startForTests(root);
      base = 'http://127.0.0.1:$port';
      client = LoopApiHttp(base);
    });

    tearDown(() async {
      await Backend.stopForTests();
      SubjectStore.resetForTests();
      _deleteQuietly(root);
    });

    test('S19 GET /api/subjects 只含默认学科；POST 创建后可在列表看到', () async {
      final (status0, list0) = await client.get('/api/subjects');
      expect(status0, 200);
      expect((list0 as List), hasLength(1));
      expect((list0.single as Map)['key'], 'default');

      final (status1, created) = await client.post('/api/subjects', {'name': '离散数学'});
      expect(status1, 200);
      final createdKey = (created as Map)['key'] as String;
      expect(createdKey, startsWith('s_'));
      expect(created['name'], '离散数学');
      expect(created['integrity'], 'ok');
      expect(created['is_default'], 0);

      final (_, list1) = await client.get('/api/subjects');
      expect((list1 as List).map((e) => (e as Map)['key']), contains(createdKey));
      expect(File(AppPaths.subjectDbPath(createdKey)).existsSync(), isTrue);

      final (statusDup, dup) = await client.post('/api/subjects', {'name': '离散数学'});
      expect(statusDup, 409);
      expect((dup as Map)['detail'], contains('同名'));
      final (statusBad, bad) = await client.post('/api/subjects', {'name': '   '});
      expect(statusBad, 400);
      expect((bad as Map)['detail'], isNotEmpty);
    });

    test('S20 同名对话在两个学科内互不可见；跨学科 id 取消息 404', () async {
      final (_, a) = await client.post('/api/subjects', {'name': 'API 甲'});
      final (_, b) = await client.post('/api/subjects', {'name': 'API 乙'});
      final keyA = (a as Map)['key'] as String;
      final keyB = (b as Map)['key'] as String;

      final (_, convA) = await client.post('/api/conversations?subject=$keyA', {'title': '同名对话'});
      final (_, convB1) = await client.post('/api/conversations?subject=$keyB', {'title': '同名对话'});
      final (_, convB2) = await client.post('/api/conversations?subject=$keyB', {'title': '乙第二条'});
      final idA = (convA as Map)['id'] as int;
      final idB1 = (convB1 as Map)['id'] as int;
      final idB2 = (convB2 as Map)['id'] as int;
      expect(idA, idB1, reason: '两个学科各自从 1 开始编号，允许同名同 id');
      expect(idB2, isNot(idA));

      final (statusList, listA) = await client.get('/api/conversations?subject=$keyA');
      expect(statusList, 200);
      final rowsA = (listA as List).cast<Map>().toList();
      expect(rowsA, hasLength(1), reason: 'A 学科只有 1 条会话，看不到 B 的 2 条');
      expect(rowsA.single['subject_key'], keyA);
      expect(rowsA.single['title'], '同名对话');

      final (_, listB) = await client.get('/api/conversations?subject=$keyB');
      final rowsB = (listB as List).cast<Map>().toList();
      expect(rowsB, hasLength(2));
      expect(rowsB.map((e) => e['subject_key']).toSet(), {keyB});

      // 跨学科 ID 作用域：B 的第二条会话 id 在 A 学科内不存在 → 404，不回退他科。
      final (statusCross, cross) = await client.get('/api/conversations/$idB2/messages?subject=$keyA');
      expect(statusCross, 404);
      expect((cross as Map)['detail'], '会话不存在');

      final (statusSelf, self) = await client.get('/api/conversations/$idA/messages?subject=$keyA');
      expect(statusSelf, 200);
      expect(self, isEmpty);
      final (statusBSelf, _) = await client.get('/api/conversations/$idB2/messages?subject=$keyB');
      expect(statusBSelf, 200);

      final (statusGhost, ghost) = await client.get('/api/conversations?subject=ghost-subject');
      expect(statusGhost, 404);
      expect((ghost as Map)['detail'], contains('学科不存在'));
      final (statusGhost2, _) = await client.get('/api/subjects/ghost-subject');
      expect(statusGhost2, 404);
      // key 也可作为 {id} 使用（PATCH 用 key 引用同一学科）。
      final (_, byKeyPatch) = await client.patch('/api/subjects/$keyA', {'goal': '用 key 引用'});
      expect((byKeyPatch as Map)['key'], keyA);
      expect(byKeyPatch['goal'], '用 key 引用');
    });

    test('S21 同名资料互不可见；跨学科 preview 404；默认作用域=当前学科', () async {
      final (_, a) = await client.post('/api/subjects', {'name': '资料甲'});
      final (_, b) = await client.post('/api/subjects', {'name': '资料乙'});
      final keyA = (a as Map)['key'] as String;
      final keyB = (b as Map)['key'] as String;
      final now = Db.nowIso();
      SubjectStore.open(keyA).insert('materials',
          {'name': '同名资料.pdf', 'kind': 'pdf', 'path': 'a', 'created_at': now});
      SubjectStore.open(keyB).insert('materials',
          {'name': '同名资料.pdf', 'kind': 'pdf', 'path': 'b', 'created_at': now});
      SubjectStore.open(keyB).insert('materials',
          {'name': '乙第二资料.pdf', 'kind': 'pdf', 'path': 'b2', 'created_at': now});
      final idA = SubjectStore.db(keyA).scalar('SELECT id FROM materials')! as int;
      final idB2 = SubjectStore.db(keyB).scalar('SELECT MAX(id) FROM materials')! as int;
      expect(idB2, isNot(idA));

      final (_, listA) = await client.get('/api/materials?subject=$keyA');
      expect((listA as List), hasLength(1));
      expect(listA.single as Map, containsPair('path', 'a'));
      expect((listA.single as Map)['subject_key'], keyA);
      final (_, listB) = await client.get('/api/materials?subject=$keyB');
      expect((listB as List), hasLength(2));

      // 跨学科 ID：乙的第二条资料 id 在甲学科内不存在 → 404（不回退他科）。
      final (statusCross, _) = await client.get('/api/materials/$idB2/preview?subject=$keyA');
      expect(statusCross, 404);
      final (statusSelf, self) = await client.get('/api/materials/$idA/preview?subject=$keyA');
      expect(statusSelf, 200);
      expect((self as Map)['subject_key'], keyA);

      // 写 active_subject 后，不带 subject 的旧调用落在该学科（向后兼容）。
      final (statusActive, active) = await client.put('/api/subjects/active', {'subject': keyA});
      expect(statusActive, 200);
      expect((active as Map)['active_subject'], keyA);
      final (_, implicit) = await client.get('/api/materials');
      expect((implicit as List).single as Map, containsPair('path', 'a'));

      final (_, health) = await client.get('/api/health');
      expect((health as Map)['active_subject'], keyA);
    });

    test('S22 归档语义经 HTTP：归档后 409 写、列表隐藏、恢复可见；默认学科 409', () async {
      final (_, created) = await client.post('/api/subjects', {'name': '待归档'});
      final key = (created as Map)['key'] as String;
      final id = (created)['id'] as int;

      final (statusArchive, archived) = await client.post('/api/subjects/$id/archive');
      expect(statusArchive, 200);
      expect((archived as Map)['status'], 'archived');
      expect(archived['archived_at'], isNotEmpty);

      final (_, visible) = await client.get('/api/subjects');
      expect((visible as List).map((e) => (e as Map)['key']), isNot(contains(key)));
      final (_, all) = await client.get('/api/subjects?include_archived=true');
      expect((all as List).map((e) => (e as Map)['key']), contains(key));

      final (statusWrite, writeError) =
          await client.post('/api/conversations?subject=$key', {'title': 'x'});
      expect(statusWrite, 409);
      expect((writeError as Map)['detail'], contains('归档'));
      // 归档学科仍可被显式打开读取（§3.5）。
      final (statusRead, archivedList) = await client.get('/api/conversations?subject=$key');
      expect(statusRead, 200);
      expect(archivedList, isEmpty);
      final (_, archivedMaterials) = await client.get('/api/materials?subject=$key');
      expect(archivedMaterials, isEmpty);

      final (statusRestore, restored) = await client.post('/api/subjects/$id/restore');
      expect(statusRestore, 200);
      expect((restored as Map)['status'], 'active');

      final (_, defaultSubject) = await client.get('/api/subjects/active');
      final defaultId = (defaultSubject as Map)['id'] as int;

      final (statusDef, def) = await client.post('/api/subjects/$defaultId/archive');
      expect(statusDef, 409);
      final (statusDel, del) = await client.delete('/api/subjects/$defaultId?confirm=default');
      expect(statusDel, 409);
      expect((del as Map)['detail'], contains('默认学科'));

      final (statusDel2, del2) = await client.delete('/api/subjects/$id?confirm=$key');
      expect(statusDel2, 409);
      expect((del2 as Map)['detail'], contains('归档'));
      await client.post('/api/subjects/$id/archive');
      final (_, delOk) = await client.delete('/api/subjects/$id?confirm=$key');
      expect((delOk) as Map, containsPair('ok', true));
    });

    test('S23 迁移与诊断接口形状', () async {
      final (status, body) = await client.get('/api/migrations/status');
      expect(status, 200);
      final map = body as Map;
      expect(map['applied'], isA<List>());
      expect(map['pending'], isA<List>());
      expect(map.containsKey('report'), isTrue);

      final (_, run) = await client.post('/api/migrations/run', {});
      expect((run as Map)['ok'], isTrue);

      final (_, active) = await client.get('/api/subjects/active');
      final id = (active as Map)['id'] as int;
      final (statusDiag, diag) = await client.get('/api/diagnostics/subject/$id');
      expect(statusDiag, 200);
      expect((diag as Map)['db_exists'], isTrue);
      expect(diag['schema_version'], kSubjectSchemaVersion);
      expect(diag['open_handles'], lessThanOrEqualTo(kSubjectMaxOpenHandles));

      final (statusPath, pathInfo) = await client.get('/api/subjects/$id/path');
      expect(statusPath, 200);
      expect((pathInfo as Map)['db_path'], endsWith(p.join('subjects', 'default', 'loop.db')));
    });

    test('S24 旧客户端兼容：不带 subject 的 /api/today 与 /api/notes 落在当前学科', () async {
      final (statusToday, today) = await client.get('/api/today');
      expect(statusToday, 200);
      expect((today as Map)['subject_key'], 'default');
      final (statusNotes, notes) = await client.get('/api/notes');
      expect(statusNotes, 200);
      expect(notes, isEmpty);
      final (statusSelf, settings) = await client.get('/api/settings');
      expect(statusSelf, 200);
      expect((settings as Map)['active_subject'], 'default');
    });
  });

  group('S25 正式库零污染（AC-10）', () {
    test('S25 全流程结束后正式 data/loop.db 的 mtime + sha256 不变', () {
      final real = _realLoopDb();
      if (real == null) {
        markTestSkipped('仓库内没有 data/loop.db（无正式库可断言）');
        return;
      }
      final root = _tempRoot();
      addTearDown(() => _deleteQuietly(root));
      _createLegacyDb(root);
      SubjectStore.initTempForTests(root);
      SubjectMigration.ensureApplied();
      final a = SubjectStore.create(name: '污染检测学科');
      SubjectStore.open(a.key).insert('conversations', {
        'title': 'should stay isolated',
        'mode': 'answer',
        'created_at': Db.nowIso(),
        'updated_at': Db.nowIso(),
      });
      SubjectStore.closeAll();
      SubjectStore.resetForTests();

      expect(_fingerprint(real), realDbFingerprintBefore);
      expect(p.normalize(AppPaths.data.path), p.normalize(root.path));
      expect(p.normalize(AppPaths.subjectsDir.path),
          p.normalize(p.join(root.path, 'subjects')));
      expect(p.normalize(AppPaths.data.path),
          isNot(p.normalize(p.join(Directory.current.path, 'data'))));
    });
  });
}

/// 极简 HTTP 客户端（测试内使用，避免依赖 LoopApi 的具体实现）。
class LoopApiHttp {
  LoopApiHttp(this.base);

  final String base;

  Future<(int, Object?)> _send(String method, String path, [Object? body]) async {
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
    final decoded = text.isEmpty ? null : jsonDecode(text);
    return (response.statusCode, decoded);
  }

  Future<(int, Object?)> get(String path) => _send('GET', path);
  Future<(int, Object?)> post(String path, [Object? body]) => _send('POST', path, body);
  Future<(int, Object?)> put(String path, [Object? body]) => _send('PUT', path, body);
  Future<(int, Object?)> patch(String path, [Object? body]) => _send('PATCH', path, body);
  Future<(int, Object?)> delete(String path) => _send('DELETE', path);
}