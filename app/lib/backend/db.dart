import 'dart:async';
import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'paths.dart';

/// 学科作用域载体：随 [Zone] 传播的学科库句柄 + key + 资料目录 + 库路径。
class SubjectScope {
  const SubjectScope({
    required this.database,
    required this.key,
    required this.filesDir,
    this.dbPath = '',
  });

  final Database database;
  final String key;
  final String filesDir;

  /// 学科库文件路径（结构性断言用：必须在 `data/subjects/` 下）。
  final String dbPath;
}

/// SQLite 数据层（进程内，同步访问）。
///
/// v0.8.0 起有两类库：
/// - **全局库** `data/loop.db`：学科注册表 `subjects`、`app_migrations`、
///   设置/用量/审计/运行状态/MCP/后台任务等应用级表（§2.4）。
/// - **学科库** `data/subjects/<key>/loop.db`：会话、消息、资料、笔记、待办、
///   进度、技能注册行（由 `subject_store.dart` 管理）。
///
/// 作用域路由：默认所有 `rows/one/scalar/insert/run` 落在全局库（保持旧行为）。
/// 在 [runScoped] 内，**不涉及全局表的 SQL** 会透明落到该学科库，因此
/// `agent.dart` / `agent_tools.dart` / `retrieval.dart` / `folder_import.dart`
/// 等既有调用点无需改动即可在学科上下文中正确取数（跨库原则 §4.5：单条 SQL
/// 只允许命中一个库，禁止跨库 JOIN）。
class Db {
  /// 全局库句柄。测试可通过 [resetForTests] 关闭后在另一个数据目录重新 [init]，
  /// 因此这里不是 `final`。
  static late Database db;
  static bool _ready = false;

  static void init() {
    if (_ready) return;
    db = sqlite3.open(AppPaths.dbPath);
    db.execute('PRAGMA journal_mode=WAL');
    db.execute('PRAGMA foreign_keys=ON');
    db.execute('PRAGMA busy_timeout=3000');
    // 生产路径：只建注册表与应用级表；学科数据一律落 data/subjects/<key>/loop.db。
    _migrate();
    db.execute("UPDATE agent_runs SET status='error' WHERE status='running'");
    _ready = true;
  }

  /// 测试专用：内存库 + 与正式库相同的迁移/默认值，不触碰用户数据目录。
  /// 额外建 v0.7.1 的学习表（`legacyCompat`），让既有的纯 Db 协议测试保持原行为。
  static void initInMemoryForTests() {
    if (_ready) return;
    db = sqlite3.openInMemory();
    _migrate(legacyCompat: true);
    _ready = true;
  }

  /// 测试专用：关闭并忘记当前全局库，允许在另一个数据目录重新 [init]。
  static void resetForTests() {
    if (_ready) {
      try {
        db.close();
      } catch (_) {}
    }
    _ready = false;
  }

  static bool get ready => _ready;

