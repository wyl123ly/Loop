import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/agent_plan_card.dart';
import '../widgets/glass.dart';
import '../widgets/markdown_text.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.active});

  final bool active;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _Attachment {
  _Attachment({required this.id, required this.name, required this.isImage});

  final String id;
  final String name;
  final bool isImage;
}

class _ChatScreenState extends State<ChatScreen> {
  final List<Message> _messages = [];
  final List<_Attachment> _attachments = [];
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final FocusNode _focus = FocusNode();

  int? _conversationId;
  String _mode = 'answer';
  String _modePrompt = '';
  String _thinking = 'medium';
  bool _sending = false;
  bool _uploading = false;
  bool _generating = false;
  bool _loadingMessages = false;
  bool _bootstrapped = false;
  int? _runId;
  Map<String, dynamic>? _approval;

  @override
  void initState() {
    super.initState();
    newChatSignal.addListener(_onNewChat);
    openConversationSignal.addListener(_onOpenConversation);
    deletedConversationSignal.addListener(_onConversationDeleted);
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  @override
  void dispose() {
    newChatSignal.removeListener(_onNewChat);
    openConversationSignal.removeListener(_onOpenConversation);
    deletedConversationSignal.removeListener(_onConversationDeleted);
    _controller.dispose();
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant ChatScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) _focus.requestFocus();
  }

  Future<void> _bootstrap() async {
    if (_bootstrapped) return;
    _bootstrapped = true;
    await appState.refreshConversations();
    if (!mounted) return;
    final items = appState.conversations;
    if (items.isNotEmpty) {
      await _loadConversation(items.first.id);
    } else {
      await _createConversation();
    }
  }

  void _onNewChat() => _createConversation();

  void _onOpenConversation() {
    final id = openConversationSignal.value;
    if (id != null) _loadConversation(id);
  }

  void _onConversationDeleted() {
    final id = deletedConversationSignal.value;
    if (id == null || id != _conversationId) return;
    setState(() {
      _conversationId = null;
      _messages.clear();
      _attachments.clear();
    });
    if (appState.conversations.isNotEmpty) {
      _loadConversation(appState.conversations.first.id);
    }
  }

  Future<void> _createConversation() async {
    if (_sending) {
      _snack('等这条回答结束再开新对话');
      return;
    }
    try {
      final id = await appState.api.createConversation();
      if (!mounted) return;
      setState(() {
        _conversationId = id;
        _messages.clear();
        _attachments.clear();
        _loadingMessages = false;
      });
      appState.setCurrentConversation(id);
      await appState.refreshConversations();
      _focus.requestFocus();
    } catch (error) {
      _snack(error.toString(), isError: true);
    }
  }

  Future<void> _loadConversation(int id) async {
    if (_sending) {
      _snack('等这条回答结束再切换对话');
      return;
    }
    if (id == _conversationId && _messages.isNotEmpty) return;
    setState(() {
      _conversationId = id;
      _messages.clear();
      _attachments.clear();
      _loadingMessages = true;
    });
    appState.setCurrentConversation(id);
    try {
      final items = await appState.api.messages(id);
      if (!mounted || _conversationId != id) return;
      setState(() {
        _messages.addAll(items);
        _loadingMessages = false;
      });
      _scrollToEnd();
      _focus.requestFocus();
    } catch (error) {
      if (!mounted) return;
      setState(() => _loadingMessages = false);
      _snack(error.toString(), isError: true);
    }
  }

