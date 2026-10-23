import 'dart:io';

import 'package:path/path.dart' as p;

import 'db.dart';
import 'parsing.dart';
import 'paths.dart';
import 'retrieval.dart';

const supportedExtensions = {'.pdf', '.docx', '.pptx', '.txt', '.md'};
const maxFileBytes = 30 * 1024 * 1024;
// 不限制文件数和总大小；仅限制单个文件大小。

class FolderFile {
  FolderFile({
    required this.path,
    required this.relative,
    required this.name,
    required this.ext,
    required this.size,
    required this.mtime,
    required this.supported,
    required this.reason,
    required this.existing,
  });

  final String path;
  final String relative;
  final String name;
  final String ext;
  final int size;
  final int mtime;
  final bool supported;
  final String reason;
  final bool existing;

  Map<String, Object?> toJson() => {
        'path': path,
        'relative': relative,
        'name': name,
        'ext': ext,
        'size': size,
        'mtime': mtime,
        'supported': supported,
        'reason': reason,
        'existing': existing,
      };
}

class FolderScanResult {
  FolderScanResult({
    required this.root,
    required this.name,
    required this.files,
    required this.truncated,
  });

  final String root;
  final String name;
  final List<FolderFile> files;
  final bool truncated;

  List<FolderFile> get supported => files.where((file) => file.supported).toList();
  int get totalBytes => files.fold(0, (sum, file) => sum + file.size);
}

FolderScanResult scanFolder(String rawPath, {bool recursive = true}) {
  final dir = Directory(rawPath);
  if (!dir.existsSync()) throw const FormatException('文件夹不存在');
  final root = dir.resolveSymbolicLinksSync();
  final files = <FolderFile>[];
  var truncated = false;

  void addEntity(FileSystemEntity entity) {
    if (entity is Link) return;
    if (entity is! File) return;
    final stat = entity.statSync();
    final ext = p.extension(entity.path).toLowerCase();
    final supported = supportedExtensions.contains(ext);
    var reason = '';
    if (!supported) {
      reason = '不支持的格式';
    } else if (stat.size > maxFileBytes) {
      reason = '超过 30MB';
    }
    final absolute = p.normalize(entity.absolute.path);
    final existing = Db.one('SELECT id FROM materials WHERE source_path=?', [absolute]) != null;
    files.add(FolderFile(
      path: absolute,
      relative: p.relative(entity.path, from: root),
      name: p.basename(entity.path),
      ext: ext,
      size: stat.size,
      mtime: stat.modified.millisecondsSinceEpoch,
      supported: supported && stat.size <= maxFileBytes,
      reason: reason,
      existing: existing,
    ));
  }

  for (final entity in dir.listSync(recursive: recursive, followLinks: false)) {
    if (entity is Directory) continue;
    final name = p.basename(entity.path);
    if (name.startsWith('.') || name.startsWith('~\$')) continue;
    final parent = p.basename(entity.parent.path);
    if (const {'.git', 'node_modules', '.venv', '__pycache__', '.idea'}.contains(parent)) continue;
    addEntity(entity);
  }
  files.sort((a, b) => a.relative.toLowerCase().compareTo(b.relative.toLowerCase()));
  return FolderScanResult(
    root: root,
    name: p.basename(root),
    files: files,
    truncated: truncated,
  );
}

int ensureFolder(String root, String name) {
  final existing = Db.one('SELECT id FROM material_folders WHERE root_path=?', [root]);
  if (existing != null) return (existing['id'] as num).toInt();
  return Db.insert('material_folders', {
    'root_path': root,
    'name': name,
    'created_at': Db.nowIso(),
    'last_scan_at': '',
  });
}

String _uniquePath(String original) {
  final ext = p.extension(original).toLowerCase();
  final stamp = DateTime.now().microsecondsSinceEpoch;
  return p.join(AppPaths.files.path, '${stamp}_folder$ext');
}

Future<Map<String, Object?>> importFolderFile(FolderFile file, int folderId, String duplicate) async {
  final existing = Db.one('SELECT * FROM materials WHERE source_path=?', [file.path]);
  if (existing != null) {
    if (duplicate != 'update') return {'status': 'skipped', 'reason': '已存在'};
    await deleteMaterialById((existing['id'] as num).toInt());
  }
  if (!file.supported) return {'status': 'skipped', 'reason': file.reason};
  final savedPath = _uniquePath(file.name);
  final copied = File(file.path).copySync(savedPath);
  try {
    final pages = await extractPages(savedPath, file.ext);
    final total = pages.fold<int>(0, (sum, page) => sum + page.length);
    if (total < 10) {
      copied.deleteSync();
      return {'status': 'skipped', 'reason': '没有可提取文字'};
    }
    final materialId = Db.insert('materials', {
      'name': file.name,
      'kind': file.ext.replaceFirst('.', ''),
      'path': savedPath,
      'status': 'ready',
      'pages': pages.length,
      'chars': total,
      'folder_id': folderId,
      'source_path': file.path,
      'source_mtime': file.mtime,
      'source_size': file.size,
      'relative_path': file.relative,
      'created_at': Db.nowIso(),
    });
    indexMaterial(materialId, pages);
    return {
      'status': 'imported',
      'id': materialId,
      'pages': pages.length,
      'chars': total,
    };
  } catch (error) {
    if (copied.existsSync()) copied.deleteSync();
    return {'status': 'failed', 'reason': '$error'};
  }
}

Future<void> deleteMaterialById(int id) async {
  final row = Db.one('SELECT * FROM materials WHERE id=?', [id]);
  if (row == null) return;
  await _deleteMaterialsWhere('id', id);
  await _deleteFile((row['path'] ?? '').toString());
}

Future<void> deleteFolderById(int id) async {
  final rows = Db.rows('SELECT path FROM materials WHERE folder_id=?', [id]);
  await _deleteMaterialsWhere('folder_id', id);
  for (final row in rows) {
    await _deleteFile((row['path'] ?? '').toString());
  }
  Db.run('DELETE FROM material_folders WHERE id=?', [id]);
}

Future<void> _deleteMaterialsWhere(String column, int id) async {
  try {
    Db.run('BEGIN');
    Db.run(
      'DELETE FROM chunks_fts WHERE chunk_id IN ('
      'SELECT id FROM chunks WHERE material_id IN ('
      'SELECT id FROM materials WHERE $column=?))',
      [id],
    );
    Db.run(
      'DELETE FROM chunks WHERE material_id IN (SELECT id FROM materials WHERE $column=?)',
      [id],
    );
    Db.run('DELETE FROM materials WHERE $column=?', [id]);
    Db.run('COMMIT');
  } catch (error) {
    try {
      Db.run('ROLLBACK');
    } catch (_) {}
    rethrow;
  }
}

Future<void> _deleteFile(String rawPath) async {
  final root = p.normalize(AppPaths.files.path);
  final target = p.normalize(rawPath);
  if (!target.startsWith(root)) return;
  final file = File(target);
  if (!file.existsSync()) return;
  try {
    await file.delete();
  } catch (_) {
    if (Platform.isWindows) {
      try {
        await Process.run('attrib', ['-R', target]);
        await file.delete();
      } catch (_) {}
    }
  }
}