  /// v0.7.1 的学习表定义（**仅** [initInMemoryForTests] 使用）。
  ///
  /// 生产库不再创建这些表：它们属于学科库；老库里遗留的实例在迁移后改名为
  /// `legacy_*` 只读留存。这里保留定义只为让"纯内存协议测试"沿用旧行为。
  static void _migrateLegacyCompat() {
    db.execute('''
      CREATE TABLE IF NOT EXISTS conversations(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT DEFAULT '新对话',
        mode TEXT DEFAULT 'answer',
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS messages(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        conversation_id INTEGER NOT NULL,
        role TEXT NOT NULL,
        content TEXT NOT NULL DEFAULT '',
        steps TEXT DEFAULT '[]',
        refs TEXT DEFAULT '[]',
        attachments TEXT DEFAULT '[]',
        model TEXT DEFAULT '',
        tokens_in INTEGER DEFAULT 0,
        tokens_out INTEGER DEFAULT 0,
        created_at TEXT NOT NULL
      );
      CREATE INDEX IF NOT EXISTS idx_messages_conv ON messages(conversation_id, id);
      CREATE TABLE IF NOT EXISTS materials(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        kind TEXT NOT NULL,
        path TEXT DEFAULT '',
        status TEXT DEFAULT 'ready',
        pages INTEGER DEFAULT 0,
        chars INTEGER DEFAULT 0,
        created_at TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS material_folders(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        root_path TEXT UNIQUE,
        name TEXT,
        created_at TEXT NOT NULL,
        last_scan_at TEXT DEFAULT ''
      );
      CREATE TABLE IF NOT EXISTS uploads(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT,
        path TEXT,
        mime TEXT,
        created_at TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS chunks(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        material_id INTEGER NOT NULL,
        page INTEGER DEFAULT 0,
        text TEXT NOT NULL
      );
      CREATE INDEX IF NOT EXISTS idx_chunks_mat ON chunks(material_id);
      CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts USING fts5(chunk_id UNINDEXED, tokens);
    CREATE TABLE IF NOT EXISTS material_ocr_pages(
      material_id INTEGER NOT NULL,
      page INTEGER NOT NULL,
      status TEXT NOT NULL,
      chars INTEGER DEFAULT 0,
      error TEXT DEFAULT '',
      PRIMARY KEY(material_id, page)
    );
      CREATE TABLE IF NOT EXISTS tasks(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT NOT NULL,
        due TEXT DEFAULT '',
        estimate_min INTEGER DEFAULT 30,
        status TEXT DEFAULT 'todo',
        created_at TEXT NOT NULL,
        done_at TEXT DEFAULT ''
      );
      CREATE TABLE IF NOT EXISTS notes(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT NOT NULL,
        body TEXT NOT NULL,
        source_ref TEXT DEFAULT '',
        created_at TEXT NOT NULL
      );
    ''');
  }

  /// 属于**学科库**的表（学习产物）：全局库不再创建、不再写入（v0.8.0 双库收敛）。
  ///
  /// 只有两种情况下它们会出现在全局库里：
  /// 1. 旧 v0.7.1 库升级而来（迁移的**来源**，迁移后改名为 `legacy_*` 只读留存）；
  /// 2. 纯内存测试（[initInMemoryForTests] 的 v0.7.1 兼容 schema，供既有流式/
  ///    代理测试沿用旧行为）。
  static const List<String> subjectOwnedTables = [
    'conversations',
    'messages',
    'materials',
    'material_folders',
    'uploads',
    'chunks',
    'tasks',
    'notes',
  ];

  /// 全局库专属表（应用自身配置/运行时/统计）。
  static const List<String> appOwnedTables = [
    'settings',
    'usage',
    'agent_runs',
    'agent_audit',
    'mcp_servers',
    'agent_jobs',
    'subjects',
    'app_migrations',
  ];

