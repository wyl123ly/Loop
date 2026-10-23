import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loop/update/app_version.dart';
import 'package:loop/update/update_service.dart';

void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('loop_update_test_');
    UpdateService.updatesDirOverride = temp.path;
  });

  tearDown(() {
    UpdateService.updatesDirOverride = null;
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  test('语义版本比较', () {
    expect(AppVersion.compare('v0.3.1', '0.3.0'), 1);
    expect(AppVersion.compare('0.3.0', 'v0.3.0'), 0);
    expect(AppVersion.compare('0.2.9', '0.3.0'), -1);
    expect(AppVersion.compare('1.0.0-beta', '1.0.0'), -1);
    expect(AppVersion.isNewer('0.3.1'), isTrue);
  });

  test('Release 解析固定附件', () {
    final info = UpdateService.parseLatest({
      'tag_name': 'v0.3.1',
      'body': 'notes',
      'assets': [
        {'name': 'other.zip', 'browser_download_url': 'https://example.com/other.zip'},
        {
          'name': 'Loop-Desktop-win64.zip',
          'browser_download_url': 'https://example.com/loop.zip',
          'size': 123,
          'digest': 'sha256:abc',
        },
      ],
    });
    expect(info.version, '0.3.1');
    expect(info.assetUrl, 'https://example.com/loop.zip');
    expect(info.assetSize, 123);
  });

  test('解压校验版本并移除用户数据', () async {
    final archive = Archive();
    final version = utf8.encode(jsonEncode({'version': '0.3.1'}));
    archive.addFile(ArchiveFile('Loop.exe', 4, [77, 90, 0, 0]));
    archive.addFile(ArchiveFile('version.json', version.length, version));
    archive.addFile(ArchiveFile('data/loop.db', 3, [1, 2, 3]));
    final zip = File('${temp.path}/update.zip')
      ..writeAsBytesSync(ZipEncoder().encode(archive));
    final info = const UpdateInfo(
      version: '0.3.1',
      tag: 'v0.3.1',
      notes: '',
      assetName: 'Loop-Desktop-win64.zip',
      assetUrl: '',
      assetSize: 0,
      digest: '',
      publishedAt: '',
    );
    final staging = await UpdateService.stage(zip, info);
    expect(File('${staging.path}/Loop.exe').existsSync(), isTrue);
    expect(File('${staging.path}/data/loop.db').existsSync(), isFalse);
  });

  test('下载并校验 SHA-256', () async {
    final archive = Archive();
    final version = utf8.encode(jsonEncode({'version': '0.3.1'}));
    archive.addFile(ArchiveFile('Loop.exe', 4, [77, 90, 0, 0]));
    archive.addFile(ArchiveFile('version.json', version.length, version));
    final bytes = ZipEncoder().encode(archive);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response.headers.contentType = ContentType('application', 'zip');
      request.response.contentLength = bytes.length;
      request.response.add(bytes);
      await request.response.close();
    });
    final info = UpdateInfo(
      version: '0.3.1',
      tag: 'v0.3.1',
      notes: '',
      assetName: 'Loop-Desktop-win64.zip',
      assetUrl: 'http://127.0.0.1:${server.port}/Loop.zip',
      assetSize: bytes.length,
      digest: 'sha256:${sha256.convert(bytes)}',
      publishedAt: '',
    );
    final file = await UpdateService.download(info);
    expect(file.existsSync(), isTrue);
    expect(file.lengthSync(), bytes.length);
    await server.close(force: true);
  });
}
