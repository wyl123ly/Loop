import 'package:flutter/material.dart';

import '../api.dart';
import '../models.dart';
import '../state.dart';
import '../theme.dart';

/// 教学技能管理面板（规格 §9.8 / §10.3 技能 tab）。
///
/// 设计红线（AC-14，静态可查）：
/// - 默认视图是「已安装」，不是商城；浏览/搜索只在用户点击后发生；
/// - **不自动更新**：进页面不拉目录、不检查版本，全部由用户显式触发；
/// - 不渲染安全盾牌/「已通过安全扫描」类承诺，verify 只按事实呈现
///   （未被规则命中 / registry 未认可 / 未验证 + 原文 summary + unsigned）。
class SkillsPanel extends StatefulWidget {
  const SkillsPanel({
    super.key,
    required this.subjectId,
    required this.subjectKey,
    this.state,
    this.subjectArchived = false,
  });

  /// 学科 id（用于诊断文案）与 key（用于展示"本学科"归属）。
  final int subjectId;
  final String subjectKey;

  /// 可选注入，便于 widget 测试；生产环境使用全局 [appState]。
  final AppState? state;

  /// 归档学科只读：启用/停用/安装/移除全部禁用。
  final bool subjectArchived;

  @override
  State<SkillsPanel> createState() => SkillsPanelState();
}

enum _SkillTab { installed, hub }

class _SkillAction {
  const _SkillAction(this.kind);

  final String kind;
}

/// 技能面板 State（公开类名便于测试与后续复用）。
class SkillsPanelState extends State<SkillsPanel> {
  AppState get _state => widget.state ?? appState;

  LoopApi get _api => _state.api;

  _SkillTab _tab = _SkillTab.installed;
  SkillLibraryData? _library;
  bool _loading = true;
  String? _error;
  bool _offline = false;

  final TextEditingController _query = TextEditingController();
  SkillCatalogData? _catalog;
  bool _searching = false;
  bool _searched = false;

  final Map<String, String> _updateVersions = {};
  final Set<String> _checking = {};
  bool _batchChecking = false;
  String? _busySlug;

  @visibleForTesting
  bool get offline => _offline;

