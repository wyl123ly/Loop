import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'app_version.dart';

class UpdateInfo {
  const UpdateInfo({
    required this.version,
    required this.tag,
    required this.notes,
    required this.assetName,
    required this.assetUrl,
    required this.assetSize,
    required this.digest,
    required this.publishedAt,
  });

  final String version;
  final String tag;
  final String notes;
  final String assetName;
  final String assetUrl;
  final int assetSize;
  final String digest;
  final String publishedAt;

  bool get hasDigest => digest.startsWith('sha256:');
}

class UpdateException implements Exception {
  const UpdateException(this.message);
  final String message;

  @override
  String toString() => message;
}

class UpdateCancelled implements Exception {
  const UpdateCancelled();
}

class UpdateService {
  static const _defaultApi = 'https://api.github.com/repos/${AppVersion.repo}/releases/latest';

  static String get apiEndpoint {
    final override = Platform.environment['LOOP_UPDATE_API'];
    return override == null || override.isEmpty ? _defaultApi : override;
  }

  static String? updatesDirOverride;

  static String get updatesDir {
    final override = updatesDirOverride;
    if (override != null && override.isNotEmpty) {
      Directory(override).createSync(recursive: true);
      return override;
    }
    final local = Platform.environment['LOCALAPPDATA'];
    final base = (local == null || local.isEmpty)
        ? Directory(p.join(Directory.systemTemp.path, 'LoopUpdater'))
        : Directory(p.join(local, 'Loop', 'updates'));
    base.createSync(recursive: true);
    return base.path;
  }

  static Future<UpdateInfo?> checkLatest({http.Client? client}) async {
    final httpClient = client ?? http.Client();
    try {
      final response = await httpClient.get(
        Uri.parse(apiEndpoint),
        headers: const {
          'Accept': 'application/vnd.github+json',
          'User-Agent': 'Loop-Desktop-Updater',
        },
      ).timeout(const Duration(seconds: 12));
      if (response.statusCode == 404) {
        throw const UpdateException('仓库还没有发布 Release');
      }
      if (response.statusCode == 403 || response.statusCode == 429) {
        throw const UpdateException('GitHub API 访问频率受限，请稍后再试');
      }
      if (response.statusCode != 200) {
        throw UpdateException('检查更新失败（HTTP ${response.statusCode}）');
      }
      final data = jsonDecode(utf8.decode(response.bodyBytes));
      if (data is! Map<String, dynamic>) {
        throw const UpdateException('GitHub 返回格式异常');
      }
      return parseLatest(data);
    } on TimeoutException {
      throw const UpdateException('连接 GitHub 超时，请检查网络');
    } on SocketException {
      throw const UpdateException('连不上 GitHub，请检查网络或代理');
    } finally {
      if (client == null) httpClient.close();
    }
  }

  static UpdateInfo parseLatest(Map<String, dynamic> data) {
    final tag = (data['tag_name'] ?? '').toString();
    final version = AppVersion.normalize(tag);
    if (version.isEmpty) throw const UpdateException('Release 缺少版本号');
    final assets = (data['assets'] as List? ?? []).whereType<Map>().toList();
    Map? chosen;
    for (final asset in assets) {
      if ((asset['name'] ?? '').toString() == AppVersion.assetName) {
        chosen = asset;
        break;
      }
    }
    chosen ??= assets.where((asset) {
      final name = (asset['name'] ?? '').toString().toLowerCase();
      return name.endsWith('.zip') && name.contains('win64');
    }).firstOrNull;
    if (chosen == null) {
      throw const UpdateException('Release 里没有找到 ${AppVersion.assetName}');
    }
    final assetUrl = (chosen['browser_download_url'] ?? '').toString();
    if (assetUrl.isEmpty) throw const UpdateException('Release 附件缺少下载地址');
    return UpdateInfo(
      version: version,
      tag: tag,
      notes: (data['body'] ?? '').toString(),
      assetName: (chosen['name'] ?? '').toString(),
      assetUrl: assetUrl,
      assetSize: (chosen['size'] as num?)?.toInt() ?? 0,
      digest: (chosen['digest'] ?? '').toString(),
      publishedAt: (data['published_at'] ?? '').toString(),
    );
  }