  /// 建全局库 schema。
  ///
  /// [legacyCompat] 为 true 时才创建 v0.7.1 的学习表——**仅测试**使用，
  /// 让既有的纯 Db 测试（流式协议/供应商注册表）保持原行为；生产路径
  /// （[init]）只建学科注册表与应用级表，学科数据一律落学科库。
  static void _migrate({bool legacyCompat = false}) {
    if (legacyCompat) {
      _migrateLegacyCompat();
    }
    db.execute('''
      CREATE TABLE IF NOT EXISTS settings(
        key TEXT PRIMARY KEY,
        value TEXT
      );
      CREATE TABLE IF NOT EXISTS usage(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        ts TEXT NOT NULL,
        model TEXT,
        tokens_in INTEGER DEFAULT 0,
        tokens_out INTEGER DEFAULT 0,
        cost REAL DEFAULT 0
      );
      DROP TABLE IF EXISTS cards;
      DROP TABLE IF EXISTS reviews;
      CREATE TABLE IF NOT EXISTS agent_runs(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        conversation_id INTEGER NOT NULL,
        status TEXT DEFAULT 'running',
        cancel_requested INTEGER DEFAULT 0,
        tool_calls INTEGER DEFAULT 0,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS mcp_servers(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        transport TEXT DEFAULT 'stdio',
        command TEXT DEFAULT '',
        args TEXT DEFAULT '[]',
        env TEXT DEFAULT '{}',
        working_directory TEXT DEFAULT '',
        url TEXT DEFAULT '',
        enabled INTEGER DEFAULT 0,
        trust_mode TEXT DEFAULT 'ask',
        created_at TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS agent_jobs(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT NOT NULL,
        prompt TEXT NOT NULL,
        mode TEXT DEFAULT 'answer',
        mode_prompt TEXT DEFAULT '',
        schedule_kind TEXT DEFAULT 'interval',
        schedule_value TEXT DEFAULT '60',
        next_run TEXT DEFAULT '',
        last_run TEXT DEFAULT '',
        enabled INTEGER DEFAULT 0,
        tool_scope TEXT DEFAULT '[]',
        budget_tokens INTEGER DEFAULT 60000,
        timeout_sec INTEGER DEFAULT 180,
        last_status TEXT DEFAULT '',
        created_at TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS agent_audit(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        run_id INTEGER,
        job_id INTEGER,
        tool TEXT,
        args TEXT,
        result TEXT,
        risk TEXT,
        approval TEXT,
        duration_ms INTEGER,
        created_at TEXT NOT NULL
      );
      -- 学科注册表（§3.1）：全局唯一权威。这里**不允许**出现
      -- `DROP TABLE IF EXISTS subjects` —— v0.7.1 有这条语句，每次启动清空用户
      -- 学科（R1 回归点）；v0.8.0 已移除，并有"重启后学科仍在"的单测保护。
      CREATE TABLE IF NOT EXISTS subjects(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        key TEXT NOT NULL UNIQUE,
        name TEXT NOT NULL,
        description TEXT DEFAULT '',
        icon TEXT DEFAULT '',
        color TEXT DEFAULT '',
        goal TEXT DEFAULT '',
        exam_date TEXT DEFAULT '',
        daily_minutes INTEGER DEFAULT 0,
        level TEXT DEFAULT '',
        status TEXT NOT NULL DEFAULT 'active',
        is_default INTEGER NOT NULL DEFAULT 0,
        sort_order INTEGER DEFAULT 0,
        db_rel_path TEXT NOT NULL,
        files_rel_path TEXT NOT NULL,
        skills_rel_path TEXT NOT NULL,
        schema_version INTEGER NOT NULL DEFAULT 1,
        integrity TEXT NOT NULL DEFAULT 'ok',
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        last_opened_at TEXT DEFAULT '',
        archived_at TEXT DEFAULT ''
      );
      CREATE UNIQUE INDEX IF NOT EXISTS idx_subjects_name ON subjects(name COLLATE NOCASE);
      CREATE INDEX IF NOT EXISTS idx_subjects_status ON subjects(status, sort_order);
      CREATE TABLE IF NOT EXISTS app_migrations(
        id TEXT PRIMARY KEY,
        applied_at TEXT NOT NULL,
        detail TEXT DEFAULT '{}'
      );
    ''');
    // 老库补齐列：只对**确实存在**的表执行，避免在生产 schema（无学习表）上
    // 反复抛 "no such table" 被吞掉。
    try {
      db.execute(
        "ALTER TABLE mcp_servers ADD COLUMN working_directory TEXT DEFAULT ''",
      );
    } catch (_) {}
    final columns = <String, String>{
      'messages': "plan TEXT DEFAULT '[]'",
      'materials': "folder_id INTEGER DEFAULT 0",
      'usage': "subject_key TEXT DEFAULT ''",
      'agent_runs': "subject_key TEXT DEFAULT ''",
      'agent_audit': "subject_key TEXT DEFAULT ''",
    };
    for (final entry in columns.entries) {
      if (!tableExists(entry.key)) continue;
      try {
        db.execute('ALTER TABLE ${entry.key} ADD COLUMN ${entry.value}');
      } catch (_) {}
    }
    for (final sql in [
      "ALTER TABLE messages ADD COLUMN attachments TEXT DEFAULT '[]'",
      "ALTER TABLE materials ADD COLUMN source_path TEXT DEFAULT ''",
      "ALTER TABLE materials ADD COLUMN source_mtime INTEGER DEFAULT 0",
      "ALTER TABLE materials ADD COLUMN source_size INTEGER DEFAULT 0",
      "ALTER TABLE materials ADD COLUMN relative_path TEXT DEFAULT ''",
      "ALTER TABLE materials ADD COLUMN ocr INTEGER DEFAULT 0",
      "ALTER TABLE materials ADD COLUMN ocr_model TEXT DEFAULT ''",
      "ALTER TABLE materials ADD COLUMN ocr_status TEXT DEFAULT ''",
      "ALTER TABLE materials ADD COLUMN ocr_failed_pages TEXT DEFAULT ''",
      "ALTER TABLE materials ADD COLUMN ocr_at TEXT DEFAULT ''",
    ]) {
      final table = sql.split(' ')[2];
      if (!tableExists(table)) continue;
      try {
        db.execute(sql);
      } catch (_) {}
    }

    seedDefaults();
  }

