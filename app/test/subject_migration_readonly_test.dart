import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'package:loop/backend/db.dart';
import 'package:loop/backend/folder_import.dart';
import 'package:loop/backend/retrieval.dart';
import 'package:loop/backend/subject_migration.dart';
import 'package:loop/backend/subject_store.dart';

/// t11：迁移只读文件残留（t8 验证发现 F1）的回归测试。
///
/// t8 在真实数据上观察到：540 个待搬迁文件里有 2 个带 Windows 只读属性，
/// 复制 + sha256 校验都成功、但删源失败（errno=5），于是这两行资料的 `path`
/// 仍指向旧 `data/files`（一旦旧目录被清理就失效）。
///
/// 本套用例覆盖：
/// R1 只读属性可被清除（等价 attrib -R）并能删除；
/// R2 含只读文件的旧库迁移：files_moved == 总数、errors 为空、全部 path 落在学科目录；
/// R3 只读场景下迁移幂等（第二次不重复搬移、不产生新错误）；
/// R4 删源仍失败时的兜底：保留可检索的目标副本 + path 指向学科目录 + 结构化错误；
/// R5 文件缺失如实记录（错误计数 + 路径）；
/// R6 学科目录外的路径（用户原始目录）按设计不动；
/// R7 folder_import 删除资料副本时同样能处理只读文件；
/// R8 全程不触碰正式 data/loop.db。

Directory _tempRoot() => Directory.systemTemp.createTempSync('loop-mig-ro-');

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

/// 目录指纹：文件数 + 总字节 + 每个（文件名, 大小, 是否只读）。
String _dirFingerprint(Directory dir) {
  final files = dir.listSync(recursive: true).whereType<File>().toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  var bytes = 0;
  final parts = <String>[];
  for (final file in files) {
    bytes += file.lengthSync();
    parts.add('${p.basename(file.path)}:${file.lengthSync()}:'
        '${(file.statSync().mode & 0x80) != 0}');
  }
  return '${files.length}|$bytes|${parts.join(',')}';
}

/// 把文件设为 Windows 只读（等价 `attrib +R`）；非 Windows 返回 false。
bool _markReadOnly(String path) {
  if (!Platform.isWindows) return false;
  final result = Process.runSync('attrib', ['+R', path]);
  expect(result.exitCode, 0, reason: 'attrib +R 应成功');
  return true;
}

bool _isWritable(String path) {
  try {
    return (File(path).statSync().mode & 0x80) != 0; // 0o200 owner write
  } catch (_) {
    return false;
  }
}

/// 造一个 v0.7.1 旧库：`files` 张材料 + `uploads` 张图片，全部指向 data/files 副本。
/// [readOnlyIndexes] / [readOnlyUploads] 指定的文件会被打成只读。
/// [missingIndexes] 指定的资料 path 指向不存在的文件。
/// [externalIndexes] 指定的资料 path 指向 data/files 之外的"用户原始目录"。
class _LegacyFixture {
  _LegacyFixture({
    required this.dataDir,
    required this.materialFiles,
    required this.readOnlyMaterials,
    required this.missingMaterials,
    this.externalFile,
  });

  final Directory dataDir;

  /// material id → 源文件绝对路径。
  final Map<int, String> materialFiles;

  /// 被打成只读的 material id 集合。
  final Set<int> readOnlyMaterials;
  final Set<int> missingMaterials;
  final String? externalFile;

  /// upload id → 源文件绝对路径（这里只放一个只读图片）。
  String? uploadFile;

  File get dbFile => File(p.join(dataDir.path, 'loop.db'));

  Map<String, int> counts() {
    final database = sqlite3.open(dbFile.path, mode: OpenMode.readOnly);
    try {
      return {
        'conversations': database.select('SELECT COUNT(*) c FROM conversations').first['c'] as int,
        'messages': database.select('SELECT COUNT(*) c FROM messages').first['c'] as int,
        'materials': database.select('SELECT COUNT(*) c FROM materials').first['c'] as int,
        'uploads': database.select('SELECT COUNT(*) c FROM uploads').first['c'] as int,
        'chunks': database.select('SELECT COUNT(*) c FROM chunks').first['c'] as int,
      };
    } finally {
      database.close();
    }
  }
}

