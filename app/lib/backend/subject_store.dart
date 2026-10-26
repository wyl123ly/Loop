/// 学科数据层（对应 docs/subject-feature-spec.md §2.5 的 `subject_registry.dart`
/// + `subject_db.dart`，合并为一个可独立测试的文件）：
///
/// - [SubjectRecord]：注册表行（全局库 `subjects`，§3.1）
/// - [SubjectDb]：单个学科库句柄 `data/subjects/<key>/loop.db`（§4.3）
/// - [SubjectStore]：注册表 CRUD、默认学科、active、按 key 打开（LRU ≤ 4）、
///   句柄关闭、完整性标记、路径安全（§3.4）
///
/// 旧数据迁移在 `subject_migration.dart`（v0.7.1 → v0.8.0，§5）。
library;

import 'dart:collection';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'db.dart';
import 'paths.dart';

/// 学科库 schema 版本（权威常量，§4.6）。
const int kSubjectSchemaVersion = 2;

/// 应用级迁移 id（幂等标记）。
const String kAppSubjectMigrationId = 'v0.8.0-subjects';

/// 默认学科（承接全部旧数据，不可归档/删除）。
const String kDefaultSubjectKey = 'default';
const String kDefaultSubjectName = '通用';

/// 默认同时打开的学科库句柄上限（§4.4）。
const int kSubjectMaxOpenHandles = 4;

const Set<String> kSubjectStatusValues = {'active', 'archived'};
const Set<String> kSubjectLevelValues = {'', 'new', 'beginner', 'intermediate', 'advanced'};

/// 学科层错误：`status` 直接映射 HTTP 状态码（400/404/409/503，§11.7）。
class SubjectError implements Exception {
  SubjectError(this.status, this.message);

  final int status;
  final String message;

  @override
  String toString() => message;
}

/// 注册表行（全局库 `subjects`）。
class SubjectRecord {
  SubjectRecord({
    required this.id,
    required this.key,
    required this.name,
    this.description = '',
    this.icon = '',
    this.color = '',
    this.goal = '',
    this.examDate = '',
    this.dailyMinutes = 0,
    this.level = '',
    this.status = 'active',
    this.isDefault = false,
    this.sortOrder = 0,
    required this.dbRelPath,
    required this.filesRelPath,
    required this.skillsRelPath,
    this.schemaVersion = kSubjectSchemaVersion,
    this.integrity = 'ok',
    required this.createdAt,
    required this.updatedAt,
    this.lastOpenedAt = '',
    this.archivedAt = '',
  });

  final int id;
  final String key;
  final String name;
  final String description;
  final String icon;
  final String color;
  final String goal;
  final String examDate;
  final int dailyMinutes;
  final String level;
  final String status;
  final bool isDefault;
  final int sortOrder;
  final String dbRelPath;
  final String filesRelPath;
  final String skillsRelPath;
  final int schemaVersion;
  final String integrity;
  final String createdAt;
  final String updatedAt;
  final String lastOpenedAt;
  final String archivedAt;

  bool get archived => status == 'archived';

  /// 学科库绝对路径（注册表字段与数据目录推导双保险校验）。
  String get dbPath {
    final fromRegistry = AppPaths.resolveFromData(dbRelPath);
    final canonical = AppPaths.subjectDbPath(key);
    return p.normalize(fromRegistry) == p.normalize(canonical) ? canonical : fromRegistry;
  }

  String get dirPath => AppPaths.subjectDir(key).path;
  String get filesPath => AppPaths.subjectFilesDir(key).path;
  String get skillsPath => AppPaths.subjectSkillsDir(key).path;

  static SubjectRecord fromRow(Map<String, Object?> row) => SubjectRecord(
        id: (row['id'] as num).toInt(),
        key: (row['key'] ?? '').toString(),
        name: (row['name'] ?? '').toString(),
        description: (row['description'] ?? '').toString(),
        icon: (row['icon'] ?? '').toString(),
        color: (row['color'] ?? '').toString(),
        goal: (row['goal'] ?? '').toString(),
        examDate: (row['exam_date'] ?? '').toString(),
        dailyMinutes: (row['daily_minutes'] as num?)?.toInt() ?? 0,
        level: (row['level'] ?? '').toString(),
        status: (row['status'] ?? 'active').toString(),
        isDefault: ((row['is_default'] as num?)?.toInt() ?? 0) == 1,
        sortOrder: (row['sort_order'] as num?)?.toInt() ?? 0,
        dbRelPath: (row['db_rel_path'] ?? '').toString(),
        filesRelPath: (row['files_rel_path'] ?? '').toString(),
        skillsRelPath: (row['skills_rel_path'] ?? '').toString(),
        schemaVersion: (row['schema_version'] as num?)?.toInt() ?? kSubjectSchemaVersion,
        integrity: (row['integrity'] ?? 'ok').toString(),
        createdAt: (row['created_at'] ?? '').toString(),
        updatedAt: (row['updated_at'] ?? '').toString(),
        lastOpenedAt: (row['last_opened_at'] ?? '').toString(),
        archivedAt: (row['archived_at'] ?? '').toString(),
      );

