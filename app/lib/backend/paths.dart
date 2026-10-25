import 'dart:io';

import 'package:path/path.dart' as p;

/// 数据目录解析规则（v0.8.0 修订 D9，见 docs/subject-feature-spec.md §5.7）：
///
/// 1. `LOOP_DATA_DIR` 一旦设置且非空 → **唯一数据目录**（不存在则创建），
///    不再比较其它候选。这是隔离验证/CI 的硬要求：把 env 指向一个空目录时
///    绝不能回退命中正式 `data/loop.db`。
/// 2. 未设置时保持 v0.7.1 的探测顺序：exe/data → exe 上级/data → 上两级/data
///    → cwd/data → cwd 上级/data → `%LOCALAPPDATA%/Loop/data`；其中**第一个已存在
///    `loop.db` 的候选**优先，都不存在时用最后一个（LOCALAPPDATA，或 cwd/data）。
///
/// 学科目录（`data/subjects/<key>/`，含 `loop.db`、`files`、`skills`）由
/// [subjectDir] 统一拼接，内部做 key 白名单 + 归属断言，禁止目录穿越。
class AppPaths {
  static late Directory data;
  static late Directory files;
  static late String dbPath;
  static late Directory subjectsDir;
  static late Directory migrationsDir;
  static late Directory trashDir;
  static bool _ready = false;

  /// 默认学科 key（旧数据迁移目标）。
  static const String defaultSubjectKey = 'default';

  static bool get ready => _ready;

  static void init() {
    if (_ready) return;
    final env = Platform.environment;
    // 测试进程（`flutter test` 会设 FLUTTER_TEST=true）里禁止"自动探测"数据目录：
    // 探测会命中真实 `data/loop.db`（cwd 的上级），把隔离验证变成污染正式数据。
    // 测试必须显式指定目录：`AppPaths.initAt(dir)` /
    // `SubjectStore.initTempForTests(dir)`，或用 LOOP_DATA_DIR 指定。
    if (env['FLUTTER_TEST'] == 'true' && (env['LOOP_DATA_DIR'] ?? '').trim().isEmpty) {
      throw StateError(
        '测试进程禁止自动探测数据目录（会命中正式 data/loop.db）：'
        '请使用 AppPaths.initAt(dir) / SubjectStore.initTempForTests(dir)，或设置 LOOP_DATA_DIR',
      );
    }
    applyDataDir(resolveDataDir());
  }

  /// 解析数据目录：只做路径推导，不创建目录，便于单测注入环境。
  static Directory resolveDataDir({
    Map<String, String>? environment,
    String? executablePath,
    Directory? currentDir,
  }) {
    final env = environment ?? Platform.environment;
    final iso = env['LOOP_DATA_DIR'];
    if (iso != null && iso.trim().isNotEmpty) {
      // D9：设置即生效，唯一权威，不做任何回退探测。
      return Directory(iso.trim());
    }

    final candidates = <Directory>[];
    try {
      final exe = executablePath ?? Platform.resolvedExecutable;
      final exeDir = File(exe).parent;
      candidates
        ..add(Directory(p.join(exeDir.path, 'data')))
        ..add(Directory(p.join(exeDir.parent.path, 'data')))
        ..add(Directory(p.join(exeDir.parent.parent.path, 'data')));
    } catch (_) {}
    final cwd = currentDir ?? Directory.current;
    candidates
      ..add(Directory(p.join(cwd.path, 'data')))
      ..add(Directory(p.join(cwd.parent.path, 'data')));
    final localAppData = env['LOCALAPPDATA'];
    if (localAppData != null && localAppData.isNotEmpty) {
      candidates.add(Directory(p.join(localAppData, 'Loop', 'data')));
    }

    for (final candidate in candidates) {
      if (File(p.join(candidate.path, 'loop.db')).existsSync()) return candidate;
    }
    return candidates.isEmpty ? Directory(p.join(cwd.path, 'data')) : candidates.last;
  }

  /// 把数据目录固定为 [dir]：创建目录结构并写入四个静态路径。
  /// 可重复调用（测试里每个隔离用例调用一次）。
  static void applyDataDir(Directory dir) {
    applyDataDirPath(dir.path);
  }

  static void applyDataDirPath(String path) {
    data = Directory(p.normalize(path));
    data.createSync(recursive: true);
    files = Directory(p.join(data.path, 'files'))..createSync(recursive: true);
    subjectsDir = Directory(p.join(data.path, 'subjects'))..createSync(recursive: true);
    migrationsDir = Directory(p.join(data.path, 'migrations'))..createSync(recursive: true);
    trashDir = Directory(p.join(data.path, 'trash'))..createSync(recursive: true);
    dbPath = p.join(data.path, 'loop.db');
    _ready = true;
  }

  /// 测试/嵌入用别名（语义与 [applyDataDir] 相同）。
  static void initAt(Directory dir) => applyDataDir(dir);

  /// 学科目录名白名单：`^[a-z0-9_]{3,40}$`。
  static final RegExp subjectKeyPattern = RegExp(r'^[a-z0-9_]{3,40}$');

  static const Set<String> _windowsReserved = {
    'con', 'prn', 'aux', 'nul',
    'com1', 'com2', 'com3', 'com4', 'com5', 'com6', 'com7', 'com8', 'com9',
    'lpt1', 'lpt2', 'lpt3', 'lpt4', 'lpt5', 'lpt6', 'lpt7', 'lpt8', 'lpt9',
  };

  /// 校验学科 key；不合法直接抛错，不降级、不猜测（§3.4）。
  static void assertValidSubjectKey(String key) {
    if (!subjectKeyPattern.hasMatch(key)) {
      throw ArgumentError('非法学科 key：$key（只允许 [a-z0-9_]{3,40}）');
    }
    if (_windowsReserved.contains(key.toLowerCase())) {
      throw ArgumentError('非法学科 key：$key（Windows 保留名）');
    }
    if (key.contains('..') || key.contains('/') || key.contains(r'\')) {
      throw ArgumentError('非法学科 key：$key（禁止路径分隔符）');
    }
  }

  static bool isValidSubjectKey(String key) {
    try {
      assertValidSubjectKey(key);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// `data/subjects/<key>`：唯一允许的学科路径拼接入口（前缀断言防穿越）。
  static Directory subjectDir(String key) {
    assertValidSubjectKey(key);
    if (!_ready) init();
    final path = p.normalize(p.join(subjectsDir.path, key));
    final root = p.normalize(subjectsDir.path);
    if (path != root && !p.isWithin(root, path)) {
      throw ArgumentError('学科目录越界：$path');
    }
    return Directory(path);
  }

  /// `data/subjects/<key>/loop.db`。
  static String subjectDbPath(String key) => p.join(subjectDir(key).path, 'loop.db');

  /// `data/subjects/<key>/files`。
  static Directory subjectFilesDir(String key) =>
      Directory(p.join(subjectDir(key).path, 'files'));

  /// `data/subjects/<key>/skills`。
  static Directory subjectSkillsDir(String key) =>
      Directory(p.join(subjectDir(key).path, 'skills'));

  /// 相对 `data/` 的路径（注册表 db_rel_path 等字段用，永远是 `/` 分隔）。
  static String relativeToData(String absolute) =>
      p.posix.joinAll(p.split(p.relative(absolute, from: data.path)));

  /// 把相对路径还原成绝对路径（注册表 → 文件系统）。
  static String resolveFromData(String relative) =>
      p.normalize(p.join(data.path, p.joinAll(p.posix.split(relative))));
}