_LegacyFixture _createLegacyFixture(Directory dataDir, {bool defects = true}) {
  final filesDir = Directory(p.join(dataDir.path, 'files'))..createSync(recursive: true);
  final externalDir = Directory(p.join(dataDir.path, 'external'))..createSync(recursive: true);
  final materialFiles = <int, String>{};
  final readOnly = <int>{};
  final missing = <int>{};
  const total = 6;
  for (var id = 1; id <= total; id++) {
    final file = File(p.join(filesDir.path, '2025010${id}_mat$id.txt'));
    if (defects && id == 6) {
      missing.add(id); // 故意不落盘
      materialFiles[id] = file.path;
      continue;
    }
    if (defects && id == 5) {
      // 这一行指向学科目录之外的"用户原始目录"，因此 data/files 里不放副本。
      materialFiles[id] = p.join(externalDir.path, 'outside.txt');
      continue;
    }
    file.writeAsStringSync('材料 $id：ROTOKEN$id 线性代数 特征值 讲义内容');
    materialFiles[id] = file.path;
    // 1、3、5 号文件带 Windows 只读属性（复现 F1）。
    if (id.isOdd && _markReadOnly(file.path)) readOnly.add(id);
  }

  final uploadFile = File(p.join(filesDir.path, '20250101_img.png'))
    ..writeAsBytesSync(List<int>.generate(64, (i) => i));
  _markReadOnly(uploadFile.path);

  final externalFile = File(p.join(externalDir.path, 'outside.txt'))
    ..writeAsStringSync('用户原始目录里的文件 OUSTSIDE1');

  final database = sqlite3.open(p.join(dataDir.path, 'loop.db'));
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
  database.execute(
    "INSERT INTO conversations(id,title,created_at,updated_at) "
    "VALUES(1,'旧对话','2025-01-01T10:00:00+08:00','2025-01-01T10:00:00+08:00')",
  );
  database.execute(
    "INSERT INTO messages(id,conversation_id,role,content,created_at) "
    "VALUES(1,1,'user','旧问题','2025-01-01T10:00:00+08:00')",
  );
  for (var id = 1; id <= total; id++) {
    final path = (defects && id == 5) ? externalFile.path : materialFiles[id]!;
    database.execute(
      'INSERT INTO materials(id,name,kind,path,status,pages,chars,created_at) '
      "VALUES($id,'mat$id.txt','txt',?,'ready',1,40,'2025-01-01T09:00:00+08:00')",
      [path],
    );
    if (!(defects && id == 6)) {
      database.execute(
        "INSERT INTO chunks(id,material_id,page,text) VALUES($id,$id,1,?)",
        ['材料 $id：ROTOKEN$id 线性代数 特征值 讲义内容'],
      );
    }
  }
  database.execute(
    'INSERT INTO uploads(id,name,path,mime,created_at) '
    "VALUES(1,'图片.png',?,'image/png','2025-01-01T09:30:00+08:00')",
    [uploadFile.path],
  );
  database.close();

  final fixture = _LegacyFixture(
    dataDir: dataDir,
    materialFiles: materialFiles,
    readOnlyMaterials: readOnly,
    missingMaterials: missing,
    externalFile: externalFile.path,
  );
  fixture.uploadFile = uploadFile.path;
  return fixture;
}

/// 旧库 data/files 里剩下的文件（搬迁后应清空）。
List<String> _legacyResidue(Directory dataDir) {
  final dir = Directory(p.join(dataDir.path, 'files'));
  if (!dir.existsSync()) return const [];
  return dir.listSync().whereType<File>().map((f) => p.basename(f.path)).toList();
}