  void _snack(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message, style: TextStyle(color: pal.toastFg, fontSize: 13)),
      backgroundColor: isError ? pal.danger : pal.toastBg,
      duration: const Duration(seconds: 3),
    ));
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent + 120,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _pickFile() async {
    const group = XTypeGroup(
      label: '学习资料',
      extensions: ['pdf', 'docx', 'pptx', 'txt', 'md', 'png', 'jpg', 'jpeg', 'webp'],
    );
    try {
      final file = await openFile(acceptedTypeGroups: [group]);
      if (file == null) return;
      final bytes = await file.readAsBytes();
      setState(() => _uploading = true);
      final result = await appState.api.upload(bytes, file.name);
      if (!mounted) return;
      setState(() {
        _uploading = false;
        _attachments.add(_Attachment(
          id: result['id'] as String,
          name: (result['name'] ?? file.name) as String,
          isImage: result['kind'] == 'image',
        ));
      });
      final isImage = result['kind'] == 'image';
      _snack(isImage ? '图片已附上' : '已解析 ${result['pages']} 页，可以提问了');
    } catch (error) {
      if (mounted) setState(() => _uploading = false);
      _snack(error.toString(), isError: true);
    }
  }

  Future<void> _send() async {
    if (_sending || _uploading || _generating) return;
    final text = _controller.text.trim();
    if (text.isEmpty && _attachments.isEmpty) return;

    final userMessage = Message(role: 'user', content: text.isEmpty ? '（见附件）' : text);
    final assistant = Message(role: 'assistant');
    final attachmentIds = _attachments.map((item) => item.id).toList();
    setState(() {
      _sending = true;
      _runId = null;
      _approval = null;
      _messages.add(userMessage);
      _messages.add(assistant);
      _controller.clear();
      _attachments.clear();
    });
    _scrollToEnd();

    try {
      var convId = _conversationId;
      if (convId == null) {
        convId = await appState.api.createConversation();
        _conversationId = convId;
        appState.setCurrentConversation(convId);
      }
      await for (final event in appState.api.chat(
        conversationId: convId,
        text: text,
        attachments: attachmentIds,
        mode: _mode,
        modePrompt: _modePrompt,
        thinking: _thinking,
      )) {
        if (!mounted) return;
        switch (event.event) {
          case 'delta':
            final delta = (event.data['text'] ?? '') as String;
            setState(() => assistant.content += delta);
            _scrollToEnd();
          case 'run':
            setState(() => _runId = (event.data['run_id'] as num?)?.toInt());
          case 'plan':
            final items = (event.data['items'] as List? ?? [])
                .whereType<Map>()
                .map((e) => PlanItem.fromJson(Map<String, dynamic>.from(e)))
                .toList();
            setState(() => assistant.plan = items);
          case 'approval':
            setState(() {
              _approval = Map<String, dynamic>.from(event.data);
            });
          case 'cancelled':
            setState(() {
              _sending = false;
              _approval = null;
              _runId = null;
            });
            _snack('已停止本次执行');
          case 'step':
            final step = ToolStep.fromJson(event.data);
            setState(() {
              final last = assistant.steps.isEmpty ? null : assistant.steps.last;
              if (last != null && last.name == step.name && last.status == 'running') {
                assistant.steps[assistant.steps.length - 1] = step;
              } else {
                assistant.steps.add(step);
              }
            });
          case 'done':
            setState(() {
              _approval = null;
              _runId = null;
              assistant.id = event.data['message_id'] as int?;
              assistant.tokensIn = (event.data['tokens_in'] ?? 0) as int;
              assistant.tokensOut = (event.data['tokens_out'] ?? 0) as int;
              assistant.cost = ((event.data['cost'] ?? 0) as num).toDouble();
              assistant.refs = (event.data['refs'] as List? ?? [])
                  .whereType<Map>()
                  .map((e) => RefItem.fromJson(Map<String, dynamic>.from(e)))
                  .toList();
            });
            appState.refreshConversations();
          case 'error':
            setState(() => _messages.remove(assistant));
            _snack((event.data['message'] ?? '出错了') as String, isError: true);
        }
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          if (assistant.content.isEmpty) _messages.remove(assistant);
        });
      }
      _snack(error.toString(), isError: true);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _resolveApproval(bool allow) async {
    final data = _approval;
    if (data == null) return;
    final runId = (data['run_id'] as num?)?.toInt() ?? _runId;
    setState(() => _approval = null);
    if (runId == null) return;
    try {
      await appState.api.approveRun(runId, allow);
    } catch (error) {
      _snack(error.toString(), isError: true);
    }
  }

  Future<void> _stop() async {
    final runId = _runId;
    if (runId == null) return;
    try {
      await appState.api.cancelRun(runId);
    } catch (error) {
      _snack(error.toString(), isError: true);
    }
  }

  Widget _approvalCard() {
    final data = _approval!;
    final tool = (data['tool'] ?? '').toString();
    final args = const JsonEncoder.withIndent('  ').convert(data['args'] ?? {});
    final clipped = args.length > 900 ? '${args.substring(0, 900)}\n…' : args;
    return Container(
      margin: const EdgeInsets.fromLTRB(24, 6, 24, 0),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
      decoration: panelDecoration(radius: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.shield_outlined, size: 16, color: pal.warm),
              const SizedBox(width: 6),
              Text('需要你确认：$tool',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: pal.ink)),
            ],
          ),
          const SizedBox(height: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 180),
            child: SingleChildScrollView(
              child: Text(clipped,
                  style: TextStyle(fontSize: 11.5, height: 1.5, color: pal.muted, fontFamily: 'monospace')),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(onPressed: () => _resolveApproval(false), child: const Text('拒绝')),
              const SizedBox(width: 6),
              FilledButton(onPressed: () => _resolveApproval(true), child: const Text('允许')),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _generate(String kind, Message message) async {
    if (message.id == null || _generating) return;
    setState(() => _generating = true);
    try {
      final result = await appState.api.generate(kind, message.id!);
      final text = kind == 'note' ? '已保存到笔记' : '已加入待办：${result['title'] ?? ''}';
      _snack(text);
    } catch (error) {
      _snack(error.toString(), isError: true);
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  String get _title {
    final conversation = appState.conversationById(_conversationId);
    return conversation?.title ?? '新对话';
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _header(context),
        Expanded(child: _body()),
        if (_approval != null) _approvalCard(),
        _composer(context),
      ],
    );
  }

  List<CustomMode> get _modes => [
        const CustomMode(id: 'answer', name: '答疑', prompt: ''),
        const CustomMode(id: 'socratic', name: '苏格拉底', prompt: ''),
        const CustomMode(id: 'read', name: '精读', prompt: ''),
        ...appState.customModes,
      ];

  String get _modeLabel =>
      _modes.firstWhere((mode) => mode.id == _mode, orElse: () => _modes.first).name;

  CustomMode? get _currentCustom {
    for (final mode in appState.customModes) {
      if (mode.id == _mode) return mode;
    }
    return null;
  }

  IconData _modeIcon(String id) => switch (id) {
        'socratic' => Icons.psychology_alt_outlined,
        'read' => Icons.menu_book_outlined,
        'answer' => Icons.chat_bubble_outline_rounded,
        _ => Icons.tune_rounded,
      };

  Future<void> _onModeSelected(String id) async {
    if (id == '__new__') return _newMode();
    if (id == '__edit__') return _editCurrentMode();
    if (id == '__delete__') return _deleteCurrentMode();
    final mode = _modes.firstWhere((item) => item.id == id);
    setState(() {
      _mode = mode.id;
      _modePrompt = mode.prompt;
      _thinking = mode.thinking;
    });
  }

  Future<void> _newMode() async {
    final mode = await showDialog<CustomMode>(
      context: context,
      builder: (_) => const _ModeEditorDialog(),
    );
    if (mode == null) return;
    await appState.saveCustomModes([...appState.customModes, mode]);
    if (!mounted) return;
    setState(() {
      _mode = mode.id;
      _modePrompt = mode.prompt;
      _thinking = mode.thinking;
    });
  }

  Future<void> _editCurrentMode() async {
    final custom = _currentCustom;
    if (custom == null) return;
    final updated = await showDialog<CustomMode>(
      context: context,
      builder: (_) => _ModeEditorDialog(initial: custom),
    );
    if (updated == null) return;
    final list = appState.customModes
        .map((mode) => mode.id == updated.id ? updated : mode)
        .toList();
    await appState.saveCustomModes(list);
    if (!mounted) return;
    setState(() {
      _mode = updated.id;
      _modePrompt = updated.prompt;
      _thinking = updated.thinking;
    });
  }

  Future<void> _deleteCurrentMode() async {
    final custom = _currentCustom;
    if (custom == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除模式'),
        content: Text('删除自定义模式「${custom.name}」？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('删除')),
        ],
      ),
    );
    if (ok != true) return;
    await appState.saveCustomModes(
      appState.customModes.where((mode) => mode.id != custom.id).toList(),
    );
    if (!mounted) return;
    setState(() {
      _mode = 'answer';
      _modePrompt = '';
      _thinking = 'medium';
    });
  }

  Widget _modePicker() {
    return PopupMenuButton<String>(
      tooltip: '问答模式',
      onSelected: _onModeSelected,
      itemBuilder: (context) => [
        for (final mode in _modes)
          PopupMenuItem(
            value: mode.id,
            child: Row(
              children: [
                Icon(_modeIcon(mode.id), size: 15,
                    color: mode.id == _mode ? pal.accent : pal.muted),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    mode.name,
                    style: TextStyle(
                      fontSize: 12.5,
                      color: mode.id == _mode ? pal.ink : pal.muted,
                      fontWeight: mode.id == _mode ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ),
                if (mode.id == _mode)
                  Icon(Icons.check_rounded, size: 14, color: pal.accent),
              ],
            ),
          ),
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: '__new__',
          child: Row(children: [
            Icon(Icons.add_rounded, size: 15),
            SizedBox(width: 8),
            Text('新建模式…', style: TextStyle(fontSize: 12.5)),
          ]),
        ),
        if (_currentCustom != null) ...[
          const PopupMenuItem(
            value: '__edit__',
            child: Row(children: [
              Icon(Icons.edit_outlined, size: 15),
              SizedBox(width: 8),
              Text('编辑当前模式', style: TextStyle(fontSize: 12.5)),
            ]),
          ),
          const PopupMenuItem(
            value: '__delete__',
            child: Row(children: [
              Icon(Icons.delete_outline_rounded, size: 15),
              SizedBox(width: 8),
              Text('删除当前模式', style: TextStyle(fontSize: 12.5)),
            ]),
          ),
        ],
      ],
      child: GlassPill(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.tune_rounded, size: 13, color: pal.muted),
            const SizedBox(width: 5),
            Text(_modeLabel,
                style: TextStyle(fontSize: 12.5, color: pal.ink, fontWeight: FontWeight.w500)),
            Icon(Icons.expand_more_rounded, size: 15, color: pal.muted),
          ],
        ),
      ),
    );
  }

  Widget _header(BuildContext context) {
    return Container(
      height: 78,
      padding: const EdgeInsets.fromLTRB(24, 18, 20, 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              _title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, letterSpacing: -0.3),
            ),
          ),
          _modePicker(),
          SizedBox(width: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
            decoration: BoxDecoration(
              color: pal.chip,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              appState.settings?.model ?? 'deepseek-flash',
              style: TextStyle(fontSize: 11, color: pal.muted),
            ),
          ),
          IconButton(
            tooltip: '新对话',
            onPressed: _createConversation,
            icon: Icon(Icons.add_comment_outlined, size: 19, color: pal.muted),
          ),
        ],
      ),
    );
  }

  Widget _body() {
    if (_loadingMessages) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2.4));
    }
    if (_messages.isEmpty) return _welcome(context);
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
      itemCount: _messages.length,
      itemBuilder: (context, index) => Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 880),
          child: _messageView(context, _messages[index]),
        ),
      ),
    );
  }

  Widget _welcome(BuildContext context) {
    final examples = [
      '解释一下 Transformer 里的注意力机制，配一个小例子',
      '用贝叶斯公式讲一个生活里的例子',
      '这段英文改得更地道：…',
      '帮我把这周要做的事排成待办',
    ];
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 54,
              height: 54,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF4F7CFF), Color(0xFF8B5CF6)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(16),
              ),
              child: const Icon(Icons.loop_rounded, color: Colors.white, size: 28),
            ),
            const SizedBox(height: 16),
            const Text('今天想学点什么？',
                style: TextStyle(fontSize: 30, fontWeight: FontWeight.w700, letterSpacing: -0.8)),
            const SizedBox(height: 6),
            Text(
              'AI、数学、英语，或者任何你想弄懂的东西。\n可以发文字、贴截图、传 PDF。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: pal.muted, height: 1.6),
            ),
            SizedBox(height: 22),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                for (final example in examples)
                  ActionChip(
                    label: Text(example, style: const TextStyle(fontSize: 12.5)),
                    backgroundColor: pal.chip,
                    side: BorderSide(color: pal.border),
                    onPressed: () {
                      _controller.text = example;
                      _controller.selection =
                          TextSelection.collapsed(offset: _controller.text.length);
                      _focus.requestFocus();
                    },
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _messageView(BuildContext context, Message message) {
    if (message.isUser) {
      return Align(
        alignment: Alignment.centerRight,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 620),
          margin: const EdgeInsets.only(bottom: 14, left: 48),
          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 12),
          decoration: BoxDecoration(
            gradient: accentGradient,
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(14),
              topRight: Radius.circular(4),
              bottomLeft: Radius.circular(14),
              bottomRight: Radius.circular(14),
            ),
          ),
          child: SelectableText(
            message.content,
            style: const TextStyle(fontSize: 14.5, height: 1.6, color: Colors.white),
          ),
        ),
      );
    }

    final empty = message.content.isEmpty;
    final refs = <String, RefItem>{};
    for (final ref in message.refs) {
      refs['${ref.name}#${ref.page}'] = ref;
    }
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 18),
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 12),
      decoration: panelDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (message.plan.isNotEmpty) AgentPlanCard(plan: message.plan),
          if (message.steps.isNotEmpty) ...[
            _steps(message.steps),
            const SizedBox(height: 10),
          ],
          if (empty && _sending)
            Row(
              children: [
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                SizedBox(width: 10),
                Text('正在思考…', style: TextStyle(fontSize: 13, color: pal.muted)),
              ],
            ),
          if (!empty) MarkdownText(message.content),
          if (refs.isNotEmpty) ...[
            SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final ref in refs.values)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: pal.chip,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text('${ref.name} p.${ref.page}',
                        style: TextStyle(fontSize: 11, color: pal.muted)),
                  ),
              ],
            ),
          ],
          if (!empty && message.id != null) ...[
            const SizedBox(height: 6),
            _actions(message),
          ],
          if (!empty && message.tokensIn + message.tokensOut > 0)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                '${message.tokensIn} in · ${message.tokensOut} out'
                '${message.cost > 0 ? ' · ¥${(message.cost * 7.2).toStringAsFixed(4)}' : ''}',
                style: TextStyle(fontSize: 10.5, color: pal.faint),
              ),
            ),
        ],
      ),
    );
  }

  Widget _steps(List<ToolStep> steps) {
    final order = <String>[];
    final latest = <String, ToolStep>{};
    final counts = <String, int>{};
    for (final step in steps) {
      if (!latest.containsKey(step.name)) order.add(step.name);
      latest[step.name] = step;
      counts[step.name] = (counts[step.name] ?? 0) + 1;
    }
    return Wrap(
      spacing: 8,
      runSpacing: 6,
      children: [
        for (final name in order)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
            decoration: BoxDecoration(
              color: pal.chip,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: pal.border),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                latest[name]!.status == 'running'
                    ? SizedBox(
                        width: 10,
                        height: 10,
                        child: CircularProgressIndicator(strokeWidth: 1.6),
                      )
                    : const Icon(Icons.check_circle_rounded, size: 12, color: Color(0xFF16A34A)),
                SizedBox(width: 5),
                Text(latest[name]!.label,
                    style: TextStyle(fontSize: 11.5, color: pal.ink)),
                if (counts[name]! > 1)
                  Text(' ×${counts[name]}',
                      style: TextStyle(fontSize: 11, color: pal.muted)),
                if (latest[name]!.detail.isNotEmpty) ...[
                  SizedBox(width: 4),
                  Text(latest[name]!.detail,
                      style: TextStyle(fontSize: 11, color: pal.muted)),
                ],
              ],
            ),
          ),
      ],
    );
  }

  Widget _actions(Message message) {
    return Wrap(
      spacing: 2,
      children: [
        _actionButton('复制 Markdown', Icons.copy_all_outlined, () => _copyMarkdown(message)),
        _actionButton('存笔记', Icons.note_alt_outlined, () => _generate('note', message)),
        _actionButton('加待办', Icons.checklist_rounded, () => _generate('task', message)),
      ],
    );
  }

  Future<void> _copyMarkdown(Message message) async {
    await Clipboard.setData(ClipboardData(text: message.content));
    if (mounted) _snack('已复制 Markdown');
  }

  Widget _actionButton(String label, IconData icon, VoidCallback onTap) {
    return TextButton.icon(
      onPressed: _generating ? null : onTap,
      icon: Icon(icon, size: 15),
      label: Text(label, style: const TextStyle(fontSize: 12)),
      style: TextButton.styleFrom(
        foregroundColor: pal.muted,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        minimumSize: const Size(0, 30),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }

  Widget _composer(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: pal.glassFill,
        border: Border(top: BorderSide(color: pal.glassBorder)),
      ),
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 880),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_attachments.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final item in _attachments)
                        Container(
                          padding: const EdgeInsets.only(left: 8, right: 2),
                          decoration: BoxDecoration(
                            color: pal.chip,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: pal.border),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                item.isImage ? Icons.image_outlined : Icons.description_outlined,
                                size: 14,
                                color: pal.muted,
                              ),
                              SizedBox(width: 5),
                              ConstrainedBox(
                                constraints: const BoxConstraints(maxWidth: 220),
                                child: Text(
                                  item.name,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(fontSize: 11.5, color: pal.ink),
                                ),
                              ),
                              IconButton(
                                onPressed: () => setState(() => _attachments.remove(item)),
                                icon: const Icon(Icons.close_rounded, size: 13),
                                visualDensity: VisualDensity.compact,
                                constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
                                padding: EdgeInsets.zero,
                                color: pal.muted,
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              if (_uploading)
                const Padding(
                  padding: EdgeInsets.only(bottom: 8),
                  child: LinearProgressIndicator(minHeight: 2),
                ),
              Container(
                decoration: BoxDecoration(
                  color: pal.glassFill,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: pal.border),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    IconButton(
                      tooltip: '上传资料 / 图片',
                      onPressed: _uploading ? null : _pickFile,
                      icon: Icon(Icons.attach_file_rounded, size: 20, color: pal.muted),
                    ),
                    Expanded(
                      child: Focus(
                        onKeyEvent: (node, event) {
                          if (event is KeyDownEvent &&
                              event.logicalKey == LogicalKeyboardKey.enter) {
                            if (!HardwareKeyboard.instance.isShiftPressed) {
                              _send();
                              return KeyEventResult.handled;
                            }
                          }
                          return KeyEventResult.ignored;
                        },
                        child: TextField(
                          controller: _controller,
                          focusNode: _focus,
                          minLines: 1,
                          maxLines: 6,
                          textInputAction: TextInputAction.newline,
                          style: const TextStyle(fontSize: 14.5, height: 1.55),
                          decoration: const InputDecoration(
                            hintText: '问点什么，或者把题目截图、PDF 附上来…',
                            filled: false,
                            isDense: true,
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                            contentPadding: EdgeInsets.symmetric(vertical: 10),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: IconButton.filled(
                        tooltip: _sending ? '停止' : '发送',
                        onPressed: _sending ? _stop : _send,
                        icon: Icon(_sending ? Icons.stop_rounded : Icons.arrow_upward_rounded, size: 18),
                        style: IconButton.styleFrom(
                          backgroundColor: _sending ? pal.danger : pal.accent,
                          foregroundColor: Colors.white,
                          minimumSize: const Size(38, 38),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              Padding(
                padding: EdgeInsets.only(left: 4),
                child: Text(
                  'Enter 发送 · Shift + Enter 换行 · 每个对话独立上下文',
                  style: TextStyle(fontSize: 11, color: pal.faint),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}


class _ModeEditorDialog extends StatefulWidget {
  const _ModeEditorDialog({this.initial});

  final CustomMode? initial;

  @override
  State<_ModeEditorDialog> createState() => _ModeEditorDialogState();
}

class _ModeEditorDialogState extends State<_ModeEditorDialog> {
  final TextEditingController _name = TextEditingController();
  final TextEditingController _prompt = TextEditingController();
  String _thinking = 'medium';

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    if (initial != null) {
      _name.text = initial.name;
      _prompt.text = initial.prompt;
      _thinking = initial.thinking;
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _prompt.dispose();
    super.dispose();
  }

  void _save() {
    final name = _name.text.trim();
    final prompt = _prompt.text.trim();
    if (name.isEmpty || prompt.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('名称和提示词都要填')),
      );
      return;
    }
    Navigator.pop(
      context,
      CustomMode(
        id: widget.initial?.id ?? 'custom_${DateTime.now().millisecondsSinceEpoch}',
        name: name,
        prompt: prompt,
        thinking: _thinking,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.initial == null ? '新建模式' : '编辑模式'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _name,
              autofocus: true,
              decoration: InputDecoration(
                labelText: '模式名称',
                hintText: '例如：雅思写作教练',
                filled: true,
                fillColor: pal.chip,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _prompt,
              maxLines: 4,
              minLines: 3,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _save(),
              decoration: InputDecoration(
                labelText: '自定义提示词',
                hintText: '例如：你是雅思考官，先指出表达问题，再给更地道的版本和理由。',
                filled: true,
                fillColor: pal.chip,
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                const Text('思考强度', style: TextStyle(fontSize: 13)),
                const Spacer(),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'low', label: Text('低')),
                    ButtonSegment(value: 'medium', label: Text('中')),
                    ButtonSegment(value: 'high', label: Text('高')),
                  ],
                  selected: {_thinking},
                  showSelectedIcon: false,
                  onSelectionChanged: (value) => setState(() => _thinking = value.first),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '高强度会改用推理模型并先完整推理，速度更慢。',
              style: TextStyle(fontSize: 11, color: pal.muted),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(onPressed: _save, child: const Text('保存')),
      ],
    );
  }
}