  /// API 形状（§11.2）；`counts` 由调用方按需计算（P1）。
  Map<String, Object?> toJson({Map<String, Object?>? counts}) => {
        'id': id,
        'key': key,
        'name': name,
        'description': description,
        'icon': icon,
        'color': color,
        'goal': goal,
        'exam_date': examDate,
        'daily_minutes': dailyMinutes,
        'level': level,
        'status': status,
        'is_default': isDefault ? 1 : 0,
        'sort_order': sortOrder,
        'integrity': integrity,
        'schema_version': schemaVersion,
        'last_opened_at': lastOpenedAt,
        'created_at': createdAt,
        'updated_at': updatedAt,
        'archived_at': archivedAt,
        'db_rel_path': dbRelPath,
        'counts': ?counts,
      };

  @override
  String toString() => 'SubjectRecord($id/$key/$name/$status)';
}

/// 单个学科库句柄。API 形状对齐 [Db]（rows/one/scalar/insert/run），
/// 便于从全局库平滑迁移到学科库。
class SubjectDb {
  SubjectDb({required this.key, required this.database, required this.path});

  final String key;
  final Database database;
  final String path;
  bool _closed = false;
  int _inUse = 0;
  bool _evicted = false;

  bool get closed => _closed;

  List<Map<String, Object?>> rows(String sql, [List<Object?> params = const []]) =>
      database.select(sql, params).map((row) => Map<String, Object?>.from(row)).toList();

  Map<String, Object?>? one(String sql, [List<Object?> params = const []]) {
    final result = database.select(sql, params);
    if (result.isEmpty) return null;
    return Map<String, Object?>.from(result.first);
  }

  Object? scalar(String sql, [List<Object?> params = const []]) {
    final result = database.select(sql, params);
    if (result.isEmpty) return null;
    return result.first.values.first;
  }

  int insert(String table, Map<String, Object?> values) {
    final keys = values.keys.toList();
    final sql =
        'INSERT INTO $table (${keys.join(',')}) VALUES (${List.filled(keys.length, '?').join(',')})';
    final stmt = database.prepare(sql);
    try {
      stmt.execute(keys.map((k) => values[k]).toList());
      return database.lastInsertRowId;
    } finally {
      stmt.close();
    }
  }

  void run(String sql, [List<Object?> params = const []]) => database.execute(sql, params);

  int count(String table) => Db.rowCountIn(database, table);

  /// 多语句原子性（§4.4）：`BEGIN IMMEDIATE … COMMIT`，失败 `ROLLBACK`。
  T transaction<T>(T Function() body) {
    database.execute('BEGIN IMMEDIATE');
    try {
      final result = body();
      database.execute('COMMIT');
      return result;
    } catch (_) {
      try {
        database.execute('ROLLBACK');
      } catch (_) {}
      rethrow;
    }
  }

  void checkpoint() {
    try {
      database.execute('PRAGMA wal_checkpoint(TRUNCATE)');
    } catch (_) {}
  }

  void close() => closeHandle(force: true);

  /// 关闭句柄。[force] 为 false 时若仍有作用域在使用该句柄，则**延迟关闭**
  /// （标记 `evicted`，等最后一个使用者 release 后再真正 close），避免
  /// "LRU 淘汰把在用句柄关掉"导致的 `This database has already been closed`。
  void closeHandle({bool force = true}) {
    if (_closed) return;
    if (!force && _inUse > 0) {
      _evicted = true;
      return;
    }
    _closed = true;
    try {
      database.close();
    } catch (_) {}
  }

  /// 进入一个学科作用域（[Db.runScoped] 自动调用）。
  void acquire() {
    if (_closed) return;
    _inUse++;
  }

  /// 退出学科作用域；若期间已被淘汰则在此真正关闭。
  void release() {
    if (_inUse > 0) _inUse--;
    if (_inUse == 0 && _evicted) closeHandle(force: true);
  }

  /// 当前作用域持有者数量（F-1：LRU 淘汰要跳过 > 0 的句柄）。
  int get inUse => _inUse;

  /// 是否已被淘汰（等待使用者退出后关闭）。
  bool get evicted => _evicted;

  /// 是否可被 LRU 安全关闭。
  bool get closable => !_closed && _inUse == 0;

  /// 在 [Db.runScoped] 中使用的作用域句柄。
  Database get scope => database;
}

/// 学科注册表 + 句柄缓存。
class SubjectStore {
  static final LinkedHashMap<String, SubjectDb> _handles = LinkedHashMap<String, SubjectDb>();
  static bool _ready = false;
  static int _totalOpened = 0;

  static bool get ready => _ready;

  /// 当前打开的学科库数量（测试断言 ≤ [kSubjectMaxOpenHandles]）。
  static int get openHandles => _handles.length;

  /// 累计打开次数（诊断用，句柄泄漏观察）。
  static int get totalOpened => _totalOpened;

  static List<String> get openKeys => _handles.keys.toList();

  /// 启动/首次使用前初始化：确保注册表与默认学科存在。**不打开任何学科库**
  /// （启动时不打开学科库，§4.4）。
  static void init() {
    if (_ready) return;
    // 先置位：init 内部会调用 byKey/resolve（它们也会调 init），否则递归。
    _ready = true;
    try {
      _installScopeObserver();
      Db.scopePathResolver = (database) => _handleForDatabase(database)?.path ?? '';
      if (!AppPaths.ready) AppPaths.init();
      if (!Db.ready) Db.init();
      ensureDefaultSubject();
      applyLaunchSubject();
      normalizeActiveSubject();
    } catch (_) {
      _ready = false;
      rethrow;
    }
  }

