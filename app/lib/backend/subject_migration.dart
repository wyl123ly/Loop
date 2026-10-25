import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'db.dart';
import 'paths.dart';
import 'retrieval.dart';
import 'subject_store.dart';

/// 一次文件搬迁的结果（结构化写入 `migration.json` / `app_migrations.detail`，
/// 并经 `GET /api/migrations/status` 暴露给界面）。
class _FileMoveResult {
  /// 已复制成功且 `path` 已指向学科目录的行数（含"旧副本残留"的行）。
  int moved = 0;

  /// 无法搬迁（复制/sha256 校验失败）的行数——这些行的 path 无法重指。
  int failed = 0;

  /// 库里指向的文件不存在。
  int missing = 0;

  /// 路径在 `data/files` 之外（用户原始目录），按设计不改动。
  int external = 0;

  /// 已搬迁但**旧副本删除失败**（数据仍可检索，只是旧目录留下残留）。
  int leftover = 0;

  final List<String> errors = <String>[];
  final List<Map<String, Object?>> fileErrors = <Map<String, Object?>>[];

  /// 待删除的旧副本（COMMIT 成功后才删，F-10）。
  final List<Map<String, Object?>> pendingSourceDeletes = <Map<String, Object?>>[];

  void record(
    String table,
    Object? id,
    String path,
    String reason, {
    String kind = 'failed',
  }) {
    switch (kind) {
      case 'missing':
        missing++;
      case 'leftover':
        leftover++;
      default:
        failed++;
    }
    errors.add('$table#$id $reason：$path');
    fileErrors.add({
      'table': table,
      'id': id,
      'path': path,
      'reason': reason,
      'kind': kind,
      // fatal=false 表示"搬迁本身成功，只是旧副本残留"（数据仍可检索）。
      'fatal': kind != 'leftover',
    });
  }
}

/// 旧数据迁移 v0.7.1 → v0.8.0（docs/subject-feature-spec.md §5）。
///
/// 权威顺序 M1–M12：备份 → 建注册表/默认学科 → 建学科库 → ATTACH 搬迁
/// （保留原 id）→ 重建 FTS → 文件搬迁 → 逐表计数与抽样校验 → `legacy_*`
/// 改名 → 写 `app_migrations`/`migration.json` → 设 active → COMMIT。
///
/// 硬约束：
/// - 任何失败路径**不 DROP、不清空旧表**（旧表只在全部校验通过后改名）；
/// - 失败回滚删除本次创建的 `subjects/default/` 与注册行，旧库保持原样；
/// - `app_migrations['v0.8.0-subjects']` 是唯一幂等标记；
/// - 凡本模块写库一律经 `main.`/`subj.` 显式前缀，或调用显式的全局方法。
class SubjectMigration {
  static const String version = 'v0.8.0';

  /// 迁移的旧学习表（按外键无关顺序；均为显式列名搬迁）。
  static const List<String> legacyTables = [
    'conversations',
    'messages',
    'materials',
    'material_folders',
    'uploads',
    'tasks',
    'notes',
    'chunks',
  ];

  static String get migrationsDir => p.join(AppPaths.migrationsDir.path, version);
  static String get backupPath => p.join(migrationsDir, 'loop.db.bak');
  static String get reportPath => p.join(migrationsDir, 'migration.json');

  static String get _markerPath =>
      p.join(AppPaths.subjectDir(kDefaultSubjectKey).path, '.migration-in-progress');

  static Map<String, Object?>? record() => Db.globalOne(
        'SELECT id, applied_at, detail FROM app_migrations WHERE id=?',
        [kAppSubjectMigrationId],
      );

  static bool get applied => record() != null;

  static Map<String, Object?>? readReport() {
    final file = File(reportPath);
    if (!file.existsSync()) return null;
    try {
      final data = jsonDecode(file.readAsStringSync());
      return data is Map ? Map<String, Object?>.from(data) : null;
    } catch (_) {
      return null;
    }
  }

