import 'package:flutter/material.dart';

import '../models.dart';
import '../state.dart';
import '../theme.dart';
import 'glass.dart';
import 'subject_switcher.dart';

class Sidebar extends StatelessWidget {
  const Sidebar({
    super.key,
    required this.index,
    required this.onSelect,
    this.compact = false,
    this.canToggle = false,
    this.onToggleCollapse,
    this.state,
  });

  final int index;
  final ValueChanged<int> onSelect;
  final bool compact;
  final bool canToggle;
  final VoidCallback? onToggleCollapse;

  /// 可选注入，便于 widget 测试；生产环境使用全局 [appState]。
  final AppState? state;

  AppState get _state => state ?? appState;

  /// 学科相关的 5 个页签（§10.1：对话/今日/笔记/资料/学科）。
  static const List<(int, IconData, String)> _subjectNav = [
    (0, Icons.chat_bubble_outline_rounded, '对话'),
    (1, Icons.checklist_rounded, '今日'),
    (2, Icons.menu_book_outlined, '笔记'),
    (3, Icons.folder_outlined, '资料'),
    (subjectPageIndex, Icons.school_outlined, '学科'),
  ];

  /// 全局页签（代理/设置）：不显示学科，也不随学科切换变化（§10.4）。
  static const List<(int, IconData, String)> _globalNav = [
    (5, Icons.smart_toy_outlined, '代理'),
    (settingsPageIndex, Icons.settings_outlined, '设置'),
  ];

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _state,
      builder: (context, _) {
        return AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          width: compact ? 76 : 248,
          margin: EdgeInsets.fromLTRB(compact ? 10 : 16, 8, compact ? 8 : 12, 16),
          child: GlassPanel(
            radius: 24,
            blur: 26,
            padding: compact
                ? const EdgeInsets.fromLTRB(8, 14, 8, 10)
                : const EdgeInsets.fromLTRB(12, 20, 12, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _brand(),
                _newChatButton(),
                SizedBox(height: compact ? 8 : 12),
                // §10.2：常驻一行学科切换器；切换后各页按新学科重新取数。
                SubjectSwitcher(state: _state, compact: compact),
                SizedBox(height: compact ? 6 : 12),
                if (compact) ...[
                  for (final item in _subjectNav)
                    _navItem(item.$1, item.$2, item.$3),
                  const Spacer(),
                  for (final item in _globalNav) ...[
                    if (item.$1 == settingsPageIndex) const SizedBox(height: 6),
                    _navItem(item.$1, item.$2, item.$3),
                  ],
                ] else ...[
                  Expanded(child: _expandedList(context)),
                  const SizedBox(height: 6),
                  for (final item in _globalNav)
                    _navItem(item.$1, item.$2, item.$3),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  /// 展开态：学科页签 + 最近对话**同一个滚动区**，窗口再矮也不会 overflow。
  Widget _expandedList(BuildContext context) {
    final items = _state.conversations;
    return ListView(
      padding: EdgeInsets.zero,
      children: [
        for (final item in _subjectNav) _navItem(item.$1, item.$2, item.$3),
        const SizedBox(height: 18),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 8, 6),
          child: Text('最近对话',
              style: TextStyle(
                  fontSize: 10,
                  letterSpacing: 1.2,
                  color: pal.faint,
                  fontWeight: FontWeight.w600)),
        ),
        if (items.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
            child: Text('这个学科还没有对话', style: TextStyle(fontSize: 11.5, color: pal.muted)),
          )
        else
          for (final conversation in items)
            _HistoryTile(
              conversation: conversation,
              selected: conversation.id == _state.currentConversationId,
              onTap: () {
                onSelect(chatPageIndex);
                _state.openConversation(conversation.id);
              },
              onDelete: () => _confirmDelete(context, conversation),
            ),
      ],
    );
  }

  Future<void> _confirmDelete(BuildContext context, Conversation conversation) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除对话'),
        content: Text('删除「${conversation.title.isEmpty ? '新对话' : conversation.title}」及全部消息？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('删除')),
        ],
      ),
    );
    if (ok == true) await _state.deleteConversation(conversation.id);
  }

  Widget _brand() {
    final mark = Container(
      width: 38,
      height: 38,
      decoration: BoxDecoration(
        gradient: accentGradient,
        borderRadius: BorderRadius.circular(LoopRadius.control),
        boxShadow: [
          BoxShadow(color: pal.accent.withValues(alpha: 0.2), blurRadius: 16, offset: Offset(0, 6)),
        ],
      ),
      child: Icon(Icons.loop_rounded, color: pal.onAccent, size: 20),
    );
    if (compact) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            mark,
            if (canToggle)
              SizedBox(
                width: 20,
                child: _collapseButton(expand: true),
              ),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 18),
      child: Row(
        children: [
          mark,
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('回路',
                    style: TextStyle(
                        fontSize: 18, fontWeight: FontWeight.w700, color: pal.ink, height: 1.2)),
                Text('Loop · 学习工作台',
                    style: TextStyle(fontSize: 10, color: pal.muted, height: 1.4)),
              ],
            ),
          ),
          if (canToggle) _collapseButton(expand: false),
        ],
      ),
    );
  }

  Widget _collapseButton({required bool expand}) {
    return Tooltip(
      message: expand ? '展开侧栏' : '收起侧栏',
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onToggleCollapse,
          child: SizedBox(
            width: 24,
            height: 28,
            child: Center(
              child: Text(
                expand ? '›' : '‹',
                style: TextStyle(
                  fontSize: 22,
                  height: 1,
                  fontWeight: FontWeight.w500,
                  color: pal.muted,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _newChatButton() {
    final p = pal;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: compact ? 0 : 4),
      child: Tooltip(
        message: compact ? '新对话' : '',
        child: Material(
          key: const Key('sidebar-new-chat'),
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(LoopRadius.control),
          child: InkWell(
            borderRadius: BorderRadius.circular(LoopRadius.control),
            onTap: () {
              onSelect(chatPageIndex);
              _state.newChat();
            },
            child: Ink(
              height: 44,
              decoration: BoxDecoration(
                gradient: p.accentFillGradient,
                borderRadius: BorderRadius.circular(LoopRadius.control),
                boxShadow: [
                  BoxShadow(
                    color: p.accent.withValues(alpha: 0.25),
                    blurRadius: 20,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: compact
                  ? Icon(Icons.add_rounded, size: 20, color: p.onAccent)
                  : Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.add_rounded, size: 18, color: p.onAccent),
                        const SizedBox(width: LoopSpace.x1),
                        Text('新对话',
                            style: TextStyle(
                                fontSize: LoopType.body,
                                fontWeight: FontWeight.w600,
                                color: p.onAccent)),
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _navItem(int target, IconData icon, String label) {
    final selected = index == target;
    if (compact) {
      // 紧凑态 7 个页签 + 学科切换器必须在 900×600 的侧栏高度内放下
      // （§10.5 不得 overflow）：纵向留白收到 1，单项 40。
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: Tooltip(
          message: label,
          child: Material(
            color: selected ? pal.chip : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => onSelect(target),
              child: Container(
                height: 38,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: selected ? pal.glassBorder : Colors.transparent,
                  ),
                ),
                child: Icon(
                  icon,
                  size: 18,
                  color: selected ? pal.accent : pal.muted,
                ),
              ),
            ),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 2, 2, 2),
      child: Material(
        color: selected ? pal.chip : Colors.transparent,
        borderRadius: BorderRadius.circular(LoopRadius.control),
        child: InkWell(
          borderRadius: BorderRadius.circular(LoopRadius.control),
          onTap: () => onSelect(target),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(LoopRadius.control),
              border: Border.all(
                color: selected ? pal.glassBorder : Colors.transparent,
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: selected
                        ? pal.accent.withValues(alpha: 0.14)
                        : pal.chip,
                    borderRadius: BorderRadius.circular(LoopRadius.small),
                  ),
                  child: Icon(icon, size: 16, color: selected ? pal.accent : pal.muted),
                ),
                const SizedBox(width: LoopSpace.x2),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                      color: selected ? pal.ink : pal.muted,
                    ),
                  ),
                ),
                if (selected)
                  Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(color: pal.accent, shape: BoxShape.circle),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  }

class _HistoryTile extends StatefulWidget {
  const _HistoryTile({
    required this.conversation,
    required this.selected,
    required this.onTap,
    required this.onDelete,
  });

  final Conversation conversation;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  State<_HistoryTile> createState() => _HistoryTileState();
}

class _HistoryTileState extends State<_HistoryTile> {
  bool _hover = false;

  Conversation get conversation => widget.conversation;
  bool get selected => widget.selected;
  VoidCallback get onTap => widget.onTap;

  String get _time {
    final raw = conversation.updatedAt;
    if (raw.length < 16) return '';
    try {
      final dt = DateTime.parse(raw).toLocal();
      final now = DateTime.now();
      if (dt.year == now.year && dt.month == now.month && dt.day == now.day) {
        return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
      }
      return '${dt.month}-${dt.day.toString().padLeft(2, '0')}';
    } catch (_) {
      return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: Material(
          color: selected ? pal.chip : Colors.transparent,
          borderRadius: BorderRadius.circular(LoopRadius.control),
          child: InkWell(
            borderRadius: BorderRadius.circular(LoopRadius.control),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Row(
                children: [
                  Icon(Icons.chat_bubble_outline_rounded,
                      size: 12, color: selected ? pal.accent : pal.faint),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      conversation.title.isEmpty ? '新对话' : conversation.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: LoopType.secondary,
                        color: selected ? pal.ink : pal.muted,
                        fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  if (_hover)
                    InkWell(
                      borderRadius: BorderRadius.circular(LoopRadius.small),
                      onTap: widget.onDelete,
                      child: Padding(
                        padding: const EdgeInsets.all(3),
                        child: Icon(Icons.delete_outline_rounded, size: 13, color: pal.faint),
                      ),
                    )
                  else
                    Text(_time, style: TextStyle(fontSize: LoopType.micro, color: pal.muted)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