  /// F-15：`LOOP_SUBJECT` 启动作用域。
  ///
  /// 启动时若设置了该环境变量（key 或 id），且能解析到**未归档**的学科，就把它
  /// 设为当前学科；非法/不存在/已归档则忽略并保持默认学科（绝不因此启动失败）。
  /// 运行时切换（UI）仍照常覆盖 `active_subject`。
  static bool applyLaunchSubject({String? ref}) {
    final requested = (ref ?? launchSubjectRef).trim();
    if (requested.isEmpty) return false;
    final record = resolve(requested);
    if (record == null || record.archived) {
      stderr.writeln('LOOP_SUBJECT 指向的学科不可用，忽略：$requested');
      return false;
    }
    Db.setSetting('active_subject', record.key);
    return true;
  }

  /// 启动学科来源：生产读环境变量 `LOOP_SUBJECT`，测试可注入。
  static String? launchSubjectOverrideForTests;

  static String get launchSubjectRef =>
      launchSubjectOverrideForTests ?? (Platform.environment['LOOP_SUBJECT'] ?? '');

  /// 测试专用：真实临时目录 + 真实 SQLite（迁移类测试必须用真实文件，§15.1）。
  /// 可重复调用以模拟"重启"：句柄全部关闭，库文件保留。
  static void initTempForTests(Directory dir) {
    closeAll();
    _ready = false;
    AppPaths.initAt(dir);
    Db.resetForTests();
    Db.init();
    init();
  }

  /// 仅重开句柄（不清空数据目录）：模拟"第二次启动"，用于回归测试。
  static void reopenForTests() {
    closeAll();
    _ready = false;
    Db.resetForTests();
    Db.init();
    init();
  }

  static void resetForTests() {
    closeAll();
    _ready = false;
  }

  // ------------------------------------------------------------ 默认学科

  /// 默认学科必须恰好存在一个（§3.3）。缺失时：
  /// - 磁盘上 `subjects/default/loop.db` 已存在 → **收编**（只补注册行，绝不清空重建）
  /// - 不存在 → 建目录 + 建空库 + 注册行
  static SubjectRecord ensureDefaultSubject() {
    final existingRow = _rowByKey(kDefaultSubjectKey);
    if (existingRow != null) {
      final existing = SubjectRecord.fromRow(existingRow);
      if (!existing.isDefault) {
        Db.globalRun('UPDATE subjects SET is_default=1 WHERE id=?', [existing.id]);
        return byId(existing.id)!;
      }
      return existing;
    }
    final dbFile = File(AppPaths.subjectDbPath(kDefaultSubjectKey));
    if (!dbFile.existsSync()) {
      createSubjectDatabaseFiles(kDefaultSubjectKey);
    } else {
      // 收编已有库：补目录 + 补齐 schema（幂等）。
      AppPaths.subjectFilesDir(kDefaultSubjectKey).createSync(recursive: true);
      AppPaths.subjectSkillsDir(kDefaultSubjectKey).createSync(recursive: true);
      final database = sqlite3.open(AppPaths.subjectDbPath(kDefaultSubjectKey));
      try {
        createSubjectSchema(database);
      } finally {
        database.close();
      }
    }
    return _insertRecord(
      key: kDefaultSubjectKey,
      name: kDefaultSubjectName,
      isDefault: true,
      sortOrder: 0,
    );
  }

  /// 默认学科的注册行（不存在则创建）。
  static SubjectRecord get defaultSubject => ensureDefaultSubject();

  // ------------------------------------------------------------ 注册表查询

  static Map<String, Object?>? _rowByKey(String key) =>
      Db.globalOne('SELECT * FROM subjects WHERE key=?', [key]);

  static Map<String, Object?>? _rowById(int id) =>
      Db.globalOne('SELECT * FROM subjects WHERE id=?', [id]);

  /// 列表：默认学科优先，其后按 sort_order、最近打开时间。
  static List<SubjectRecord> list({bool includeArchived = false}) {
    init();
    final rows = includeArchived
        ? Db.globalRows(
            'SELECT * FROM subjects ORDER BY is_default DESC, sort_order ASC, '
            "CASE WHEN last_opened_at='' THEN 1 ELSE 0 END ASC, last_opened_at DESC, id ASC",
          )
        : Db.globalRows(
            'SELECT * FROM subjects WHERE status=? ORDER BY is_default DESC, sort_order ASC, '
            "CASE WHEN last_opened_at='' THEN 1 ELSE 0 END ASC, last_opened_at DESC, id ASC",
            ['active'],
          );
    return [for (final row in rows) _repairIntegrity(SubjectRecord.fromRow(row))];
  }

  static List<SubjectRecord> listArchived() {
    init();
    final rows = Db.globalRows('SELECT * FROM subjects WHERE status=? ORDER BY archived_at DESC', [
      'archived',
    ]);
    return [for (final row in rows) _repairIntegrity(SubjectRecord.fromRow(row))];
  }

  static SubjectRecord? byKey(String key) {
    init();
    final row = _rowByKey(key);
    return row == null ? null : _repairIntegrity(SubjectRecord.fromRow(row));
  }

  static SubjectRecord? byId(int id) {
    init();
    final row = _rowById(id);
    return row == null ? null : _repairIntegrity(SubjectRecord.fromRow(row));
  }

