import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:supabase/supabase.dart';
import 'package:uuid/uuid.dart';

import '../backend/paths.dart';
import '../update/app_version.dart';
import 'cloud_restore_service.dart';
import 'cloud_sync_service.dart';

class CloudSnapshotResult {
  const CloudSnapshotResult({
    required this.snapshotId,
    required this.bytes,
    required this.chunks,
    required this.duration,
  });

  final String snapshotId;
  final int bytes;
  final int chunks;
  final Duration duration;
}

class CloudSnapshotException implements Exception {
  CloudSnapshotException(this.message);
  final String message;
  @override
  String toString() => message;
}

class CloudConflictException extends CloudSnapshotException {
  CloudConflictException({
    required this.latestSnapshotId,
    required this.latestDevice,
    required this.createdAt,
  }) : super(
          '云端有来自其他设备（$latestDevice，$createdAt）的更新快照。'
          '请先下载恢复，或选择强制上传覆盖云端。',
        );

  final String latestSnapshotId;
  final String latestDevice;
  final String createdAt;
}

/// 方案 B：本地快照 -> tar.gz -> Argon2id + AES-256-GCM 分片 -> Supabase。
///
/// 当前是“手动立即同步”版本；退出自动同步与恢复在后续阶段接。
class CloudSnapshotService {
  CloudSnapshotService({CloudSyncService? cloud})
      : cloud = cloud ?? CloudSyncService.instance;

  final CloudSyncService cloud;

  static const int chunkSize = 8 * 1024 * 1024;

