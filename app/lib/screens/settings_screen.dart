import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../state.dart';
import '../update/app_version.dart';
import '../update/update_ui.dart';
import '../theme.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.active});

  final bool active;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final TextEditingController _keyController = TextEditingController();
  final TextEditingController _baseController = TextEditingController();
  String _model = 'deepseek-flash';
  bool _saving = false;
  bool _testing = false;
  String? _testResult;
  bool _testOk = false;
  bool _checkingUpdate = false;

  @override
  void initState() {
    super.initState();
    _syncFromState();
  }

  @override
  void didUpdateWidget(covariant SettingsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) {
      appState.refreshSettings().then((_) {
        if (mounted) _syncFromState();
      });
    }
  }

  void _syncFromState() {
    final settings = appState.settings;
    if (settings == null) return;
    _baseController.text = settings.baseUrl;
    _model = settings.model;
    setState(() {});
  }

  @override
  void dispose() {
    _keyController.dispose();
    _baseController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await appState.api.saveSettings(
        apiKey: _keyController.text.trim(),
        baseUrl: _baseController.text.trim(),
        model: _model,
      );
      _keyController.clear();
      await appState.refreshSettings();
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('设置已保存', style: TextStyle(color: pal.toastFg)),
        backgroundColor: pal.toastBg,
      ));
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(error.toString()),
        backgroundColor: pal.danger,
      ));
    }
  }

  Future<void> _test() async {
    setState(() {
      _testing = true;
      _testResult = null;
    });
    try {
      final result = await appState.api.testSettings();
      if (!mounted) return;
      setState(() {
        _testOk = result['ok'] == true;
        _testResult = (result['message'] ?? '') as String;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _testOk = false;
        _testResult = error.toString();
      });
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = appState.settings;
    return Column(
      children: [
        Container(
          height: 78,
          padding: const EdgeInsets.fromLTRB(32, 20, 28, 6),
          child: Row(
            children: const [
              Text('设置', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700, letterSpacing: -0.5)),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(28, 24, 28, 40),
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 680),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(22),
                      decoration: panelDecoration(),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('外观',
                              style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: pal.ink)),
                          const SizedBox(height: 14),
                          Row(
                            children: [
                              Text('主题', style: TextStyle(fontSize: 13, color: pal.ink)),
                              const Spacer(),
                              SegmentedButton<ThemeMode>(
                                segments: const [
                                  ButtonSegment(value: ThemeMode.system, label: Text('跟随系统')),
                                  ButtonSegment(value: ThemeMode.light, label: Text('浅色')),
                                  ButtonSegment(value: ThemeMode.dark, label: Text('深色')),
                                ],
                                selected: {appState.themeMode},
                                showSelectedIcon: false,
                                onSelectionChanged: (value) => appState.setTheme(value.first),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.all(22),
                      decoration: panelDecoration(),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Text('DeepSeek 接入',
                                  style:
                                      TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600)),
                              const SizedBox(width: 8),
                              Container(
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                decoration: BoxDecoration(
                                  color: (settings?.hasKey ?? false)
                                      ? pal.chip
                                      : pal.chip,
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                child: Text(
                                  (settings?.hasKey ?? false) ? '已配置' : '未配置',
                                  style: TextStyle(
                                    fontSize: 10.5,
                                    color: (settings?.hasKey ?? false)
                                        ? pal.accent
                                        : pal.danger,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text('Key 只存在本机 SQLite，不会上传到任何第三方。',
                              style: TextStyle(fontSize: 11.5, color: pal.muted)),
                          const SizedBox(height: 16),
                          TextField(
                            controller: _keyController,
                            obscureText: true,
                            decoration: InputDecoration(
                              labelText: 'API Key',
                              hintText: settings?.apiKeyMasked.isNotEmpty == true
                                  ? '已保存：${settings!.apiKeyMasked}（留空则不修改）'
                                  : 'sk-...',
                            ),
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: _baseController,
                            decoration: const InputDecoration(
                              labelText: 'Base URL',
                              hintText: 'https://api.deepseek.com',
                            ),
                          ),
                          const SizedBox(height: 12),
                          DropdownButtonFormField<String>(
                            initialValue: _model,
                            decoration: const InputDecoration(labelText: '对话模型'),
                            items: const [
                              DropdownMenuItem(
                                value: 'deepseek-flash',
                                child: Text('deepseek-flash · 快、便宜、支持图片'),
                              ),
                              DropdownMenuItem(
                                value: 'deepseek-v4-pro',
                                child: Text('deepseek-v4-pro · 强推理，不支持图片'),
                              ),
                            ],
                            onChanged: (value) {
                              if (value != null) setState(() => _model = value);
                            },
                          ),
                          const SizedBox(height: 16),
                          Row(
                            children: [
                              FilledButton(
                                onPressed: _saving ? null : _save,
                                child: Text(_saving ? '保存中…' : '保存'),
                              ),
                              const SizedBox(width: 10),
                              OutlinedButton.icon(
                                onPressed: _testing ? null : _test,
                                icon: _testing
                                    ? const SizedBox(
                                        width: 12,
                                        height: 12,
                                        child: CircularProgressIndicator(strokeWidth: 2),
                                      )
                                    : const Icon(Icons.wifi_tethering_rounded, size: 16),
                                label: Text(_testing ? '测试中…' : '测试连接'),
                              ),
                            ],
                          ),
                          if (_testResult != null) ...[
                            const SizedBox(height: 12),
                            Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: _testOk
                                    ? pal.chip
                                    : pal.chip,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                _testResult!,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: _testOk
                                      ? pal.accent
                                      : pal.danger,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.all(22),
                      decoration: panelDecoration(),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Text('关于与更新',
                                  style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600)),
                              const Spacer(),
                              Text('v${AppVersion.current}',
                                  style: TextStyle(fontSize: 12, color: pal.muted)),
                            ],
                          ),
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  '从 GitHub Release 检查新版本；下载完成后自动替换并重启，资料库与笔记不受影响。',
                                  style: TextStyle(fontSize: 11.5, height: 1.6, color: pal.muted),
                                ),
                              ),
                              const SizedBox(width: 12),
                              FilledButton.icon(
                                onPressed: _checkingUpdate ? null : _checkUpdates,
                                icon: _checkingUpdate
                                    ? const SizedBox(
                                        width: 14,
                                        height: 14,
                                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                      )
                                    : const Icon(Icons.system_update_alt_rounded, size: 16),
                                label: Text(_checkingUpdate ? '检查中…' : '检查更新'),
                              ),
                            ],
                          ),
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            dense: true,
                            title: const Text('启动时自动检查更新',
                                style: TextStyle(fontSize: 12.5)),
                            value: appState.settings?.autoCheckUpdates ?? true,
                            onChanged: (value) async {
                              await appState.setAutoCheckUpdates(value);
                              if (mounted) setState(() {});
                            },
                          ),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: TextButton.icon(
                              onPressed: () => launchUrl(
                                Uri.parse('https://github.com/${AppVersion.repo}/releases'),
                                mode: LaunchMode.externalApplication,
                              ),
                              style: TextButton.styleFrom(
                                padding: EdgeInsets.zero,
                                visualDensity: VisualDensity.compact,
                              ),
                              icon: Icon(Icons.open_in_new_rounded, size: 14, color: pal.muted),
                              label: Text('手动下载 / Release 页面',
                                  style: TextStyle(fontSize: 11.5, color: pal.muted)),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.all(22),
                      decoration: panelDecoration(),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('运行信息',
                              style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600)),
                          const SizedBox(height: 12),
                          _row('本地服务', appState.api.baseUrl),
                          _row('数据位置', 'data/loop.db + data/files/'),
                          _row('版本', 'Loop ${AppVersion.current} · Dart 后端'),
                          const SizedBox(height: 10),
                          Text(
                            '后端在进程内运行，无需启动其他服务；数据备份 = 复制整个 data 目录。',
                            style: TextStyle(fontSize: 11.5, color: pal.muted, height: 1.6),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.all(22),
                      decoration: panelDecoration(),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: const [
                          Text('快捷键',
                              style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600)),
                          SizedBox(height: 10),
                          _Shortcut('Enter', '发送'),
                          _Shortcut('Shift + Enter', '换行'),
                          _Shortcut('侧栏「新对话」', '开一个新会话，上下文互不影响'),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _checkUpdates() async {
    setState(() => _checkingUpdate = true);
    try {
      await checkForUpdates(context, manual: true);
    } finally {
      if (mounted) setState(() => _checkingUpdate = false);
    }
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 80,
            child: Text(label, style: TextStyle(fontSize: 12, color: pal.muted)),
          ),
          Expanded(
            child: SelectableText(value,
                style: const TextStyle(fontSize: 12.5, fontFamily: 'monospace')),
          ),
        ],
      ),
    );
  }
}

class _Shortcut extends StatelessWidget {
  const _Shortcut(this.keys, this.label);

  final String keys;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Container(
            width: 150,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: pal.chip,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(keys,
                style: const TextStyle(fontSize: 11.5, fontFamily: 'monospace')),
          ),
          SizedBox(width: 12),
          Text(label, style: TextStyle(fontSize: 12.5, color: pal.muted)),
        ],
      ),
    );
  }
}
