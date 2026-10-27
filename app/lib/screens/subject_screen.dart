import 'package:flutter/material.dart';

import '../api.dart';
import '../models.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/subject_skills_panel.dart';
import '../widgets/subject_switcher.dart';

/// 学科页（§10.1 / §10.3）：概览 / 进度 / 技能 三个 tab。
///
/// - 作用域就是学科本身：所有取数走 `api.subject*`（按 id），并显式带上当前
///   学科；切到其他学科时整页重新取数；
/// - 三个 tab 各自独立加载：进度接口失败只让概览/进度显示错误与重试，
///   技能面板自己加载（§10.3「加载」）。
class SubjectScreen extends StatefulWidget {
  const SubjectScreen({super.key, required this.active, this.state});

  final bool active;

  /// 可选注入，便于 widget 测试；生产环境使用全局 [appState]。
  final AppState? state;

  @override
  State<SubjectScreen> createState() => _SubjectScreenState();
}

class _SubjectScreenState extends State<SubjectScreen> {
  static const List<String> _tabLabels = ['概览', '进度', '技能'];

  AppState get _state => widget.state ?? appState;

  int _tab = 0;
  Subject? _subject;

  /// 归档学科的管理预览目标；null 表示跟随当前学科。
  ///
  /// 归档学科不能被设为当前学科（后端 409），但删除前必须先归档，因此
  /// 管理页需要能在不切换 active subject 的情况下只读打开归档学科。
  Subject? _managementTarget;
  SubjectProgress? _progress;
  bool _loading = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    subjectChangedSignal.addListener(_onSubjectChanged);
    subjectManagementRequest.addListener(_onManagementRequested);
    _managementTarget = subjectManagementRequest.value?.subject;
    _load();
  }

  @override
  void didUpdateWidget(covariant SubjectScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) _load();
  }

  @override
  void dispose() {
    subjectChangedSignal.removeListener(_onSubjectChanged);
    subjectManagementRequest.removeListener(_onManagementRequested);
    super.dispose();
  }

  void _onSubjectChanged() {
    if (!mounted) return;
    _managementTarget = null;
    _progress = null;
    _load();
  }

  void _onManagementRequested() {
    if (!mounted) return;
    final request = subjectManagementRequest.value;
    if (request == null) return;
    setState(() {
      _managementTarget = request.subject;
      _progress = null;
      _loading = true;
      _error = null;
    });
    _load();
  }

  Future<void> _load() async {
    final st = _state;
    try {
      await st.loadSubjects();
    } catch (_) {}
    if (!mounted) return;

    var target = _managementTarget;
    if (target != null) {
      Subject? refreshed;
      for (final item in st.subjects) {
        if (item.id == target.id) {
          refreshed = item;
          break;
        }
      }
      if (refreshed == null) {
        // 目标已被删除/移除：回到当前学科，避免继续请求已消失的学科。
        _managementTarget = null;
        target = null;
      } else {
        _managementTarget = refreshed;
        target = refreshed;
      }
    }

    final subject = target ?? st.activeSubject;
    if (subject == null) {
      setState(() {
        _loading = false;
        _error = '还没有学科信息（后端未就绪）。';
      });
      return;
    }
    setState(() {
      _subject = subject;
      _error = null;
      if (_progress == null) _loading = true;
    });
    try {
      final progress = await st.api.subjectProgress(subject.id);
      if (!mounted) return;
      setState(() {
        _progress = progress;
        _loading = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error is ApiException ? error.message : error.toString();
      });
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

  bool get _readOnly => _subject?.archived ?? false;

  // ------------------------------------------------------------------ 构建

  @override
  Widget build(BuildContext context) {
    final subject = _subject;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(subject),
        _tabBar(),
        if (_readOnly) _notice('学科已归档（只读）：可以查看资料与进度，写操作会被拒绝。', pal.warningInk),
        if (subject != null && subject.integrity != 'ok')
          _notice('找不到这个学科的数据文件，界面只显示注册信息。可重建空库或移除记录。', pal.danger),
        Expanded(
          child: _tab == 2
              ? SkillsPanel(
                  subjectId: subject?.id ?? 0,
                  subjectKey: subject?.key ?? _state.activeKey,
                  state: _state,
                  subjectArchived: _readOnly,
                )
              : _tab == 1
                  ? _progressTab()
                  : _overviewTab(),
        ),
      ],
    );
  }

  Widget _header(Subject? subject) {
    final name = subjectDisplayName(subject, _state.activeKey);
    final chips = <Widget>[
      if ((subject?.goal ?? '').isNotEmpty) _profileChip('目标', subject!.goal),
      if ((subject?.examDate ?? '').isNotEmpty) _profileChip('考试日', subject!.examDate),
      if ((subject?.dailyMinutes ?? 0) > 0)
        _profileChip('每日', '${subject!.dailyMinutes} 分钟'),
      if ((subject?.level ?? '').isNotEmpty) _profileChip('水平', subject!.level),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 20, 32, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: LoopType.display,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.5,
                          color: pal.ink,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Tooltip(
                      message: '数据目录 key：${subject?.key ?? _state.activeKey}',
                      child: SubjectAvatar(
                        name: name,
                        colorToken: subject?.color ?? '',
                        size: 22,
                        selected: true,
                      ),
                    ),
                  ],
                ),
                if (chips.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Wrap(spacing: 6, runSpacing: 6, children: chips),
                  ),
              ],
            ),
          ),
          IconButton(
            tooltip: '重新取数',
            onPressed: _loading ? null : _load,
            icon: Icon(Icons.refresh_rounded, size: 18, color: pal.muted),
          ),
          _manageMenu(subject),
        ],
      ),
    );
  }

  Widget _profileChip(String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: pal.chip,
        borderRadius: BorderRadius.circular(LoopRadius.pill),
        border: Border.all(color: pal.glassBorder),
      ),
      child: Text(
        '$label · $value',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: LoopType.caption, color: pal.muted),
      ),
    );
  }

  Widget _tabBar() {
    Widget tab(int index) {
      final selected = _tab == index;
      return Padding(
        padding: const EdgeInsets.only(right: 8),
        child: Material(
          key: Key('subject-tab-$index'),
          color: selected ? pal.chip : Colors.transparent,
          borderRadius: BorderRadius.circular(LoopRadius.control),
          child: InkWell(
            borderRadius: BorderRadius.circular(LoopRadius.control),
            onTap: () => setState(() => _tab = index),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(LoopRadius.control),
                border: Border.all(color: selected ? pal.glassBorder : pal.border),
              ),
              child: Text(
                _tabLabels[index],
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
      padding: const EdgeInsets.fromLTRB(32, 4, 32, 8),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [for (var i = 0; i < _tabLabels.length; i++) tab(i)],
        ),
      ),
    );
  }

  Widget _notice(String text, Color color) {
    return Container(
      margin: const EdgeInsets.fromLTRB(32, 0, 32, 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(LoopRadius.control),
        border: Border.all(color: color.withValues(alpha: 0.32)),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline_rounded, size: 15, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text, style: TextStyle(fontSize: LoopType.caption, color: pal.ink, height: 1.5)),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------------ 概览

  Widget _overviewTab() {
    if (_loading) return const Center(child: CircularProgressIndicator(strokeWidth: 2.4));
    if (_error != null && _progress == null) {
      return _errorView();
    }
    final progress = _progress ?? const SubjectProgress();
    final summary = progress.summary;
    final topics = progress.topics;
    final total = _int(summary['topics_total']);
    final events = _int(summary['events_total']);
    if (total == 0 && events == 0 && topics.isEmpty) return _emptyState();

    final due = _dueTopics(topics);
    final recent = _recentTopics(topics);

    return ListView(
      padding: const EdgeInsets.fromLTRB(32, 8, 32, 32),
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            _metricCard('覆盖度', _percent(summary['coverage']), '知识点 + 资料', pal.accent),
            _metricCard('掌握度均值', _percent(summary['mastery_avg']), '${_int(summary['studied_topics'])} 个在学习',
                pal.accentInk),
            _metricCard('已掌握', '${_int(summary['mastered'])}', '个知识点', pal.warningInk),
            _metricCard('连续学习', '${_int(summary['streak_days'])}', '天', pal.accent),
            _metricCard('近 7 天', '${_int(summary['minutes_7d'])}', '分钟', pal.accentInk),
            _metricCard('待复习', '${_int(summary['review_due'])}', '个知识点', pal.warningInk),
          ],
        ),
        const SizedBox(height: 22),
        _sectionTitle('待复习', due.isEmpty ? '' : '最多显示 5 个'),
        if (due.isEmpty)
          _hint('暂时没有到期的复习。新学的知识点会按掌握度自动排期。')
        else
          for (final topic in due.take(5)) _dueRow(topic),
        const SizedBox(height: 20),
        _sectionTitle('最近学习', recent.isEmpty ? '' : '按最近学习时间'),
        if (recent.isEmpty)
          _hint('还没有学习记录。去对话里问一个问题，AI 会开始记录这个学科的进度。')
        else
          for (final topic in recent) _recentRow(topic),
        const SizedBox(height: 20),
        _sectionTitle('这个学科', ''),
        _countsRow(summary),
      ],
    );
  }

  Widget _metricCard(String label, String value, String unit, Color color) {
    return Container(
      width: 148,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: panelDecoration(radius: LoopRadius.card),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: TextStyle(fontSize: LoopType.caption, color: pal.muted)),
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Flexible(
                child: Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: LoopType.display,
                    fontWeight: FontWeight.w700,
                    color: color,
                    letterSpacing: -0.6,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              Text(unit, style: TextStyle(fontSize: LoopType.micro, color: pal.muted)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(String title, String hint) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(title, style: TextStyle(fontSize: LoopType.body, fontWeight: FontWeight.w700, color: pal.ink)),
          if (hint.isNotEmpty) ...[
            const SizedBox(width: 8),
            Text(hint, style: TextStyle(fontSize: LoopType.micro, color: pal.muted)),
          ],
        ],
      ),
    );
  }

  Widget _hint(String text) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: softDecoration(radius: LoopRadius.control),
      child: Text(text, style: TextStyle(fontSize: LoopType.caption, color: pal.muted, height: 1.6)),
    );
  }

  Widget _countsRow(Map<String, dynamic> summary) {
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        _profileChip('资料', '${_int(summary['materials_total'])} 份'),
        _profileChip('已学资料', '${_int(summary['materials_studied'])} 份'),
        _profileChip('学习事件', '${_int(summary['events_total'])} 次'),
        _profileChip('知识点', '${_int(summary['topics_total'])} 个'),
      ],
    );
  }

  Widget _dueRow(TopicItem topic) {
    return _topicShell(
      topic,
      meta: '掌握度 ${(topic.mastery * 100).round()}% · 下次复习 ${_shortTime(topic.nextReviewAt)}',
      trailing: TextButton(
        key: Key('subject-due-${topic.id}'),
        onPressed: () => requestChatDraft('帮我复习「${topic.name}」，先出一道题。'),
        child: const Text('去复习'),
      ),
    );
  }

  Widget _recentRow(TopicItem topic) {
    return _topicShell(
      topic,
      meta: '最近学习 ${_shortTime(topic.lastStudiedAt)} · 掌握度 ${(topic.mastery * 100).round()}%',
      trailing: _masteryBar(topic.mastery),
    );
  }

  List<TopicItem> _dueTopics(List<TopicItem> topics) {
    final today = DateTime.now();
    final rows = topics.where((topic) {
      if (topic.status == 'archived') return false;
      if (topic.status == 'review_due') return true;
      if (topic.nextReviewAt.isEmpty) return false;
      final date = DateTime.tryParse(topic.nextReviewAt);
      if (date == null) return false;
      return !date.isAfter(today);
    }).toList();
    rows.sort((a, b) => a.nextReviewAt.compareTo(b.nextReviewAt));
    return rows;
  }

  List<TopicItem> _recentTopics(List<TopicItem> topics) {
    final rows = topics.where((topic) => topic.lastStudiedAt.isNotEmpty).toList()
      ..sort((a, b) => b.lastStudiedAt.compareTo(a.lastStudiedAt));
    return rows.take(3).toList();
  }

  // ------------------------------------------------------------------ 进度

  Widget _progressTab() {
    if (_loading) return const Center(child: CircularProgressIndicator(strokeWidth: 2.4));
    if (_error != null && _progress == null) return _errorView();
    final topics = (_progress?.topics ?? const <TopicItem>[])
        .where((topic) => topic.status != 'archived')
        .toList();
    if (topics.isEmpty) return _emptyState();
    return ListView(
      padding: const EdgeInsets.fromLTRB(32, 8, 32, 32),
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '${topics.length} 个知识点 · 掌握度与状态可以手工纠正（重算不会覆盖手工值）',
                  maxLines: 2,
                  style: TextStyle(fontSize: LoopType.caption, color: pal.muted, height: 1.5),
                ),
              ),
              const SizedBox(width: 8),
              TextButton.icon(
                key: const Key('subject-recompute'),
                onPressed: _busy || _readOnly ? null : _confirmRecompute,
                icon: const Icon(Icons.calculate_outlined, size: 16),
                label: const Text('重新计算进度'),
              ),
            ],
          ),
        ),
        for (final topic in topics) _topicTile(topic),
      ],
    );
  }

  Widget _topicTile(TopicItem topic) {
    return Container(
      key: Key('subject-topic-${topic.id}'),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      decoration: panelDecoration(radius: LoopRadius.card),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        topic.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: LoopType.body,
                          fontWeight: FontWeight.w600,
                          color: pal.ink,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _statusBadge(topic.status),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '最近学习 ${_shortTime(topic.lastStudiedAt)} · 下次复习 ${_shortTime(topic.nextReviewAt)}'
                  ' · 证据 ${topic.evidenceCount}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: LoopType.micro, color: pal.muted),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          _masteryBar(topic.mastery),
          IconButton(
            tooltip: '编辑掌握度/状态',
            onPressed: _readOnly ? null : () => _editTopic(topic),
            icon: Icon(Icons.edit_outlined, size: 16, color: pal.muted),
          ),
          IconButton(
            tooltip: '删除知识点',
            onPressed: _readOnly ? null : () => _deleteTopic(topic),
            icon: Icon(Icons.delete_outline_rounded, size: 17, color: pal.muted),
          ),
        ],
      ),
    );
  }

  Widget _topicShell(TopicItem topic, {required Widget trailing, required String meta}) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      decoration: panelDecoration(radius: LoopRadius.control),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  topic.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: LoopType.body, fontWeight: FontWeight.w600, color: pal.ink),
                ),
                const SizedBox(height: 2),
                Text(
                  meta,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: LoopType.micro, color: pal.muted),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          trailing,
        ],
      ),
    );
  }

  Widget _masteryBar(double mastery) {
    final value = mastery.clamp(0.0, 1.0);
    final color = value >= 0.9
        ? pal.accent
        : value >= 0.4
            ? pal.accentInk
            : pal.warningInk;
    return SizedBox(
      width: 86,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('${(value * 100).round()}%',
              style: TextStyle(fontSize: LoopType.caption, color: pal.ink, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(LoopRadius.pill),
            child: LinearProgressIndicator(
              value: value,
              minHeight: 5,
              backgroundColor: pal.chip,
              valueColor: AlwaysStoppedAnimation<Color>(color),
            ),
          ),
        ],
      ),
    );
  }

  Widget _statusBadge(String status) {
    final (label, color) = switch (status) {
      'mastered' => ('已掌握', pal.accent),
      'review_due' => ('待复习', pal.warningInk),
      'new' => ('新', pal.muted),
      'archived' => ('已归档', pal.faint),
      _ => ('学习中', pal.accentInk),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(LoopRadius.pill),
        border: Border.all(color: color.withValues(alpha: 0.34)),
      ),
      child: Text(label,
          style: TextStyle(fontSize: LoopType.micro, color: color, fontWeight: FontWeight.w600)),
    );
  }

  Widget _emptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.insights_outlined, size: 38, color: pal.muted),
            const SizedBox(height: 12),
            const Text('还没有学习记录', style: TextStyle(fontSize: LoopType.reading, fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Text(
              '在对话里问一个问题，AI 会开始记录这个学科的进度。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: LoopType.secondary, color: pal.muted),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              key: const Key('subject-go-chat'),
              onPressed: () => requestChatDraft(''),
              icon: const Icon(Icons.chat_bubble_outline_rounded, size: 17),
              label: const Text('去对话'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _errorView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error ?? '加载失败', style: TextStyle(fontSize: LoopType.secondary, color: pal.muted)),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: _load, child: const Text('重试')),
          ],
        ),
      ),
    );
  }

  // ------------------------------------------------------------------ 动作

  Future<void> _editTopic(TopicItem topic) async {
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => _TopicEditorDialog(topic: topic),
    );
    if (result == null || !mounted) return;
    final subject = _subject;
    if (subject == null) return;
    setState(() => _busy = true);
    try {
      final updated = await _state.api.patchSubjectProgress(subject.id, {
        'topics': [
          {'id': topic.id, ...result},
        ],
      });
      if (!mounted) return;
      setState(() {
        _progress = updated;
        _busy = false;
      });
      _snack('已保存「${topic.name}」的手工值（重算不会覆盖）');
    } catch (error) {
      if (mounted) setState(() => _busy = false);
      _snack(error is ApiException ? error.message : error.toString(), isError: true);
    }
  }

  Future<void> _deleteTopic(TopicItem topic) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除知识点'),
        content: Text('把「${topic.name}」从进度里移除？已产生的学习事件会保留。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('subject-topic-delete-confirm'),
            style: FilledButton.styleFrom(backgroundColor: pal.dangerInk),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    final subject = _subject;
    if (ok != true || subject == null || !mounted) return;
    try {
      await _state.api.deleteTopic(subject.id, topic.id);
      _snack('已移除「${topic.name}」');
      await _load();
    } catch (error) {
      _snack(error is ApiException ? error.message : error.toString(), isError: true);
    }
  }

  Future<void> _confirmRecompute() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重新计算进度'),
        content: const Text(
          '由学习事件重算每日汇总与知识点证据计数；不会凭空生成掌握度，'
          '手工纠正过的知识点会整条跳过。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('subject-recompute-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('开始重算'),
          ),
        ],
      ),
    );
    final subject = _subject;
    if (ok != true || subject == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final data = await _state.api.recomputeSubjectProgress(subject.id);
      if (!mounted) return;
      setState(() => _busy = false);
      _snack('重算完成：更新 ${data['topics_updated'] ?? 0} 个，'
          '保留手工值 ${data['topics_preserved'] ?? 0} 个');
      await _load();
    } catch (error) {
      if (mounted) setState(() => _busy = false);
      _snack(error is ApiException ? error.message : error.toString(), isError: true);
    }
  }

  Widget _manageMenu(Subject? subject) {
    return PopupMenuButton<String>(
      key: const Key('subject-manage-menu'),
      tooltip: '学科管理',
      color: pal.cardSolid,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(LoopRadius.control)),
      onSelected: (value) => _handleManage(value, subject),
      itemBuilder: (context) => [
        PopupMenuItem(
          key: const Key('subject-manage-rename'),
          value: 'rename',
          enabled: subject != null,
          child: Text('改名…', style: TextStyle(fontSize: LoopType.body, color: pal.ink)),
        ),
        PopupMenuItem(
          key: const Key('subject-manage-profile'),
          value: 'profile',
          enabled: subject != null,
          child: Text('编辑目标 / 考试日 / 每日时长…', style: TextStyle(fontSize: LoopType.body, color: pal.ink)),
        ),
        const PopupMenuDivider(),
        if (subject?.archived == true)
          PopupMenuItem(
            key: const Key('subject-manage-restore'),
            value: 'restore',
            child: Text('恢复学科', style: TextStyle(fontSize: LoopType.body, color: pal.ink)),
          )
        else
          PopupMenuItem(
            key: const Key('subject-manage-archive'),
            value: 'archive',
            enabled: subject != null && !subject.isDefault,
            child: Text(
              subject?.isDefault == true ? '归档（默认学科不支持）' : '归档学科',
              style: TextStyle(
                fontSize: LoopType.body,
                color: subject?.isDefault == true ? pal.faint : pal.ink,
              ),
            ),
          ),
        PopupMenuItem(
          key: const Key('subject-manage-delete'),
          value: 'delete',
          enabled: subject?.archived == true,
          child: Text(
            subject?.archived == true ? '删除学科（移入回收站）' : '删除（先归档）',
            style: TextStyle(
              fontSize: LoopType.body,
              color: subject?.archived == true ? pal.danger : pal.faint,
            ),
          ),
        ),
        if (subject != null && subject.integrity != 'ok') ...[
          const PopupMenuDivider(),
          PopupMenuItem(
            key: const Key('subject-manage-rebuild'),
            value: 'rebuild',
            child: Text('重建空库', style: TextStyle(fontSize: LoopType.body, color: pal.ink)),
          ),
          PopupMenuItem(
            key: const Key('subject-manage-unregister'),
            value: 'unregister',
            child: Text('移除记录', style: TextStyle(fontSize: LoopType.body, color: pal.dangerInk)),
          ),
        ],
      ],
      icon: Icon(Icons.more_horiz_rounded, size: 18, color: pal.muted),
    );
  }

  Future<void> _handleManage(String action, Subject? subject) async {
    if (subject == null) return;
    switch (action) {
      case 'rename':
        final name = await _promptText(
          title: '重命名学科',
          initial: subject.name,
          hint: '新的学科名',
          key: const Key('subject-rename-field'),
          confirmKey: const Key('subject-rename-save'),
        );
        if (name == null || name.isEmpty) return;
        await _patch({'name': name}, '已改名');
      case 'profile':
        final fields = await showDialog<Map<String, dynamic>>(
          context: context,
          builder: (context) => _ProfileDialog(subject: subject),
        );
        if (fields == null) return;
        await _patch(fields, '画像已更新');
      case 'archive':
        final ok = await _confirm('归档学科', '归档后默认列表不再出现，写操作会被拒绝；随时可以恢复。');
        if (!ok) return;
        await _subjectAction(() => _state.api.archiveSubject(subject.id), '已归档');
      case 'restore':
        await _subjectAction(() => _state.api.restoreSubject(subject.id), '已恢复');
      case 'delete':
        final key = await _promptText(
          title: '删除学科',
          initial: '',
          hint: '输入学科名以确认：${subject.name}',
          key: const Key('subject-delete-field'),
          confirmKey: const Key('subject-delete-confirm'),
          danger: true,
          confirmLabel: '删除',
        );
        if (key == null) return;
        if (key.trim() != subject.name.trim()) {
          _snack('输入的名称不一致，未删除', isError: true);
          return;
        }
        try {
          await _state.api.deleteSubject(subject.id, confirm: subject.key);
          _snack('已删除「${subject.name}」（数据移入回收站）');
          _managementTarget = null;
          _progress = null;
          await _state.loadSubjects();
          await _load();
        } catch (error) {
          _snack(error is ApiException ? error.message : error.toString(), isError: true);
        }
      case 'rebuild':
        final ok = await _confirm('重建空库', '会用空库替换缺失的学科库；旧文件不会自动找回。');
        if (!ok) return;
        await _subjectAction(() => _state.api.rebuildEmptySubject(subject.id), '已重建空库');
      case 'unregister':
        final ok = await _confirm('移除记录', '只从注册表移除，磁盘上的文件保持不动。');
        if (!ok) return;
        try {
          await _state.api.removeSubjectRegistryRow(subject.id);
          _managementTarget = null;
          _progress = null;
          await _state.loadSubjects();
          await _load();
          _snack('已移除注册记录');
        } catch (error) {
          _snack(error is ApiException ? error.message : error.toString(), isError: true);
        }
    }
  }

  Future<void> _patch(Map<String, dynamic> fields, String done) async {
    final subject = _subject;
    if (subject == null) return;
    try {
      await _state.api.patchSubject(subject.id, fields);
      await _state.loadSubjects();
      await _load();
      _snack(done);
    } catch (error) {
      _snack(error is ApiException ? error.message : error.toString(), isError: true);
    }
  }

  Future<void> _subjectAction(Future<Subject> Function() run, String done) async {
    try {
      await run();
      await _state.loadSubjects();
      await _load();
      _snack(done);
    } catch (error) {
      _snack(error is ApiException ? error.message : error.toString(), isError: true);
    }
  }

  Future<bool> _confirm(String title, String message) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  Future<String?> _promptText({
    required String title,
    required String initial,
    required String hint,
    required Key key,
    required Key confirmKey,
    bool danger = false,
    String confirmLabel = '保存',
  }) {
    return showDialog<String>(
      context: context,
      builder: (context) => _PromptDialog(
        title: title,
        initial: initial,
        hint: hint,
        fieldKey: key,
        confirmKey: confirmKey,
        danger: danger,
        confirmLabel: confirmLabel,
      ),
    );
  }

  // ------------------------------------------------------------------ 工具

  static int _int(Object? value) => (value as num?)?.toInt() ?? 0;

  static String _percent(Object? value) {
    final ratio = (value as num?)?.toDouble() ?? 0;
    return '${(ratio * 100).round()}%';
  }

  static String _shortTime(String raw) {
    if (raw.isEmpty) return '—';
    try {
      final date = DateTime.parse(raw).toLocal();
      final now = DateTime.now();
      final mm = date.month.toString().padLeft(2, '0');
      final dd = date.day.toString().padLeft(2, '0');
      if (date.year == now.year && date.month == now.month && date.day == now.day) {
        return '今天 ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
      }
      return '${date.year == now.year ? '' : '${date.year}-'}$mm-$dd';
    } catch (_) {
      return raw.length > 10 ? raw.substring(0, 10) : raw;
    }
  }
}