  /// 把 key 或 id（字符串/数字）解析成注册表行；找不到返回 null。
  static SubjectRecord? resolve(Object? ref) {
    init();
    if (ref == null) return null;
    if (ref is num) return byId(ref.toInt());
    final text = ref.toString().trim();
    if (text.isEmpty) return null;
    final asId = int.tryParse(text);
    if (asId != null) {
      final byIdRow = byId(asId);
      if (byIdRow != null) return byIdRow;
    }
    return byKey(text);
  }

  /// 解析失败抛 404（**不回退到他科**，§11.1）。
  static SubjectRecord require(Object? ref) {
    final record = resolve(ref);
    if (record == null) {
      throw SubjectError(404, '学科不存在：$ref');
    }
    return record;
  }

  // ------------------------------------------------------------ 生命周期

  static String normalizeName(String raw) {
    final name = raw.replaceAll(RegExp(r'[\r\n\t]+'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    if (name.isEmpty) throw SubjectError(400, '学科名不能为空');
    if (name.length > 40) throw SubjectError(400, '学科名过长（≤ 40 字符）');
    for (final rune in name.runes) {
      if (rune < 0x20) throw SubjectError(400, '学科名包含控制字符');
    }
    return name;
  }

  static void _assertNameFree(String name, {int? exceptId}) {
    final row = Db.globalOne('SELECT id FROM subjects WHERE name = ? COLLATE NOCASE', [name]);
    if (row == null) return;
    if (exceptId != null && (row['id'] as num).toInt() == exceptId) return;
    throw SubjectError(409, '已存在同名学科：$name');
  }

  static String _generateKey() {
    for (var attempt = 0; attempt < 5; attempt++) {
      final base = 's_${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}';
      final key = attempt == 0
          ? base
          : '$base${(DateTime.now().microsecond % 1296).toRadixString(36).padLeft(2, '0')}';
      if (!AppPaths.isValidSubjectKey(key)) continue;
      if (_rowByKey(key) != null) continue;
      if (Directory(AppPaths.subjectDir(key).path).existsSync()) continue;
      return key;
    }
    throw SubjectError(500, '无法生成学科 key');
  }

  static SubjectRecord create({
    required String name,
    String description = '',
    String icon = '',
    String color = '',
    String goal = '',
    String examDate = '',
    int dailyMinutes = 0,
    String level = '',
    int? sortOrder,
  }) {
    init();
    final clean = normalizeName(name);
    _assertNameFree(clean);
    if (description.length > 200) throw SubjectError(400, '简介过长（≤ 200 字符）');
    if (goal.length > 200) throw SubjectError(400, '目标过长（≤ 200 字符）');
    if (!kSubjectLevelValues.contains(level)) throw SubjectError(400, '未知水平：$level');
    if (dailyMinutes < 0 || dailyMinutes > 720) throw SubjectError(400, '每日时长需在 0–720 分钟');

    final key = _generateKey();
    final dir = AppPaths.subjectDir(key);
    try {
      createSubjectDatabaseFiles(key);
    } catch (error) {
      _removeDirQuietly(dir);
      throw SubjectError(500, '创建学科库失败：$error');
    }
    try {
      return _insertRecord(
        key: key,
        name: clean,
        description: description,
        icon: icon,
        color: color,
        goal: goal,
        examDate: examDate,
        dailyMinutes: dailyMinutes,
        level: level,
        isDefault: false,
        sortOrder: sortOrder ?? _nextSortOrder(),
      );
    } catch (error) {
      // 不留"注册表有记录但库残缺"或"有目录无记录"的学科（§4.3）。
      _removeDirQuietly(dir);
      rethrow;
    }
  }

  static int _nextSortOrder() {
    final row = Db.globalOne('SELECT MAX(sort_order) AS m FROM subjects');
    return ((row?['m'] as num?)?.toInt() ?? 0) + 1;
  }

  static SubjectRecord _insertRecord({
    required String key,
    required String name,
    String description = '',
    String icon = '',
    String color = '',
    String goal = '',
    String examDate = '',
    int dailyMinutes = 0,
    String level = '',
    required bool isDefault,
    int sortOrder = 0,
  }) {
    final now = Db.nowIso();
    Db.globalRun(
      'INSERT INTO subjects(key,name,description,icon,color,goal,exam_date,daily_minutes,level,'
      'status,is_default,sort_order,db_rel_path,files_rel_path,skills_rel_path,schema_version,'
      'integrity,created_at,updated_at,last_opened_at,archived_at) '
      'VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
      [
        key,
        name,
        description,
        icon,
        color,
        goal,
        examDate,
        dailyMinutes,
        level,
        'active',
        isDefault ? 1 : 0,
        sortOrder,
        AppPaths.relativeToData(AppPaths.subjectDbPath(key)),
        AppPaths.relativeToData(AppPaths.subjectFilesDir(key).path),
        AppPaths.relativeToData(AppPaths.subjectSkillsDir(key).path),
        kSubjectSchemaVersion,
        'ok',
        now,
        now,
        '',
        '',
      ],
    );
    return byKey(key)!;
  }

  /// 允许更新的字段（不改 key、不搬目录，§3.2）。
  static const Set<String> patchableFields = {
    'name',
    'description',
    'icon',
    'color',
    'goal',
    'exam_date',
    'daily_minutes',
    'level',
    'sort_order',
  };

  static SubjectRecord patch(int id, Map<String, Object?> fields) {
    init();
    final record = byId(id);
    if (record == null) throw SubjectError(404, '学科不存在：$id');
    final updates = <String, Object?>{};
    for (final entry in fields.entries) {
      if (!patchableFields.contains(entry.key)) continue;
      final value = entry.value;
      if (value == null) continue;
      switch (entry.key) {
        case 'name':
          final name = normalizeName(value.toString());
          _assertNameFree(name, exceptId: id);
          updates['name'] = name;
          break;
        case 'description':
          final text = value.toString().trim();
          if (text.length > 200) throw SubjectError(400, '简介过长（≤ 200 字符）');
          updates['description'] = text;
          break;
        case 'goal':
          final text = value.toString().trim();
          if (text.length > 200) throw SubjectError(400, '目标过长（≤ 200 字符）');
          updates['goal'] = text;
          break;
        case 'exam_date':
          final text = value.toString().trim();
          if (text.isNotEmpty && !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(text)) {
            throw SubjectError(400, '考试日期需为 YYYY-MM-DD');
          }
          updates['exam_date'] = text;
          break;
        case 'daily_minutes':
          final minutes = int.tryParse(value.toString());
          if (minutes == null || minutes < 0 || minutes > 720) {
            throw SubjectError(400, '每日时长需在 0–720 分钟');
          }
          updates['daily_minutes'] = minutes;
          break;
        case 'level':
          final level = value.toString();
          if (!kSubjectLevelValues.contains(level)) throw SubjectError(400, '未知水平：$level');
          updates['level'] = level;
          break;
        case 'sort_order':
          final order = int.tryParse(value.toString());
          if (order == null) throw SubjectError(400, 'sort_order 必须是整数');
          updates['sort_order'] = order;
          break;
        default:
          updates[entry.key] = value.toString();
      }
    }
    if (updates.isEmpty) return record;
    updates['updated_at'] = Db.nowIso();
    final sets = updates.keys.map((key) => '$key=?').join(',');
    Db.globalRun('UPDATE subjects SET $sets WHERE id=?', [...updates.values, id]);
    return byId(id)!;
  }

  static SubjectRecord archive(int id) {
    init();
    final record = byId(id);
    if (record == null) throw SubjectError(404, '学科不存在：$id');
    if (record.isDefault) throw SubjectError(409, '默认学科不可归档');
    if (record.archived) return record;
    final now = Db.nowIso();
    Db.globalRun('UPDATE subjects SET status=?, archived_at=?, updated_at=? WHERE id=?', [
      'archived',
      now,
      now,
      id,
    ]);
    close(record.key);
    if (activeKey() == record.key) setActive(kDefaultSubjectKey);
    return byId(id)!;
  }

  static SubjectRecord restore(int id) {
    init();
    final record = byId(id);
    if (record == null) throw SubjectError(404, '学科不存在：$id');
    if (!record.archived) return record;
    Db.globalRun(
      "UPDATE subjects SET status='active', archived_at='', updated_at=? WHERE id=?",
      [Db.nowIso(), id],
    );
    return byId(id)!;
  }

  /// 删除：仅允许已归档，且 `confirm` 必须等于 key（§3.5）。
  /// 目录整体移动到 `data/trash/<key>-<ts>/`（可手工找回）。
  static Map<String, Object?> delete(int id, String confirm) {
    init();
    final record = byId(id);
    if (record == null) throw SubjectError(404, '学科不存在：$id');
    if (record.isDefault) throw SubjectError(409, '默认学科不可删除');
    if (!record.archived) throw SubjectError(409, '请先归档再删除');
    if (confirm != record.key) throw SubjectError(400, 'confirm 必须等于学科 key');

    close(record.key);
    final dir = Directory(record.dirPath);
    var trashedTo = '';
    if (dir.existsSync()) {
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final target = Directory(p.join(AppPaths.trashDir.path, '${record.key}-$stamp'));
      target.createSync(recursive: true);
      trashedTo = target.path;
      _moveDirectory(dir, target);
    }
    Db.globalRun('DELETE FROM subjects WHERE id=?', [id]);
    if (activeKey() == record.key) setActive(kDefaultSubjectKey);
    return {'ok': true, 'trashed_to': trashedTo, 'key': record.key};
  }

  static void _moveDirectory(Directory from, Directory to) {
    Object? lastError;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        for (final entity in from.listSync()) {
          final name = p.basename(entity.path);
          entity.renameSync(p.join(to.path, name));
        }
        from.deleteSync(recursive: true);
        return;
      } catch (error) {
        lastError = error;
        sleep(const Duration(milliseconds: 200));
      }
    }
    throw SubjectError(500, '移动学科目录失败（可能被占用）：$lastError');
  }