  @override
  void initState() {
    super.initState();
    _loadLibrary();
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------------ 数据

  Future<void> _loadLibrary() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final library = await _api.skillLibrary();
      if (!mounted) return;
      setState(() {
        _library = library;
        _loading = false;
        _offline = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = _message(error);
        if (_isOffline(error)) _offline = true;
      });
    }
  }

  bool _isOffline(Object error) =>
      error is ApiException && error.code == 'offline';

  String _message(Object error) =>
      error is ApiException ? error.message : error.toString();

  void _noteOffline(Object error) {
    if (!_isOffline(error)) return;
    if (_offline) return;
    setState(() => _offline = true);
  }

  Future<void> _search({String? query}) async {
    final text = (query ?? _query.text).trim();
    setState(() {
      _searching = true;
      _searched = true;
      if (query != null) _query.text = query;
    });
    try {
      final catalog = await _api.skillCatalog(query: text);
      if (!mounted) return;
      setState(() {
        _catalog = catalog;
        _searching = false;
        _offline = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _searching = false;
        _catalog = null;
        if (_isOffline(error)) _offline = true;
      });
      _snack(_isOffline(error) ? '当前离线，无法浏览 EduHub。已安装技能仍可使用。' : _message(error),
          isError: true);
    }
  }

  void _snack(String text, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(text, style: TextStyle(color: pal.toastFg, fontSize: LoopType.body)),
      backgroundColor: isError ? pal.dangerInk : pal.toastBg,
      duration: const Duration(seconds: 3),
    ));
  }

  bool get _readOnly => widget.subjectArchived;

  // ------------------------------------------------------------------ 已安装操作

  Future<void> _toggleEnabled(InstalledSkillInfo skill, bool enabled) async {
    if (_readOnly) {
      _snack('学科已归档，无法修改技能状态', isError: true);
      return;
    }
    setState(() => _busySlug = skill.slug);
    try {
      final updated = await _api.setSkillEnabled(skill.slug, enabled);
      await _loadLibrary();
      if (!mounted) return;
      _snack('${updated.displayName} 已${enabled ? '启用' : '停用'}');
    } catch (error) {
      _snack(_message(error), isError: true);
    } finally {
      if (mounted) setState(() => _busySlug = null);
    }
  }

  Future<void> _checkUpdate(InstalledSkillInfo skill) async {
    if (_checking.contains(skill.slug)) return;
    setState(() => _checking.add(skill.slug));
    try {
      final detail = await _api.skillDetail(skill.slug);
      final raw = detail['skill'];
      final latest = raw is Map ? (raw['version'] ?? '').toString() : '';
      if (!mounted) return;
      if (latest.isEmpty || latest == skill.version) {
        setState(() => _updateVersions.remove(skill.slug));
        _snack('${skill.displayName} 已是最新（${skill.version}）');
      } else {
        setState(() => _updateVersions[skill.slug] = latest);
        _snack('${skill.displayName} 有新版本 $latest（不会自动安装）');
      }
    } catch (error) {
      _noteOffline(error);
      _snack(
        _isOffline(error)
            ? '当前离线，无法检查更新。已安装技能仍可使用。'
            : '检查更新失败：${_message(error)}',
        isError: true,
      );
    } finally {
      if (mounted) setState(() => _checking.remove(skill.slug));
    }
  }

  Future<void> _install(
    String slug, {
    String? version,
    bool allowSuspicious = false,
    String name = '',
  }) async {
    if (_readOnly) {
      _snack('学科已归档，无法安装技能', isError: true);
      return;
    }
    setState(() => _busySlug = slug);
    try {
      final installed = await _api.installSkill(
        slug,
        version: version,
        allowUnverified: true,
        allowSuspicious: allowSuspicious,
      );
      await _loadLibrary();
      if (!mounted) return;
      final label = name.isNotEmpty ? name : installed.displayName;
      final note = installed.unverified ? '（未验证：registry 裁决不可得）' : '';
      _snack('$label ${installed.version} 已安装$note');
      setState(() => _updateVersions.remove(slug));
    } catch (error) {
      _noteOffline(error);
      _snack(_installErrorText(error), isError: true);
    } finally {
      if (mounted) setState(() => _busySlug = null);
    }
  }

  /// F-5：批量「检查更新（全部）」——走 `POST /api/skills/check-updates`（只查不装）。
  /// 已锁定版本（pinned）的技能按 §9.6 跳过提示，避免诱导覆盖。
  Future<void> _checkAllUpdates() async {
    setState(() => _batchChecking = true);
    try {
      final items = await _api.checkSkillUpdates();
      final updates = <String, String>{};
      var offline = 0;
      var skippedPinned = 0;
      for (final item in items) {
        final slug = (item['slug'] ?? '').toString();
        if (slug.isEmpty) continue;
        if (item['pinned'] == true) {
          skippedPinned++;
          continue;
        }
        if (item['offline'] == true) {
          offline++;
          continue;
        }
        if (item['update_available'] == true) {
          updates[slug] = (item['latest'] ?? '').toString();
        }
      }
      if (!mounted) return;
      setState(() {
        _updateVersions
          ..removeWhere((slug, _) => !updates.containsKey(slug))
          ..addAll(updates);
      });
      final parts = <String>[
        if (updates.isEmpty) '已是最新' else '${updates.length} 个有新版本（不会自动安装）',
        if (skippedPinned > 0) '$skippedPinned 个已锁定版本，已跳过',
        if (offline > 0) '$offline 个离线未检查',
      ];
      _snack(parts.join('；'));
    } catch (error) {
      _noteOffline(error);
      _snack(
        _isOffline(error) ? '当前离线，无法检查更新。已安装技能仍可使用。' : '检查更新失败：${_message(error)}',
        isError: true,
      );
    } finally {
      if (mounted) setState(() => _batchChecking = false);
    }
  }

  /// F-5：版本锁定开关（pinned=1 → 跳过更新提示，也不允许直接覆盖更新）。
  Future<void> _togglePinned(InstalledSkillInfo skill, bool pinned) async {
    if (_readOnly) {
      _snack('学科已归档，无法修改技能', isError: true);
      return;
    }
    setState(() => _busySlug = skill.slug);
    try {
      await _api.setSkillPinned(skill.slug, pinned);
      await _loadLibrary();
      if (!mounted) return;
      if (pinned) _updateVersions.remove(skill.slug);
      _snack(pinned ? '已锁定「${skill.displayName}」的版本' : '已解除「${skill.displayName}」的版本锁定');
    } catch (error) {
      _noteOffline(error);
      _snack('操作失败：${_message(error)}', isError: true);
    } finally {
      if (mounted) setState(() => _busySlug = null);
    }
  }

  /// F-5：更新走 `POST /api/skills/{slug}/update`（同 install 语义，含 verify 与
  /// sha256 校验；失败保持旧版本可用）。锁定版本会被后端 409 拦下。
  Future<void> _updateSkill(InstalledSkillInfo skill) async {
    if (_readOnly) {
      _snack('学科已归档，无法更新技能', isError: true);
      return;
    }
    setState(() => _busySlug = skill.slug);
    try {
      final result = await _api.updateSkill(skill.slug);
      await _loadLibrary();
      if (!mounted) return;
      final skillMap = result['skill'];
      final version = skillMap is Map ? '${skillMap['version'] ?? ''}' : '';
      final previous = '${result['previous_version'] ?? ''}';
      setState(() => _updateVersions.remove(skill.slug));
      _snack('已更新「${skill.displayName}」${previous.isEmpty ? '' : '$previous → '}$version');
    } catch (error) {
      _noteOffline(error);
      final msg = error is ApiException && error.code == 'pinned'
          ? '该技能已锁定版本，请先解除锁定再更新'
          : '更新失败：${_message(error)}';
      _snack(msg, isError: true);
    } finally {
      if (mounted) setState(() => _busySlug = null);
    }
  }

  /// 安装失败的人话提示：离线/裁决阻断/完整性失败必须能区分（§9.5 / AC-13）。
  String _installErrorText(Object error) {
    if (error is! ApiException) return '安装失败：$error';
    switch (error.code) {
      case 'offline':
        return '当前离线，无法下载技能。已安装技能仍可使用。';
      case 'suspicious':
        return 'registry 未认可这个技能包，已拒绝安装：${error.message}';
      case 'sha256_mismatch':
        return '完整性校验失败（逐文件 sha256 不一致），已拒绝安装：${error.message}';
      case 'zip_slip':
      case 'zip_bomb':
      case 'symlink':
      case 'suffix_not_allowed':
      case 'no_manifest':
        return '技能包未通过导入检查（${error.code}）：${error.message}';
      case 'no_previous':
        return '没有可回退的上一版本。';
      case 'blocked':
        return '被后端策略拒绝：${error.message}';
      default:
        return '安装失败：${error.message}';
    }
  }

  Future<void> _rollback(InstalledSkillInfo skill) async {
    if (_readOnly) {
      _snack('学科已归档，无法回退技能', isError: true);
      return;
    }
    setState(() => _busySlug = skill.slug);
    try {
      final restored = await _api.rollbackSkill(skill.slug);
      await _loadLibrary();
      if (!mounted) return;
      _snack('${restored.displayName} 已回退到 ${restored.version}（纯本地快照，无需联网）');
    } catch (error) {
      _snack(_installErrorText(error), isError: true);
    } finally {
      if (mounted) setState(() => _busySlug = null);
    }
  }

  Future<void> _remove(InstalledSkillInfo skill) async {
    if (_readOnly) {
      _snack('学科已归档，无法移除技能', isError: true);
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('移除教学技能'),
        content: Text('从「本学科」移除「${skill.displayName}」？只会删除本学科的副本，不影响其他学科。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('skill-remove-confirm'),
            style: FilledButton.styleFrom(backgroundColor: pal.dangerInk),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busySlug = skill.slug);
    try {
      await _api.removeSkill(skill.slug);
      await _loadLibrary();
      if (!mounted) return;
      _snack('已移除「${skill.displayName}」');
    } catch (error) {
      _snack(_message(error), isError: true);
    } finally {
      if (mounted) setState(() => _busySlug = null);
    }
  }

  // ------------------------------------------------------------------ 详情

  Future<void> _showInstalledDetail(InstalledSkillInfo skill) async {
    await showDialog<bool>(
      context: context,
      builder: (context) => _SkillDetailDialog(
        title: skill.displayName,
        version: skill.version,
        description: skill.description,
        license: skill.licenseLabel,
        owner: skill.owner,
        sourceUrl: skill.sourceUrl,
        sha256: skill.sha256,
        files: skill.files,
        installedAt: skill.installedAt,
        hub: skill.hub,
        verdict: skill.verdict,
        hasScripts: skill.hasScripts,
        previousVersion: skill.previousVersion,
        playbookLoader: skill.enabled
            ? () async {
                final rows = await _api.skillPlaybooks();
                for (final row in rows) {
                  if ((row['slug'] ?? '').toString() == skill.slug) {
                    return (row['content'] ?? '').toString();
                  }
                }
                return '';
              }
            : null,
        disabledNote: skill.enabled ? '' : '技能已停用：启用后可在对话中生效，正文不再读取。',
      ),
    );
  }

  Future<void> _showHubDetail(HubSkillInfo item) async {
    setState(() => _busySlug = item.slug);
    Map<String, dynamic> detail;
    try {
      detail = await _api.skillDetail(item.slug, version: item.version);
    } catch (error) {
      _noteOffline(error);
      if (mounted) {
        _snack(
          _isOffline(error)
              ? '当前离线，无法读取技能详情。已安装技能仍可使用。'
              : '读取详情失败：${_message(error)}',
          isError: true,
        );
        setState(() => _busySlug = null);
      }
      return;
    }
    SkillVerdictInfo verdict;
    try {
      verdict = await _api.skillVerdict(item.slug, version: item.version);
    } catch (_) {
      verdict = const SkillVerdictInfo(status: 'unknown', detail: '没有取得 registry 的裁决结果');
    }
    if (!mounted) return;
    setState(() => _busySlug = null);

    final skill = detail['skill'] is Map
        ? Map<String, dynamic>.from(detail['skill'] as Map)
        : <String, dynamic>{};
    final install = await showDialog<bool>(
      context: context,
      builder: (context) => _SkillDetailDialog(
        title: (skill['name'] ?? item.displayName).toString(),
        version: (skill['version'] ?? item.version).toString(),
        description: (skill['summary'] ?? item.summary).toString(),
        license: (skill['license'] ?? '').toString(),
        owner: (skill['owner'] ?? item.owner).toString(),
        ownerUrl: (skill['owner_url'] ?? item.ownerUrl).toString(),
        sourceUrl: (skill['web_url'] ?? item.webUrl).toString(),
        sha256: '',
        files: (skill['files'] as List? ?? const []).length,
        installedAt: '',
        hub: (detail['hub'] ?? 'eduhub').toString(),
        verdict: verdict,
        hasScripts: false,
        previousVersion: '',
        content: (skill['content'] ?? '').toString(),
        allowInstall: !_readOnly,
      ),
    );
    if (install != true || !mounted) return;
    if (verdict.status == 'suspicious') {
      final forced = await _confirmSuspicious(verdict, item.displayName);
      if (!forced || !mounted) return;
      await _install(
        item.slug,
        version: (skill['version'] ?? item.version).toString(),
        allowSuspicious: true,
        name: item.displayName,
      );
      return;
    }
    await _install(
      item.slug,
      version: (skill['version'] ?? item.version).toString(),
      name: item.displayName,
    );
  }

  /// registry 未认可的包必须显式勾选「我了解风险」才强装（§9.8 裁决展示）。
  Future<bool> _confirmSuspicious(SkillVerdictInfo verdict, String name) async {
    var understood = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: const Text('registry 未认可这个技能包'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  verdict.explanation,
                  style: TextStyle(fontSize: LoopType.secondary, color: pal.ink, height: 1.6),
                ),
                const SizedBox(height: 10),
                Text(
                  'Loop 侧仍会做 zip 防护与逐文件 sha256 校验，且永不执行包内脚本，'
                  '但这不构成对内容的安全性判断。',
                  style: TextStyle(fontSize: LoopType.caption, color: pal.muted, height: 1.6),
                ),
                CheckboxListTile(
                  key: const Key('skill-suspicious-understood'),
                  contentPadding: EdgeInsets.zero,
                  value: understood,
                  onChanged: (value) => setLocal(() => understood = value ?? false),
                  title: const Text('我了解风险，仍然安装', style: TextStyle(fontSize: LoopType.secondary)),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              key: const Key('skill-suspicious-force'),
              style: FilledButton.styleFrom(backgroundColor: pal.dangerInk),
              onPressed: understood ? () => Navigator.of(context).pop(true) : null,
              child: Text('仍然安装「$name」'),
            ),
          ],
        ),
      ),
    );
    return ok == true;
  }

  // ------------------------------------------------------------------ 构建

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _tabBar(),
        if (_offline) _offlineBanner(),
        Expanded(child: _tab == _SkillTab.installed ? _installedView() : _hubView()),
      ],
    );
  }

  Widget _tabBar() {
    Widget tab(_SkillTab value, String label, Key key) {
      final selected = _tab == value;
      return Padding(
        padding: const EdgeInsets.only(right: 8),
        child: Material(
          key: key,
          color: selected ? pal.chip : Colors.transparent,
          borderRadius: BorderRadius.circular(LoopRadius.control),
          child: InkWell(
            borderRadius: BorderRadius.circular(LoopRadius.control),
            onTap: () => setState(() => _tab = value),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(LoopRadius.control),
                border: Border.all(color: selected ? pal.glassBorder : pal.border),
              ),
              child: Text(
                label,
                style: TextStyle(
                  fontSize: LoopType.body,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: selected ? pal.ink : pal.muted,
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 12, 32, 8),
      child: Row(
        children: [
          // Expanded（不是 Flexible+Spacer）：窄窗下 tab 条拿到全部剩余宽度，
          // 超出时自身横向滚动，绝不被裁掉一半导致点不到（§10.5）。
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  tab(_SkillTab.installed, '已安装', const Key('skills-tab-installed')),
                  tab(_SkillTab.hub, '从 EduHub 添加', const Key('skills-tab-hub')),
                ],
              ),
            ),
          ),
          IconButton(
            tooltip: '刷新已安装列表',
            onPressed: _loading ? null : _loadLibrary,
            icon: Icon(Icons.refresh_rounded, size: 17, color: pal.muted),
          ),
        ],
      ),
    );
  }

  Widget _offlineBanner() {
    return Container(
      key: const Key('skills-offline-banner'),
      margin: const EdgeInsets.fromLTRB(32, 4, 32, 4),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: pal.chip,
        borderRadius: BorderRadius.circular(LoopRadius.control),
        border: Border.all(color: pal.glassBorder),
      ),
      child: Row(
        children: [
          Icon(Icons.cloud_off_rounded, size: 15, color: pal.warningInk),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '当前离线，已安装技能仍可使用；浏览与安装已暂时不可用。',
              style: TextStyle(fontSize: LoopType.caption, color: pal.ink),
            ),
          ),
        ],
      ),
    );
  }

  Widget _installedView() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2.4));
    }
    if (_error != null && _library == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, style: TextStyle(color: pal.muted, fontSize: LoopType.body)),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: _loadLibrary, child: const Text('重试')),
          ],
        ),
      );
    }
    final library = _library;
    final skills = library?.installed ?? const <InstalledSkillInfo>[];
    if (skills.isEmpty) return _emptyInstalled();

    return ListView(
      padding: const EdgeInsets.fromLTRB(32, 8, 32, 32),
      children: [
        _policyNote(library?.policy),
        const SizedBox(height: 10),
        for (final skill in skills) _installedCard(skill),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              key: const Key('skills-check-updates'),
              onPressed: _readOnly || _batchChecking ? null : _checkAllUpdates,
              icon: _batchChecking
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh_rounded, size: 17),
              label: Text(_batchChecking ? '检查中…' : '检查更新（全部）'),
            ),
            OutlinedButton.icon(
              key: const Key('skills-open-hub'),
              onPressed: () => setState(() => _tab = _SkillTab.hub),
              icon: const Icon(Icons.download_for_offline_outlined, size: 17),
              label: Text('从 ${library?.hubLabel ?? 'EduHub'} 添加'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _policyNote(SkillPolicyInfo? policy) {
    final note = policy?.verifyNote ?? '';
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: softDecoration(radius: LoopRadius.control),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.description_outlined, size: 15, color: pal.muted),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '教学技能是文档：Loop 只把它们作为提示词素材读取，不会执行包里的任何脚本。',
                  style: TextStyle(fontSize: LoopType.caption, color: pal.ink),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '不自动更新：版本变化只会提示，安装/升级/回退都由你点击触发。'
            '${note.isEmpty ? '' : '（$note）'}',
            style: TextStyle(fontSize: LoopType.micro, color: pal.muted, height: 1.5),
          ),
        ],
      ),
    );
  }

  Widget _emptyInstalled() {
    final label = _library?.hubLabel ?? 'EduHub';
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.extension_outlined, size: 38, color: pal.muted),
            const SizedBox(height: 12),
            const Text('本学科还没有教学技能',
                style: TextStyle(fontSize: LoopType.reading, fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Text(
              '从 $label 按需挑选，安装后只在本学科生效；也可以随时停用或移除。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: LoopType.secondary, color: pal.muted),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              key: const Key('skills-open-hub'),
              onPressed: () => setState(() => _tab = _SkillTab.hub),
              icon: const Icon(Icons.download_for_offline_outlined, size: 17),
              label: Text('从 $label 添加'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _installedCard(InstalledSkillInfo skill) {
    final busy = _busySlug == skill.slug;
    final update = _updateVersions[skill.slug] ?? '';
    final checking = _checking.contains(skill.slug);
    return Container(
      key: Key('skill-card-${skill.slug}'),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      decoration: panelDecoration(radius: LoopRadius.card),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: pal.chip,
                  borderRadius: BorderRadius.circular(LoopRadius.control),
                ),
                child: Icon(Icons.auto_stories_outlined, size: 18, color: pal.accent),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            skill.displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: LoopType.body,
                              fontWeight: FontWeight.w700,
                              color: pal.ink,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(skill.version,
                            style: TextStyle(fontSize: LoopType.caption, color: pal.muted)),
                        if (update.isNotEmpty) ...[
                          const SizedBox(width: 8),
                          _badge('有新版本 $update', pal.warningInk),
                        ],
                      ],
                    ),
                    if (skill.description.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          skill.description,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: LoopType.caption, color: pal.muted, height: 1.5),
                        ),
                      ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        _verdictBadge(skill.verdict),
                        _badge(skill.enabled ? '本学科已启用' : '本学科已停用',
                            skill.enabled ? pal.accent : pal.muted),
                        if (skill.hasScripts)
                          Tooltip(
                            message: 'Loop 不会运行这些脚本',
                            child: _badge('含脚本(未执行)', pal.warningInk),
                          ),
                        if (skill.suspicious) _badge('registry 未认可', pal.danger),
                        _badge(skill.pinned ? '已锁定版本' : skill.licenseLabel, pal.muted),
                      ],
                    ),
                    if (update.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          '上次检查：$update 可用；不会自动安装。',
                          style: TextStyle(fontSize: LoopType.micro, color: pal.muted),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              if (busy)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                  child: SizedBox(
                    width: 15,
                    height: 15,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              else
                Switch(
                  key: Key('skill-toggle-${skill.slug}'),
                  value: skill.enabled,
                  onChanged: _readOnly ? null : (value) => _toggleEnabled(skill, value),
                ),
              PopupMenuButton<_SkillAction>(
                key: Key('skill-menu-${skill.slug}'),
                tooltip: '更多操作',
                color: pal.cardSolid,
                onSelected: (action) {
                  switch (action.kind) {
                    case 'detail':
                      _showInstalledDetail(skill);
                    case 'check':
                      _checkUpdate(skill);
                    case 'update':
                      _updateSkill(skill);
                    case 'pin':
                      _togglePinned(skill, !skill.pinned);
                    case 'rollback':
                      _rollback(skill);
                    case 'remove':
                      _remove(skill);
                  }
                },
                itemBuilder: (context) => [
                  PopupMenuItem(
                    key: Key('skill-detail-${skill.slug}'),
                    value: const _SkillAction('detail'),
                    child: Text('查看 SKILL.md / 详情', style: TextStyle(fontSize: LoopType.body, color: pal.ink)),
                  ),
                  PopupMenuItem(
                    key: Key('skill-check-update-${skill.slug}'),
                    value: const _SkillAction('check'),
                    enabled: !checking,
                    child: Text(
                      checking ? '检查更新中…' : '检查更新（手动）',
                      style: TextStyle(fontSize: LoopType.body, color: pal.ink),
                    ),
                  ),
                  PopupMenuItem(
                    key: Key('skill-update-${skill.slug}'),
                    value: const _SkillAction('update'),
                    enabled: update.isNotEmpty,
                    child: Text(
                      update.isEmpty ? '更新（先检查更新）' : '更新到 $update',
                      style: TextStyle(
                        fontSize: LoopType.body,
                        color: update.isEmpty ? pal.faint : pal.ink,
                      ),
                    ),
                  ),
                  PopupMenuItem(
                    key: Key('skill-pin-${skill.slug}'),
                    value: const _SkillAction('pin'),
                    child: Text(
                      skill.pinned ? '解除版本锁定' : '锁定版本（不提示更新）',
                      style: TextStyle(fontSize: LoopType.body, color: pal.ink),
                    ),
                  ),
                  PopupMenuItem(
                    key: Key('skill-rollback-${skill.slug}'),
                    value: const _SkillAction('rollback'),
                    enabled: skill.canRollback,
                    child: Text(
                      skill.canRollback
                          ? '回退到上一版 ${skill.previousVersion}'.trim()
                          : '回退（没有上一版）',
                      style: TextStyle(
                        fontSize: LoopType.body,
                        color: skill.canRollback ? pal.ink : pal.faint,
                      ),
                    ),
                  ),
                  PopupMenuItem(
                    key: Key('skill-remove-${skill.slug}'),
                    value: const _SkillAction('remove'),
                    child: Text('移除', style: TextStyle(fontSize: LoopType.body, color: pal.dangerInk)),
                  ),
                ],
                icon: Icon(Icons.more_horiz_rounded, size: 18, color: pal.muted),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _badge(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(LoopRadius.pill),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: LoopType.micro, color: color, fontWeight: FontWeight.w600),
      ),
    );
  }

  /// verify 三态**如实**呈现（没有"安全"字样）。
  Widget _verdictBadge(SkillVerdictInfo verdict) {
    final color = switch (verdict.status) {
      'ok' => pal.muted,
      'suspicious' => pal.danger,
      _ => pal.warningInk,
    };
    return Tooltip(
      message: verdict.explanation,
      child: _badge(
        verdict.status == 'ok' ? 'registry 未命中规则（非安全保证）' : verdict.label,
        color,
      ),
    );
  }

  Widget _hubView() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(32, 8, 32, 8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  key: const Key('skills-search-field'),
                  controller: _query,
                  decoration: const InputDecoration(hintText: '按关键词搜索教学技能（中文或英文）'),
                  onSubmitted: (_) => _searching ? null : _search(),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                key: const Key('skills-search-button'),
                onPressed: _searching ? null : _search,
                child: Text(_searching ? '搜索中…' : '搜索'),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(32, 0, 32, 8),
          child: Text(
            '按需浏览：请求只带关键词，由你点击触发；不发送学科名或资料内容，也不自动更新。'
            '只接 ${_library?.hubLabel ?? 'EduHub'}（后端白名单固定）。',
            style: TextStyle(fontSize: LoopType.micro, color: pal.muted, height: 1.5),
          ),
        ),
        Expanded(child: _hubResults()),
      ],
    );
  }

  Widget _hubResults() {
    if (_searching) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2.4));
    }
    final catalog = _catalog;
    if (catalog == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.travel_explore_rounded, size: 36, color: pal.muted),
              const SizedBox(height: 10),
              Text(
                _searched ? '没有结果，换个关键词试试。' : '输入关键词，或直接点「搜索」浏览列表。',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: LoopType.secondary, color: pal.muted),
              ),
            ],
          ),
        ),
      );
    }
    if (catalog.skills.isEmpty) {
      return Center(
        child: Text(
          _searched ? '没有结果，换个关键词试试。' : '列表为空。',
          style: TextStyle(fontSize: LoopType.secondary, color: pal.muted),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(32, 4, 32, 32),
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            '${catalog.skills.length} 个结果 · ${catalog.hub}'
            '${catalog.query.isEmpty ? '' : ' · 关键词「${catalog.query}」'}',
            style: TextStyle(fontSize: LoopType.caption, color: pal.muted),
          ),
        ),
        for (final item in catalog.skills) _hubCard(item),
      ],
    );
  }

  Widget _hubCard(HubSkillInfo item) {
    final busy = _busySlug == item.slug;
    return Container(
      key: Key('hub-card-${item.slug}'),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      decoration: panelDecoration(radius: LoopRadius.card),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        item.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: LoopType.body,
                          fontWeight: FontWeight.w700,
                          color: pal.ink,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(item.version, style: TextStyle(fontSize: LoopType.caption, color: pal.muted)),
                    if (item.installed) ...[
                      const SizedBox(width: 8),
                      _badge('本学科已安装', pal.accent),
                    ],
                  ],
                ),
                if (item.summary.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      item.summary,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: LoopType.caption, color: pal.muted, height: 1.5),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    '${item.owner.isEmpty ? '发布者未知' : item.owner} · 下载 ${item.downloads}（弱信号）',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: LoopType.micro, color: pal.muted),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (busy)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: SizedBox(
                width: 15,
                height: 15,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            OutlinedButton(
              key: Key('hub-detail-${item.slug}'),
              onPressed: _offline ? null : () => _showHubDetail(item),
              child: const Text('详情'),
            ),
        ],
      ),
    );
  }
}