/// 知识点手工纠正（mastery + 状态）。保存后由后端标记为手工值，重算不覆盖。
class _TopicEditorDialog extends StatefulWidget {
  const _TopicEditorDialog({required this.topic});

  final TopicItem topic;

  @override
  State<_TopicEditorDialog> createState() => _TopicEditorDialogState();
}

class _TopicEditorDialogState extends State<_TopicEditorDialog> {
  late double _mastery = widget.topic.mastery.clamp(0.0, 1.0);
  late String _status = widget.topic.status;

  static const List<String> _statuses = ['new', 'learning', 'mastered', 'review_due'];

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.topic.name, style: const TextStyle(fontSize: LoopType.title)),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('掌握度 ${(_mastery * 100).round()}%',
                style: TextStyle(fontSize: LoopType.secondary, color: pal.ink)),
            Slider(
              key: const Key('subject-topic-mastery'),
              value: _mastery,
              divisions: 20,
              onChanged: (value) => setState(() => _mastery = value),
            ),
            const SizedBox(height: 6),
            Text('状态', style: TextStyle(fontSize: LoopType.secondary, color: pal.ink)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final status in _statuses)
                  ChoiceChip(
                    key: Key('subject-topic-status-$status'),
                    label: Text(_statusLabel(status), style: const TextStyle(fontSize: LoopType.secondary)),
                    selected: _status == status,
                    onSelected: (_) => setState(() => _status = status),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              '手工值会被标记，重新计算进度时整条跳过。',
              style: TextStyle(fontSize: LoopType.caption, color: pal.muted),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('subject-topic-save'),
          onPressed: () => Navigator.of(context).pop({
            'mastery': _mastery,
            'status': _status,
          }),
          child: const Text('保存'),
        ),
      ],
    );
  }

  static String _statusLabel(String status) => switch (status) {
        'mastered' => '已掌握',
        'review_due' => '待复习',
        'new' => '新',
        _ => '学习中',
      };
}