  Future<CloudSnapshotResult> uploadSnapshot({
    required String passphrase,
    String? lastSnapshotId,
    bool force = false,
    void Function(String phase, int done, int total)? onProgress,
  }) async {
    if (pendingCloudRestoreExists()) {
      throw CloudSnapshotException('已有待恢复的云端快照；请先重启完成恢复，避免覆盖。');
    }
    final userId = cloud.userId;
    if (userId == null) throw CloudSnapshotException('请先登录 Supabase 账号。');
    final stateRows = await cloud.client
        .from('sync_state')
        .select()
        .eq('user_id', userId)
        .limit(1);
    final latestId =
        stateRows.isEmpty ? null : stateRows.first['latest_snapshot']?.toString();
    if (!force &&
        latestId != null &&
        latestId.isNotEmpty &&
        latestId != lastSnapshotId) {
      final rows = await cloud.client
          .from('snapshots')
          .select('device_id,created_at')
          .eq('id', latestId)
          .limit(1);
      final otherDevice = rows.isNotEmpty
          ? rows.first['device_id']?.toString() ?? ''
          : '';
      if (otherDevice.isNotEmpty && otherDevice != cloud.deviceId) {
        throw CloudConflictException(
          latestSnapshotId: latestId,
          latestDevice: otherDevice,
          createdAt: rows.isNotEmpty
              ? rows.first['created_at']?.toString() ?? ''
              : '',
        );
      }
    }
    if (passphrase.trim().length < 8) {
      throw CloudSnapshotException('同步口令至少 8 个字符。');
    }
    final started = DateTime.now();
    final snapshotId = const Uuid().v4();
    final syncRoot = Directory(p.join(AppPaths.data.path, '.sync'));
    syncRoot.createSync(recursive: true);
    final staging = Directory(p.join(syncRoot.path, 'staging-$snapshotId'));
    final archive = File(p.join(syncRoot.path, 'snapshot-$snapshotId.tar.gz'));
    try {
      onProgress?.call('snapshot', 0, 0);
      await _buildStaging(staging);
      onProgress?.call('archive', 0, 0);
      await _tar(staging, archive);
      final archiveBytes = await archive.length();
      final archiveHash = await _sha256File(archive);

      onProgress?.call('encrypt', 0, 0);
      final salt = _randomBytes(16);
      final key = await _deriveKey(passphrase, salt);
      final totalChunks = (archiveBytes / chunkSize).ceil();
      final parts = <Map<String, Object?>>[];
      final partFiles = <File>[];
      var done = 0;
      final input = archive.openRead();
      final buffer = BytesBuilder(copy: false);
      await for (final data in input) {
        buffer.add(data);
        while (buffer.length >= chunkSize) {
          final all = buffer.takeBytes();
          final chunk = all.sublist(0, chunkSize);
          final rest = all.sublist(chunkSize);
          final part = await _encryptChunk(key, chunk, done, salt);
          final file = File(p.join(syncRoot.path, 'part-$done.bin'));
          await file.writeAsBytes(part, flush: true);
          partFiles.add(file);
          parts.add({
            'index': done,
            'bytes': part.length,
            'sha256': crypto.sha256.convert(part).toString(),
          });
          done++;
          onProgress?.call('encrypt', done, totalChunks);
          if (rest.isNotEmpty) buffer.add(rest);
        }
      }
      final remaining = buffer.takeBytes();
      if (remaining.isNotEmpty) {
        final part = await _encryptChunk(key, remaining, done, salt);
        final file = File(p.join(syncRoot.path, 'part-$done.bin'));
        await file.writeAsBytes(part, flush: true);
        partFiles.add(file);
        parts.add({
          'index': done,
          'bytes': part.length,
          'sha256': crypto.sha256.convert(part).toString(),
        });
        done++;
        onProgress?.call('encrypt', done, totalChunks);
      }

      onProgress?.call('upload', 0, parts.length);
      final prefix = '$userId/$snapshotId';
      final bucket = cloud.client.storage.from('loop-snapshots');
      for (var i = 0; i < partFiles.length; i++) {
        await bucket.uploadBinary(
          '$prefix/part-$i.bin',
          await partFiles[i].readAsBytes(),
          fileOptions: const FileOptions(
            upsert: true,
            contentType: 'application/octet-stream',
          ),
        );
        onProgress?.call('upload', i + 1, partFiles.length);
      }

      final manifest = <String, Object?>{
        'format': 'loop-snapshot-v1',
        'salt': base64Encode(salt),
        'chunk_size': chunkSize,
        'chunk_count': parts.length,
        'parts': parts,
        'archive_sha256': archiveHash,
        'archive_bytes': archiveBytes,
        'encrypted': true,
        'created_at': DateTime.now().toUtc().toIso8601String(),
      };
      final manifestBytes = utf8.encode(jsonEncode(manifest));
      await bucket.uploadBinary(
        '$prefix/manifest.json',
        Uint8List.fromList(manifestBytes),
        fileOptions: const FileOptions(
          upsert: true,
          contentType: 'application/json',
        ),
      );

      await cloud.client.from('snapshots').insert({
        'id': snapshotId,
        'user_id': userId,
        'device_id': cloud.deviceId,
        'app_version': AppVersion.current,
        'schema_version': 3,
        'total_bytes': archiveBytes,
        'chunk_size': chunkSize,
        'chunk_count': parts.length,
        'sha256': archiveHash,
        'manifest': manifest,
        'storage_prefix': prefix,
        'status': 'ready',
      });
      await cloud.client.from('sync_state').upsert({
        'user_id': userId,
        'latest_snapshot': snapshotId,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      });
      await _pruneOldSnapshots(userId);
      return CloudSnapshotResult(
        snapshotId: snapshotId,
        bytes: archiveBytes,
        chunks: parts.length,
        duration: DateTime.now().difference(started),
      );
    } catch (error) {
      try {
        await cloud.client
            .from('snapshots')
            .update({'status': 'failed'}).eq('id', snapshotId);
      } catch (_) {}
      if (error is CloudSnapshotException) rethrow;
      throw CloudSnapshotException('同步失败：$error');
    } finally {
      try {
        if (await archive.exists()) await archive.delete();
        if (await staging.exists()) await staging.delete(recursive: true);
      } catch (_) {}
    }
  }