/// 技能详情（已安装 / hub 共用）。所有事实原样展示，**不做安全性承诺**。
class _SkillDetailDialog extends StatefulWidget {
  const _SkillDetailDialog({
    required this.title,
    required this.version,
    required this.description,
    required this.license,
    required this.owner,
    required this.sourceUrl,
    required this.sha256,
    required this.files,
    required this.installedAt,
    required this.hub,
    required this.verdict,
    required this.hasScripts,
    required this.previousVersion,
    this.ownerUrl = '',
    this.content = '',
    this.playbookLoader,
    this.disabledNote = '',
    this.allowInstall = false,
  });

  final String title;
  final String version;
  final String description;
  final String license;
  final String owner;
  final String ownerUrl;
  final String sourceUrl;
  final String sha256;
  final int files;
  final String installedAt;
  final String hub;
  final SkillVerdictInfo verdict;
  final bool hasScripts;
  final String previousVersion;
  final String content;
  final Future<String> Function()? playbookLoader;
  final String disabledNote;
  final bool allowInstall;

  @override
  State<_SkillDetailDialog> createState() => _SkillDetailDialogState();
}

class _SkillDetailDialogState extends State<_SkillDetailDialog> {
  String? _loaded;
  bool _loading = false;
  String? _loadError;
  bool _showBody = false;

