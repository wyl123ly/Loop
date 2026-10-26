import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import '../update/update_ui.dart';
import 'cloud_restore_service.dart';
import 'cloud_snapshot_service.dart';
import 'cloud_sync_service.dart';

/// 退出时的云端同步协调器。
///
/// - 只有已配置、已登录且 auto_sync=true 才触发；
/// - 口令只保存在内存；没有口令时退出前询问；
/// - 上传期间显示不可关闭进度框；失败则中止退出并提示。
class CloudSyncCoordinator {
  CloudSyncCoordinator._();
  static final CloudSyncCoordinator instance = CloudSyncCoordinator._();

  final CloudSyncService cloud = CloudSyncService.instance;
  final ValueNotifier<String> progress = ValueNotifier('准备同步…');

  /// 本进程内用户输入过的同步口令；不落盘。
  String? passphrase;

  Future<bool> beforeExit() async {
    // 已下载待恢复时绝不上传旧数据，否则会覆盖云端最新快照。
    if (pendingCloudRestoreExists()) return true;
    final api = LoopApi();
    Map<String, dynamic> config;
    try {
      config = await api.cloudConfig();
    } catch (_) {
      return true; // 后端不可用时不阻塞退出
    }
    final url = (config['url'] ?? '').toString();
    final key = (config['key'] ?? '').toString();
    if (url.isEmpty || key.isEmpty) return true;
    if ((config['auto_sync'] ?? true) != true) return true;
    try {
      cloud.configure(url: url, key: key);
      final token = (config['refresh_token'] ?? '').toString();
      if (token.isNotEmpty) await cloud.restoreSession(token);
      if (!cloud.signedIn) return true;
      await cloud.registerDevice(
        deviceId: (config['device_id'] ?? '').toString(),
        deviceName: (config['device_name'] ?? 'Windows PC').toString(),
      );
    } catch (_) {
      return true;
    }
    if (passphrase == null || passphrase!.trim().length < 8) {
      final value = await _askPassphrase();
      if (value == null) return false;
      if (value.isEmpty) return true; // 用户选择跳过同步并退出
      passphrase = value;
    }
    final navigator = rootNavigatorKey.currentState;
    if (navigator == null) return true;
    unawaited(showDialog<void>(
      context: rootNavigatorKey.currentContext!,
      barrierDismissible: false,
      builder: (_) => _CloudExitDialog(progress: progress),
    ));
    await Future<void>.delayed(const Duration(milliseconds: 250));
    try {
      await CloudSnapshotService().uploadSnapshot(
        passphrase: passphrase!,
        lastSnapshotId: (config['last_snapshot'] ?? '').toString(),
        onProgress: (phase, done, total) {
          progress.value = switch (phase) {
            'snapshot' => '生成数据库快照…',
            'archive' => '打包资料…',
            'encrypt' => total > 0 ? '加密 $done/$total 块…' : '加密…',
            'upload' => total > 0 ? '上传 $done/$total 块…' : '上传…',
            _ => phase,
          };
        },
      );
      if (navigator.canPop()) navigator.pop();
      return true;
    } catch (error) {
      if (navigator.canPop()) navigator.pop();
      return await _showError(error.toString());
    }
  }

  Future<String?> _askPassphrase() async {
    final context = rootNavigatorKey.currentContext;
    if (context == null) return null;
    final controller = TextEditingController();
    try {
      return await showDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          title: const Text('退出前同步'),
          content: SizedBox(
            width: 360,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  '输入同步口令，把本次数据加密上传到云端；口令不会保存到磁盘。',
                  style: TextStyle(fontSize: 12),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: controller,
                  obscureText: true,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: '同步口令（至少 8 位）',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, ''),
              child: const Text('跳过同步并退出'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, controller.text),
              child: const Text('同步并退出'),
            ),
          ],
        ),
      );
    } finally {
      controller.dispose();
    }
  }

  Future<bool> _showError(String message) async {
    final context = rootNavigatorKey.currentContext;
    if (context == null) return true;
    return await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (context) => AlertDialog(
            title: const Text('同步失败'),
            content: Text(message, style: const TextStyle(fontSize: 12)),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('留在这里'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('跳过同步并退出'),
              ),
            ],
          ),
        ) ??
        false;
  }
}

class _CloudExitDialog extends StatelessWidget {
  const _CloudExitDialog({required this.progress});

  final ValueNotifier<String> progress;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('正在同步到云端'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ValueListenableBuilder<String>(
              valueListenable: progress,
              builder: (context, value, _) => Text(
                value,
                style: const TextStyle(fontSize: 12),
              ),
            ),
            const SizedBox(height: 14),
            const LinearProgressIndicator(),
            const SizedBox(height: 8),
            const Text(
              '同步完成后自动退出；期间请不要关闭 Loop。',
              style: TextStyle(fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }
}
