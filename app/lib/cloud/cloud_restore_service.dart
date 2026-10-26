import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../backend/paths.dart';
import 'cloud_sync_service.dart';

class RestoreReady {
  const RestoreReady({
    required this.snapshotId,
    required this.incomingPath,
    required this.bytes,
  });

  final String snapshotId;
  final String incomingPath;
  final int bytes;
}

class CloudRestoreException implements Exception {
  CloudRestoreException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 方案 B 的下载侧：下载最新快照分片 -> 校验 -> 解密 -> 解包到 data/.sync/incoming。
/// 真正替换 data/ 在下次启动时由 [applyPendingCloudRestore] 完成。
class CloudRestoreService {
  CloudRestoreService({CloudSyncService? cloud})
      : cloud = cloud ?? CloudSyncService.instance;

  final CloudSyncService cloud;

  Future<RestoreReady> downloadLatest({
    required String passphrase,
    void Function(String phase, int done, int total)? onProgress,
  }) async {
    final userId = cloud.userId;
    if (userId == null) throw CloudRestoreException('请先登录 Supabase 账号。');
    if (passphrase.trim().length < 8) {
      throw CloudRestoreException('同步口令至少 8 个字符。');
    }
    final stateRows = await cloud.client
        .from('sync_state')
        .select()
        .eq('user_id', userId)
        .limit(1);
    if (stateRows.isEmpty) {
      throw CloudRestoreException('云端还没有快照，请先上传一次。');
    }
    final snapshotId = stateRows.first['latest_snapshot']?.toString() ?? '';
    if (snapshotId.isEmpty) {
      throw CloudRestoreException('云端还没有可恢复的快照。');
    }
    final rows = await cloud.client
        .from('snapshots')
        .select()
        .eq('id', snapshotId)
        .eq('status', 'ready')
        .limit(1);
    if (rows.isEmpty) {
      throw CloudRestoreException('云端快照不存在或未完成上传。');
    }
    final row = Map<String, dynamic>.from(rows.first as Map);
    final manifest = Map<String, dynamic>.from(row['manifest'] as Map);
    final parts = (manifest['parts'] as List? ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    final chunkCount = (manifest['chunk_count'] as num?)?.toInt() ?? 0;
    if (parts.length != chunkCount || chunkCount == 0) {
      throw CloudRestoreException('云端快照 manifest 不完整。');
    }
    final salt = base64Decode((manifest['salt'] ?? '').toString());
    final key = await _deriveKey(passphrase, salt);
    final prefix = row['storage_prefix'].toString();
    final syncRoot = Directory(p.join(AppPaths.data.path, '.sync'));
    syncRoot.createSync(recursive: true);
    final archive = File(p.join(syncRoot.path, 'incoming-$snapshotId.tar.gz'));
    final incoming = Directory(p.join(syncRoot.path, 'incoming-$snapshotId'));
    if (await archive.exists()) await archive.delete();
    if (await incoming.exists()) await incoming.delete(recursive: true);
    final bucket = cloud.client.storage.from('loop-snapshots');
    final sink = archive.openWrite();
    try {
      for (var i = 0; i < chunkCount; i++) {
        onProgress?.call('download', i, chunkCount);
        final bytes = await bucket.download('$prefix/part-$i.bin');
        final expected = parts[i]['sha256']?.toString() ?? '';
        if (expected.isNotEmpty &&
            crypto.sha256.convert(bytes).toString() != expected) {
          throw CloudRestoreException('第 ${i + 1} 块校验失败（下载损坏）。');
        }
        final clear = await _decryptPart(key, bytes, i, salt);
        sink.add(clear);
      }
      await sink.flush();
      await sink.close();
      final archiveHash = await _sha256File(archive);
      if (archiveHash != (manifest['archive_sha256'] ?? '').toString()) {
        throw CloudRestoreException('快照整体校验失败。');
      }
      final archiveBytes = await archive.length();
      if (archiveBytes != ((manifest['archive_bytes'] as num?)?.toInt() ?? 0)) {
        throw CloudRestoreException('快照大小不一致。');
      }
      onProgress?.call('extract', 0, 1);
      incoming.createSync(recursive: true);
      final result = await Process.run(
        'tar.exe',
        ['-xzf', archive.path, '-C', incoming.path],
        runInShell: true,
      );
      if (result.exitCode != 0) {
        throw CloudRestoreException(
          '解包失败：${result.stderr.toString().trim()}',
        );
      }
      if (!File(p.join(incoming.path, 'loop.db')).existsSync()) {
        throw CloudRestoreException('快照里没有 loop.db，拒绝恢复。');
      }
      final marker = File(p.join(syncRoot.path, 'pending-restore.json'));
      await marker.writeAsString(
        jsonEncode({
          'snapshot_id': snapshotId,
          'incoming': incoming.path,
          'created_at': DateTime.now().toUtc().toIso8601String(),
        }),
        flush: true,
      );
      onProgress?.call('ready', 1, 1);
      return RestoreReady(
        snapshotId: snapshotId,
        incomingPath: incoming.path,
        bytes: archiveBytes,
      );
    } catch (error) {
      try {
        await sink.close();
      } catch (_) {}
      if (error is CloudRestoreException) rethrow;
      throw CloudRestoreException('下载恢复失败：$error');
    } finally {
      try {
        if (await archive.exists()) await archive.delete();
      } catch (_) {}
    }
  }

  Future<SecretKey> _deriveKey(String passphrase, List<int> salt) {
    return Argon2id(
      parallelism: 1,
      memory: 64 * 1024,
      iterations: 3,
      hashLength: 32,
    ).deriveKey(
      secretKey: SecretKey(utf8.encode(passphrase)),
      nonce: salt,
    );
  }

  Future<List<int>> _decryptPart(
    SecretKey key,
    Uint8List bytes,
    int index,
    List<int> salt,
  ) async {
    if (bytes.length < 1 + 12 + 16 || bytes[0] != 1) {
      throw CloudRestoreException('快照分块格式不正确。');
    }
    final nonce = bytes.sublist(1, 13);
    final macStart = bytes.length - 16;
    final cipher = bytes.sublist(13, macStart);
    final mac = bytes.sublist(macStart);
    final box = SecretBox(
      cipher,
      nonce: nonce,
      mac: Mac(mac),
    );
    final clear = await AesGcm.with256bits().decrypt(
      box,
      secretKey: key,
      aad: [...salt, index],
    );
    return clear;
  }

  Future<String> _sha256File(File file) async {
    final digest = await crypto.sha256.bind(file.openRead()).first;
    return digest.toString();
  }
}

/// 是否存在“已下载、等待下次启动应用”的恢复快照。
/// 存在时退出同步必须跳过，避免用旧数据覆盖刚下载的云端最新快照。
bool pendingCloudRestoreExists() {
  try {
    AppPaths.init();
    return File(
      p.join(AppPaths.data.path, '.sync', 'pending-restore.json'),
    ).existsSync();
  } catch (_) {
    return false;
  }
}

/// 下次启动、Backend.start 之前调用：把 incoming 原子替换到 data/。
Future<void> applyPendingCloudRestore() async {
  try {
    AppPaths.init();
  } catch (_) {
    return;
  }
  final syncRoot = Directory(p.join(AppPaths.data.path, '.sync'));
  final marker = File(p.join(syncRoot.path, 'pending-restore.json'));
  if (!await marker.exists()) return;
  Map<String, dynamic> data;
  try {
    data = jsonDecode(await marker.readAsString()) as Map<String, dynamic>;
  } catch (_) {
    return;
  }
  final incomingPath = (data['incoming'] ?? '').toString();
  final incoming = Directory(incomingPath);
  if (!incoming.existsSync() ||
      !File(p.join(incoming.path, 'loop.db')).existsSync()) {
    return;
  }
  final backup = Directory(
    p.join(
      AppPaths.data.path,
      '.backup',
      'restore-${DateTime.now().millisecondsSinceEpoch}',
    ),
  );
  backup.createSync(recursive: true);
  final moved = <String>[];
  try {
    for (final name in ['loop.db', 'subjects', 'files', 'migrations']) {
      final source = FileSystemEntity.typeSync(p.join(AppPaths.data.path, name));
      if (source == FileSystemEntityType.notFound) continue;
      await _moveEntity(
        p.join(AppPaths.data.path, name),
        p.join(backup.path, name),
      );
      moved.add(name);
    }
    for (final name in ['loop.db', 'subjects', 'files', 'migrations']) {
      final source = p.join(incoming.path, name);
      if (FileSystemEntity.typeSync(source) == FileSystemEntityType.notFound) {
        continue;
      }
      await _moveEntity(source, p.join(AppPaths.data.path, name));
    }
    _verifyRestoredDatabases();
    await marker.delete();
    await incoming.delete(recursive: true);
  } catch (error) {
    // 回滚已移动的顶层项。
    for (final name in moved) {
      try {
        final target = p.join(AppPaths.data.path, name);
        if (FileSystemEntity.typeSync(target) != FileSystemEntityType.notFound) {
          await _moveEntity(target, p.join(backup.path, name));
        }
      } catch (_) {}
    }
    for (final name in moved) {
      try {
        final source = p.join(backup.path, name);
        if (FileSystemEntity.typeSync(source) != FileSystemEntityType.notFound) {
          await _moveEntity(source, p.join(AppPaths.data.path, name));
        }
      } catch (_) {}
    }
    stderr.writeln('pending cloud restore failed: $error');
  }
}

void _verifyRestoredDatabases() {
  void check(String path) {
    if (!File(path).existsSync()) return;
    final db = sqlite3.open(path, mode: OpenMode.readOnly);
    try {
      final result = db.select('PRAGMA integrity_check');
      if (result.isEmpty || result.first.values.first.toString() != 'ok') {
        throw StateError('SQLite integrity_check 失败：$path');
      }
    } finally {
      db.close();
    }
  }

  check(p.join(AppPaths.data.path, 'loop.db'));
  final subjects = Directory(p.join(AppPaths.data.path, 'subjects'));
  if (subjects.existsSync()) {
    for (final entity in subjects.listSync()) {
      if (entity is Directory) {
        check(p.join(entity.path, 'loop.db'));
      }
    }
  }
}

Future<void> _moveEntity(String from, String to) async {
  final type = FileSystemEntity.typeSync(from);
  if (type == FileSystemEntityType.directory) {
    await Directory(from).rename(to);
  } else if (type == FileSystemEntityType.file) {
    await File(from).rename(to);
  }
}