  /// 把缺失的默认设置补进老库（幂等；启动迁移与测试升级路径共用）。
  static void seedDefaults() {
    for (final entry in _defaults.entries) {
      db.execute('INSERT OR IGNORE INTO settings(key, value) VALUES(?, ?)', [
        entry.key,
        entry.value,
      ]);
    }
  }

  static const _defaults = {
    'api_key': '',
    'base_url': 'https://api.deepseek.com',
    'model': 'deepseek-flash',
    'reason_model': 'deepseek-v4-pro',
    'providers_v1': '[]',
    'active_provider': 'deepseek',
    'theme': 'system',
    'auto_check_updates': 'true',
    'sidebar_collapsed': 'false',
    'stream_output': 'true',
    'custom_modes': '[]',
    'workspace_path': '',
    'agent_shell': 'true',
    'agent_browser': 'true',
    'agent_mcp': 'true',
    'agent_background': 'false',
    // v0.8.0 学科相关（§4.2）
    'active_subject': AppPaths.defaultSubjectKey,
    'cross_subject_search': 'false',
    'skill_hub_url': 'https://eduhub.deeptutor.info',
    'skill_auto_update_check': 'false',
    'skill_inject_max': '3',
  };

  // ---------------------------------------------------------------- 作用域

  /// 全局库专属表：即使处于学科作用域内也必须落在全局库。
  static const Set<String> globalTables = {
    'settings',
    'usage',
    'agent_runs',
    'agent_audit',
    'mcp_servers',
    'agent_jobs',
    'subjects',
    'app_migrations',
  };

  /// 从 SQL 里解析被引用的表名（`FROM`/`JOIN`/`INTO`/`UPDATE`/`TABLE`）。
  ///
  /// F-16：路由不再靠"文本启发式"（整句里出现某关键字就落全局库），而是先把
  /// 语句目标表解析出来，再按 [appOwnedTables] 判定归属；同时断言一条语句
  /// **不得同时引用全局表与学科表**（跨库 JOIN 是结构性禁止的，§4.5）。
  static final RegExp _tableRef = RegExp(
    r'\b(?:from|join|into|update|table)\s+([A-Za-z_][A-Za-z0-9_]*)',
    caseSensitive: false,
  );

  /// F-16（t13 复修）：解析前先剔除字符串字面量与注释——否则
  /// `WHERE title = 'from settings'` 或 `-- 见 materials 表` 会被误判成跨库引用。
  static String stripSqlNoise(String sql) {
    final out = StringBuffer();
    var i = 0;
    while (i < sql.length) {
      final ch = sql[i];
      final next = i + 1 < sql.length ? sql[i + 1] : '';
      // 单引号字符串（'' 转义）
      if (ch == "'") {
        out.write(' ');
        i++;
        while (i < sql.length) {
          if (sql[i] == "'") {
            if (i + 1 < sql.length && sql[i + 1] == "'") {
              i += 2;
              continue;
            }
            i++;
            break;
          }
          i++;
        }
        continue;
      }
      // 双引号标识符 / 反引号 / [方括号]
      if (ch == '"' || ch == '`') {
        final quote = ch;
        out.write(' ');
        i++;
        while (i < sql.length) {
          if (sql[i] == quote) {
            if (i + 1 < sql.length && sql[i + 1] == quote) {
              i += 2;
              continue;
            }
            i++;
            break;
          }
          i++;
        }
        continue;
      }
      if (ch == '[') {
        out.write(' ');
        i++;
        while (i < sql.length && sql[i] != ']') {
          i++;
        }
        if (i < sql.length) i++;
        continue;
      }
      // -- 行注释
      if (ch == '-' && next == '-') {
        while (i < sql.length && sql[i] != '\n') {
          i++;
        }
        continue;
      }
      // /* 块注释 */
      if (ch == '/' && next == '*') {
        i += 2;
        while (i + 1 < sql.length && !(sql[i] == '*' && sql[i + 1] == '/')) {
          i++;
        }
        i += 2;
        continue;
      }
      out.write(ch);
      i++;
    }
    return out.toString();
  }

