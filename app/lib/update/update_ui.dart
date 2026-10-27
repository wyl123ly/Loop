import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../state.dart';
import '../theme.dart';
import 'app_version.dart';
import 'update_service.dart';

final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

Future<void> checkForUpdatesOnStartup() async {
  if (!Platform.isWindows) return;
  await Future<void>.delayed(const Duration(seconds: 4));
  for (var i = 0; i < 30 && !appState.ready; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
  if (!appState.ready || appState.settings?.autoCheckUpdates == false) return;
  final context = rootNavigatorKey.currentContext;
  if (context == null) return;
  if (!context.mounted) return;
  await checkForUpdates(context, manual: false);
}

Future<void> checkForUpdates(BuildContext context, {required bool manual}) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    final info = await UpdateService.checkLatest();
    if (info == null || !context.mounted) return;
    if (!AppVersion.isNewer(info.version)) {
      if (manual) {
        messenger.showSnackBar(SnackBar(
          content: Text('已是最新版本 v${AppVersion.current}',
              style: TextStyle(color: pal.toastFg)),
          backgroundColor: pal.toastBg,
        ));
      }
      return;
    }
    final accepted = await showDialog<bool>(
      context: context,
      builder: (_) => _UpdateAvailableDialog(info: info),
    );
    if (accepted == true && context.mounted) {
      final installed = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _ProgressDialog(info: info),
      );
      if (installed == true) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        exit(0);
      }
    }
  } catch (error) {
    if (!manual || !context.mounted) {
      debugPrint('update check failed: $error');
      return;
    }
    messenger.showSnackBar(SnackBar(
      content: Text(error.toString(), style: TextStyle(color: pal.onPrimaryBtn)),
      backgroundColor: pal.dangerInk,
    ));
  }
}

class _UpdateAvailableDialog extends StatelessWidget {
  const _UpdateAvailableDialog({required this.info});

  final UpdateInfo info;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 48, vertical: 32),
      child: Container(
        width: 580,
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
        decoration: panelDecoration(color: pal.cardSolid, radius: LoopRadius.panel),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(color: pal.chip, borderRadius: BorderRadius.circular(LoopRadius.control)),
                  child: Icon(Icons.system_update_alt_rounded, size: 19, color: pal.accent),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('发现新版本 v${info.version}',
                          style: TextStyle(fontSize: LoopType.title, fontWeight: FontWeight.w700, color: pal.ink)),
                      Text('当前 v${AppVersion.current} · ${info.tag}',
                          style: TextStyle(fontSize: LoopType.caption, color: pal.muted)),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Text('更新说明',
                style: TextStyle(fontSize: LoopType.secondary, fontWeight: FontWeight.w600, color: pal.muted)),
            const SizedBox(height: 6),
            Container(
              width: double.infinity,
              constraints: const BoxConstraints(maxHeight: 230),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: pal.codeBg,
                borderRadius: BorderRadius.circular(LoopRadius.control),
                border: Border.all(color: pal.border),
              ),
              child: SingleChildScrollView(
                child: SelectableText(
                  info.notes.trim().isEmpty ? '（没有填写更新说明）' : info.notes.trim(),
                  style: TextStyle(fontSize: LoopType.secondary, height: 1.6, color: pal.ink),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: Text('稍后', style: TextStyle(color: pal.muted)),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: () => Navigator.pop(context, true),
                  icon: const Icon(Icons.download_rounded, size: 16),
                  label: const Text('立即更新'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ProgressDialog extends StatefulWidget {
  const _ProgressDialog({required this.info});

  final UpdateInfo info;

  @override
  State<_ProgressDialog> createState() => _ProgressDialogState();
}

class _ProgressDialogState extends State<_ProgressDialog> {
  double _progress = 0;
  int _received = 0;
  int _total = 0;
  String _stage = '正在下载更新…';
  String? _error;
  bool _cancelled = false;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  Future<void> _run() async {
    try {
      final file = await UpdateService.download(
        widget.info,
        isCancelled: () => _cancelled,
        onProgress: (received, total) {
          if (!mounted) return;
          setState(() {
            _received = received;
            _total = total;
            _progress = total > 0 ? (received / total).clamp(0.0, 1.0) : 0;
          });
        },
      );
      if (_cancelled) {
        if (mounted) Navigator.pop(context, false);
        return;
      }
      if (mounted) setState(() => _stage = '正在校验并解压…');
      final staging = await UpdateService.stage(file, widget.info);
      if (_cancelled) {
        if (mounted) Navigator.pop(context, false);
        return;
      }
      if (mounted) setState(() => _stage = '正在准备重启安装…');
      await UpdateService.launchInstaller(staging, widget.info);
      if (!mounted) return;
      setState(() => _done = true);
      Navigator.pop(context, true);
    } on UpdateCancelled {
      if (mounted) Navigator.pop(context, false);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error.toString());
    }
  }

  /// 从 asset 直链推导 Release 页面，供自动更新失败时手动下载。
  String get _manualUrl {
    final url = widget.info.assetUrl;
    final index = url.indexOf('/releases/download/');
    if (index < 0) return url;
    return '${url.substring(0, index)}/releases/tag/${widget.info.tag}';
  }

  String _size(int bytes) {
    if (bytes > 1024 * 1024) return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    if (bytes > 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '$bytes B';
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      child: Container(
        width: 460,
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
        decoration: panelDecoration(color: pal.cardSolid, radius: LoopRadius.panel),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('更新到 v${widget.info.version}',
                style: TextStyle(fontSize: LoopType.title, fontWeight: FontWeight.w700, color: pal.ink)),
            const SizedBox(height: 6),
            Text(_stage, style: TextStyle(fontSize: LoopType.secondary, color: pal.muted)),
            const SizedBox(height: 16),
            if (_error == null) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(LoopRadius.pill),
                child: LinearProgressIndicator(
                  value: _total > 0 && _stage == '正在下载更新…' ? _progress : null,
                  minHeight: 6,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                _total > 0 ? '${_size(_received)} / ${_size(_total)}' : _size(_received),
                style: TextStyle(fontSize: LoopType.caption, color: pal.muted),
              ),
            ] else ...[
              Text(_error!, style: TextStyle(fontSize: LoopType.secondary, height: 1.5, color: pal.dangerInk)),
              if (_error!.contains('Process is detached')) ...[
                const SizedBox(height: 6),
                Text(
                  '自动替换没能启动，请点下方按钮手动下载新版本压缩包，解压覆盖当前目录即可。',
                  style: TextStyle(fontSize: LoopType.caption, height: 1.5, color: pal.muted),
                ),
              ],
            ],
            const SizedBox(height: 14),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (_error != null) ...[
                  TextButton.icon(
                    onPressed: () async {
                      final url = _manualUrl;
                      try {
                        await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
                      } catch (_) {}
                    },
                    icon: const Icon(Icons.download_rounded, size: 16),
                    label: const Text('打开下载页'),
                  ),
                  const SizedBox(width: 6),
                  FilledButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('关闭'),
                  ),
                ]
                else
                  TextButton(
                    onPressed: _done || _cancelled ? null : () => setState(() => _cancelled = true),
                    child: Text(_cancelled ? '正在取消…' : '取消', style: TextStyle(color: pal.muted)),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
