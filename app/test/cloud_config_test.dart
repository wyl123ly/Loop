import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:loop/api.dart';
import 'package:loop/backend/paths.dart';
import 'package:loop/backend/server.dart';
import 'package:loop/cloud/cloud_restore_service.dart';
import 'package:loop/cloud/cloud_sync_service.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite;

void main() {
  late Directory dataDir;
  late int port;
  late LoopApi api;

  setUp(() async {
    dataDir = await Directory.systemTemp.createTemp('loop_cloud_test_');
    port = await Backend.startForTests(dataDir);
    api = LoopApi(baseUrl: 'http://127.0.0.1:$port');
  });

  tearDown(() async {
    await Backend.stopForTests();
    try {
      if (dataDir.existsSync()) dataDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('云端配置可保存/读取，且拒绝 service_role', () async {
    final initial = await api.cloudConfig();
    expect(initial['url'], '');
    expect(initial['device_id'], '');

    await api.saveCloudConfig(
      url: 'https://demo.supabase.co',
      key: 'sb_publishable_test',
      deviceId: 'device-1',
      deviceName: 'My PC',
    );
    final saved = await api.cloudConfig();
    expect(saved['url'], 'https://demo.supabase.co');
    expect(saved['key'], 'sb_publishable_test');
    expect(saved['device_id'], 'device-1');
    expect(saved['device_name'], 'My PC');

    await expectLater(
      api.saveCloudConfig(key: 'service_role-secret'),
      throwsA(isA<ApiException>()),
    );
  });

  test('CloudSyncService 拒绝 service_role 和非 https URL', () {
    final service = CloudSyncService();
    expect(
      () => service.configure(
        url: 'https://demo.supabase.co',
        key: 'service_role-secret',
      ),
      throwsArgumentError,
    );
    expect(
      () => service.configure(url: 'http://demo.supabase.co', key: 'sb_test'),
      throwsArgumentError,
    );
  });

  test('待恢复快照会在启动前替换 data/ 并保留备份', () async {
    final root = await Directory.systemTemp.createTemp('loop_restore_test_');
    try {
      AppPaths.applyDataDirPath(root.path);
      File(p.join(root.path, 'loop.db')).writeAsStringSync('old');
      final oldSubjects = Directory(p.join(root.path, 'subjects'))..createSync();
      File(p.join(oldSubjects.path, 'old.txt')).writeAsStringSync('old');
      final sync = Directory(p.join(root.path, '.sync'))..createSync();
      final incoming = Directory(p.join(sync.path, 'incoming-test'))..createSync();
      final incomingDb = sqlite.sqlite3.open(p.join(incoming.path, 'loop.db'));
      incomingDb.execute('CREATE TABLE restored(value TEXT)');
      incomingDb.execute("INSERT INTO restored VALUES ('new')");
      incomingDb.close();
      final newSubjects = Directory(p.join(incoming.path, 'subjects'))..createSync();
      File(p.join(newSubjects.path, 'new.txt')).writeAsStringSync('new');
      File(p.join(sync.path, 'pending-restore.json')).writeAsStringSync(
        jsonEncode({'incoming': incoming.path, 'snapshot_id': 'test'}),
      );
      expect(pendingCloudRestoreExists(), isTrue);

      await applyPendingCloudRestore();

      final restored = sqlite.sqlite3.open(p.join(root.path, 'loop.db'));
      expect(
        restored.select('SELECT value FROM restored').first['value'],
        'new',
      );
      restored.close();
      expect(File(p.join(root.path, 'subjects', 'new.txt')).existsSync(), isTrue);
      expect(pendingCloudRestoreExists(), isFalse);
      final backups = Directory(p.join(root.path, '.backup'));
      expect(
        backups.listSync(recursive: true).whereType<File>().isNotEmpty,
        isTrue,
      );
    } finally {
      try {
        root.deleteSync(recursive: true);
      } catch (_) {}
    }
  });
}