  Future<void> _loadBody() async {
    final loader = widget.playbookLoader;
    if (loader == null || _loading) return;
    setState(() {
      _loading = true;
      _loadError = null;
      _showBody = true;
    });
    try {
      final text = await loader();
      if (!mounted) return;
      setState(() {
        _loaded = text;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = error.toString();
      });
    }
  }

  String get _sha12 {
    final value = widget.sha256.trim();
    if (value.isEmpty) return '不可得';
    return value.length <= 12 ? value : value.substring(0, 12);
  }

  @override
  Widget build(BuildContext context) {
    final verdict = widget.verdict;
    return AlertDialog(
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.title, style: const TextStyle(fontSize: LoopType.title)),
          const SizedBox(height: 4),
          Text(
            '${widget.version} · ${widget.hub}'
            '${widget.previousVersion.isEmpty ? '' : ' · 上一版 ${widget.previousVersion}'}',
            style: TextStyle(fontSize: LoopType.caption, color: pal.muted),
          ),
        ],
      ),
      content: SizedBox(
        width: 540,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 460),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (widget.description.isNotEmpty)
                  Text(
                    widget.description,
                    style: TextStyle(fontSize: LoopType.secondary, color: pal.ink, height: 1.6),
                  ),
                const SizedBox(height: 12),
                _row('发布者', widget.owner.isEmpty ? '未提供（来源不可追溯）' : widget.owner),
                _row('许可', widget.license.trim().isEmpty ? '未声明许可' : widget.license),
                _row('内容 sha256', _sha12),
                _row('文件数', '${widget.files}'),
                if (widget.installedAt.isNotEmpty) _row('安装时间', widget.installedAt),
                _row('registry 裁决', _verdictText(verdict)),
                _row('包签名', _signatureText(verdict)),
                if (widget.hasScripts) _row('脚本', '包含脚本文件，Loop 不会执行'),
                if (verdict.summary.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      'registry security.summary 原文：${verdict.summary}',
                      style: TextStyle(fontSize: LoopType.caption, color: pal.muted, height: 1.5),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    '说明：verify 只是 registry 侧的静态扫描参考信号，包没有签名，'
                    'Loop 不把它当作安全保证；真正的防线是导入管线（zip 防护 + 逐文件 sha256）'
                    '与「永不执行」。',
                    style: TextStyle(fontSize: LoopType.micro, color: pal.muted, height: 1.5),
                  ),
                ),
                if (widget.content.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text('SKILL.md',
                      style: TextStyle(fontSize: LoopType.caption, fontWeight: FontWeight.w600, color: pal.muted)),
                  const SizedBox(height: 4),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: softDecoration(radius: LoopRadius.control),
                    child: SelectableText(
                      widget.content,
                      style: TextStyle(fontSize: LoopType.caption, color: pal.ink, height: 1.6),
                    ),
                  ),
                ],
                if (widget.playbookLoader != null) ...[
                  const SizedBox(height: 12),
                  if (!_showBody)
                    OutlinedButton.icon(
                      key: const Key('skill-detail-load-md'),
                      onPressed: _loadBody,
                      icon: const Icon(Icons.article_outlined, size: 16),
                      label: const Text('查看 SKILL.md（AI 会读到的内容）'),
                    )
                  else if (_loading)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: LinearProgressIndicator(minHeight: 2),
                    )
                  else if (_loadError != null)
                    Text(_loadError!, style: TextStyle(fontSize: LoopType.caption, color: pal.dangerInk))
                  else
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: softDecoration(radius: LoopRadius.control),
                      child: SelectableText(
                        (_loaded ?? '').isEmpty ? '（正文为空）' : _loaded!,
                        style: TextStyle(fontSize: LoopType.caption, color: pal.ink, height: 1.6),
                      ),
                    ),
                ],
                if (widget.disabledNote.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      widget.disabledNote,
                      style: TextStyle(fontSize: LoopType.caption, color: pal.muted),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('关闭'),
        ),
        if (widget.allowInstall)
          FilledButton(
            key: const Key('skill-install-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('安装到本学科'),
          ),
      ],
    );
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: Text(label, style: TextStyle(fontSize: LoopType.caption, color: pal.muted)),
          ),
          Expanded(
            child: Text(value, style: TextStyle(fontSize: LoopType.caption, color: pal.ink, height: 1.5)),
          ),
        ],
      ),
    );
  }

  String _verdictText(SkillVerdictInfo verdict) {
    switch (verdict.status) {
      case 'ok':
        return '未被规则命中（decision=${verdict.decision.isEmpty ? 'n/a' : verdict.decision}'
            '，confidence=${verdict.confidence.isEmpty ? '未知' : verdict.confidence}）——不是安全保证';
      case 'suspicious':
        return 'registry 未认可（默认拒绝安装）：${verdict.explanation}';
      default:
        return '未验证（没有取得 registry 的裁决结果；安装后会标注为"未验证"）';
    }
  }

  String _signatureText(SkillVerdictInfo verdict) {
    final signature = verdict.signature.trim();
    if (signature.isEmpty) return 'unsigned / 未提供（不能作为信任锚）';
    return '$signature（不作为信任锚）';
  }
}