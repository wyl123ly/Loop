import 'package:flutter/material.dart';

import '../models.dart';
import '../state.dart';
import '../theme.dart';

/// 请求 Shell 切到「学科」页（切换器菜单里的「管理学科…」）。
///
/// 递增计数：每次点击都会通知（`ValueNotifier` 同值不通知，这里始终 +1）。
final ValueNotifier<int> subjectPageSignal = ValueNotifier<int>(0);

/// 对话正在流式回答（`ChatScreen._sending`）时为 true。
///
/// §10.2「阻塞」：回答进行中不允许切换学科，切换器变灰并提示
/// "回答中，停止后再切换"。设置点在 ChatScreen 的发送/收尾路径。
final ValueNotifier<bool> chatBusySignal = ValueNotifier<bool>(false);

/// 页签索引常量（§10.1）。`main.dart` 的 `_pageTitles` 必须与之一致。
const int chatPageIndex = 0;
const int subjectPageIndex = 4;
const int settingsPageIndex = 6;

/// 「带入对话输入框」请求（学科页的待复习/去对话按钮）。
///
/// [nonce] 保证同样的文本也能再次触发（`ValueNotifier` 同值不通知）。
class ChatDraftRequest {
  const ChatDraftRequest({required this.nonce, required this.text});

  final int nonce;
  final String text;
}

/// 请求 Shell 切到对话页并预填输入框；ChatScreen 监听后写入输入框。
final ValueNotifier<ChatDraftRequest?> chatDraftSignal =
    ValueNotifier<ChatDraftRequest?>(null);

/// 发出一次「切到对话页 + 预填文本」请求。
void requestChatDraft(String text) {
  chatDraftSignal.value = ChatDraftRequest(
    nonce: DateTime.now().microsecondsSinceEpoch,
    text: text,
  );
}

/// 学科色 token → 当前主题下的颜色。
///
/// 规格 §10.6：学科色只用于**色点/徽标/细边框**，不用于大面积背景；取值一律
/// 来自 `pal.*`（不新增硬编码色值），因此浅色/深色两套主题都自动成立。
Color subjectTokenColor(String token) {
  switch (token.trim().toLowerCase()) {
    case 'warm':
    case 'amber':
    case 'orange':
      return pal.warm;
    case 'violet':
    case 'purple':
    case 'accent2':
      return pal.accent2;
    case 'slate':
    case 'gray':
    case 'grey':
      return pal.muted;
    case 'ink':
      return pal.ink;
    case 'rose':
    case 'red':
      return pal.danger;
    case 'accent':
    case 'blue':
    case 'indigo':
    default:
      return pal.accent;
  }
}

/// 学科展示名：注册表未加载时给出稳定回退（默认学科叫「通用」）。
String subjectDisplayName(Subject? subject, String key) {
  final name = subject?.name.trim() ?? '';
  if (name.isNotEmpty) return name;
  final fallback = key.trim();
  if (fallback.isEmpty || fallback == 'default') return '通用';
  return fallback;
}

/// 学科首字（按 code point 取 1 个字符，emoji 不会截断）。
String subjectInitial(String name) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return '学';
  return String.fromCharCodes(trimmed.runes.take(1));
}

/// 学科色点/首字徽标（§10.6：色只出现在小面积上）。
class SubjectAvatar extends StatelessWidget {
  const SubjectAvatar({
    super.key,
    required this.name,
    this.colorToken = '',
    this.size = 26,
    this.selected = false,
  });

  final String name;
  final String colorToken;
  final double size;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final color = subjectTokenColor(colorToken);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color.withValues(alpha: selected ? 0.22 : 0.13),
        borderRadius: BorderRadius.circular(size * 0.32),
        border: Border.all(
          color: color.withValues(alpha: selected ? 0.75 : 0.42),
        ),
      ),
      child: Center(
        child: Text(
          subjectInitial(name),
          style: TextStyle(
            fontSize: size * 0.46,
            height: 1,
            fontWeight: FontWeight.w700,
            color: color,
          ),
        ),
      ),
    );
  }
}

/// 侧栏常驻的学科切换器（§10.2）。
///
/// - 展开态：一行「色点 + 学科名 + ▾」；
/// - 紧凑态（76 px 侧栏）：只剩徽标按钮，点击弹出**同一个**菜单；
/// - 切换只调 `AppState.switchSubject`（写 active_subject + 刷新 + 信号）。
class SubjectSwitcher extends StatelessWidget {
  const SubjectSwitcher({
    super.key,
    this.state,
    this.compact = false,
    this.enabled = true,
  });

