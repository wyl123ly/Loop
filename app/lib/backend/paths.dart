import 'dart:io';

import 'package:path/path.dart' as p;

/// 数据目录解析规则，与旧版保持一致：
/// LOOP_DATA_DIR → exe 同级 data → 上级 → 上两级 → 当前目录 → 当前目录上级 → LOCALAPPDATA
class AppPaths {
  static late final Directory data;
  static late final Directory files;
  static late final String dbPath;
  static bool _ready = false;

  static void init() {
    if (_ready) return;
    final candidates = <Directory>[];
    final env = Platform.environment['LOOP_DATA_DIR'];
    if (env != null && env.isNotEmpty) {
      candidates.add(Directory(env));
    }
    try {
      final exeDir = File(Platform.resolvedExecutable).parent;
      candidates
        ..add(Directory(p.join(exeDir.path, 'data')))
        ..add(Directory(p.join(exeDir.parent.path, 'data')))
        ..add(Directory(p.join(exeDir.parent.parent.path, 'data')));
    } catch (_) {}
    final cwd = Directory.current;
    candidates
      ..add(Directory(p.join(cwd.path, 'data')))
      ..add(Directory(p.join(cwd.parent.path, 'data')));
    final localAppData = Platform.environment['LOCALAPPDATA'];
    if (localAppData != null && localAppData.isNotEmpty) {
      candidates.add(Directory(p.join(localAppData, 'Loop', 'data')));
    }

    Directory? chosen;
    for (final candidate in candidates) {
      if (File(p.join(candidate.path, 'loop.db')).existsSync()) {
        chosen = candidate;
        break;
      }
    }
    chosen ??= candidates.isEmpty ? Directory(p.join(cwd.path, 'data')) : candidates.last;

    data = chosen;
    data.createSync(recursive: true);
    files = Directory(p.join(data.path, 'files'))..createSync(recursive: true);
    dbPath = p.join(data.path, 'loop.db');
    _ready = true;
  }
}