  static Set<String> referencedTables(String sql) {
    final out = <String>{};
    for (final match in _tableRef.allMatches(stripSqlNoise(sql))) {
      final name = (match.group(1) ?? '').toLowerCase();
      if (name.isEmpty || _sqlKeywords.contains(name)) continue;
      out.add(name);
    }
    return out;
  }

  /// 关键字不得被当成表名（`UPDATE SET x=1` 里的 `SET`、`INSERT INTO … VALUES …`）。
  static const Set<String> _sqlKeywords = {
    'set',
    'values',
    'select',
    'where',
    'and',
    'or',
    'on',
    'using',
    'as',
    'if',
    'exists',
    'all',
    'any',
    'not',
    'null',
    'limit',
    'order',
    'group',
    'by',
    'left',
    'right',
    'inner',
    'outer',
    'cross',
    'union',
    'when',
    'then',
    'else',
    'end',
    'case',
    'with',
    'temporary',
    'virtual',
    'insert',
    'update',
    'delete',
    'from',
    'join',
    'into',
    'table',
    'index',
    'view',
    'trigger',
    'pragma',
  };

  static bool _isAppOwned(String table) =>
      appOwnedTables.contains(table) || globalTables.contains(table);

  /// 学科作用域路径断言（F-16）：作用域必须确实是 `data/subjects/<key>/loop.db`，
  /// 否则说明有人把全局库或其它文件当成学科库传了进来。
  static void assertSubjectScopePath(String dbPath) {
    if (dbPath.isEmpty || !AppPaths.ready) return;
    final target = p.normalize(dbPath);
    final root = p.normalize(AppPaths.subjectsDir.path);
    if (!p.isWithin(root, target)) {
      throw StateError('学科作用域路径不在 data/subjects/ 下：$dbPath');
    }
  }

  static final Object _scopeKey = Object();

  /// 学科作用域进出钩子（由 `SubjectStore` 注册；用于句柄 in-use 计数与
  /// "LRU 不得关闭使用中的句柄"，F-1）。生产路径之外保持 null。
  static void Function(Database database, bool entering)? scopeObserver;

  /// 由 `SubjectStore` 注册：按 Database 反查学科库文件路径，用于作用域
  /// 路径前缀断言（F-16），让所有 `runScoped` 调用点自动获得校验。
  static String Function(Database database)? scopePathResolver;

  /// 当前 zone 的学科作用域（无作用域时为 null）。
  static SubjectScope? get scope => Zone.current[_scopeKey] as SubjectScope?;

  /// 当前 zone 的学科库句柄（无作用域时为 null）。
  static Database? get scopedDatabase => scope?.database;

  /// 当前 zone 的学科 key（无作用域时为空串）。
  static String get scopedSubjectKey => scope?.key ?? '';

  /// 当前 zone 的学科资料目录（无作用域时为空串）。
  static String get scopedFilesDir => scope?.filesDir ?? '';