  static void _removeDirQuietly(Directory dir) {
    try {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    } catch (_) {}
  }

  // ------------------------------------------------------------ active

  static String activeKey() {
    final value = Db.setting('active_subject', kDefaultSubjectKey);
    return value.trim().isEmpty ? kDefaultSubjectKey : value.trim();
  }

  static SubjectRecord activeSubject() {
    init();
    final record = resolve(activeKey());
    if (record != null && !record.archived) return record;
    return defaultSubject;
  }

  static SubjectRecord setActive(String ref) {
    init();
    final record = require(ref);
    if (record.archived) throw SubjectError(409, '已归档学科不能设为当前学科');
    Db.setSetting('active_subject', record.key);
    final now = Db.nowIso();
    Db.globalRun('UPDATE subjects SET last_opened_at=?, updated_at=? WHERE id=?', [
      now,
      now,
      record.id,
    ]);
    return byId(record.id)!;
  }

  /// 启动时纠正非法 `active_subject`（不存在/已归档 → default，§3.3）。
  static void normalizeActiveSubject() {
    final record = resolve(activeKey());
    if (record == null || record.archived) {
      Db.setSetting('active_subject', kDefaultSubjectKey);
    }
  }

  // ------------------------------------------------------------ 句柄与库

  /// 解析 key → 已打开的学科库（LRU，上限 [kSubjectMaxOpenHandles]）。
  ///
  /// F-1：淘汰**只跳过使用中（in-use）的句柄**——被淘汰但有使用者的句柄会
  /// 标记 `evicted`，等最后一个使用者退出后自动关闭；因此并发 run / 长流式
  /// 请求期间绝不会出现 `This database has already been closed`。
  static SubjectDb open(String key) {
    init();
    final existing = _handles.remove(key);
    if (existing != null && !existing.closed) {
      _handles[key] = existing; // 标记为最近使用
      return existing;
    }
    final record = byKey(key);
    if (record == null) throw SubjectError(404, '学科不存在：$key');
    final file = File(record.dbPath);
    if (!file.existsSync()) {
      _markIntegrity(key, 'missing');
      throw SubjectError(503, '学科库文件不存在：${record.dbPath}');
    }
    final Database database;
    try {
      database = sqlite3.open(record.dbPath);
    } catch (error) {
      _markIntegrity(key, 'error');
      throw SubjectError(503, '学科库打不开：$error');
    }
    database.execute('PRAGMA journal_mode=WAL');
    database.execute('PRAGMA foreign_keys=ON');
    database.execute('PRAGMA busy_timeout=3000');
    final version = ensureSubjectSchema(database, key);
    if (version > kSubjectSchemaVersion) {
      database.close();
      _markIntegrity(key, 'error');
      throw SubjectError(503, '该学科数据由更新版本创建（schema $version > $kSubjectSchemaVersion）');
    }
    final handle = SubjectDb(key: key, database: database, path: record.dbPath);
    _handles[key] = handle;
    _totalOpened++;
    _evictIdle(protect: key);
    _markIntegrity(key, 'ok');
    return handle;
  }

