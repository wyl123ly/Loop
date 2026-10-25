import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/markdown_text.dart';
import '../widgets/subject_switcher.dart';

class NotesScreen extends StatefulWidget {
  const NotesScreen({super.key, required this.active, this.state});

  final bool active;

  /// 可选注入，便于 widget 测试；生产环境使用全局 [appState]。
  final AppState? state;

  @override
  State<NotesScreen> createState() => _NotesScreenState();
}

class _NotesScreenState extends State<NotesScreen> {
  List<NoteItem> _items = [];
  int? _selectedId;
  bool _loading = true;
  String? _error;

  AppState get _state => widget.state ?? appState;

  @override
  void initState() {
    super.initState();
    subjectChangedSignal.addListener(_onSubjectChanged);
    _load();
  }

  @override
  void didUpdateWidget(covariant NotesScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) _load();
  }

  @override
  void dispose() {
    subjectChangedSignal.removeListener(_onSubjectChanged);
    super.dispose();
  }

  /// 学科切换：笔记属于当前学科（§10.4）。
  void _onSubjectChanged() {
    if (!mounted) return;
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final items = await _state.api.notes();
      if (!mounted) return;
      setState(() {
        _items = items;
        _loading = false;
        _error = null;
        if (_selectedId == null || !items.any((item) => item.id == _selectedId)) {
          _selectedId = items.isEmpty ? null : items.first.id;
        }
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  NoteItem? get _selected {
    for (final item in _items) {
      if (item.id == _selectedId) return item;
    }
    return null;
  }

  Future<void> _copy(NoteItem note) async {
    await Clipboard.setData(ClipboardData(text: '# ${note.title}\n\n${note.body}'));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('Markdown 已复制到剪贴板', style: TextStyle(color: pal.toastFg)),
      backgroundColor: pal.toastBg,
    ));
  }

  Future<void> _delete(NoteItem note) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除笔记'),
        content: Text('「${note.title}」删除后不可恢复。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFDC2626)),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _state.api.deleteNote(note.id);
      if (!mounted) return;
      setState(() => _selectedId = null);
      await _load();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.toString())));
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
              Text('笔记', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700, letterSpacing: -0.5)),
              SizedBox(width: 10),
              Text('${_items.length} 篇', style: TextStyle(fontSize: 12.5, color: pal.muted)),
              const SizedBox(width: 10),
              // §10.4：笔记属于当前学科，页头必须显示学科名。
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
    if (_loading) return Center(child: CircularProgressIndicator(strokeWidth: 2.4));
    if (_error != null) {
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
    if (_items.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.menu_book_outlined, size: 40, color: pal.faint),
            const SizedBox(height: 12),
            const Text('还没有笔记', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Text('在对话里点回答下方的「存笔记」，整理好的笔记会出现在这里。',
                style: TextStyle(fontSize: 12.5, color: pal.muted)),
          ],
        ),
      );
    }
    return Row(
      children: [
        SizedBox(width: 300, child: _list()),
        const VerticalDivider(width: 1, thickness: 1),
        Expanded(child: _reader()),
      ],
    );
  }

  Widget _list() {
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
      itemCount: _items.length,
      itemBuilder: (context, index) {
        final note = _items[index];
        final selected = note.id == _selectedId;
        return Padding(
          padding: const EdgeInsets.only(bottom: 2),
          child: Material(
            color: selected ? pal.chip : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () => setState(() => _selectedId = note.id),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      note.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.4,
                        fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                        color: selected ? pal.accent : pal.ink,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Text(_fmt(note.createdAt),
                            style: TextStyle(fontSize: 10.5, color: pal.faint)),
                        const Spacer(),
                        Text('${note.body.length} 字',
                            style: TextStyle(fontSize: 10.5, color: pal.faint)),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _reader() {
    final note = _selected;
    if (note == null) {
      return Center(
        child: Text('选一篇笔记查看', style: TextStyle(fontSize: 13, color: pal.muted)),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(32, 24, 24, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(note.title,
                  style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w700, height: 1.4)),
              SizedBox(height: 6),
              Row(
                children: [
                  Text(_fmt(note.createdAt),
                      style: TextStyle(fontSize: 11.5, color: pal.muted)),
                  if (note.sourceRef.isNotEmpty) ...[
                    const SizedBox(width: 10),
                    Text(_sourceLabel(note.sourceRef),
                        style: TextStyle(fontSize: 11.5, color: pal.faint)),
                  ],
                  const Spacer(),
                  TextButton.icon(
                    onPressed: () => _copy(note),
                    icon: const Icon(Icons.copy_rounded, size: 15),
                    label: const Text('复制 Markdown'),
                  ),
                  const SizedBox(width: 4),
                  TextButton.icon(
                    onPressed: () => _delete(note),
                    icon: const Icon(Icons.delete_outline_rounded, size: 15),
                    label: const Text('删除'),
                    style: TextButton.styleFrom(foregroundColor: const Color(0xFFB42318)),
                  ),
                ],
              ),
            ],
          ),
        ),
        Divider(height: 1),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(32, 20, 32, 40),
            child: MarkdownText(
              note.body,
              baseStyle: TextStyle(fontSize: 14.5, height: 1.75, color: pal.ink),
            ),
          ),
        ),
      ],
    );
  }

  String _sourceLabel(String ref) {
    if (ref.startsWith('msg:')) return '来源：对话中的回答';
    return '来源：$ref';
  }

  String _fmt(String raw) {
    try {
      final dt = DateTime.parse(raw).toLocal();
      String two(int value) => value.toString().padLeft(2, '0');
      return '${dt.year}-${two(dt.month)}-${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}';
    } catch (_) {
      return raw;
    }
  }
}
