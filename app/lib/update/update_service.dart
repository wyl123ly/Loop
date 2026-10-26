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
  static const _defaultApi =
      'https://api.github.com/repos/${AppVersion.repo}/releases?per_page=10';

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
      if (data is List) {
        final releases = data
            .whereType<Map>()
            .map((item) => Map<String, dynamic>.from(item))
            .toList();
        return parseReleaseList(releases);
      }
      if (data is Map<String, dynamic>) {
        return parseLatest(data);
      }
      throw const UpdateException('GitHub 返回格式异常');
    } on TimeoutException {
      throw const UpdateException('连接 GitHub 超时，请检查网络');
    } on SocketException {
      throw const UpdateException('连不上 GitHub，请检查网络或代理');
    } finally {
      if (client == null) httpClient.close();
    }
  }

  /// 从 Release 列表里挑**最新且带可用附件**的一版：
  /// 最新 Release 还没上传 zip 时，自动回退到上一个有附件的版本。
  static UpdateInfo parseReleaseList(List<Map<String, dynamic>> releases) {
    final usable = releases.where((item) {
      return item['draft'] != true && item['prerelease'] != true;
    });
    for (final release in usable) {
      try {
        return parseLatest(release);
      } on UpdateException {
        continue;
      }
    }
    throw const UpdateException('最近的 Release 里都没有可用的 ${AppVersion.assetName}');
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
      _flattenSingleRoot(staging);
      final exe = _findEntryExe(staging);
      if (exe == null) throw const UpdateException('更新包里没有 Loop.exe');
      final versionFile = File(p.join(staging.path, 'version.json'));
      if (!versionFile.existsSync()) throw const UpdateException('更新包里没有 version.json');
      final versionData = jsonDecode(versionFile.readAsStringSync());
      final packaged = AppVersion.normalize((versionData is Map ? versionData['version'] : '').toString());
      if (packaged != info.version) {
        throw UpdateException('更新包版本 $packaged 与 Release 版本 ${info.version} 不一致');
      }
      _removeUserData(staging.path);
      return staging;
    } catch (error) {
      if (staging.existsSync()) staging.deleteSync(recursive: true);
      if (error is UpdateException) rethrow;
      throw UpdateException('解压更新包失败：$error');
    }
  }

  /// 更新包里的用户数据路径：即使误打进包里也在安装前删除，绝不覆盖本机数据。
  static const List<String> userDataPaths = [
    'data/loop.db',
    'data/loop.db-wal',
    'data/loop.db-shm',
    'data/files',
    'data/uploads',
    'data/subjects',
    'data/skills',
    'data/mcp',
    'data/logs',
    'data/tmp',
    'data/backups',
    'data/trash',
    'data/tray.ico',
  ];

  static void _removeUserData(String root) {
    for (final path in userDataPaths) {
      final target = p.join(root, path);
      final type = FileSystemEntity.typeSync(target);
      if (type == FileSystemEntityType.directory) {
        Directory(target).deleteSync(recursive: true);
      } else if (type == FileSystemEntityType.file) {
        File(target).deleteSync();
      }
    }
  }

  /// 有些打包工具会多包一层目录；把唯一子目录的内容提升到 staging 根。
  static void _flattenSingleRoot(Directory staging) {
    final entries = staging.listSync();
    if (entries.length != 1 || entries.first is! Directory) return;
    final inner = entries.first as Directory;
    for (final entity in inner.listSync()) {
      final target = p.join(staging.path, p.basename(entity.path));
      if (FileSystemEntity.typeSync(target) == FileSystemEntityType.notFound) {
        entity.renameSync(target);
      }
    }
    try {
      inner.deleteSync(recursive: true);
    } catch (_) {}
  }

  static File? _findEntryExe(Directory staging) {
    for (final name in ['Loop.exe', 'loop.exe']) {
      final file = File(p.join(staging.path, name));
      if (file.existsSync()) return file;
    }
    for (final entity in staging.listSync(recursive: true, followLinks: false)) {
      if (entity is File && p.basename(entity.path).toLowerCase() == 'loop.exe') {
        return entity;
      }
    }
    return null;
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
    await Process.start(
      'powershell.exe',
      [
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', scriptFile.path,
        '-ParentPid', '$pid',
        '-InstallDir', installDir,
        '-StagingDir', staging.path,
        '-ExeName', p.basename(Platform.resolvedExecutable),
        '-BackupDir', backup,
        '-LogPath', log,
      ],
      mode: ProcessStartMode.detached,
    );
    // 注意：detached 进程不能读取 exitCode，否则 Dart 抛
    // Bad state: Process is detached。这里只负责拉起 updater.ps1；
    // 脚本会等待父进程退出后再替换文件并重启 Loop。
  }
}