  /// LRU：从最久未用的一端淘汰，跳过 in-use 句柄。若全部在用则暂时超出上限
  /// （上限是缓存目标，不是硬上限；宁可多开连接也不关闭在用句柄）。
  static void _evictIdle({String protect = ''}) {
    if (_handles.length <= kSubjectMaxOpenHandles) return;
    for (final key in _handles.keys.toList()) {
      if (_handles.length <= kSubjectMaxOpenHandles) break;
      if (key == protect) continue;
      final handle = _handles[key]!;
      if (!handle.closable) {
        handle.closeHandle(force: false); // 打标记，等 release 后关闭
        continue;
      }
      _handles.remove(key);
      handle.close();
    }
  }

  /// 按 key/id 打开（缺省 → 当前学科）。
  static SubjectDb db([Object? ref]) {
    init();
    final record = ref == null ? activeSubject() : require(ref);
    return open(record.key);
  }

  static SubjectDb? handle(String key) {
    final handle = _handles[key];
    return (handle != null && !handle.closed) ? handle : null;
  }

  /// 关闭某学科句柄；正在被作用域使用时延迟关闭（F-1）。
  static void close(String key) {
    final handle = _handles.remove(key);
    handle?.closeHandle(force: false);
  }

  /// 强制关闭全部句柄（迁移/删除学科/测试收尾用）。
  static void closeAll() {
    for (final handle in _handles.values) {
      handle.closeHandle(force: true);
    }
    _handles.clear();
  }

  /// 使用中的句柄数（诊断/断言）。
  static int get inUseHandles => _handles.values.where((h) => h.inUse > 0).length;

  /// 以 [database] 身份找到句柄（供 [Db.scopeObserver] 计数）。
  static SubjectDb? _handleForDatabase(Database database, {bool includeClosed = false}) {
    for (final handle in _handles.values) {
      if (identical(handle.database, database)) {
        if (handle.closed && !includeClosed) return null;
        return handle;
      }
    }
    return null;
  }

  /// 把 in-use 计数挂到 [Db.runScoped]（幂等）。
  static void _installScopeObserver() {
    Db.scopeObserver = (database, entering) {
      final handle = _handleForDatabase(database, includeClosed: true);
      if (handle == null) return;
      if (entering) {
        handle.acquire();
      } else {
        handle.release();
      }
    };
  }

  static void _markIntegrity(String key, String integrity) {
    final row = _rowByKey(key);
    if (row == null) return;
    final current = (row['integrity'] ?? 'ok').toString();
    if (current == integrity) return;
    Db.globalRun('UPDATE subjects SET integrity=? WHERE key=?', [integrity, key]);
  }

  /// 轻量完整性校验：库文件缺失 → `missing`（**绝不自动重建**，§4.8）。
  static SubjectRecord _repairIntegrity(SubjectRecord record) {
    final exists = File(record.dbPath).existsSync();
    final expected = exists ? (record.integrity == 'missing' ? 'ok' : record.integrity) : 'missing';
    if (expected == record.integrity) return record;
    Db.globalRun('UPDATE subjects SET integrity=? WHERE key=?', [expected, record.key]);
    return byKey(record.key)!;
  }