  static Future<File> download(
    UpdateInfo info, {
    void Function(int received, int total)? onProgress,
    bool Function()? isCancelled,
    http.Client? client,
  }) async {
    final httpClient = client ?? http.Client();
    final target = File(p.join(updatesDir, 'Loop-${info.version}.zip'));
    if (target.existsSync()) target.deleteSync();
    try {
      final request = http.Request('GET', Uri.parse(info.assetUrl));
      request.headers['User-Agent'] = 'Loop-Desktop-Updater';
      final response = await httpClient.send(request).timeout(const Duration(seconds: 20));
      if (response.statusCode >= 400) {
        throw UpdateException('下载更新失败（HTTP ${response.statusCode}）');
      }
      final sink = target.openWrite();
      var received = 0;
      final total = response.contentLength ?? info.assetSize;
      try {
        await for (final chunk in response.stream) {
          if (isCancelled?.call() == true) throw const UpdateCancelled();
          sink.add(chunk);
          received += chunk.length;
          onProgress?.call(received, total);
        }
      } catch (error) {
        await sink.close();
        if (target.existsSync()) target.deleteSync();
        if (error is UpdateCancelled) throw const UpdateCancelled();
        rethrow;
      }
      await sink.close();
      if (info.assetSize > 0 && received != info.assetSize) {
        target.deleteSync();
        throw const UpdateException('更新包大小不一致，可能下载不完整');
      }
      if (info.hasDigest) {
        final actual = sha256.convert(await target.readAsBytes()).toString();
        final expected = info.digest.substring('sha256:'.length).toLowerCase();
        if (actual != expected) {
          target.deleteSync();
          throw const UpdateException('更新包校验失败（SHA-256 不匹配）');
        }
      }
      return target;
    } on TimeoutException {
      throw const UpdateException('下载更新超时');
    } on SocketException {
      throw const UpdateException('下载更新时网络断开');
    } finally {
      if (client == null) httpClient.close();
    }
  }

  static Future<Directory> stage(File zip, UpdateInfo info) async {
    final staging = Directory(p.join(updatesDir, 'staging-${info.version}'));
    if (staging.existsSync()) staging.deleteSync(recursive: true);
    staging.createSync(recursive: true);
    try {
      final archive = ZipDecoder().decodeBytes(await zip.readAsBytes());
      for (final entry in archive) {
        final name = p.normalize(entry.name);
        if (name.startsWith('..') || p.isAbsolute(name)) {
          throw const UpdateException('更新包包含非法路径');
        }
        final target = p.normalize(p.join(staging.path, name));
        if (!p.isWithin(staging.path, target) && target != staging.path) {
          throw const UpdateException('更新包包含非法路径');
        }
        if (entry.isFile) {
          final file = File(target);
          file.parent.createSync(recursive: true);
          file.writeAsBytesSync(entry.content as List<int>);
        } else {
          Directory(target).createSync(recursive: true);
        }
      }
      final exe = File(p.join(staging.path, 'Loop.exe'));
      if (!exe.existsSync()) throw const UpdateException('更新包里没有 Loop.exe');
      final versionFile = File(p.join(staging.path, 'version.json'));
      if (!versionFile.existsSync()) throw const UpdateException('更新包里没有 version.json');
      final versionData = jsonDecode(versionFile.readAsStringSync());
      final packaged = AppVersion.normalize((versionData is Map ? versionData['version'] : '').toString());
      if (packaged != info.version) {
        throw UpdateException('更新包版本 $packaged 与 Release 版本 ${info.version} 不一致');
      }
      for (final path in ['data/loop.db', 'data/files', 'data/uploads']) {
        final item = FileSystemEntity.typeSync(p.join(staging.path, path));
        if (item == FileSystemEntityType.directory) {
          Directory(p.join(staging.path, path)).deleteSync(recursive: true);
        } else if (item == FileSystemEntityType.file) {
          File(p.join(staging.path, path)).deleteSync();
        }
      }
      return staging;
    } catch (error) {
      if (staging.existsSync()) staging.deleteSync(recursive: true);
      if (error is UpdateException) rethrow;
      throw UpdateException('解压更新包失败：$error');
    }
  }

  static Future<void> launchInstaller(Directory staging, UpdateInfo info) async {
    if (kDebugMode) {
      throw const UpdateException('开发模式不执行自动替换，请在 release 版测试');
    }
    final installDir = File(Platform.resolvedExecutable).parent.path;
    try {
      final probe = File(p.join(installDir, '.loop_write_test'));
      probe.writeAsStringSync('ok');
      probe.deleteSync();
    } catch (_) {
      throw const UpdateException('安装目录不可写，请把 Loop 放到用户目录后重试');
    }
    final script = await rootBundle.loadString('assets/updater.ps1');
    final scriptFile = File(p.join(updatesDir, 'updater.ps1'));
    scriptFile.writeAsStringSync(script);
    final backup = p.join(updatesDir, 'backup-${AppVersion.current}-${DateTime.now().millisecondsSinceEpoch}');
    final log = p.join(updatesDir, 'update.log');
    final process = await Process.start(
      'powershell.exe',
      [
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', scriptFile.path,
        '-ParentPid', '$pid',
        '-InstallDir', installDir,
        '-StagingDir', staging.path,
        '-ExeName', 'Loop.exe',
        '-BackupDir', backup,
        '-LogPath', log,
      ],
      mode: ProcessStartMode.detached,
    );
    // detached 进程不一定有输出；保留引用避免被过早回收。
    unawaited(process.exitCode);
  }
}