void main() {
  final realDbBefore = _fingerprint(_realLoopDb());

  tearDownAll(() {
    expect(_fingerprint(_realLoopDb()), realDbBefore,
        reason: 'R8：迁移只读测试不得触碰正式 data/loop.db');
  });

  group('R1 只读属性清除', () {
    late Directory root;

    setUp(() => root = _tempRoot());
    tearDown(() => _deleteQuietly(root));

    test('R1 clearWindowsReadOnly 清除只读后文件可删除；只读时删除会失败（Windows）', () {
      final file = File(p.join(root.path, 'ro.txt'))..writeAsStringSync('hello');
      expect(_isWritable(file.path), isTrue);

      if (!_markReadOnly(file.path)) {
        // 非 Windows：只读位不影响删除（目录可写即可），跳过该分支断言。
        return;
      }
      expect(_isWritable(file.path), isFalse, reason: 'attrib +R 后应缺 owner-write 位');
      // 复现 F1：只读文件直接删除失败（errno=5）。
      expect(() => file.deleteSync(), throwsA(isA<FileSystemException>()));

      final cleared = SubjectMigration.clearWindowsReadOnly(file.path);
      expect(cleared, isTrue);
      expect(_isWritable(file.path), isTrue);
      file.deleteSync();
      expect(file.existsSync(), isFalse);
    });
  });

  group('R2-R4/R7 迁移搬迁（全量可搬，含只读文件）', () {
    late Directory root;
    late _LegacyFixture fixture;

    setUp(() {
      root = _tempRoot();
      fixture = _createLegacyFixture(root, defects: false);
      SubjectStore.initTempForTests(root);
    });

    tearDown(() {
      SubjectMigration.deleteFailureForTests = null;
      SubjectStore.closeAll();
      SubjectStore.resetForTests();
      _deleteQuietly(root);
    });

    test('R2 只读文件全部搬迁成功：files_moved=总数、errors 为空、path 都在学科目录', () {
      // 无缺陷 fixture：6 份资料（1/3/5 只读）+ 1 个只读图片 = 7 个文件，
      // 全在 data/files 下 → 必须 100% 搬迁且 errors 为空（F1 的直接回归）。
      const expectedMoves = 7;

      final result = SubjectMigration.ensureApplied();
      expect(result['ok'], isTrue, reason: '${result['error']}');
      expect(result['files_moved'], expectedMoves, reason: 'result=$result');
      expect(result['files_failed'], 0);
      expect(result['files_leftover'], 0, reason: '只读文件也必须能删源');
      expect(result['files_missing'], 0);
      expect(result['files_external'], 0);
      final errors = (result['errors'] as List).cast<Object?>();
      expect(errors, isEmpty, reason: 'errors=$errors');
      expect((result['file_errors'] as List), isEmpty);

      // 报告（migration.json）里同样可查。
      final report = SubjectMigration.readReport()!;
      expect(report['result'], 'ok');
      expect(report['files_moved'], expectedMoves);
      expect(report['files_failed'], 0);
      expect(report['files_leftover'], 0);
      expect((report['counts'] as Map)['files_moved'], expectedMoves);
      expect((report['file_errors'] as List), isEmpty);

      // 每份资料的 path 都在学科目录内，且旧副本已删。
      final def = SubjectStore.byKey('default')!;
      final db = SubjectStore.open(def.key);
      final rows = db.rows('SELECT id, name, path FROM materials');
      expect(rows, hasLength(expectedMoves - 1));
      for (final row in rows) {
        final id = (row['id'] as num).toInt();
        final path = '${row['path']}';
        expect(p.isWithin(def.filesPath, path), isTrue, reason: 'mat$id path 必须在学科目录内');
        expect(File(path).existsSync(), isTrue);
        expect(File(path).readAsStringSync(), contains('ROTOKEN$id'));
      }
      final upload = db.one('SELECT path FROM uploads WHERE id=1')!;
      expect(p.isWithin(def.filesPath, '${upload['path']}'), isTrue);
      expect(File('${upload['path']}').existsSync(), isTrue);
      expect(_legacyResidue(root), isEmpty, reason: '旧 data/files 必须清空');

      // 迁移后仍可检索：连"原来是只读"的文件也能被 FTS 命中。
      for (final id in [1, 3, 5]) {
        final tokens = tokenize('ROTOKEN$id').take(3).map((t) => '"$t"').join(' OR ');
        expect(
          db.rows('SELECT chunks_fts.chunk_id FROM chunks_fts WHERE chunks_fts MATCH ?', [tokens]),
          isNotEmpty,
          reason: 'mat$id 搬迁后必须可检索',
        );
      }
    });

    test('R3 幂等：第二次运行不重复搬移、不产生新错误', () {
      final first = SubjectMigration.ensureApplied();
      final report = SubjectMigration.readReport()!;
      final appliedAt = SubjectMigration.record()!['applied_at'];
      final movedCount = first['files_moved'];
      final def = SubjectStore.byKey('default')!;
      final handle = SubjectStore.open(def.key);
      final pathsBefore = [
        for (final row in handle.rows('SELECT id, path FROM materials ORDER BY id')) row['path'],
      ];
      final filesBefore = Directory(def.filesPath).listSync().whereType<File>().length;
      final errorsBefore = jsonEncode(report['file_errors']);

      SubjectStore.reopenForTests();
      final second = SubjectMigration.ensureApplied();
      expect(second['skipped'], isTrue);
      expect(second['reason'], 'already-applied');
      expect(SubjectMigration.record()!['applied_at'], appliedAt);
      expect((SubjectMigration.readReport()!['counts'] as Map)['files_moved'], movedCount);
      expect(jsonEncode(SubjectMigration.readReport()!['file_errors']), errorsBefore);

      final handle2 = SubjectStore.open(SubjectStore.byKey('default')!.key);
      final pathsAfter = [
        for (final row in handle2.rows('SELECT id, path FROM materials ORDER BY id')) row['path'],
      ];
      expect(pathsAfter, pathsBefore, reason: 'path 不得被二次搬迁改动');
      expect(Directory(def.filesPath).listSync().whereType<File>().length, filesBefore,
          reason: '不得产生重复副本');
    });

    test('R4 删源仍失败：保留可检索的目标副本 + path 指向学科目录 + 结构化错误', () {
      final loser = fixture.materialFiles[1]!; // 故意让 1 号（只读）删源失败
      SubjectMigration.deleteFailureForTests = (path) => p.normalize(path) == p.normalize(loser);

      final result = SubjectMigration.ensureApplied();
      expect(result['ok'], isTrue);
      expect(result['files_failed'], 0, reason: '复制成功，只是旧副本没删干净');
      expect(result['files_leftover'], 1);
      final fileErrors = (result['file_errors'] as List).cast<Map>();
      final leftover = fileErrors.firstWhere((e) => e['fatal'] == false);
      expect(leftover['table'], 'materials');
      expect(leftover['id'], 1);
      expect(p.normalize('${leftover['path']}'), p.normalize(loser));
      expect('${leftover['reason']}', contains('旧副本残留'));
      final errors = (result['errors'] as List).map((e) => '$e');
      expect(errors.any((e) => e.contains('旧副本残留') && e.contains(p.basename(loser))), isTrue,
          reason: '错误必须带明确路径：$errors');

      // 关键：资料 path 绝不能停留在即将被清理的旧目录。
      final def = SubjectStore.byKey('default')!;
      final db = SubjectStore.open(def.key);
      final row = db.one('SELECT path FROM materials WHERE id=1')!;
      expect(p.isWithin(def.filesPath, '${row['path']}'), isTrue);
      expect(File('${row['path']}').existsSync(), isTrue);
      expect(File('${row['path']}').readAsStringSync(), contains('ROTOKEN1'));
      expect(File(loser).existsSync(), isTrue, reason: '注入的失败意味着源文件保留');

      // 目标副本可检索（回退可用）。
      final tokens = tokenize('ROTOKEN1').take(3).map((t) => '"$t"').join(' OR ');
      expect(
        db.rows('SELECT chunks_fts.chunk_id FROM chunks_fts WHERE chunks_fts MATCH ?', [tokens]),
        isNotEmpty,
      );

      // 报告/接口可见：migration.json 记录 + /api/migrations/status 的 report 字段。
      final report = SubjectMigration.readReport()!;
      expect(report['files_leftover'], 1);
      // 无缺陷 fixture：只剩"旧副本残留"这一条结构化错误。
      expect((report['file_errors'] as List), hasLength(1));
      expect((SubjectMigration.status()['report'] as Map)['files_leftover'], 1);
    });

    test('R5/R6 缺失文件与学科目录外路径：如实记录，不误报为搬迁失败', () {
      // 这一条需要"缺失 + 目录外"的缺陷 fixture，因此单独换一个隔离数据目录。
      final defectRoot = _tempRoot();
      try {
        final defect = _createLegacyFixture(defectRoot, defects: true);
        SubjectStore.initTempForTests(defectRoot);

        final result = SubjectMigration.ensureApplied();
        expect(result['ok'], isTrue, reason: '${result['error']}');
        expect(result['files_moved'], 5, reason: '可搬的 4 份资料 + 1 张图片');
        expect(result['files_failed'], 0, reason: '缺失/外部路径都不算"搬迁失败"');
        expect(result['files_missing'], 1);
        final fileErrors = (result['file_errors'] as List).cast<Map>();
        final missing = fileErrors.where((e) => '${e['reason']}'.contains('文件缺失')).toList();
        expect(missing, hasLength(1));
        expect(missing.first['id'], 6);
        expect(p.normalize('${missing.first['path']}'),
            p.normalize(defect.materialFiles[6]!));
        expect(result['files_external'], 1, reason: '外部路径按设计不改动，且不算错误');
        final externalErrors = fileErrors.where((e) => '${e['path']}'.contains('outside.txt'));
        expect(externalErrors, isEmpty);

        // 缺陷路径下：能搬的都搬了，path 都在学科目录；外部原始文件保持不动。
        final def = SubjectStore.byKey('default')!;
        final db = SubjectStore.open(def.key);
        for (final row in db.rows('SELECT id, path FROM materials')) {
          final id = (row['id'] as num).toInt();
          if (id == 5) continue;
          if (id == 6) continue;
          expect(p.isWithin(def.filesPath, '${row['path']}'), isTrue);
        }
      } finally {
        SubjectStore.closeAll();
        SubjectStore.resetForTests();
        _deleteQuietly(defectRoot);
      }
    });

    test('R7 folder_import 删除资料副本时能处理只读文件', () async {
      SubjectMigration.ensureApplied();
      final def = SubjectStore.byKey('default')!;
      final handle = SubjectStore.open(def.key);

      // 学科目录内造一个只读副本 + 一条资料行。
      final copy = File(p.join(def.filesPath, 'ro_copy.txt'))..writeAsStringSync('x');
      _markReadOnly(copy.path);
      final id = handle.insert('materials', {
        'name': 'ro_copy.txt',
        'kind': 'txt',
        'path': copy.path,
        'status': 'ready',
        'created_at': Db.nowIso(),
      });

      await Db.runScoped(
        handle.database,
        () async => deleteMaterialById(id),
        subjectKey: def.key,
        filesDir: def.filesPath,
      );

      expect(copy.existsSync(), isFalse, reason: '删除资料应连只读副本一起清掉');
      expect(handle.one('SELECT id FROM materials WHERE id=?', [id]), isNull);
    });
  });

  // F1 的直接回归：全量都是"正常文件 + 只读文件"、没有缺失/外部路径时，
  // 迁移必须 errors=0、files_moved=全部、result=ok（对齐真实数据的 540/540）。
  group('R2b 无缺陷旧库（对齐真实 540/540）', () {
    late Directory root;
    late _LegacyFixture fixture;

    setUp(() {
      root = _tempRoot();
      fixture = _createLegacyFixture(root, defects: false);
      SubjectStore.initTempForTests(root);
    });

    tearDown(() {
      SubjectStore.closeAll();
      SubjectStore.resetForTests();
      _deleteQuietly(root);
    });

    test('只读文件也 100% 搬迁：errors 为空、result=ok、全部 path 在学科目录且可检索', () {
      final expected = fixture.counts()['materials']! + fixture.counts()['uploads']!;
      final result = SubjectMigration.ensureApplied();

      expect(result['ok'], isTrue, reason: '${result['error']}');
      expect(result['files_moved'], expected);
      expect(result['files_failed'], 0);
      expect(result['files_leftover'], 0);
      expect(result['files_missing'], 0);
      expect(result['files_external'], 0);
      expect((result['errors'] as List), isEmpty, reason: 'errors=${result['errors']}');
      expect((result['file_errors'] as List), isEmpty);

      final report = SubjectMigration.readReport()!;
      expect(report['result'], 'ok');
      expect((report['counts'] as Map)['files_moved'], expected);
      expect(report['files_failed'], 0);
      expect(report['file_errors'], isEmpty);

      final def = SubjectStore.byKey('default')!;
      final db = SubjectStore.open(def.key);
      final rows = db.rows('SELECT id, path FROM materials');
      expect(rows, hasLength(expected - 1));
      for (final row in rows) {
        final path = '${row['path']}';
        expect(p.isWithin(def.filesPath, path), isTrue, reason: 'mat${row['id']} 必须在学科目录内');
        expect(File(path).existsSync(), isTrue);
      }
      final upload = db.one('SELECT path FROM uploads')!;
      expect(p.isWithin(def.filesPath, '${upload['path']}'), isTrue);
      expect(_legacyResidue(root), isEmpty, reason: '旧 data/files 必须清空');

      // 只读来源的文件（1/3/5）搬迁后仍可检索。
      for (final id in [1, 3, 5]) {
        final tokens = tokenize('ROTOKEN$id').take(3).map((t) => '"$t"').join(' OR ');
        expect(
          db.rows('SELECT chunks_fts.chunk_id FROM chunks_fts WHERE chunks_fts MATCH ?', [tokens]),
          isNotEmpty,
          reason: 'mat$id 搬迁后必须可检索',
        );
      }
    });
  });

  // 真实数据副本演练（默认跳过）：把正式 data/loop.db + data/files 复制到隔离目录、
  // 把副本库里的绝对路径改写到隔离目录，然后跑迁移，验证 t8 F1 的现场
  // （540 个文件、其中 2 个 Windows 只读）能 540/540 搬迁且 errors=0。
  // 源数据全程只读：结束时用指纹断言守住。
  // 复现：`$env:LOOP_REAL_MIGRATION_DRILL='1'; flutter test test/subject_migration_readonly_test.dart`
  final drillEnabled = Platform.environment['LOOP_REAL_MIGRATION_DRILL'] == '1';

  group('R-DRILL 真实数据副本演练（opt-in）', () {
    test('真实 540 文件（含 2 只读）全部搬迁、errors=0、源数据零改动', () {
      Directory? repoData;
      for (final candidate in [Directory.current, Directory.current.parent]) {
        final dir = Directory(p.join(candidate.path, 'data'));
        if (File(p.join(dir.path, 'loop.db')).existsSync()) {
          repoData = dir;
          break;
        }
      }
      expect(repoData, isNotNull, reason: '找不到正式 data/ 目录');
      final realData = repoData!;
      final realDb = File(p.join(realData.path, 'loop.db'));
      final realFiles = Directory(p.join(realData.path, 'files'));
      final realDbBefore = _fingerprint(realDb);
      final realFilesBefore = _dirFingerprint(realFiles);
      final realFileCount = realFiles.listSync().whereType<File>().length;
      final realReadOnly = realFiles
          .listSync()
          .whereType<File>()
          .where((f) => (f.statSync().mode & 0x80) == 0)
          .map((f) => p.basename(f.path))
          .toList();

      final iso = Directory.systemTemp.createTempSync('loop-real-migrate-');
      try {
        // 1) 复制全局库 + 资料副本（源只读，属性也一并复制）。
        realDb.copySync(p.join(iso.path, 'loop.db'));
        final isoFiles = Directory(p.join(iso.path, 'files'))..createSync(recursive: true);
        for (final entity in realFiles.listSync().whereType<File>()) {
          entity.copySync(p.join(isoFiles.path, p.basename(entity.path)));
        }
        expect(isoFiles.listSync().whereType<File>().length, realFileCount);
        expect(
          isoFiles.listSync().whereType<File>().where((f) => (f.statSync().mode & 0x80) == 0).length,
          realReadOnly.length,
          reason: '复制后必须保留只读属性，否则复现不出 F1',
        );

        // 2) 把副本库里的绝对路径改写到隔离目录（源库/源文件全程不动）。
        final legacy = sqlite3.open(p.join(iso.path, 'loop.db'));
        final realPrefix = p.normalize(realData.path);
        final isoPrefix = p.normalize(iso.path);
        for (final table in ['materials', 'uploads']) {
          legacy.execute(
            'UPDATE $table SET path = ? || substr(path, ?) WHERE path LIKE ?',
            [isoPrefix, realPrefix.length + 1, '$realPrefix%'],
          );
        }
        final expectedMoves =
            (legacy.select('SELECT COUNT(*) c FROM materials WHERE path LIKE ?', ['$isoPrefix%'])
                        .first['c'] as int) +
                (legacy.select('SELECT COUNT(*) c FROM uploads WHERE path LIKE ?', ['$isoPrefix%'])
                        .first['c'] as int);
        final sampleText =
            (legacy.select('SELECT text FROM chunks LIMIT 1').first['text'] ?? '').toString();
        legacy.close();

        // 3) 迁移。
        SubjectStore.initTempForTests(iso);
        final result = SubjectMigration.ensureApplied();
        expect(result['ok'], isTrue, reason: '${result['error']}');
        expect(result['files_moved'], expectedMoves, reason: '必须全部搬迁（对齐 540/540）');
        expect(result['files_failed'], 0);
        expect(result['files_leftover'], 0, reason: '只读文件也必须能删源');
        expect(result['files_missing'], 0);
        expect((result['errors'] as List), isEmpty, reason: 'errors=${result['errors']}');
        expect((SubjectMigration.readReport()!['counts'] as Map)['files_moved'], expectedMoves);

        // 4) 每份资料的 path 都在学科目录内、文件存在、旧目录清空、FTS 可检索。
        final def = SubjectStore.byKey('default')!;
        final handle = SubjectStore.open(def.key);
        var checked = 0;
        for (final row in handle.rows('SELECT id, path FROM materials')) {
          final path = '${row['path']}';
          if (!path.startsWith(isoPrefix)) continue; // 学科目录之外的原路径（按设计不动）
          expect(p.isWithin(def.filesPath, path), isTrue,
              reason: 'material ${row['id']} path 必须在学科目录：$path');
          expect(File(path).existsSync(), isTrue);
          checked++;
        }
        for (final row in handle.rows('SELECT id, path FROM uploads')) {
          expect(p.isWithin(def.filesPath, '${row['path']}'), isTrue);
          expect(File('${row['path']}').existsSync(), isTrue);
        }
        expect(checked, greaterThan(0));
        expect(isoFiles.listSync().whereType<File>(), isEmpty, reason: '旧 data/files 必须清空');
        final tokens = tokenize(sampleText).take(4).map((t) => '"$t"').join(' OR ');
        if (tokens.isNotEmpty) {
          expect(
            handle.rows('SELECT chunks_fts.chunk_id FROM chunks_fts WHERE chunks_fts MATCH ? LIMIT 1',
                [tokens]),
            isNotEmpty,
            reason: '迁移后必须可检索',
          );
        }
      } finally {
        SubjectStore.closeAll();
        Db.resetForTests();
        SubjectStore.resetForTests();
        try {
          for (final entity in iso.listSync(recursive: true).whereType<File>()) {
            SubjectMigration.clearWindowsReadOnly(entity.path, force: true);
          }
          iso.deleteSync(recursive: true);
        } catch (_) {}
        // 源数据必须一字未动。
        expect(_fingerprint(realDb), realDbBefore, reason: '正式 loop.db 不得被改动');
        expect(_dirFingerprint(realFiles), realFilesBefore, reason: '正式 data/files 不得被改动');
      }
    }, skip: drillEnabled
        ? false
        : '设置 LOOP_REAL_MIGRATION_DRILL=1 才跑真实数据副本演练（默认跳过，保持测试自足）');
  });
}