  /// 显式「重建空库」：注册记录保留，库内容重建为空（用户二次确认后调用）。
  static SubjectRecord rebuildEmpty(int id) {
    init();
    final record = byId(id);
    if (record == null) throw SubjectError(404, '学科不存在：$id');
    close(record.key);
    for (final suffix in ['', '-wal', '-shm']) {
      final file = File('${record.dbPath}$suffix');
      if (file.existsSync()) {
        try {
          file.deleteSync();
        } catch (_) {}
      }
    }
    createSubjectDatabaseFiles(record.key);
    Db.globalRun("UPDATE subjects SET integrity='ok', updated_at=? WHERE id=?", [
      Db.nowIso(),
      id,
    ]);
    return byId(id)!;
  }

  /// 「移除注册记录」：只删注册行，不动任何文件（§4.8）。
  static void removeRegistryRow(int id) {
    init();
    final record = byId(id);
    if (record == null) throw SubjectError(404, '学科不存在：$id');
    if (record.isDefault) throw SubjectError(409, '默认学科不可移除');
    close(record.key);
    Db.globalRun('DELETE FROM subjects WHERE id=?', [id]);
  }

  static Map<String, Object?> diagnostics(int id) {
    init();
    final record = byId(id);
    if (record == null) throw SubjectError(404, '学科不存在：$id');
    final dbFile = File(record.dbPath);
    var filesSize = 0;
    final filesDir = Directory(record.filesPath);
    if (filesDir.existsSync()) {
      for (final entity in filesDir.listSync(recursive: true)) {
        if (entity is File) {
          try {
            filesSize += entity.statSync().size;
          } catch (_) {}
        }
      }
    }
    var schemaVersion = 0;
    if (dbFile.existsSync()) {
      try {
        final database = sqlite3.open(record.dbPath, mode: OpenMode.readOnly);
        try {
          schemaVersion = readSchemaVersion(database);
        } finally {
          database.close();
        }
      } catch (_) {
        schemaVersion = -1;
      }
    }
    return {
      'id': record.id,
      'key': record.key,
      'integrity': record.integrity,
      'db_exists': dbFile.existsSync(),
      'db_size': dbFile.existsSync() ? dbFile.statSync().size : 0,
      'files_size': filesSize,
      'schema_version': schemaVersion,
      'lock_present': File('${record.dbPath}-wal').existsSync(),
      'open_handles': openHandles,
      'data_dir': AppPaths.data.path,
      'db_path': record.dbPath,
      'files_dir': record.filesPath,
      'skills_dir': record.skillsPath,
    };
  }

  /// 轻量计数（materials/conversations/topics），供列表接口可选返回（§11.2 P1）。
  static Map<String, Object?> counts(String key) {
    final record = byKey(key);
    if (record == null || !File(record.dbPath).existsSync()) {
      return {'materials': 0, 'conversations': 0, 'topics': 0};
    }
    final handle = open(key);
    return {
      'materials': handle.count('materials'),
      'conversations': handle.count('conversations'),
      'topics': handle.count('topics'),
    };
  }

  // ------------------------------------------------------------ 建库与 schema

  /// 建目录 + 建空学科库（DDL 全量 + `meta.schema_version`）。
  static void createSubjectDatabaseFiles(String key) {
    final dir = AppPaths.subjectDir(key)..createSync(recursive: true);
    AppPaths.subjectFilesDir(key).createSync(recursive: true);
    AppPaths.subjectSkillsDir(key).createSync(recursive: true);
    final Database database;
    try {
      database = sqlite3.open(AppPaths.subjectDbPath(key));
    } catch (error) {
      throw SubjectError(500, '打开学科库失败：$error');
    }
    try {
      database.execute('PRAGMA journal_mode=WAL');
      createSubjectSchema(database);
    } catch (error) {
      database.close();
      _removeDirQuietly(dir);
      throw SubjectError(500, '建学科库失败：$error');
    }
    database.close();
  }