/// 单字段输入对话框（改名 / 删除确认）。controller 由 State 持有，
/// 随路由销毁一起释放，避免 pop 动画期间使用已释放的 controller。
class _PromptDialog extends StatefulWidget {
  const _PromptDialog({
    required this.title,
    required this.initial,
    required this.hint,
    required this.fieldKey,
    required this.confirmKey,
    this.danger = false,
    this.confirmLabel = '保存',
  });

  final String title;
  final String initial;
  final String hint;
  final Key fieldKey;
  final Key confirmKey;
  final bool danger;
  final String confirmLabel;

  @override
  State<_PromptDialog> createState() => _PromptDialogState();
}

class _PromptDialogState extends State<_PromptDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 360,
        child: TextField(
          key: widget.fieldKey,
          controller: _controller,
          autofocus: true,
          decoration: InputDecoration(hintText: widget.hint),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: widget.confirmKey,
          style: widget.danger
              ? FilledButton.styleFrom(backgroundColor: pal.dangerInk)
              : null,
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}

class _ProfileDialog extends StatefulWidget {
  const _ProfileDialog({required this.subject});

  final Subject subject;

  @override
  State<_ProfileDialog> createState() => _ProfileDialogState();
}

class _ProfileDialogState extends State<_ProfileDialog> {
  late final TextEditingController _goal = TextEditingController(text: widget.subject.goal);
  late final TextEditingController _exam = TextEditingController(text: widget.subject.examDate);
  late final TextEditingController _minutes =
      TextEditingController(text: widget.subject.dailyMinutes == 0 ? '' : '${widget.subject.dailyMinutes}');
  late final TextEditingController _level = TextEditingController(text: widget.subject.level);

  @override
  void dispose() {
    _goal.dispose();
    _exam.dispose();
    _minutes.dispose();
    _level.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('学科画像'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              key: const Key('subject-profile-goal'),
              controller: _goal,
              decoration: const InputDecoration(hintText: '学习目标'),
            ),
            const SizedBox(height: 10),
            TextField(
              key: const Key('subject-profile-exam'),
              controller: _exam,
              decoration: const InputDecoration(hintText: '考试日（如 2026-06-07）'),
            ),
            const SizedBox(height: 10),
            TextField(
              key: const Key('subject-profile-minutes'),
              controller: _minutes,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(hintText: '每日目标时长（分钟）'),
            ),
            const SizedBox(height: 10),
            TextField(
              key: const Key('subject-profile-level'),
              controller: _level,
              decoration: const InputDecoration(hintText: '水平（如 零基础 / 已过一轮）'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('subject-profile-save'),
          onPressed: () => Navigator.of(context).pop({
            'goal': _goal.text.trim(),
            'exam_date': _exam.text.trim(),
            'daily_minutes': int.tryParse(_minutes.text.trim()) ?? 0,
            'level': _level.text.trim(),
          }),
          child: const Text('保存'),
        ),
      ],
    );
  }
}