  /// 某条 SQL 的目标库（F-16）：
  /// - 无作用域 → 全局库（旧行为）；
  /// - 引用了应用级表 → 全局库；
  /// - 引用学科表（或没有可解析的表名，例如 PRAGMA/BEGIN）→ 学科库；
  /// - 同时引用两类 → 抛错（禁止跨库 JOIN / 跨库子查询）。
  static Database _target(String sql) {
    final current = scope;
    if (current == null) return db;
    final tables = referencedTables(sql);
    if (tables.isEmpty) {
      // R2-7：DML 语句却解析不出表名 → 解析失败（而不是静默落学科库）。
      if (_dmlWithoutTable.hasMatch(stripSqlNoise(sql))) {
        throw StateError(
          '无法解析 SQL 的目标表（R2-7）：${_sqlFragment(sql)}；已解析表名：${tables.join('/')}',
        );
      }
      return current.database;
    }
    final appRefs = tables.where(_isAppOwned).toList();
    final subjectRefs = tables.where((table) => !_isAppOwned(table)).toList();
    if (appRefs.isNotEmpty && subjectRefs.isNotEmpty) {
      throw StateError(
        '禁止跨库 JOIN：同一语句同时引用全局表 ${appRefs.join('/')} 与学科表 '
        '${subjectRefs.join('/')}（§4.5）；SQL 片段：${_sqlFragment(sql)}',
      );
    }
    return appRefs.isNotEmpty ? db : current.database;
  }

  /// DML/DDL 却解析不出表名（PRAGMA/BEGIN/SELECT 1 等不算）。
  static final RegExp _dmlWithoutTable = RegExp(
    r'^\s*(?:insert\s+into|update|delete\s+from|alter\s+table|create\s+(?:virtual\s+)?table)\s',
    caseSensitive: false,
  );

  /// 错误信息里附 SQL 片段（截断，避免把整段 SQL 灌进异常）。
  static String _sqlFragment(String sql, {int max = 160}) {
    final clean = sql.replaceAll(RegExp(r'\s+'), ' ').trim();
    return clean.length > max ? '${clean.substring(0, max)}…' : clean;
  }

  /// 在 [database]（学科库）作用域内执行 [body]；期间 [rows]/[one]/[scalar]/
  /// [insert]/[run] 自动路由。传入全局库时等价于直接调用。
  ///
  /// [dbPath] 会做 `data/subjects/` 前缀断言（F-16）；进入/退出作用域时还会
  /// 通知 [scopeObserver]（SubjectStore 用它做句柄 in-use 计数，F-1）。
  static Future<T> runScoped<T>(
    Database database,
    Future<T> Function() body, {
    String subjectKey = '',
    String filesDir = '',
    String dbPath = '',
  }) {
    if (identical(database, db)) {
      // 全局库不是学科作用域：若调用方显式传了 dbPath，仍要做前缀断言。
      if (dbPath.isNotEmpty) assertSubjectScopePath(dbPath);
      return body();
    }
    final path = dbPath.isNotEmpty
        ? dbPath
        : (scopePathResolver?.call(database) ?? '');
    assertSubjectScopePath(path);
    final scope = SubjectScope(
      database: database,
      key: subjectKey,
      filesDir: filesDir,
      dbPath: path,
    );
    final observer = scopeObserver;
    return runZoned(() async {
      observer?.call(database, true);
      try {
        return await body();
      } finally {
        observer?.call(database, false);
      }
    }, zoneValues: {_scopeKey: scope});
  }

  /// 同步版作用域（供测试/短事务使用）。
  static T runScopedSync<T>(
    Database database,
    T Function() body, {
    String subjectKey = '',
    String filesDir = '',
    String dbPath = '',
  }) {
    if (identical(database, db)) {
      if (dbPath.isNotEmpty) assertSubjectScopePath(dbPath);
      return body();
    }
    final path = dbPath.isNotEmpty
        ? dbPath
        : (scopePathResolver?.call(database) ?? '');
    assertSubjectScopePath(path);
    final scope = SubjectScope(
      database: database,
      key: subjectKey,
      filesDir: filesDir,
      dbPath: path,
    );
    final observer = scopeObserver;
    return runZoned(() {
      observer?.call(database, true);
      try {
        return body();
      } finally {
        observer?.call(database, false);
      }
    }, zoneValues: {_scopeKey: scope});
  }

