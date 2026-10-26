import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import 'package:url_launcher/url_launcher.dart';

import '../backend/llm.dart';
import '../cloud/cloud_restore_service.dart';
import '../cloud/cloud_sync_coordinator.dart';
import '../cloud/cloud_snapshot_service.dart';
import '../cloud/cloud_sync_service.dart';
import '../desktop/window_controls.dart';
import '../models.dart';
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
  bool _fetchingModels = false;
  String? _testResult;
  bool _testOk = false;
  bool _checkingUpdate = false;

  // F-11：数据与迁移
  MigrationOverview? _migration;
  bool _migrationBusy = false;
  String? _migrationNote;

  // 云端同步（方案 B 第一阶段：连接/登录/设备）
  final CloudSyncService _cloud = CloudSyncService.instance;
  final TextEditingController _cloudUrlController = TextEditingController();
  final TextEditingController _cloudKeyController = TextEditingController();
  final TextEditingController _cloudDeviceController = TextEditingController();
  final TextEditingController _cloudEmailController = TextEditingController();
  final TextEditingController _cloudPasswordController = TextEditingController();
  final TextEditingController _cloudPassphraseController = TextEditingController();
  String _cloudDeviceId = '';
  String _cloudLastSnapshot = '';
  bool _cloudRestoreReady = false;
  bool _cloudSyncing = false;
  bool _cloudExpanded = false;
  String _cloudProgress = '';
  bool _cloudBusy = false;
  String? _cloudMessage;
  bool _cloudOk = false;

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
    _loadMigration();
    _loadCloudConfig();
  }

  // ------------------------------------------------------------ 云端同步（方案 B）

  Future<void> _loadCloudConfig() async {
    try {
      final config = await _state.api.cloudConfig();
      if (!mounted) return;
      var deviceId = (config['device_id'] ?? '').toString();
      if (deviceId.isEmpty) {
        deviceId = const Uuid().v4();
        await _state.api.saveCloudConfig(deviceId: deviceId);
      }
      final url = (config['url'] ?? '').toString();
      final key = (config['key'] ?? '').toString();
      setState(() {
        _cloudDeviceId = deviceId;
        _cloudLastSnapshot = (config['last_snapshot'] ?? '').toString();
        _cloudRestoreReady = pendingCloudRestoreExists();
        _cloudUrlController.text = url;
        _cloudKeyController.text = key;
        _cloudExpanded = url.isEmpty || key.isEmpty;
        _cloudDeviceController.text =
            (config['device_name'] ?? Platform.localHostname).toString();
      });
      if (url.isNotEmpty && key.isNotEmpty) {
        _cloud.configure(url: url, key: key);
        final refreshToken = (config['refresh_token'] ?? '').toString();
        if (refreshToken.isNotEmpty) {
          try {
            await _cloud.restoreSession(refreshToken);
            await _cloud.registerDevice(
              deviceId: deviceId,
              deviceName: _cloudDeviceController.text,
            );
          } catch (_) {}
        }
        if (mounted) {
          setState(() {
            _cloudMessage = _cloud.signedIn
                ? '已恢复登录：${_cloud.userEmail ?? ''}'
                : null;
            _cloudOk = _cloud.signedIn;
          });
        }
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _cloudOk = false;
        _cloudMessage = '读取云端配置失败：$error';
      });
    }
  }

  Future<bool> _saveCloudConfig() async {
    final url = _cloudUrlController.text.trim();
    final key = _cloudKeyController.text.trim();
    if (url.isEmpty || key.isEmpty) {
      setState(() {
        _cloudOk = false;
        _cloudMessage = '先填写 Supabase URL 和 publishable key。';
      });
      return false;
    }
    try {
      await _state.api.saveCloudConfig(
        url: url,
        key: key,
        deviceId: _cloudDeviceId,
        deviceName: _cloudDeviceController.text.trim(),
      );
      _cloud.configure(url: url, key: key);
      return true;
    } catch (error) {
      setState(() {
        _cloudOk = false;
        _cloudMessage = '保存失败：$error';
      });
      return false;
    }
  }

  Future<void> _testCloud() async {
    if (_cloudBusy) return;
    setState(() {
      _cloudBusy = true;
      _cloudMessage = null;
    });
    try {
      if (!await _saveCloudConfig()) return;
      await _cloud.testConnection();
      if (!mounted) return;
      setState(() {
        _cloudOk = true;
        _cloudMessage = '连接成功：Supabase URL、Key、Data API 正常。';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _cloudOk = false;
        _cloudMessage = '连接失败：$error';
      });
    } finally {
      if (mounted) setState(() => _cloudBusy = false);
    }
  }

  Future<void> _loginCloud() async {
    if (_cloudBusy) return;
    final email = _cloudEmailController.text.trim();
    final password = _cloudPasswordController.text;
    if (email.isEmpty || password.isEmpty) {
      setState(() {
        _cloudOk = false;
        _cloudMessage = '请输入测试账号邮箱和密码。';
      });
      return;
    }
    setState(() {
      _cloudBusy = true;
      _cloudMessage = null;
    });
    try {
      if (!await _saveCloudConfig()) return;
      await _cloud.signIn(email: email, password: password);
      await _cloud.registerDevice(
        deviceId: _cloudDeviceId,
        deviceName: _cloudDeviceController.text,
      );
      var storageNote = 'Storage 权限正常。';
      try {
        await _cloud.probeStorage();
      } catch (error) {
        storageNote = 'Storage 权限异常：$error';
      }
      await _state.api.saveCloudConfig(refreshToken: _cloud.refreshToken ?? '');
      final latest = await _cloud.latestSnapshot();
      if (!mounted) return;
      setState(() {
        _cloudOk = true;
        _cloudPasswordController.clear();
        _cloudMessage = latest == null
            ? '已登录 ${_cloud.userEmail ?? email}，设备已注册；$storageNote 云端还没有快照。'
            : '已登录 ${_cloud.userEmail ?? email}；$storageNote 云端最新快照：${latest['created_at']}';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _cloudOk = false;
        _cloudMessage = '登录失败：$error';
      });
    } finally {
      if (mounted) setState(() => _cloudBusy = false);
    }
  }

  Future<void> _uploadCloudSnapshot({bool force = false}) async {
    if (_cloudBusy || _cloudSyncing) return;
    final passphrase = _cloudPassphraseController.text;
    if (passphrase.trim().length < 8) {
      setState(() {
        _cloudOk = false;
        _cloudMessage = '同步口令至少 8 个字符；它不会上传到服务器。';
      });
      return;
    }
    CloudSyncCoordinator.instance.passphrase = passphrase;
    setState(() {
      _cloudSyncing = true;
      _cloudProgress = '准备快照…';
      _cloudMessage = null;
    });
    try {
      final result = await CloudSnapshotService().uploadSnapshot(
        passphrase: passphrase,
        lastSnapshotId: _cloudLastSnapshot,
        force: force,
        onProgress: (phase, done, total) {
          if (!mounted) return;
          setState(() {
            _cloudProgress = switch (phase) {
              'snapshot' => '生成数据库快照…',
              'archive' => '打包资料…',
              'encrypt' => total > 0 ? '加密 $done/$total 块…' : '加密…',
              'upload' => total > 0 ? '上传 $done/$total 块…' : '上传…',
              _ => phase,
            };
          });
        },
      );
      if (!mounted) return;
      _cloudLastSnapshot = result.snapshotId;
      await _state.api.saveCloudConfig(lastSnapshotId: result.snapshotId);
      if (!mounted) return;
      setState(() {
        _cloudOk = true;
        _cloudMessage =
            '快照已上传：${(result.bytes / 1024 / 1024).toStringAsFixed(1)} MB，${result.chunks} 块，用时 ${result.duration.inSeconds}s。';
      });
    } on CloudConflictException catch (conflict) {
      if (!mounted) return;
      setState(() {
        _cloudSyncing = false;
        _cloudOk = false;
        _cloudMessage = conflict.toString();
      });
      final override = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('云端有更新'),
          content: Text('${conflict.message}\n\n强制上传会用本机数据覆盖云端最新快照。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('强制覆盖'),
            ),
          ],
        ),
      );
      if (override == true && mounted) {
        await _uploadCloudSnapshot(force: true);
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _cloudOk = false;
        _cloudMessage = error.toString();
      });
    } finally {
      if (mounted) setState(() => _cloudSyncing = false);
    }
  }

  Future<void> _restoreCloudSnapshot() async {
    if (_cloudBusy || _cloudSyncing) return;
    final passphrase = _cloudPassphraseController.text;
    if (passphrase.trim().length < 8) {
      setState(() {
        _cloudOk = false;
        _cloudMessage = '同步口令至少 8 个字符。';
      });
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('从云端恢复'),
        content: const Text(
          '会下载最新快照，覆盖本机当前数据。下载完成后需要重启 Loop 才会真正替换；'
          '当前数据会先备份到 data/.backup。',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('下载')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _cloudSyncing = true;
      _cloudProgress = '读取云端快照…';
      _cloudMessage = null;
    });
    try {
      final result = await CloudRestoreService().downloadLatest(
        passphrase: passphrase,
        onProgress: (phase, done, total) {
          if (!mounted) return;
          setState(() {
            _cloudProgress = switch (phase) {
              'download' => total > 0 ? '下载 $done/$total 块…' : '下载…',
              'extract' => '解包快照…',
              'ready' => '已准备，等待重启…',
              _ => phase,
            };
          });
        },
      );
      if (!mounted) return;
      _cloudLastSnapshot = result.snapshotId;
      await _state.api.saveCloudConfig(lastSnapshotId: result.snapshotId);
      if (!mounted) return;
      setState(() {
        _cloudOk = true;
        _cloudRestoreReady = true;
        _cloudMessage =
            '已下载 ${(result.bytes / 1024 / 1024).toStringAsFixed(1)} MB；重启 Loop 后完成恢复。';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _cloudOk = false;
        _cloudMessage = error.toString();
      });
    } finally {
      if (mounted) setState(() => _cloudSyncing = false);
    }
  }

  Future<void> _logoutCloud() async {
    if (_cloudBusy) return;
    setState(() => _cloudBusy = true);
    try {
      await _cloud.signOut();
      await _state.api.saveCloudConfig(refreshToken: '');
      if (!mounted) return;
      setState(() {
        _cloudOk = true;
        _cloudMessage = '已退出云端账号；本地数据不受影响。';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _cloudOk = false;
        _cloudMessage = '退出失败：$error';
      });
    } finally {
      if (mounted) setState(() => _cloudBusy = false);
    }
  }

  Widget _cloudSyncCard() {
    final pal = LoopTheme.palette;
    final configured = _cloudUrlController.text.trim().isNotEmpty &&
        _cloudKeyController.text.trim().isNotEmpty;
    final status = _cloud.signedIn
        ? '已登录 ${_cloud.userEmail ?? ''}'
        : (configured ? '已配置，未登录' : '未配置');
    return Container(
      key: const Key('settings-cloud-sync'),
      decoration: panelDecoration(),
      child: Material(
        color: Colors.transparent,
        child: ExpansionTile(
        key: const Key('settings-cloud-expand'),
        initiallyExpanded: _cloudExpanded,
        onExpansionChanged: (value) => setState(() => _cloudExpanded = value),
        tilePadding: const EdgeInsets.symmetric(horizontal: 22, vertical: 6),
        childrenPadding: const EdgeInsets.fromLTRB(22, 0, 22, 22),
        title: Row(
          children: [
            const Text('云端同步',
                style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600)),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: pal.chip,
                borderRadius: BorderRadius.circular(7),
              ),
              child: Text(configured ? '方案 B' : '未配置',
                  style: TextStyle(fontSize: 10.5, color: pal.muted)),
            ),
            const Spacer(),
            Text(status, style: TextStyle(fontSize: 11.5, color: pal.muted)),
          ],
        ),
        subtitle: Text(
          _cloud.signedIn
              ? '退出时自动上传；只保留最新 2 份'
              : '单用户加密快照同步，点此展开配置',
          style: TextStyle(fontSize: 11, color: pal.faint),
        ),
        children: [
          Text(
            '本地 SQLite 为主；上传/恢复都使用同一同步口令加密。不是实时多端同时编辑。',
            style: TextStyle(fontSize: 11.5, height: 1.6, color: pal.muted),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('cloud-url'),
            controller: _cloudUrlController,
            decoration: const InputDecoration(
              labelText: 'Supabase URL',
              hintText: 'https://xxxx.supabase.co',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            key: const Key('cloud-key'),
            controller: _cloudKeyController,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'publishable / anon key',
              hintText: '不要填 service_role',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            key: const Key('cloud-device'),
            controller: _cloudDeviceController,
            decoration: const InputDecoration(
              labelText: '设备名称',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          if (!_cloud.signedIn) ...[
            const SizedBox(height: 8),
            TextField(
              key: const Key('cloud-email'),
              controller: _cloudEmailController,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(
                labelText: '账号邮箱',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              key: const Key('cloud-password'),
              controller: _cloudPasswordController,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: '账号密码（不保存）',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ],
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton(
                key: const Key('cloud-test'),
                onPressed: _cloudBusy ? null : _testCloud,
                child: const Text('测试云端连接'),
              ),
              if (!_cloud.signedIn)
                FilledButton(
                  key: const Key('cloud-login'),
                  onPressed: _cloudBusy ? null : _loginCloud,
                  child: Text(_cloudBusy ? '处理中…' : '登录并注册设备'),
                )
              else
                OutlinedButton(
                  key: const Key('cloud-logout'),
                  onPressed: (_cloudBusy || _cloudSyncing) ? null : _logoutCloud,
                  child: const Text('退出账号'),
                ),
            ],
          ),
          if (_cloud.signedIn) ...[
            const SizedBox(height: 12),
            TextField(
              key: const Key('cloud-passphrase'),
              controller: _cloudPassphraseController,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: '同步口令（本地加密，不上传）',
                hintText: '至少 8 个字符',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  key: const Key('cloud-upload'),
                  onPressed: (_cloudBusy || _cloudSyncing) ? null : _uploadCloudSnapshot,
                  icon: const Icon(Icons.cloud_upload_outlined, size: 17),
                  label: Text(_cloudSyncing ? '同步中…' : '立即上传'),
                ),
                OutlinedButton.icon(
                  key: const Key('cloud-restore'),
                  onPressed: (_cloudBusy || _cloudSyncing) ? null : _restoreCloudSnapshot,
                  icon: const Icon(Icons.cloud_download_outlined, size: 17),
                  label: const Text('从云端恢复'),
                ),
              ],
            ),
          ],
          if (_cloudSyncing || _cloudProgress.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(_cloudProgress,
                style: TextStyle(fontSize: 11.5, color: pal.muted)),
          ],
          if (_cloudRestoreReady) ...[
            const SizedBox(height: 8),
            OutlinedButton.icon(
              key: const Key('cloud-restart'),
              onPressed: () => WindowController.instance.quit(),
              icon: const Icon(Icons.restart_alt_rounded, size: 17),
              label: const Text('立即重启 Loop'),
            ),
          ],
          if (_cloudMessage != null) ...[
            const SizedBox(height: 8),
            Text(
              _cloudMessage!,
              key: const Key('cloud-message'),
              style: TextStyle(
                fontSize: 11.5,
                color: _cloudOk ? pal.accent : pal.danger,
              ),
            ),
          ],
        ],
      ),
      ),
    );
  }

  // ------------------------------------------------------------ 数据与迁移（F-11）

  /// 读迁移状态（applied/pending/running/last_error/report + 一次性提示标记）。
  Future<void> _loadMigration() async {
    try {
      final overview = await _state.api.migrationOverview();
      if (!mounted) return;
      setState(() {
        _migration = overview;
        _migrationNote = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _migrationNote = '读取迁移状态失败：$error');
    }
  }

  /// 失败重试：`POST /api/migrations/run`（幂等；已应用则 skipped）。
  Future<void> _rerunMigration() async {
    setState(() {
      _migrationBusy = true;
      _migrationNote = null;
    });
    try {
      final result = await _state.api.runMigration();
      await _loadMigration();
      if (!mounted) return;
      setState(() {
        _migrationBusy = false;
        _migrationNote = result['skipped'] == true
            ? '迁移已应用过（skipped: ${result['reason'] ?? ''}）'
            : (result['ok'] == true ? '迁移完成' : '迁移失败：${result['error'] ?? ''}');
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _migrationBusy = false;
        _migrationNote = '重试失败：$error';
      });
    }
  }

  /// 一次性提示：把"已看过"写进设置（下次不再显示）。
  Future<void> _dismissMigrationNotice() async {
    try {
      await _state.api.saveSettings(subjectMigrationNoticeSeen: true);
      await _state.refreshSettings();
    } catch (_) {}
    await _loadMigration();
  }

  Future<void> _setCrossSubjectSearch(bool value) async {
    try {
      await _state.api.saveSettings(crossSubjectSearch: value);
      await _state.refreshSettings();
      await _loadMigration();
    } catch (error) {
      if (!mounted) return;
      setState(() => _migrationNote = '保存失败：$error');
    }
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

  Future<void> _refreshModels() async {
    setState(() => _fetchingModels = true);
    final saved = await _persist(silent: true);
    if (!saved) {
      if (mounted) setState(() => _fetchingModels = false);
      _snack('请先填写并保存供应商配置', error: true);
      return;
    }
    try {
      final result = await _state.api.fetchModels(providerId: _selectedProvider);
      if (!mounted) return;
      if (result['ok'] != true) {
        _snack((result['message'] ?? '拉取失败').toString(), error: true);
        return;
      }
      final ids = ((result['models'] as List?) ?? const [])
          .map((item) => item.toString().trim())
          .where((id) => id.isNotEmpty)
          .toList();
      final selected = _selected;
      if (selected == null) return;
      if (ids.isEmpty) {
        _snack('${selected.name} 端点没有返回模型', error: true);
        return;
      }
      final merged = mergeFetchedModels(
        selected.models,
        [for (final id in ids) ModelInfo(id: id)],
      );
      final added = merged.length - selected.models.length;
      final index = _providers.indexWhere((item) => item.id == selected.id);
      if (index >= 0) {
        _providers[index] = selected.copyWith(models: merged);
      }
      setState(() {});
      await _persist(silent: true);
      _snack(added > 0
          ? '已拉取 ${ids.length} 个模型，新增 $added 个'
          : '已拉取 ${ids.length} 个模型，无新增');
    } catch (error) {
      _snack('拉取失败：$error', error: true);
    } finally {
      if (mounted) setState(() => _fetchingModels = false);
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
    _cloudUrlController.dispose();
    _cloudKeyController.dispose();
    _cloudDeviceController.dispose();
    _cloudEmailController.dispose();
    _cloudPasswordController.dispose();
    _cloudPassphraseController.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------ 数据与迁移（F-11）

  /// 「数据与迁移」卡片：迁移状态/进度、失败重试、一次性提示、跨学科检索开关，
  /// 以及只读的技能来源（F-18）。
  Widget _dataAndMigrationCard() {
    final overview = _migration;
    final settings = _state.settings;
    return Container(
      key: const Key('settings-data-migration'),
      padding: const EdgeInsets.all(22),
      decoration: panelDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('数据与迁移',
                  style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600)),
              const Spacer(),
              TextButton(
                key: const Key('migration-refresh'),
                onPressed: _migrationBusy ? null : _loadMigration,
                child: const Text('刷新'),
              ),
            ],
          ),
          const SizedBox(height: 6),
          if (overview == null)
            Text('读取中…', style: TextStyle(fontSize: 12, color: pal.muted))
          else ...[
            Text(
              overview.pending.isEmpty
                  ? '结构版本：已是最新${overview.appliedAt.isEmpty ? '' : '（迁移于 ${overview.appliedAt}）'}'
                  : '结构版本：待迁移 ${overview.pending.join(', ')}',
              key: const Key('migration-status-line'),
              style: TextStyle(fontSize: 12.5, color: pal.ink),
            ),
            if (overview.running)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('迁移进行中…', style: TextStyle(fontSize: 12, color: pal.warm)),
              ),
            if (overview.countsLabel.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('迁入记录：${overview.countsLabel}',
                    style: TextStyle(fontSize: 11.5, color: pal.muted)),
              ),
            if (overview.filesLabel.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(overview.filesLabel,
                    key: const Key('migration-files-line'),
                    style: TextStyle(fontSize: 11.5, color: pal.muted)),
              ),
            if (overview.fileErrors.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final item in overview.fileErrors.take(5))
                      Text(
                        '· ${item['table']}#${item['id']} ${item['reason']}',
                        style: TextStyle(fontSize: 11, color: pal.warm, height: 1.5),
                      ),
                  ],
                ),
              ),
            if (overview.failed)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  '上次迁移未完成：${overview.lastError.isEmpty ? (overview.report['error'] ?? '未知原因') : overview.lastError}',
                  key: const Key('migration-error-line'),
                  style: TextStyle(fontSize: 12, color: pal.danger),
                ),
              ),
            if (!overview.noticeSeen && overview.appliedAt.isNotEmpty)
              Container(
                key: const Key('migration-notice'),
                margin: const EdgeInsets.only(top: 10),
                padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
                decoration: softDecoration(radius: 12),
                child: Row(
                  children: [
                    Icon(Icons.info_outline_rounded, size: 15, color: pal.accent),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '旧数据已迁入默认学科：会话/资料/进度都在学科库里，原库保留为只读副本。',
                        style: TextStyle(fontSize: 11.5, color: pal.ink, height: 1.5),
                      ),
                    ),
                    TextButton(
                      key: const Key('migration-notice-dismiss'),
                      onPressed: _dismissMigrationNotice,
                      child: const Text('知道了'),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 8),
            Row(
              children: [
                OutlinedButton.icon(
                  key: const Key('migration-retry'),
                  onPressed: (_migrationBusy || overview.pending.isEmpty) ? null : _rerunMigration,
                  icon: _migrationBusy
                      ? const SizedBox(
                          width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.play_arrow_rounded, size: 17),
                  label: Text(_migrationBusy ? '处理中…' : '重试迁移'),
                ),
                const SizedBox(width: 10),
                if (_migrationNote != null)
                  Expanded(
                    child: Text(_migrationNote!,
                        key: const Key('migration-note'),
                        style: TextStyle(fontSize: 11.5, color: pal.muted)),
                  ),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('跨学科兜底检索', style: TextStyle(fontSize: 13, color: pal.ink)),
                      const SizedBox(height: 2),
                      Text(
                        '默认关闭：只在本学科资料里检索。开启后，仅当本学科零命中时才兜底到其它学科，'
                        '并在回答里标注来源学科。',
                        style: TextStyle(fontSize: 11, color: pal.muted, height: 1.5),
                      ),
                    ],
                  ),
                ),
                Switch(
                  key: const Key('cross-subject-search-switch'),
                  value: settings?.crossSubjectSearch ?? false,
                  onChanged: (value) => _setCrossSubjectSearch(value),
                ),
              ],
            ),
            const Divider(height: 22),
            Row(
              children: [
                Icon(Icons.hub_outlined, size: 14, color: pal.muted),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '教学技能来源：${settings?.skillHubUrl ?? ''}（只读，由后端白名单固定）',
                    key: const Key('skill-hub-readonly'),
                    style: TextStyle(fontSize: 11, color: pal.muted),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
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
                              OutlinedButton.icon(
                                onPressed: _fetchingModels ? null : _refreshModels,
                                icon: _fetchingModels
                                    ? const SizedBox(
                                        width: 12,
                                        height: 12,
                                        child: CircularProgressIndicator(strokeWidth: 2),
                                      )
                                    : const Icon(Icons.refresh_rounded, size: 16),
                                label: Text(_fetchingModels ? '拉取中…' : '刷新模型列表'),
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
                    _cloudSyncCard(),
                    const SizedBox(height: 16),
                    _dataAndMigrationCard(),
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