  /// 学科库全量 DDL（§4.3：与 v0.7.1 的 8 张表同构 + v0.8.0 新表）。
  static void createSubjectSchema(Database database) {
    database.execute('''
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
        created_at TEXT NOT NULL,
        plan TEXT DEFAULT '[]'
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
        created_at TEXT NOT NULL,
        folder_id INTEGER DEFAULT 0,
        source_path TEXT DEFAULT '',
        source_mtime INTEGER DEFAULT 0,
        source_size INTEGER DEFAULT 0,
        relative_path TEXT DEFAULT ''
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
      CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
      CREATE TABLE IF NOT EXISTS subject_profile(
        id INTEGER PRIMARY KEY CHECK(id=1),
        goal TEXT DEFAULT '',
        exam_date TEXT DEFAULT '',
        daily_minutes INTEGER DEFAULT 0,
        level TEXT DEFAULT '',
        preferences TEXT DEFAULT '{}',
        updated_at TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS topics(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        aliases TEXT DEFAULT '[]',
        status TEXT NOT NULL DEFAULT 'learning',
        mastery REAL DEFAULT 0,
        confidence REAL DEFAULT 0,
        evidence_count INTEGER DEFAULT 0,
        source_refs TEXT DEFAULT '[]',
        last_studied_at TEXT DEFAULT '',
        next_review_at TEXT DEFAULT '',
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      );
      CREATE UNIQUE INDEX IF NOT EXISTS idx_topics_name ON topics(name COLLATE NOCASE);
      CREATE TABLE IF NOT EXISTS study_events(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        ts TEXT NOT NULL,
        kind TEXT NOT NULL,
        topic TEXT DEFAULT '',
        result TEXT DEFAULT '',
        duration_min INTEGER DEFAULT 0,
        message_id INTEGER DEFAULT 0,
        material_id INTEGER DEFAULT 0,
        note TEXT DEFAULT '',
        created_at TEXT NOT NULL
      );
      CREATE UNIQUE INDEX IF NOT EXISTS idx_events_dedupe
        ON study_events(message_id, kind, topic) WHERE message_id <> 0;
      CREATE INDEX IF NOT EXISTS idx_events_ts ON study_events(ts);
      CREATE TABLE IF NOT EXISTS conversation_summaries(
        conversation_id INTEGER PRIMARY KEY,
        summary TEXT DEFAULT '',
        upto_message_id INTEGER DEFAULT 0,
        updated_at TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS memories(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        kind TEXT DEFAULT 'fact',
        title TEXT NOT NULL,
        body TEXT NOT NULL,
        tags TEXT DEFAULT '',
        importance REAL DEFAULT 0.5,
        source_conversation_id INTEGER DEFAULT 0,
        source_message_id INTEGER DEFAULT 0,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        last_used_at TEXT DEFAULT '',
        use_count INTEGER DEFAULT 0
      );
      CREATE VIRTUAL TABLE IF NOT EXISTS memories_fts USING fts5(memory_id UNINDEXED, tokens);
      CREATE UNIQUE INDEX IF NOT EXISTS idx_memories_title ON memories(title COLLATE NOCASE);
      CREATE INDEX IF NOT EXISTS idx_memories_updated ON memories(updated_at);
      CREATE TABLE IF NOT EXISTS study_sessions(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        started_at TEXT NOT NULL,
        last_at TEXT NOT NULL,
        active_seconds INTEGER DEFAULT 0,
        messages INTEGER DEFAULT 0,
        source TEXT DEFAULT 'chat',
        created_at TEXT NOT NULL
      );
      CREATE INDEX IF NOT EXISTS idx_sessions_last ON study_sessions(last_at);
      CREATE TABLE IF NOT EXISTS progress_daily(
        day TEXT PRIMARY KEY,
        minutes INTEGER DEFAULT 0,
        events INTEGER DEFAULT 0,
        mastered INTEGER DEFAULT 0,
        review_due INTEGER DEFAULT 0,
        updated_at TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS subject_skills(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        slug TEXT NOT NULL,
        version TEXT NOT NULL,
        name TEXT DEFAULT '',
        display_name TEXT DEFAULT '',
        description TEXT DEFAULT '',
        hub TEXT DEFAULT '',
        source_url TEXT DEFAULT '',
        sha256 TEXT DEFAULT '',
        files_rel_path TEXT NOT NULL,
        skill_md TEXT DEFAULT '',
        enabled INTEGER NOT NULL DEFAULT 1,
        pinned INTEGER NOT NULL DEFAULT 0,
        installed_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        UNIQUE(slug, version)
      );
      CREATE INDEX IF NOT EXISTS idx_skills_slug ON subject_skills(slug, enabled);
    ''');
    if (readSchemaVersion(database) == 0) {
      writeSchemaVersion(database, kSubjectSchemaVersion);
    }
  }

  static int readSchemaVersion(Database database) {
    try {
      final rows = database.select("SELECT value FROM meta WHERE key='schema_version'");
      if (rows.isEmpty) return 0;
      return int.tryParse((rows.first['value'] ?? '').toString()) ?? 0;
    } catch (_) {
      return 0;
    }
  }

  static void writeSchemaVersion(Database database, int version) {
    database.execute(
      "INSERT INTO meta(key, value) VALUES('schema_version', ?) "
      'ON CONFLICT(key) DO UPDATE SET value=excluded.value',
      ['$version'],
    );
  }

  /// 打开时的按需迁移（§4.6）：返回迁移后的版本号。
  static int ensureSubjectSchema(Database database, String key) {
    final version = readSchemaVersion(database);
    if (version == 0) {
      createSubjectSchema(database);
      writeSchemaVersion(database, kSubjectSchemaVersion);
      return kSubjectSchemaVersion;
    }
    if (version < kSubjectSchemaVersion) {
      _migrateSubjectSchema(database, version);
      writeSchemaVersion(database, kSubjectSchemaVersion);
      return kSubjectSchemaVersion;
    }
    return version;
  }

  /// 幂等 ALTER 风格迁移（新增列/表一律 IF NOT EXISTS 或 try/catch）。
  static void _migrateSubjectSchema(Database database, int from) {
    if (from < 1) {
      createSubjectSchema(database);
    }
    if (from < 2) {
      // F-12：slug 是身份键（`name` 与之一致），frontmatter 自报的可读名
      // 单独放 display_name，只影响展示与注入文案。
      try {
        database.execute("ALTER TABLE subject_skills ADD COLUMN display_name TEXT DEFAULT ''");
      } catch (_) {}
    }
  }
}