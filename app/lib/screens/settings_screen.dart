import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../backend/llm.dart';
import '../state.dart';
import '../update/app_version.dart';
import '../update/update_ui.dart';
import '../theme.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.active, this.state});

  final bool active;

  /// 可选注入，便于测试；生产环境使用全局 [appState]。
  final AppState? state;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final TextEditingController _keyController = TextEditingController();
  final TextEditingController _baseController = TextEditingController();
  final TextEditingController _modelController = TextEditingController();
  final TextEditingController _reasonController = TextEditingController();

  List<ProviderProfile> _providers = const [];
  String _activeProvider = 'deepseek';
  String _selectedProvider = 'deepseek';
  bool _vision = false;
  bool _tools = true;
  bool _streamUsage = false;
  bool _reasoning = false;
  ThinkingStyle _thinkingStyle = ThinkingStyle.none;

  bool _saving = false;
  bool _testing = false;
  String? _testResult;
  bool _testOk = false;
  bool _checkingUpdate = false;

  AppState get _state => widget.state ?? appState;

  ProviderProfile? get _selected {
    for (final item in _providers) {
      if (item.id == _selectedProvider) return item;
    }
    return _providers.isEmpty ? null : _providers.first;
  }

  @override
  void initState() {
    super.initState();
    _syncFromState();
  }

  @override
  void didUpdateWidget(covariant SettingsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) {
      _state.refreshSettings().then((_) {
        if (mounted) _syncFromState();
      });
    }
  }

  void _syncFromState() {
    final settings = _state.settings;
    if (settings == null) return;
    final byId = <String, ProviderProfile>{
      for (final item in ProviderRegistry.builtIns()) item.id: item,
    };
    for (final item in ProviderRegistry.decodeStored(settings.providersJson)) {
      byId[item.id] = item;
    }
    _providers = byId.values.toList();
    _activeProvider = byId.containsKey(settings.activeProvider)
        ? settings.activeProvider
        : ProviderRegistry.defaultProviderId;
    if (!byId.containsKey(_selectedProvider)) {
      _selectedProvider = _activeProvider;
    }
    _loadSelected();
    if (mounted) setState(() {});
  }

  void _loadSelected() {
    final profile = _selected;
    if (profile == null) return;
    _keyController.clear();
    _baseController.text = profile.baseUrl;
    _modelController.text = profile.defaultModel;
    _reasonController.text = profile.reasonModel;
    _vision = profile.capabilities.vision;
    _tools = profile.capabilities.tools;
    _streamUsage = profile.capabilities.streamUsage;
    _reasoning = profile.capabilities.reasoning;
    _thinkingStyle = profile.thinkingStyle;
  }

  String _providersJson() =>
      jsonEncode([for (final item in _providers) item.toJson()]);

  void _snack(String message, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message,
          style: TextStyle(color: error ? Colors.white : pal.toastFg)),
      backgroundColor: error ? pal.danger : pal.toastBg,
    ));
  }

  Future<bool> _persist({bool silent = false}) async {
    final profile = _selected;
    if (profile == null) return false;
    final typedKey = _keyController.text.trim();
    final modelText = _modelController.text.trim();
    final updated = profile.copyWith(
      baseUrl: _baseController.text.trim(),
      apiKey: typedKey.isEmpty ? profile.apiKey : typedKey,
      defaultModel: modelText.isEmpty ? profile.defaultModel : modelText,
      reasonModel: _reasonController.text.trim(),
      capabilities: ProviderCapabilities(
        vision: _vision,
        tools: _tools,
        streamUsage: _streamUsage,
        reasoning: _reasoning,
      ),
      thinkingStyle: _thinkingStyle,
    );
    final index = _providers.indexWhere((item) => item.id == updated.id);
    if (index >= 0) _providers[index] = updated;
    try {
      await _state.api.saveSettings(
        activeProvider: _activeProvider,
        providersJson: _providersJson(),
      );
      _keyController.clear();
      await _state.refreshSettings();
      if (mounted) setState(() {});
      if (!silent) _snack('供应商配置已保存');
      return true;
    } catch (error) {
      if (!silent) _snack(error.toString(), error: true);
      return false;
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    await _persist();
    if (mounted) setState(() => _saving = false);
  }

  Future<void> _test() async {
    setState(() {
      _testing = true;
      _testResult = null;
    });
    final saved = await _persist(silent: true);
    if (!saved) {
      if (mounted) setState(() => _testing = false);
      _snack('请先填写并保存供应商配置', error: true);
      return;
    }
    try {
      final result = await _state.api.testSettings(providerId: _selectedProvider);
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

  Future<void> _setActive() async {
    setState(() => _activeProvider = _selectedProvider);
    await _persist(silent: true);
    _snack('已切换为当前供应商');
  }

  Future<void> _addProvider() async {
    final id = 'custom_${DateTime.now().millisecondsSinceEpoch}';
    final profile = ProviderProfile(
      id: id,
      name: '自定义供应商',
      baseUrl: 'https://api.openai.com/v1',
      defaultModel: 'gpt-4o-mini',
      capabilities: const ProviderCapabilities(
        vision: true,
        tools: true,
        streamUsage: true,
      ),
      models: const [ModelInfo(id: 'gpt-4o-mini', label: '示例模型')],
    );
    setState(() {
      _providers = [..._providers, profile];
      _selectedProvider = id;
      _loadSelected();
    });
    await _persist(silent: true);
  }

  Future<void> _removeProvider() async {
    final profile = _selected;
    if (profile == null || profile.builtIn) return;
    setState(() {
      _providers = [
        for (final item in _providers)
          if (item.id != profile.id) item,
      ];
      if (_activeProvider == profile.id) {
        _activeProvider = ProviderRegistry.defaultProviderId;
      }
      _selectedProvider = _activeProvider;
      _loadSelected();
    });
    await _persist(silent: true);
    _snack('已删除自定义供应商');
  }

  @override
  void dispose() {
    _keyController.dispose();
    _baseController.dispose();
    _modelController.dispose();
    _reasonController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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
                                selected: {_state.themeMode},
                                showSelectedIcon: false,
                                onSelectionChanged: (value) => _state.setTheme(value.first),
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
                          const Text('对话与模型',
                              style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600)),
                          Material(
                            type: MaterialType.transparency,
                            child: SwitchListTile(
                              contentPadding: EdgeInsets.zero,
                              dense: true,
                              title: const Text('流式输出', style: TextStyle(fontSize: 13)),
                              subtitle: Text(
                                '开启后逐字显示；关闭后等待完整回复；对下一条消息生效。',
                                style: TextStyle(fontSize: 11.5, height: 1.5, color: pal.muted),
                              ),
                              value: _state.settings?.streamOutput ?? true,
                              onChanged: (value) async {
                                final messenger = ScaffoldMessenger.of(context);
                                final ok = await _state.setStreamOutput(value);
                                if (!mounted) return;
                                setState(() {});
                                if (!ok) {
                                  messenger.showSnackBar(SnackBar(
                                    content: Text('流式设置保存失败，已恢复原状态'),
                                    backgroundColor: pal.danger,
                                  ));
                                }
                              },
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
                          Row(
                            children: [
                              const Text('AI 供应商',
                                  style:
                                      TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600)),
                              const SizedBox(width: 8),
                              Container(
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                decoration: BoxDecoration(
                                  color: pal.chip,
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                child: Text(
                                  _selected?.id == _activeProvider ? '当前使用' : '未使用',
                                  style: TextStyle(
                                    fontSize: 10.5,
                                    color: _selected?.id == _activeProvider
                                        ? pal.accent
                                        : pal.muted,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text('每个供应商独立保存 Key；Key 只存在本机 SQLite，不会上传。',
                              style: TextStyle(fontSize: 11.5, color: pal.muted)),
                          const SizedBox(height: 14),
                          Row(
                            children: [
                              Expanded(
                                child: DropdownButtonFormField<String>(
                                  initialValue: _selected?.id,
                                  decoration: const InputDecoration(labelText: '供应商'),
                                  items: [
                                    for (final item in _providers)
                                      DropdownMenuItem(
                                        value: item.id,
                                        child: Text(
                                          '${item.name}${item.id == _activeProvider ? ' · 当前' : ''}',
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                  ],
                                  onChanged: (value) {
                                    if (value == null) return;
                                    setState(() {
                                      _selectedProvider = value;
                                      _loadSelected();
                                    });
                                  },
                                ),
                              ),
                              const SizedBox(width: 10),
                              OutlinedButton.icon(
                                onPressed: _addProvider,
                                icon: const Icon(Icons.add_rounded, size: 16),
                                label: const Text('自定义'),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              FilterChip(
                                label: const Text('图片'),
                                selected: _vision,
                                onSelected: (value) => setState(() => _vision = value),
                              ),
                              FilterChip(
                                label: const Text('工具'),
                                selected: _tools,
                                onSelected: (value) => setState(() => _tools = value),
                              ),
                              FilterChip(
                                label: const Text('思考'),
                                selected: _reasoning,
                                onSelected: (value) => setState(() => _reasoning = value),
                              ),
                              FilterChip(
                                label: const Text('流式用量'),
                                selected: _streamUsage,
                                onSelected: (value) => setState(() => _streamUsage = value),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          DropdownButtonFormField<ThinkingStyle>(
                            initialValue: _thinkingStyle,
                            decoration: const InputDecoration(labelText: '思考参数形态'),
                            items: const [
                              DropdownMenuItem(
                                value: ThinkingStyle.none,
                                child: Text('不发送思考参数'),
                              ),
                              DropdownMenuItem(
                                value: ThinkingStyle.deepseek,
                                child: Text('DeepSeek 形态'),
                              ),
                              DropdownMenuItem(
                                value: ThinkingStyle.zhipu,
                                child: Text('智谱 GLM 形态'),
                              ),
                              DropdownMenuItem(
                                value: ThinkingStyle.openaiEffort,
                                child: Text('reasoning_effort'),
                              ),
                              DropdownMenuItem(
                                value: ThinkingStyle.custom,
                                child: Text('自定义 extra body'),
                              ),
                            ],
                            onChanged: (value) {
                              if (value != null) setState(() => _thinkingStyle = value);
                            },
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: _keyController,
                            obscureText: true,
                            decoration: InputDecoration(
                              labelText: 'API Key',
                              hintText: (_selected?.apiKey.isNotEmpty ?? false)
                                  ? '已保存：${_selected!.maskedKey}（留空则不修改）'
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
                          TextField(
                            controller: _modelController,
                            decoration: const InputDecoration(labelText: '对话模型 ID'),
                          ),
                          if (_selected?.models.isNotEmpty ?? false) ...[
                            const SizedBox(height: 6),
                            Wrap(
                              spacing: 6,
                              runSpacing: 6,
                              children: [
                                for (final info in _selected!.models.take(8))
                                  ActionChip(
                                    label: Text(info.id,
                                        style: const TextStyle(fontSize: 11)),
                                    onPressed: () => setState(
                                        () => _modelController.text = info.id),
                                  ),
                              ],
                            ),
                          ],
                          const SizedBox(height: 12),
                          TextField(
                            controller: _reasonController,
                            decoration: const InputDecoration(
                              labelText: '推理模型 ID（可留空）',
                            ),
                          ),
                          const SizedBox(height: 16),
                          Wrap(
                            spacing: 10,
                            runSpacing: 10,
                            children: [
                              FilledButton(
                                onPressed: _saving ? null : _save,
                                child: Text(_saving ? '保存中…' : '保存'),
                              ),
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
                              OutlinedButton(
                                onPressed: _selected?.id == _activeProvider
                                    ? null
                                    : _setActive,
                                child: const Text('设为当前'),
                              ),
                              if (!(_selected?.builtIn ?? true))
                                TextButton(
                                  onPressed: _removeProvider,
                                  child: const Text('删除'),
                                ),
                            ],
                          ),
                          if (_testResult != null) ...[
                            const SizedBox(height: 12),
                            Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: pal.chip,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                _testResult!,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: _testOk ? pal.accent : pal.danger,
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
                          Material(
                            type: MaterialType.transparency,
                            child: SwitchListTile(
                              contentPadding: EdgeInsets.zero,
                              dense: true,
                              title: const Text('启动时自动检查更新',
                                  style: TextStyle(fontSize: 12.5)),
                              value: _state.settings?.autoCheckUpdates ?? true,
                              onChanged: (value) async {
                                await _state.setAutoCheckUpdates(value);
                                if (mounted) setState(() {});
                              },
                            ),
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
                          _row('本地服务', _state.api.baseUrl),
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