  Future<void> _buildStaging(Directory staging) async {
    await staging.create(recursive: true);
    await _copyDirectory(
      Directory(p.join(AppPaths.data.path, 'files')),
      Directory(p.join(staging.path, 'files')),
    );
    await _copyDirectory(
      Directory(p.join(AppPaths.data.path, 'migrations')),
      Directory(p.join(staging.path, 'migrations')),
    );

    final db = sqlite.sqlite3.open(AppPaths.dbPath);
    try {
      _vacuumInto(db, p.join(staging.path, 'loop.db'));
    } finally {
      db.close();
    }

    final subjects = Directory(p.join(AppPaths.data.path, 'subjects'));
    if (await subjects.exists()) {
      for (final entity in subjects.listSync()) {
        if (entity is! Directory) continue;
        final sourceDb = File(p.join(entity.path, 'loop.db'));
        if (!sourceDb.existsSync()) continue;
        final key = p.basename(entity.path);
        final target = Directory(p.join(staging.path, 'subjects', key));
        target.createSync(recursive: true);
        final subjectDb = sqlite.sqlite3.open(sourceDb.path);
        try {
          _vacuumInto(subjectDb, p.join(target.path, 'loop.db'));
        } finally {
          subjectDb.close();
        }
        await _copyDirectory(
          Directory(p.join(entity.path, 'files')),
          Directory(p.join(target.path, 'files')),
        );
        await _copyDirectory(
          Directory(p.join(entity.path, 'skills')),
          Directory(p.join(target.path, 'skills')),
        );
      }
    }
  }

  void _vacuumInto(sqlite.Database db, String target) {
    final escaped = target.replaceAll("'", "''");
    final file = File(target);
    if (file.existsSync()) file.deleteSync();
    db.execute("VACUUM INTO '$escaped'");
  }

  Future<void> _tar(Directory staging, File archive) async {
    if (archive.existsSync()) archive.deleteSync();
    final result = await Process.run(
      'tar.exe',
      ['-czf', archive.path, '-C', staging.path, '.'],
      runInShell: true,
    );
    if (result.exitCode != 0) {
      throw CloudSnapshotException(
        '打包失败：${result.stderr.toString().trim()}',
      );
    }
  }

  Future<SecretKey> _deriveKey(String passphrase, List<int> salt) async {
    final algorithm = Argon2id(
      parallelism: 1,
      memory: 64 * 1024,
      iterations: 3,
      hashLength: 32,
    );
    return algorithm.deriveKey(
      secretKey: SecretKey(utf8.encode(passphrase)),
      nonce: salt,
    );
  }

  Future<Uint8List> _encryptChunk(
    SecretKey key,
    List<int> data,
    int index,
    List<int> salt,
  ) async {
    final algorithm = AesGcm.with256bits();
    final nonce = _randomBytes(12);
    final box = await algorithm.encrypt(
      data,
      secretKey: key,
      nonce: nonce,
      aad: [...salt, index],
    );
    return Uint8List.fromList([
      1,
      ...nonce,
      ...box.cipherText,
      ...box.mac.bytes,
    ]);
  }

  List<int> _randomBytes(int length) {
    final random = Random.secure();
    return List<int>.generate(length, (_) => random.nextInt(256));
  }

  Future<String> _sha256File(File file) async {
    final digest = await crypto.sha256.bind(file.openRead()).first;
    return digest.toString();
  }

  Future<void> _copyDirectory(Directory source, Directory target) async {
    if (!await source.exists()) return;
    await target.create(recursive: true);
    await for (final entity in source.list(recursive: true)) {
      if (entity is! File) continue;
      final relative = p.relative(entity.path, from: source.path);
      final dest = File(p.join(target.path, relative));
      await dest.parent.create(recursive: true);
      await entity.copy(dest.path);
    }
  }

  Future<void> _pruneOldSnapshots(String userId) async {
    final rows = await cloud.client
        .from('snapshots')
        .select('id,storage_prefix,chunk_count')
        .eq('user_id', userId)
        .eq('status', 'ready')
        .order('created_at', ascending: false);
    if (rows.length <= 2) return;
    final bucket = cloud.client.storage.from('loop-snapshots');
    for (final row in rows.skip(2)) {
      final id = row['id'].toString();
      final prefix = row['storage_prefix'].toString();
      final count = (row['chunk_count'] as num?)?.toInt() ?? 0;
      try {
        final paths = <String>[
          for (var i = 0; i < count; i++) '$prefix/part-$i.bin',
          '$prefix/manifest.json',
        ];
        await bucket.remove(paths);
        await cloud.client.from('snapshots').delete().eq('id', id);
      } catch (_) {}
    }
  }
}