  /// `/api/migrations/status` 的数据源（§11.6）。
  static Map<String, Object?> status() {
    final report = readReport();
    return {
      'applied': [
        for (final row in Db.globalRows('SELECT id, applied_at FROM app_migrations ORDER BY applied_at'))
          {'id': row['id'], 'applied_at': row['applied_at']},
      ],
      'pending': applied ? <String>[] : <String>[kAppSubjectMigrationId],
      'running': false,
      'last_error': report?['result'] == 'ok' ? '' : (report?['error'] ?? ''),
      'report': report,
      'backup': File(backupPath).existsSync() ? backupPath : '',
      'data_dir': AppPaths.data.path,
    };
  }

  /// 启动时调用：已应用则直接返回；否则按需迁移（幂等）。
  static Map<String, Object?> ensureApplied({bool force = false}) {
    if (!AppPaths.ready) AppPaths.init();
    if (!Db.ready) Db.init();
    if (!force && applied) {
      SubjectStore.init();
      return {'ok': true, 'skipped': true, 'reason': 'already-applied'};
    }
    return run();
  }

  /// 执行迁移。返回 `{ok, skipped?, reason?, counts?, errors?, backup?}`。
  static Map<String, Object?> run() {
    if (!AppPaths.ready) AppPaths.init();
    if (!Db.ready) Db.init();
    SubjectStore.init();
    SubjectStore.closeAll();

    final global = Db.db;
    final legacyCounts = <String, int>{
      for (final table in legacyTables) table: Db.tableRowCount(table),
    };
    final legacyTotal = legacyCounts.values.fold<int>(0, (sum, value) => sum + value);

    // 上次迁移未完成（marker 仍在）→ 该目录不被承认，清空重建（§5.4 崩溃恢复）。
    final staleMarker = File(_markerPath);
    if (staleMarker.existsSync()) {
      SubjectStore.closeAll();
      final dir = Directory(AppPaths.subjectDir(kDefaultSubjectKey).path);
      if (dir.existsSync()) dir.deleteSync(recursive: true);
      Db.globalRun('DELETE FROM subjects WHERE key=?', [kDefaultSubjectKey]);
    }

    SubjectStore.ensureDefaultSubject();
    final defaultRecord = SubjectStore.byKey(kDefaultSubjectKey)!;

    if (legacyTotal == 0) {
      return {
        'ok': true,
        'skipped': true,
        'reason': 'no-legacy-data',
        'counts': legacyCounts,
      };
    }

    // 默认学科已经有数据 → 视为"已迁移过"，不重复搬（避免混库/重复）。
    final existing = SubjectStore.open(kDefaultSubjectKey);
    final existingRows = existing.count('conversations') +
        existing.count('messages') +
        existing.count('materials') +
        existing.count('notes') +
        existing.count('tasks') +
        existing.count('chunks');
    if (existingRows > 0) {
      SubjectStore.close(kDefaultSubjectKey);
      return {
        'ok': true,
        'skipped': true,
        'reason': 'default-not-empty',
        'counts': legacyCounts,
      };
    }
    SubjectStore.close(kDefaultSubjectKey);

    final errors = <String>[];
    final at = Db.nowIso();
    _FileMoveResult moveResult = _FileMoveResult();
    final report = <String, Object?>{
      'version': version,
      'at': at,
      'data_dir': AppPaths.data.path,
      'counts': legacyCounts,
      'errors': errors,
      'result': 'failed',
    };
    var backupSha = '';
    var backupSize = 0;
    var filesMoved = 0;

    try {
      Directory(migrationsDir).createSync(recursive: true);
      // M1：WAL 落盘 + 独占事务。
      global.execute('PRAGMA wal_checkpoint(TRUNCATE)');
      global.execute('BEGIN IMMEDIATE');

      // M2：备份（先 checkpoint 再按文件流复制，保证包含 WAL 内容）。
      backupSize = File(AppPaths.dbPath).copySync(backupPath).lengthSync();
      backupSha = sha256File(backupPath);
      report['backup'] = p.posix.joinAll(p.split(p.relative(backupPath, from: AppPaths.data.path)));
      report['backup_sha256'] = backupSha;
      report['backup_size'] = backupSize;

      // M3–M5：默认学科目录 + 空学科库 + marker（成功前该目录不被承认）。
      File(p.join(defaultRecord.dirPath, '.migration-in-progress')).writeAsStringSync(at);
      report['default_key'] = defaultRecord.key;

      // M6：ATTACH 学科库（仅迁移事务内允许，§4.5）。
      final subjectDbLiteral = defaultRecord.dbPath.replaceAll(r'\', '/').replaceAll("'", "''");
      global.execute("ATTACH DATABASE '$subjectDbLiteral' AS subj");

      final copied = <String, int>{};
      for (final table in legacyTables) {
        if (!Db.tableExistsIn(global, table)) continue;
        final target = global.select('PRAGMA subj.table_info($table)');
        if (target.isEmpty) continue;
        final source = {for (final row in global.select('PRAGMA main.table_info($table)'))
          (row['name'] ?? '').toString()};
        final columns = [
          for (final row in target)
            if (source.contains((row['name'] ?? '').toString())) (row['name'] ?? '').toString(),
        ];
        if (columns.isEmpty) continue;
        final list = columns.join(',');
        global.execute(
          'INSERT INTO subj.$table($list) SELECT $list FROM main.$table',
        );
        copied[table] = (global.select('SELECT COUNT(*) AS c FROM subj.$table').first['c'] as num)
            .toInt();
      }

      // M7：重建 FTS（虚拟表不能跨库复制；tokenize 规则与 retrieval.dart 一致）。
      final chunkRows = global.select('SELECT id, text FROM subj.chunks ORDER BY id');
      final insertFts = global.prepare('INSERT INTO subj.chunks_fts(chunk_id, tokens) VALUES(?, ?)');
      try {
        for (final row in chunkRows) {
          insertFts.execute([
            row['id'],
            tokenize((row['text'] ?? '').toString()).join(' '),
          ]);
        }
      } finally {
        insertFts.close();
      }

      // M8：文件搬迁（复制 → 校验 sha256 → **先把 path 指到学科目录**）。
      // F-10：本次**不删源**——删源放到 COMMIT 成功之后（M13），这样任何晚期
      // 失败（校验/改名/提交）都不会出现"唯一副本已被删掉"的数据丢失窗口。
      moveResult = _moveLegacyFiles(global);
      filesMoved = moveResult.moved;
      errors.addAll(moveResult.errors);
      report['files_moved'] = moveResult.moved;
      report['files_failed'] = moveResult.failed;
      report['files_missing'] = moveResult.missing;
      report['files_external'] = moveResult.external;
      report['files_leftover'] = moveResult.leftover;
      report['file_errors'] = moveResult.fileErrors;
      if (moveResult.errors.isNotEmpty) {
        // 日志可查：桌面端把 stderr 落进 data/loop.log。
        stderr.writeln(
          'subject migration: ${moveResult.errors.length} 个文件问题 '
          '(failed=${moveResult.failed}, leftover=${moveResult.leftover})：'
          '${moveResult.errors.take(5).join(' | ')}',
        );
      }

      // M9：校验。
      final mismatches = <String>[];
      if (failAfterCopyForTests) {
        throw StateError('注入的晚期失败（测试用）：复制已完成但尚未提交');
      }
      for (final table in legacyTables) {
        if (!Db.tableExistsIn(global, table)) continue;
        final sourceCount = (global.select('SELECT COUNT(*) AS c FROM main.$table').first['c'] as num).toInt();
        final targetCount = (global.select('SELECT COUNT(*) AS c FROM subj.$table').first['c'] as num).toInt();
        if (sourceCount != targetCount) {
          mismatches.add('$table: main=$sourceCount subj=$targetCount');
        }
      }
      if (mismatches.isNotEmpty) {
        throw StateError('逐表计数不一致：${mismatches.join('; ')}');
      }
      final ftsOk = _verifyFts(global);
      report['fts_ok'] = ftsOk;
      if (!ftsOk) {
        errors.add('FTS 抽样检索无命中（chunks 为空时属正常）');
      }

      // M10：旧表改名（保留只读副本，降级/取证）+ 迁移记录。
      for (final table in legacyTables) {
        if (!Db.tableExistsIn(global, table)) continue;
        global.execute('ALTER TABLE main.$table RENAME TO legacy_$table');
      }
      report['legacy_renamed'] = legacyTables
          .where((table) => Db.tableExistsIn(global, 'legacy_$table'))
          .toList();
      report['counts'] = {...legacyCounts, 'files_moved': filesMoved};

      // M11：active_subject 兜底。
      final active = Db.setting('active_subject', '');
      if (active.isEmpty || SubjectStore.resolve(active) == null) {
        Db.setSetting('active_subject', kDefaultSubjectKey);
      }

      // M12：提交 + 幂等记录。
      report['result'] = errors.isEmpty ? 'ok' : 'ok-with-errors';
      global.execute(
        'INSERT OR REPLACE INTO app_migrations(id, applied_at, detail) VALUES(?,?,?)',
        [kAppSubjectMigrationId, at, jsonEncode(report)],
      );
      global.execute('COMMIT');
      try {
        global.execute('DETACH DATABASE subj');
      } catch (_) {}

      // M13（F-10）：提交成功后才删旧副本。此时学科库已经是权威副本，
      // 删源失败只会留下"旧副本残留"（path 早已指向学科目录，不影响可用性）。
      _deleteMovedSources(moveResult);
      if (moveResult.leftover > 0) {
        errors.addAll(moveResult.errors.where(
          (message) => message.contains('旧副本残留'),
        ));
        for (final entry in moveResult.fileErrors) {
          if (entry['kind'] != 'leftover') continue;
          report['file_errors'] = moveResult.fileErrors;
          break;
        }
        report['result'] = 'ok-with-errors';
        report['files_leftover'] = moveResult.leftover;
        // 记账（DB 行 + migration.json）都要反映删源后的真实结果。
        try {
          Db.globalRun(
            'UPDATE app_migrations SET detail=? WHERE id=?',
            [jsonEncode(report), kAppSubjectMigrationId],
          );
        } catch (_) {}
        stderr.writeln(
          'subject migration: ${moveResult.leftover} 个旧副本未能删除（数据已在学科目录，可稍后清理）',
        );
      }

      final marker = File(_markerPath);
      if (marker.existsSync()) marker.deleteSync();
      _writeReport(report);
      return {
        'ok': true,
        'migration': kAppSubjectMigrationId,
        'counts': report['counts'],
        'files_moved': filesMoved,
        'files_failed': moveResult.failed,
        'files_missing': moveResult.missing,
        'files_external': moveResult.external,
        'files_leftover': moveResult.leftover,
        'file_errors': moveResult.fileErrors,
        'errors': errors,
        'backup': backupPath,
        'backup_sha256': backupSha,
      };
    } catch (error) {
      try {
        global.execute('ROLLBACK');
      } catch (_) {}
      try {
        global.execute('DETACH DATABASE subj');
      } catch (_) {}
      errors.add('$error');
      report['result'] = 'failed';
      report['error'] = '$error';
      // F-10 回滚策略：**保留**默认学科目录与备份，绝不删除任何副本。
      // 删源（M13）只在 COMMIT 成功后才发生，因此此刻旧 data/files 里的源文件
      // 一定还在；保留目录只是"下次启动重新迁移"的中间状态，不会丢数据。
      SubjectStore.closeAll();
      report['rollback'] = 'kept-default-dir-and-backup';
      report['backup_kept'] = File(backupPath).existsSync();
      report['sources_intact'] = moveResult.pendingSourceDeletes
          .every((pending) => File((pending['path'] ?? '').toString()).existsSync());
      // marker 保留：下次启动会重新执行迁移（幂等重建默认学科目录）。
      final defaultDir = Directory(defaultRecord.dirPath);
      if (defaultDir.existsSync()) {
        // 目录已建：留下"目录 + 注册行 + marker"，下次启动重跑（不丢任何副本）。
        report['default_dir_kept'] = true;
      } else {
        // 早期失败（目录都没建）：注册行是残留，删掉即可。
        Db.globalRun('DELETE FROM subjects WHERE key=?', [kDefaultSubjectKey]);
        report['default_dir_kept'] = false;
      }
      _writeReport(report);
      return {
        'ok': false,
        'error': '$error',
        'errors': errors,
        'files_moved': moveResult.moved,
        'files_leftover': moveResult.leftover,
        'sources_intact': report['sources_intact'],
        'backup': File(backupPath).existsSync() ? backupPath : '',
      };
    }
  }

  /// 文件搬迁：只搬 `data/files/**` 下的副本（外部路径不动）。
///
/// 顺序（F1 修复，t8 验证发现 2/540 个只读源文件删不掉）：
/// 1. 复制到 `subjects/<key>/files/` 并做 sha256 校验；
/// 2. **先把资料行的 path 指向学科目录**，再尝试删源——即使删源失败，也绝不
///    留下指向即将被清理的 `data/files` 的记录；
/// 3. 删源前清 Windows 只读属性（等价 `attrib -R`），失败重试一次；
/// 4. 仍删不掉：保留已校验的目标副本（可检索），记 `leftover` + 结构化错误。
  static _FileMoveResult _moveLegacyFiles(Database global) {
    final legacyRoot = p.normalize(AppPaths.files.path);
    final targetDir = AppPaths.subjectFilesDir(kDefaultSubjectKey)..createSync(recursive: true);
    final result = _FileMoveResult();
    for (final table in ['materials', 'uploads']) {
      final List<ResultSet> resultSets;
      try {
        resultSets = [global.select('SELECT id, path FROM subj.$table')];
      } catch (_) {
        continue; // 老库可能没有 uploads 表
      }
      for (final resultSet in resultSets) {
        for (final row in resultSet) {
          final id = row['id'];
          final rawPath = (row['path'] ?? '').toString();
          if (rawPath.trim().isEmpty) continue;
          final source = File(p.normalize(rawPath));
          if (!source.existsSync()) {
            result.record(table, id, rawPath, '文件缺失', kind: 'missing');
            continue;
          }
          if (!p.isWithin(legacyRoot, source.path)) {
            // 外部路径（用户原始目录）不改动。
            result.external++;
            continue;
          }

          File target;
          try {
            final name = _uniqueTargetName(targetDir.path, p.basename(source.path));
            target = source.copySync(p.join(targetDir.path, name));
            final sourceHash = sha256File(source.path);
            final targetHash = sha256File(target.path);
            if (sourceHash != targetHash) {
              _deleteFileForcing(target);
              result.record(table, id, rawPath, '复制校验失败（sha256 不一致）');
              continue;
            }
          } catch (error) {
            result.record(table, id, rawPath, '复制失败：$error');
            continue;
          }

          // 复制已校验：先重指 path（顺序很关键，见方法注释）；删源推迟到 COMMIT 后
          // （F-10：任何晚期失败都不会丢唯一副本）。
          global.execute('UPDATE subj.$table SET path=? WHERE id=?', [target.path, id]);
          result.moved++;
          result.pendingSourceDeletes.add({
            'table': table,
            'id': id,
            'path': source.path,
            'target': target.path,
          });
        }
      }
    }
    return result;
  }

  /// 删除源文件：**先清 Windows 只读属性**（等价 `attrib -R`）再删；仍失败则抛错。
  static void _deleteSourceFile(File source) {
    final injected = deleteFailureForTests;
    if (injected != null && injected(source.path)) {
      throw FileSystemException('注入的删除失败（测试用）', source.path);
    }
    clearWindowsReadOnly(source.path);
    try {
      source.deleteSync();
    } catch (_) {
      // 属性清除没生效（占位/权限/其它进程接管）：强制再清一次并重试。
      clearWindowsReadOnly(source.path, force: true);
      source.deleteSync();
    }
  }

  /// 测试注入点：返回 true 表示"这次删除源文件必须失败"，用于确定性地验证
  /// "删源失败 → 保留目标副本 + 结构化错误"的兜底路径。
  /// 生产路径永远为 null。
  static bool Function(String path)? deleteFailureForTests;

  /// 测试注入点（F-10）：在复制/校验之后、改名/提交之前抛错，模拟"晚期失败"，
  /// 用于验证回滚不会删掉唯一副本。生产路径恒为 false。
  static bool failAfterCopyForTests = false;

  /// COMMIT 成功之后统一删旧副本（F-10）。失败只记 leftover，不回滚。
  static void _deleteMovedSources(_FileMoveResult result) {
    for (final pending in result.pendingSourceDeletes) {
      final path = (pending['path'] ?? '').toString();
      if (path.isEmpty) continue;
      final source = File(path);
      if (!source.existsSync()) continue;
      try {
        _deleteSourceFile(source);
      } catch (error) {
        result.record(
          (pending['table'] ?? '').toString(),
          pending['id'],
          path,
          '源文件删除失败，旧副本残留（目标副本已保留且可检索）：$error',
          kind: 'leftover',
        );
      }
    }
  }

  /// 删除文件；失败只吞掉（用于清理校验失败的临时副本）。
  static void _deleteFileForcing(File file) {
    try {
      clearWindowsReadOnly(file.path);
      file.deleteSync();
    } catch (_) {
      try {
        clearWindowsReadOnly(file.path, force: true);
        file.deleteSync();
      } catch (_) {}
    }
  }

  /// 清除 Windows 只读属性（等价 `attrib -R`）；其它平台 no-op。
  ///
  /// Windows 上 Dart 合成的 `stat.mode` 会把只读文件标成 `0o100444`
  /// （缺 owner-write 位），据此判断是否需要调用 `attrib`，避免每个文件都
  /// 起一次子进程。返回"当前是否可写"。
  static bool clearWindowsReadOnly(String path, {bool force = false}) {
    if (!Platform.isWindows) return true;
    final file = File(path);
    try {
      if (!file.existsSync()) return false;
    } catch (_) {
      return false;
    }
    if (!force && _isWritable(file)) return true;
    try {
      final result = Process.runSync('attrib', ['-R', path]);
      if (result.exitCode != 0) {
        stderr.writeln('attrib -R 失败（${result.exitCode}）：$path ${result.stderr}');
      }
    } catch (error) {
      stderr.writeln('attrib -R 无法执行：$path $error');
    }
    return _isWritable(file);
  }

  /// Windows 只读属性在 dart:io 里映射为"缺 owner-write 位"。
  static bool _isWritable(File file) {
    try {
      return (file.statSync().mode & 0x80) != 0; // 0o200
    } catch (_) {
      return false;
    }
  }

  static String _uniqueTargetName(String dir, String name) {
    final candidate = p.join(dir, name);
    if (!File(candidate).existsSync()) return name;
    final ext = p.extension(name);
    final base = p.basenameWithoutExtension(name);
    for (var index = 1; index < 1000; index++) {
      final variant = '${base}_dup$index$ext';
      if (!File(p.join(dir, variant)).existsSync()) return variant;
    }
    return '${DateTime.now().microsecondsSinceEpoch}_$name';
  }

  /// FTS 抽样校验：取 3 条 chunk 的关键词检索，命中非空。
  static bool _verifyFts(Database global) {
    final samples = global.select('SELECT text FROM subj.chunks ORDER BY id LIMIT 3');
    if (samples.isEmpty) return true;
    var hits = 0;
    for (final row in samples) {
      final tokens = tokenize((row['text'] ?? '').toString()).take(4).toList();
      if (tokens.isEmpty) continue;
      final match = tokens.map((token) => '"$token"').join(' OR ');
      try {
        final found = global.select(
          'SELECT COUNT(*) AS c FROM subj.chunks_fts WHERE chunks_fts MATCH ?',
          [match],
        );
        if (((found.first['c'] as num?)?.toInt() ?? 0) > 0) hits++;
      } catch (_) {}
    }
    return hits > 0;
  }

  static void _writeReport(Map<String, Object?> report) {
    try {
      Directory(migrationsDir).createSync(recursive: true);
      File(reportPath).writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(report),
      );
    } catch (_) {}
  }

  /// 文件 sha256（小写十六进制，与 registry 逐文件清单一致）。
  static String sha256File(String path) {
    final digest = sha256.convert(File(path).readAsBytesSync());
    return digest.toString();
  }
}