  // ---------------------------------------------------------------- 查询

  static List<Map<String, Object?>> rows(
    String sql, [
    List<Object?> params = const [],
  ]) {
    return _target(sql)
        .select(sql, params)
        .map((row) => Map<String, Object?>.from(row))
        .toList();
  }

  static Map<String, Object?>? one(
    String sql, [
    List<Object?> params = const [],
  ]) {
    final result = _target(sql).select(sql, params);
    if (result.isEmpty) return null;
    return Map<String, Object?>.from(result.first);
  }

  static Object? scalar(String sql, [List<Object?> params = const []]) {
    final result = _target(sql).select(sql, params);
    if (result.isEmpty) return null;
    return result.first.values.first;
  }

  static int insert(String table, Map<String, Object?> values) {
    final keys = values.keys.toList();
    final sql =
        'INSERT INTO $table (${keys.join(',')}) VALUES (${List.filled(keys.length, '?').join(',')})';
    final target = _target(sql);
    final stmt = target.prepare(sql);
    try {
      stmt.execute(keys.map((k) => values[k]).toList());
      return target.lastInsertRowId;
    } finally {
      stmt.close();
    }
  }

  static void run(String sql, [List<Object?> params = const []]) {
    _target(sql).execute(sql, params);
  }

  // ------------------------------------------------- 始终落在全局库的便捷方法

  static List<Map<String, Object?>> globalRows(
    String sql, [
    List<Object?> params = const [],
  ]) => db
      .select(sql, params)
      .map((row) => Map<String, Object?>.from(row))
      .toList();

  static Map<String, Object?>? globalOne(
    String sql, [
    List<Object?> params = const [],
  ]) {
    final result = db.select(sql, params);
    if (result.isEmpty) return null;
    return Map<String, Object?>.from(result.first);
  }

  static void globalRun(String sql, [List<Object?> params = const []]) =>
      db.execute(sql, params);

  static bool tableExists(String name) => tableExistsIn(db, name);

  static bool tableExistsIn(Database database, String name) {
    final row = database.select(
      "SELECT name FROM sqlite_master WHERE type IN ('table','view') AND name=?",
      [name],
    );
    return row.isNotEmpty;
  }

  static int rowCountIn(Database database, String table) {
    if (!tableExistsIn(database, table)) return 0;
    final value = database.select('SELECT COUNT(*) AS c FROM $table');
    if (value.isEmpty) return 0;
    return (value.first['c'] as num?)?.toInt() ?? 0;
  }

  static int tableRowCount(String table) => rowCountIn(db, table);

  // ---------------------------------------------------------------- 设置

  static String setting(String key, [String fallback = '']) {
    final value = globalOne('SELECT value FROM settings WHERE key=?', [
      key,
    ])?['value'];
    if (value == null) return fallback;
    final text = value.toString();
    return text.isEmpty ? fallback : text;
  }

  static void setSetting(String key, String value) {
    db.execute(
      'INSERT INTO settings(key, value) VALUES(?, ?) '
      'ON CONFLICT(key) DO UPDATE SET value=excluded.value',
      [key, value],
    );
  }

  static String nowIso() {
    final now = DateTime.now();
    final offset = now.timeZoneOffset;
    final sign = offset.isNegative ? '-' : '+';
    String two(int v) => v.toString().padLeft(2, '0');
    final hours = two(offset.inHours.abs());
    final minutes = two(offset.inMinutes.abs() % 60);
    return '${now.year}-${two(now.month)}-${two(now.day)}T'
        '${two(now.hour)}:${two(now.minute)}:${two(now.second)}$sign$hours:$minutes';
  }

  static String today() {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${now.year}-${two(now.month)}-${two(now.day)}';
  }

  static String encode(Object? value) => jsonEncode(value);

  static List<Map<String, Object?>> parseList(Object? raw) {
    if (raw == null) return [];
    try {
      final data = jsonDecode(raw.toString());
      if (data is List) {
        return data
            .whereType<Map>()
            .map((e) => Map<String, Object?>.from(e))
            .toList();
      }
    } catch (_) {}
    return [];
  }
}