  final AppState? state;
  final bool compact;
  final bool enabled;

  AppState get _state => state ?? appState;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: chatBusySignal,
      builder: (context, busy, _) => AnimatedBuilder(
        animation: _state,
        builder: (context, _) {
          final subject = _state.activeSubject;
          final key = _state.activeKey;
          final name = subjectDisplayName(subject, key);
          final colorToken = subject?.color ?? '';
          final archived = subject?.archived ?? false;
          final canSwitch = enabled && !busy;
          if (compact) {
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Tooltip(
                message: busy ? '回答中，停止后再切换学科' : '学科：$name（点击切换）',
                child: Material(
                  key: const Key('subject-switcher'),
                  color: Colors.transparent,
                  borderRadius: BorderRadius.circular(12),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: canSwitch
                        ? () => showSubjectMenu(context, state: _state)
                        : null,
                    child: SizedBox(
                      height: 36,
                      child: Center(
                        child: Opacity(
                          opacity: canSwitch ? 1 : 0.5,
                          child: SubjectAvatar(
                            name: name,
                            colorToken: colorToken,
                            size: 24,
                            selected: true,
                          ),
                        ),
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
              key: const Key('subject-switcher'),
              color: pal.chip,
              borderRadius: BorderRadius.circular(14),
              child: Tooltip(
                message: busy ? '回答中，停止后再切换学科' : '切换学科',
                child: InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: canSwitch
                      ? () => showSubjectMenu(context, state: _state)
                      : null,
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(8, 7, 8, 7),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: pal.glassBorder),
                    ),
                    child: Row(
                      children: [
                        Opacity(
                          opacity: canSwitch ? 1 : 0.5,
                          child: SubjectAvatar(
                            name: name,
                            colorToken: colorToken,
                            size: 22,
                            selected: true,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w700,
                                  color: canSwitch ? pal.ink : pal.muted,
                                  height: 1.2,
                                ),
                              ),
                              Text(
                                busy
                                    ? '回答中…'
                                    : (archived ? '已归档（只读）' : '当前学科'),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 9.5,
                                  color: pal.muted,
                                  height: 1.3,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Icon(Icons.expand_more_rounded, size: 16, color: pal.muted),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// 页头常驻的学科 chip（对话/今日/笔记/资料）。
///
/// 窄宽（< 520）退化为「色点 + tooltip」，保证 360 窄窗不溢出（§10.5）。
class SubjectChip extends StatelessWidget {
  const SubjectChip({super.key, this.state, this.forceDot = false});

  final AppState? state;
  final bool forceDot;

  AppState get _state => state ?? appState;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: chatBusySignal,
      builder: (context, busy, _) => AnimatedBuilder(
        animation: _state,
        builder: (context, _) {
          final subject = _state.activeSubject;
          final name = subjectDisplayName(subject, _state.activeKey);
          final colorToken = subject?.color ?? '';
          final narrow = forceDot || MediaQuery.sizeOf(context).width < 520;
          return Tooltip(
            message: busy ? '回答中，停止后再切换学科' : '当前学科：$name（点击切换）',
            child: Material(
              key: const Key('subject-chip'),
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(20),
              child: InkWell(
                borderRadius: BorderRadius.circular(20),
                onTap: busy
                    ? null
                    : () => showSubjectMenu(context, state: _state),
                child: Container(
                  padding: EdgeInsets.symmetric(horizontal: narrow ? 7 : 9, vertical: 5),
                  decoration: BoxDecoration(
                    color: pal.chip,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SubjectAvatar(
                        name: name,
                        colorToken: colorToken,
                        size: 14,
                        selected: true,
                      ),
                      if (!narrow) ...[
                        const SizedBox(width: 6),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 120),
                          child: Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 11.5, color: pal.ink),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// 打开学科菜单（当前学科列表 + 归档 + 新建 + 管理）。
///
/// 与侧栏切换器共用同一入口：紧凑态与展开态行为一致（§10.2）。
Future<void> showSubjectMenu(BuildContext anchorContext, {AppState? state}) async {
  final st = state ?? appState;
  var showArchived = false;
  while (true) {
    if (!anchorContext.mounted) return;
    final choice = await _openMenu(anchorContext, st, showArchived: showArchived);
    if (choice == null) return;
    switch (choice.kind) {
      case 'switch':
        if (choice.key == st.activeKey) return;
        final ok = await st.switchSubject(choice.key);
        if (!ok) {
          if (!anchorContext.mounted) return;
          ScaffoldMessenger.of(anchorContext).showSnackBar(SnackBar(
            content: Text('切换学科失败，请重试', style: TextStyle(color: pal.toastFg)),
            backgroundColor: pal.danger,
          ));
        }
        return;
      case 'archived':
        showArchived = true;
        continue;
      case 'collapse':
        showArchived = false;
        continue;
      case 'new':
        if (!anchorContext.mounted) return;
        await showNewSubjectDialog(anchorContext, state: st);
        return;
      case 'manage':
        subjectPageSignal.value = subjectPageSignal.value + 1;
        return;
      default:
        return;
    }
  }
}

class _MenuChoice {
  const _MenuChoice(this.kind, [this.key = '']);

  final String kind;
  final String key;
}

Future<_MenuChoice?> _openMenu(
  BuildContext anchorContext,
  AppState st, {
  required bool showArchived,
}) async {
  final box = anchorContext.findRenderObject();
  final screen = MediaQuery.sizeOf(anchorContext);
  RelativeRect position;
  if (box is RenderBox && box.hasSize) {
    final topLeft = box.localToGlobal(Offset.zero);
    final bottom = box.localToGlobal(box.size.bottomLeft(Offset.zero));
    position = RelativeRect.fromRect(
      Rect.fromLTWH(topLeft.dx, bottom.dy + 4, 1, 1),
      Offset.zero & screen,
    );
  } else {
    position = const RelativeRect.fromLTRB(48, 140, 300, 300);
  }

  final active = <Subject>[
    ...st.subjects.where((item) => !item.archived),
  ]..sort((a, b) {
      final byOrder = a.sortOrder.compareTo(b.sortOrder);
      if (byOrder != 0) return byOrder;
      return b.lastOpenedAt.compareTo(a.lastOpenedAt);
    });
  final archived = st.subjects.where((item) => item.archived).toList()
    ..sort((a, b) => a.name.compareTo(b.name));
  final hasActive = active.any((item) => item.key == st.activeKey);
  final activeSubject = st.activeSubject;
  final activeName = subjectDisplayName(activeSubject, st.activeKey);

  final items = <PopupMenuEntry<_MenuChoice>>[
    PopupMenuItem<_MenuChoice>(
      key: const Key('subject-menu-current'),
      enabled: false,
      height: 34,
      child: Text(
        '当前：$activeName',
        style: TextStyle(fontSize: 11, color: pal.muted, fontWeight: FontWeight.w600),
      ),
    ),
    for (final subject in active)
      PopupMenuItem<_MenuChoice>(
        key: Key('subject-menu-${subject.key}'),
        value: _MenuChoice('switch', subject.key),
        height: 42,
        child: SizedBox(
          width: 208,
          child: Row(
            children: [
              SubjectAvatar(
                name: subject.name,
                colorToken: subject.color,
                size: 20,
                selected: subject.key == st.activeKey,
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  subject.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    color: pal.ink,
                    fontWeight: subject.key == st.activeKey
                        ? FontWeight.w700
                        : FontWeight.w500,
                  ),
                ),
              ),
              if (subject.integrity != 'ok')
                Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: Tooltip(
                    message: '找不到这个学科的数据文件',
                    child: Icon(Icons.warning_amber_rounded, size: 14, color: pal.warm),
                  ),
                ),
              if (subject.key == st.activeKey)
                Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: Icon(Icons.check_rounded, size: 15, color: pal.accent),
                ),
            ],
          ),
        ),
      ),
    if (!hasActive && activeSubject == null)
      PopupMenuItem<_MenuChoice>(
        key: const Key('subject-menu-pending'),
        value: _MenuChoice('switch', st.activeKey),
        height: 42,
        child: SizedBox(
          width: 208,
          child: Text(
            activeName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 13, color: pal.ink, fontWeight: FontWeight.w700),
          ),
        ),
      ),
    if (archived.isNotEmpty && !showArchived)
      PopupMenuItem<_MenuChoice>(
        key: const Key('subject-menu-archived-toggle'),
        value: const _MenuChoice('archived'),
        height: 40,
        child: SizedBox(
          width: 208,
          child: Text(
            '查看归档（${archived.length}）',
            style: TextStyle(fontSize: 12, color: pal.muted),
          ),
        ),
      ),
    if (showArchived) ...[
      for (final subject in archived)
        PopupMenuItem<_MenuChoice>(
          key: Key('subject-menu-${subject.key}'),
          value: _MenuChoice('switch', subject.key),
          height: 42,
          child: SizedBox(
            width: 208,
            child: Row(
              children: [
                SubjectAvatar(
                  name: subject.name,
                  colorToken: subject.color,
                  size: 20,
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    subject.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, color: pal.muted),
                  ),
                ),
                Text('已归档', style: TextStyle(fontSize: 10, color: pal.faint)),
              ],
            ),
          ),
        ),
      PopupMenuItem<_MenuChoice>(
        key: const Key('subject-menu-archived-collapse'),
        value: const _MenuChoice('collapse'),
        height: 38,
        child: SizedBox(
          width: 208,
          child: Text('收起归档', style: TextStyle(fontSize: 12, color: pal.muted)),
        ),
      ),
    ],
    const PopupMenuDivider(),
    PopupMenuItem<_MenuChoice>(
      key: const Key('subject-menu-new'),
      value: const _MenuChoice('new'),
      height: 42,
      child: SizedBox(
        width: 208,
        child: Row(
          children: [
            Icon(Icons.add_rounded, size: 17, color: pal.accent),
            const SizedBox(width: 8),
            Text('＋ 新建学科…', style: TextStyle(fontSize: 13, color: pal.ink)),
          ],
        ),
      ),
    ),
    PopupMenuItem<_MenuChoice>(
      key: const Key('subject-menu-manage'),
      value: const _MenuChoice('manage'),
      height: 42,
      child: SizedBox(
        width: 208,
        child: Row(
          children: [
            Icon(Icons.tune_rounded, size: 16, color: pal.muted),
            const SizedBox(width: 8),
            Text('管理学科…', style: TextStyle(fontSize: 13, color: pal.ink)),
          ],
        ),
      ),
    ),
  ];

  return showMenu<_MenuChoice>(
    context: anchorContext,
    position: position,
    items: items,
    color: pal.cardSolid,
  );
}

/// 新建学科（单字段必填 + 可选目标/考试日/每日时长）；创建成功后自动切换。
Future<Subject?> showNewSubjectDialog(BuildContext context, {AppState? state}) async {
  final st = state ?? appState;
  final created = await showDialog<Subject>(
    context: context,
    builder: (context) => _NewSubjectDialog(state: st),
  );
  return created;
}

class _NewSubjectDialog extends StatefulWidget {
  const _NewSubjectDialog({required this.state});

  final AppState state;

  @override
  State<_NewSubjectDialog> createState() => _NewSubjectDialogState();
}

class _NewSubjectDialogState extends State<_NewSubjectDialog> {
  final TextEditingController _name = TextEditingController();
  final TextEditingController _goal = TextEditingController();
  final TextEditingController _exam = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _goal.dispose();
    _exam.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = '学科名不能为空');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final subject = await widget.state.createSubject(
      name: name,
      goal: _goal.text.trim(),
      examDate: _exam.text.trim(),
    );
    if (!mounted) return;
    if (subject == null) {
      setState(() {
        _saving = false;
        _error = '创建失败：名称可能已存在，或后端未就绪';
      });
      return;
    }
    Navigator.of(context).pop(subject);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('新建学科'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              key: const Key('subject-new-name'),
              controller: _name,
              autofocus: true,
              decoration: const InputDecoration(hintText: '学科名（必填），如：线性代数'),
              onSubmitted: (_) => _saving ? null : _save(),
            ),
            const SizedBox(height: 10),
            TextField(
              key: const Key('subject-new-goal'),
              controller: _goal,
              decoration: const InputDecoration(hintText: '学习目标（可选），如：考研数学一'),
            ),
            const SizedBox(height: 10),
            TextField(
              key: const Key('subject-new-exam'),
              controller: _exam,
              decoration: const InputDecoration(hintText: '考试日（可选），如：2026-06-07'),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(_error!, style: TextStyle(fontSize: 12, color: pal.danger)),
              ),
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                '每个学科有独立的对话、资料、进度与技能，互不串数据。',
                style: TextStyle(fontSize: 11, color: pal.muted),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('subject-new-save'),
          onPressed: _saving ? null : _save,
          child: Text(_saving ? '创建中…' : '创建并切换'),
        ),
      ],
    );
  }
}