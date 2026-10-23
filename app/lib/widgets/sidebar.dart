import 'package:flutter/material.dart';

import '../models.dart';
import '../state.dart';
import '../theme.dart';
import 'glass.dart';

class Sidebar extends StatelessWidget {
  const Sidebar({
    super.key,
    required this.index,
    required this.onSelect,
    this.compact = false,
    this.canToggle = false,
    this.onToggleCollapse,
  });

  final int index;
  final ValueChanged<int> onSelect;
  final bool compact;
  final bool canToggle;
  final VoidCallback? onToggleCollapse;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: appState,
      builder: (context, _) {
        return AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          width: compact ? 76 : 250,
          margin: EdgeInsets.fromLTRB(compact ? 10 : 14, 8, 0, 14),
          child: GlassPanel(
            radius: compact ? 24 : 30,
            blur: 26,
            padding: compact
                ? const EdgeInsets.fromLTRB(8, 14, 8, 10)
                : const EdgeInsets.fromLTRB(12, 20, 12, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _brand(),
                _newChatButton(),
                SizedBox(height: compact ? 10 : 16),
                _navItem(0, Icons.chat_bubble_outline_rounded, '对话'),
                _navItem(1, Icons.checklist_rounded, '今日'),
                _navItem(2, Icons.menu_book_outlined, '笔记'),
                _navItem(3, Icons.folder_outlined, '资料'),
                _navItem(4, Icons.smart_toy_outlined, '代理'),
                if (!compact) ...[
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
                  Expanded(child: _history()),
                ] else
                  const Spacer(),
                const SizedBox(height: 6),
                _navItem(5, Icons.settings_outlined, '设置'),
              ],
            ),
          ),
        );
      },
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
    if (ok == true) await appState.deleteConversation(conversation.id);
  }

  Widget _brand() {
    final mark = Container(
      width: 38,
      height: 38,
      decoration: BoxDecoration(
        gradient: accentGradient,
        borderRadius: BorderRadius.circular(13),
        boxShadow: const [
          BoxShadow(color: Color(0x337B8CFF), blurRadius: 16, offset: Offset(0, 6)),
        ],
      ),
      child: const Icon(Icons.loop_rounded, color: Colors.white, size: 21),
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
                        fontSize: 17, fontWeight: FontWeight.w700, color: pal.ink, height: 1.2)),
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
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: compact ? 0 : 4),
      child: Tooltip(
        message: compact ? '新对话' : '',
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: () {
              onSelect(0);
              appState.newChat();
            },
            child: Ink(
              height: compact ? 44 : 46,
              decoration: BoxDecoration(
                gradient: accentGradient,
                borderRadius: BorderRadius.circular(16),
                boxShadow: const [
                  BoxShadow(color: Color(0x337B8CFF), blurRadius: 20, offset: Offset(0, 8)),
                ],
              ),
              child: compact
                  ? const Icon(Icons.add_rounded, size: 21, color: Colors.white)
                  : const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.add_rounded, size: 19, color: Colors.white),
                        SizedBox(width: 5),
                        Text('新对话',
                            style: TextStyle(
                                fontSize: 14, fontWeight: FontWeight.w600, color: Colors.white)),
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
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
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
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => onSelect(target),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
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
                        ? const Color(0xFF6C7BFF).withValues(alpha: 0.14)
                        : pal.chip,
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Icon(icon, size: 16, color: selected ? pal.accent : pal.muted),
                ),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
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

  Widget _history() {
    final items = appState.conversations;
    if (items.isEmpty) {
      return Padding(
        padding: EdgeInsets.fromLTRB(14, 8, 8, 8),
        child: Text('还没有历史对话', style: TextStyle(fontSize: 11.5, color: pal.muted)),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      itemCount: items.length,
      itemBuilder: (context, index) => _HistoryTile(
        conversation: items[index],
        selected: items[index].id == appState.currentConversationId,
        onTap: () {
          onSelect(0);
          appState.openConversation(items[index].id);
        },
        onDelete: () => _confirmDelete(context, items[index]),
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
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
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
                        fontSize: 12,
                        color: selected ? pal.ink : pal.muted,
                        fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  if (_hover)
                    InkWell(
                      borderRadius: BorderRadius.circular(6),
                      onTap: widget.onDelete,
                      child: Padding(
                        padding: const EdgeInsets.all(3),
                        child: Icon(Icons.delete_outline_rounded, size: 13, color: pal.faint),
                      ),
                    )
                  else
                    Text(_time, style: TextStyle(fontSize: 9.5, color: pal.faint)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
