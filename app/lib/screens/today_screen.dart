import 'dart:async';

import 'package:flutter/material.dart';

import '../models.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/subject_switcher.dart';

class TodayScreen extends StatefulWidget {
  const TodayScreen({super.key, required this.active, this.state});

  final bool active;

  /// 可选注入，便于 widget 测试；生产环境使用全局 [appState]。
  final AppState? state;

  @override
  State<TodayScreen> createState() => _TodayScreenState();
}

class _TodayScreenState extends State<TodayScreen> {
  TodayData? _data;
  bool _loading = false;
  String? _error;
  final TextEditingController _taskInput = TextEditingController();

  AppState get _state => widget.state ?? appState;

  @override
  void initState() {
    super.initState();
    subjectChangedSignal.addListener(_onSubjectChanged);
    _load();
  }

  @override
  void didUpdateWidget(covariant TodayScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) _load();
  }

  @override
  void dispose() {
    subjectChangedSignal.removeListener(_onSubjectChanged);
    _taskInput.dispose();
    super.dispose();
  }

  /// 学科切换：待办属于当前学科（§10.4），必须按新学科重新取数。
  void _onSubjectChanged() {
    if (!mounted) return;
    unawaited(_load());
  }

  Future<void> _load() async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      final data = await _state.api.today();
      if (!mounted) return;
      setState(() {
        _data = data;
        _error = null;
      });
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _toggleTask(TaskItem task) async {
    try {
      await _state.api.patchTask(task.id, {'status': task.done ? 'todo' : 'done'});
      await _load();
    } catch (error) {
      _snack(error.toString(), isError: true);
    }
  }

  Future<void> _addTask() async {
    final title = _taskInput.text.trim();
    if (title.isEmpty) return;
    try {
      await _state.api.createTask(title: title, due: _data?.date ?? '');
      _taskInput.clear();
      await _load();
    } catch (error) {
      _snack(error.toString(), isError: true);
    }
  }

  Future<void> _deleteTask(TaskItem task) async {
    try {
      await _state.api.deleteTask(task.id);
      await _load();
    } catch (error) {
      _snack(error.toString(), isError: true);
    }
  }

  void _snack(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message, style: TextStyle(color: pal.toastFg, fontSize: 13)),
      backgroundColor: isError ? pal.danger : pal.toastBg,
    ));
  }

  String get _dateLabel {
    final raw = _data?.date;
    if (raw == null || raw.isEmpty) return '今天';
    try {
      final date = DateTime.parse(raw);
      const weekdays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
      return '${date.month} 月 ${date.day} 日 · ${weekdays[date.weekday - 1]}';
    } catch (_) {
      return raw;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          height: 78,
          padding: const EdgeInsets.fromLTRB(32, 20, 28, 6),
          child: Row(
            children: [
              Text('今日', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700, letterSpacing: -0.5)),
              SizedBox(width: 10),
              Text(_dateLabel, style: TextStyle(fontSize: 12.5, color: pal.muted)),
              const SizedBox(width: 10),
              // §10.4：今日是当前学科的作用域，页头必须显示学科名。
              SubjectChip(state: _state),
              Spacer(),
              IconButton(
                tooltip: '刷新',
                onPressed: _loading ? null : _load,
                icon: Icon(Icons.refresh_rounded, size: 18, color: pal.muted),
              ),
            ],
          ),
        ),
        Expanded(child: _body()),
      ],
    );
  }

  Widget _body() {
    final data = _data;
    if (_error != null && data == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, style: TextStyle(color: pal.muted, fontSize: 13)),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: _load, child: const Text('重试')),
          ],
        ),
      );
    }
    if (data == null) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2.4));
    }
    final remaining = data.tasks.length;
    return ListView(
      padding: const EdgeInsets.fromLTRB(28, 24, 28, 40),
      children: [
        _hero(data, remaining),
        const SizedBox(height: 16),
        _tasksCard(data),
        const SizedBox(height: 16),
        Row(
          children: [
            _stat('今日完成', '${data.doneToday}', '件'),
            const SizedBox(width: 12),
            _stat('待办总数', '${data.openTotal}', '件'),
            const SizedBox(width: 12),
            _stat('已逾期', '${data.overdue}', '件'),
          ],
        ),
      ],
    );
  }

  Widget _hero(TodayData data, int remaining) {
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: pal.hero,
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('今天要做的事',
                    style: TextStyle(fontSize: 12.5, color: Colors.white70)),
                const SizedBox(height: 6),
                Text(
                  remaining == 0 ? '清空了，休息一下' : '$remaining 件待办',
                  style: const TextStyle(
                      fontSize: 26, fontWeight: FontWeight.w700, color: Colors.white),
                ),
                const SizedBox(height: 4),
                Text(
                  remaining == 0
                      ? '想到什么随时在对话里加'
                      : '今日已完成 ${data.doneToday} 件 · 共 ${data.openTotal} 件待办',
                  style: const TextStyle(fontSize: 12.5, color: Colors.white70),
                ),
              ],
            ),
          ),
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Icon(Icons.task_alt_rounded, color: Colors.white, size: 24),
          ),
        ],
      ),
    );
  }

  Widget _tasksCard(TodayData data) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 10),
      decoration: panelDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('待办', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              SizedBox(width: 8),
              Text('${data.tasks.length} 件',
                  style: TextStyle(fontSize: 12, color: pal.muted)),
            ],
          ),
          const SizedBox(height: 6),
          if (data.tasks.isEmpty)
            Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text('还没有待办。可以手动加，也可以在对话里说「帮我安排今天的学习」。',
                  style: TextStyle(fontSize: 12.5, color: pal.muted)),
            ),
          for (final task in data.tasks) _taskRow(task, data),
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 6),
            child: Row(
              children: [
                Icon(Icons.add_rounded, size: 17, color: pal.muted),
                const SizedBox(width: 6),
                Expanded(
                  child: TextField(
                    controller: _taskInput,
                    onSubmitted: (_) => _addTask(),
                    style: const TextStyle(fontSize: 13),
                    decoration: const InputDecoration(
                      hintText: '加一件事，回车确认',
                      filled: false,
                      isDense: true,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      contentPadding: EdgeInsets.symmetric(vertical: 8),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _taskRow(TaskItem task, TodayData data) {
    final overdue = task.due.isNotEmpty && task.due.compareTo(data.date) < 0;
    final label = task.due.isEmpty
        ? '未排期'
        : (task.due == data.date ? '今天' : (overdue ? '逾期 · ${task.due.substring(5)}' : task.due));
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 30,
            height: 30,
            child: Checkbox(
              value: task.done,
              onChanged: (_) => _toggleTask(task),
              visualDensity: VisualDensity.compact,
            ),
          ),
          Expanded(
            child: Text(
              task.title,
              style: TextStyle(
                fontSize: 13.5,
                color: task.done ? pal.muted : pal.ink,
                decoration: task.done ? TextDecoration.lineThrough : null,
              ),
            ),
          ),
          if (label.isNotEmpty)
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                color: overdue ? pal.danger : pal.faint,
              ),
            ),
          if (task.estimateMin > 0)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Text('${task.estimateMin}min',
                  style: TextStyle(fontSize: 11, color: pal.faint)),
            ),
          IconButton(
            tooltip: '删除',
            onPressed: () => _deleteTask(task),
            icon: Icon(Icons.close_rounded, size: 14, color: pal.faint),
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }

  Widget _stat(String label, String value, String unit) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: panelDecoration(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: TextStyle(fontSize: 11.5, color: pal.muted)),
            SizedBox(height: 6),
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(value,
                    style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
                SizedBox(width: 3),
                Text(unit, style: TextStyle(fontSize: 11, color: pal.muted)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
