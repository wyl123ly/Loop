import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:loop/update/app_version.dart';
import 'package:loop/update/update_service.dart';
import 'package:path/path.dart' as p;

/// 更新功能回归：
/// - 最新 Release 没有附件时回退到上一个有附件的版本；
/// - 更新包多一层目录可自动展平；
/// - 用户数据不会被更新包覆盖/复制进备份；
/// - updater.ps1 真实执行：替换文件、保留 data、日志正常。
void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('loop-update-test-');
    UpdateService.updatesDirOverride = p.join(root.path, 'updates');
  });

  tearDown(() {
    UpdateService.updatesDirOverride = null;
    try {
      if (root.existsSync()) root.deleteSync(recursive: true);
    } catch (_) {}
  });

  Map<String, dynamic> release({
    required String tag,
    required List<Map<String, dynamic>> assets,
    bool prerelease = false,
  }) =>
      {
        'tag_name': tag,
        'body': 'notes',
        'draft': false,
        'prerelease': prerelease,
        'published_at': '2026-10-26T00:00:00Z',
        'assets': assets,
      };

  Map<String, dynamic> asset(String name, {String? digest}) => {
        'name': name,
        'browser_download_url': 'https://example.com/$name',
        'size': 123,
        'digest': ?digest,
      };

  test('UH1 最新 Release 缺附件时回退到上一个可用版本', () {
    final info = UpdateService.parseReleaseList([
      release(tag: 'v0.9.1', assets: []),
      release(tag: 'v0.9.0', assets: [asset(AppVersion.assetName)]),
      release(tag: 'v0.8.9', assets: [asset(AppVersion.assetName)]),
    ]);
    expect(info.version, '0.9.0');
    expect(info.assetName, AppVersion.assetName);
  });

  test('UH2 跳过 prerelease/draft，全部不可用时给出明确错误', () {
    expect(
      () => UpdateService.parseReleaseList([
        release(tag: 'v0.9.1', assets: [asset(AppVersion.assetName)], prerelease: true),
        release(tag: 'v0.9.0', assets: []),
      ]),
      throwsA(isA<UpdateException>()),
    );
  });

  test('UH3 checkLatest 支持 releases 列表接口并选出可用版本', () async {
    final client = MockClient((request) async {
      expect(request.url.path, contains('/releases'));
      return http.Response(
        jsonEncode([
          release(tag: 'v0.9.1', assets: []),
          release(tag: 'v0.9.0', assets: [
            asset(AppVersion.assetName, digest: 'sha256:abc'),
          ]),
        ]),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final info = await UpdateService.checkLatest(client: client);
    expect(info, isNotNull);
    expect(info!.version, '0.9.0');
    expect(info.hasDigest, isTrue);
  });

  test('UH4 stage 自动展平单层目录并删除用户数据路径', () async {
    final archive = Archive();
    void add(String name, String content) {
      final bytes = utf8.encode(content);
      archive.addFile(ArchiveFile(name, bytes.length, bytes));
    }

    add('Loop-0.9.0/Loop.exe', 'new-exe');
    add('Loop-0.9.0/version.json', jsonEncode({'version': '0.9.0'}));
    add('Loop-0.9.0/data/flutter_assets/app.txt', 'runtime');
    add('Loop-0.9.0/data/loop.db', 'user-db');
    add('Loop-0.9.0/data/subjects/s1/loop.db', 'user-subject');
    add('Loop-0.9.0/data/files/a.pdf', 'user-file');

    final zip = File(p.join(root.path, 'update.zip'))
      ..writeAsBytesSync(ZipEncoder().encode(archive));
    final info = UpdateInfo(
      version: '0.9.0',
      tag: 'v0.9.0',
      notes: '',
      assetName: AppVersion.assetName,
      assetUrl: 'https://example.com/x.zip',
      assetSize: zip.lengthSync(),
      digest: '',
      publishedAt: '',
    );

    final staging = await UpdateService.stage(zip, info);
    expect(File(p.join(staging.path, 'Loop.exe')).existsSync(), isTrue);
    expect(File(p.join(staging.path, 'version.json')).existsSync(), isTrue);
    expect(File(p.join(staging.path, 'data', 'flutter_assets', 'app.txt')).existsSync(), isTrue);
    expect(File(p.join(staging.path, 'data', 'loop.db')).existsSync(), isFalse);
    expect(Directory(p.join(staging.path, 'data', 'subjects')).existsSync(), isFalse);
    expect(Directory(p.join(staging.path, 'data', 'files')).existsSync(), isFalse);
  });

  test('UH5 updater.ps1 替换程序、保留用户数据、备份不含用户数据', () async {
    if (!Platform.isWindows) return;
    final script = File(p.join(Directory.current.path, 'assets', 'updater.ps1'));
    expect(script.existsSync(), isTrue, reason: '测试需在 app 目录运行');

    final install = Directory(p.join(root.path, 'install'))..createSync(recursive: true);
    final staging = Directory(p.join(root.path, 'staging'))..createSync(recursive: true);
    final backup = p.join(root.path, 'backup');
    final log = p.join(root.path, 'update.log');

    File(p.join(install.path, 'Loop.exe')).writeAsStringSync('old-exe');
    Directory(p.join(install.path, 'data', 'flutter_assets')).createSync(recursive: true);
    File(p.join(install.path, 'data', 'flutter_assets', 'keep.txt')).writeAsStringSync('keep');
    File(p.join(install.path, 'data', 'loop.db')).writeAsStringSync('user-db');
    Directory(p.join(install.path, 'data', 'subjects', 's1')).createSync(recursive: true);
    File(p.join(install.path, 'data', 'subjects', 's1', 'loop.db')).writeAsStringSync('user-subject');

    File(p.join(staging.path, 'Loop.exe')).writeAsStringSync('new-exe');
    File(p.join(staging.path, 'version.json')).writeAsStringSync('{"version":"0.9.0"}');
    Directory(p.join(staging.path, 'data', 'flutter_assets')).createSync(recursive: true);
    File(p.join(staging.path, 'data', 'flutter_assets', 'new.txt')).writeAsStringSync('new');

    final parent = await Process.start('cmd', ['/c', 'exit', '0']);
    final parentPid = parent.pid;
    await parent.exitCode;

    final result = await Process.run('powershell.exe', [
      '-NoProfile',
      '-ExecutionPolicy', 'Bypass',
      '-File', script.path,
      '-ParentPid', '$parentPid',
      '-InstallDir', install.path,
      '-StagingDir', staging.path,
      '-ExeName', 'Loop.exe',
      '-BackupDir', backup,
      '-LogPath', log,
      '-NoRestart',
    ]);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect(File(p.join(install.path, 'Loop.exe')).readAsStringSync(), 'new-exe');
    expect(File(p.join(install.path, 'version.json')).existsSync(), isTrue);
    expect(File(p.join(install.path, 'data', 'flutter_assets', 'keep.txt')).existsSync(), isTrue);
    expect(File(p.join(install.path, 'data', 'flutter_assets', 'new.txt')).existsSync(), isTrue);
    expect(File(p.join(install.path, 'data', 'loop.db')).readAsStringSync(), 'user-db');
    expect(File(p.join(install.path, 'data', 'subjects', 's1', 'loop.db')).existsSync(), isTrue);
    expect(File(p.join(backup, 'Loop.exe')).readAsStringSync(), 'old-exe');
    expect(File(p.join(backup, 'data', 'loop.db')).existsSync(), isFalse);
    expect(Directory(p.join(backup, 'data', 'subjects')).existsSync(), isFalse);
    expect(File(log).readAsStringSync(), contains('update done'));
  });
}