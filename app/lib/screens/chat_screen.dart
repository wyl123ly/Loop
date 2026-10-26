import 'dart:async';
import 'dart:convert';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../desktop/floating_signals.dart';
import '../desktop/screenshot_service.dart';
import '../desktop/window_mode.dart';
import '../models.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/agent_plan_card.dart';
import '../widgets/glass.dart';
import '../widgets/image_preview.dart';
import '../widgets/markdown_text.dart';
import '../widgets/minimal_bar.dart';
import '../widgets/subject_switcher.dart';
import 'screenshot_overlay.dart';

/// 主窗口提交问题时的载荷（t3 侧；Shell 转成 t2 `AnswerSubmission`）。
@immutable
class ChatSubmission {
  const ChatSubmission({
    required this.conversationId,
    required this.question,
    this.runId,
    this.inputBarRect,
    this.themeMode = ThemeMode.system,
  });

  final int conversationId;

  /// 已 trim 的非空问题文本（附件-only 不会生成该对象）。
  final String question;
  final int? runId;

  /// 输入条在**主窗口逻辑坐标**中的矩形；主窗口/DPI 换算由 host 完成。
  final Rect? inputBarRect;
  final ThemeMode themeMode;
}

/// ChatScreen SSE → 回答窗 host 的数据源接口。
///
/// 生产实现由 Shell 适配 t2 的 `AnswerWindowHost`；widget 测试用 fake 记录
/// 调用。回答窗是只读镜像，所有写操作仍只发生在主窗口。
abstract class ChatAnswerSink {
  void submit(ChatSubmission submission);

  /// 流式增量（stream_output=false 时只收到一次整段文本）。
  void appendText(String delta);

  void setRunId(int? runId);

  void setPlan(List<PlanItem> plan);

  /// `state` 取协议 wire 值：thinking/streaming/tool/waiting_approval/done/stopped/error。
  void setStatus(String state, {String? label, bool approvalRequired = false});

  void complete({List<RefItem> refs = const []});

  void stop();

  void fail(String message);
}

class ChatScreen extends StatefulWidget {
  const ChatScreen({
    super.key,
    required this.active,
    this.state,
    this.floating = false,
    this.compact = false,
    this.minimal = false,
    this.screenshots,
    this.screenshotSignal,
    this.answerSink,
    this.onMinimalBack,
    this.onMinimalExpand,
    this.onMinimalDragStart,
  });

  final bool active;

  /// 可选注入，便于 widget 测试；生产环境使用全局 [appState]。
  final AppState? state;

  /// 浮窗形态：隐藏页头、按紧凑断点收缩（规格 §6）。
  final bool floating;

  /// 浮窗紧凑模式（宽 <420 或高 <520）。
  final bool compact;

  /// 极简形态（规格 §3）：只渲染 52px 紧凑条，消息区/页头不 build；
  /// 本 State（消息/附件/SSE/输入）保持不销毁。
  final bool minimal;

  /// 截图服务；测试注入 fake，生产使用平台实现。
  final ScreenshotService? screenshots;

  /// 截图请求信号（Alt+A / 浮窗截图按钮）；为空时监听全局信号。
  final ValueListenable<ScreenshotRequest?>? screenshotSignal;

  /// 回答浮窗数据源（可选；未注入时不产生任何回答窗行为）。
  final ChatAnswerSink? answerSink;

  /// 极简条“返回”= 退出浮窗到主窗口（不是展开到浮窗）。
  final VoidCallback? onMinimalBack;

  /// 双击极简条拖动区 = 退出极简、恢复展开浮窗。
  final VoidCallback? onMinimalExpand;

  /// 极简条拖动（注入 WindowController.startDragging）。
  final VoidCallback? onMinimalDragStart;

  @override
  State<ChatScreen> createState() => ChatScreenState();
}

// F-15：一个学科的输入草稿（文本 + 光标 + 待发附件）。
class _ChatDraft {
  const _ChatDraft({
    required this.text,
    required this.selection,
    required this.attachments,
  });

  final String text;
  final TextSelection selection;
  final List<_Attachment> attachments;
}

class _Attachment {
  _Attachment({required this.id, required this.name, required this.isImage});

  final String id;
  final String name;
  final bool isImage;
}

/// 对话页 State。类名公开仅为让 Shell 用 `GlobalKey<ChatScreenState>`
/// 保活（规格 §5.3）；字段仍然私有，测试通过只读 getter 断言。
class ChatScreenState extends State<ChatScreen> {
  final List<Message> _messages = [];
  final List<_Attachment> _attachments = [];
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final FocusNode _focus = FocusNode();

  AppState get _appState => widget.state ?? appState;

  int? _conversationId;
  String _mode = 'answer';
  String _modePrompt = '';
  String _thinking = 'medium';
  bool _sending = false;
  bool _uploading = false;
  bool _dragging = false;
  bool _screenshotting = false;
  bool _generating = false;
  bool _loadingMessages = false;
  bool _bootstrapped = false;
  int? _runId;
  Map<String, dynamic>? _approval;

  /// 用户是否停在消息区底部；上滚后暂停自动跟随（规格 §6.3 / FR-7）。
  bool _followTail = true;

  /// 已消费的截图请求 nonce，避免同一次请求重复触发。
  int _lastScreenshotNonce = 0;

  /// 已消费的「带入输入框」请求 nonce（学科页的待复习/去对话）。
  int _lastDraftNonce = 0;

  /// 输入条（常规 composer / 极简条）在窗口内的逻辑矩形，用于回答窗定位；
  /// 物理像素与窗口原点换算由主窗口 host 完成（规格 §4.5）。
  final GlobalKey _inputBarKey = GlobalKey(debugLabel: 'chat-input-bar');

  /// 进入极简前输入框是否有焦点（退出时按需恢复一次）。
  bool _hadInputFocusBeforeMinimal = false;

  // ---------------------------------------------------------------------------
  // 测试可观测接口（只读；字段保持私有）。
  // ---------------------------------------------------------------------------
  @visibleForTesting
  int? get conversationId => _conversationId;

  @visibleForTesting
  int get messageCount => _messages.length;

  @visibleForTesting
  int get attachmentCount => _attachments.length;

  @visibleForTesting
  bool get isSending => _sending;

  @visibleForTesting
  bool get isGenerating => _generating;

  @visibleForTesting
  int? get runId => _runId;

  @visibleForTesting
  bool get approvalVisible => _approval != null;

  @visibleForTesting
  bool get followTail => _followTail;

  /// 输入条当前逻辑矩形；未布局时返回 null。
  ///
  /// 生产用途：回答窗几何排除区（提交载荷 + Shell anchor 周期同步）。
  Rect? get inputBarRect {
    final render = _inputBarKey.currentContext?.findRenderObject();
    if (render is! RenderBox || !render.hasSize) return null;
    return render.localToGlobal(Offset.zero) & render.size;
  }

  /// 回答窗创建后的一次性焦点补偿（`AnswerWindowHost.onFocusCompensation`）。
  void focusInput() {
    if (!mounted) return;
    _focus.requestFocus();
  }

  ValueListenable<ScreenshotRequest?> get _screenshotSignal =>
      widget.screenshotSignal ?? screenshotRequestSignal;

  ScreenshotService get _screenshotService =>
      widget.screenshots ?? const PlatformScreenshotService();

  @override
  void initState() {
    super.initState();
    _lastSubjectKey = _appState.activeKey;
    newChatSignal.addListener(_onNewChat);
    openConversationSignal.addListener(_onOpenConversation);
    deletedConversationSignal.addListener(_onConversationDeleted);
    subjectChangedSignal.addListener(_onSubjectChanged);
    chatDraftSignal.addListener(_onChatDraft);
    _screenshotSignal.addListener(_onScreenshotRequest);
    _scroll.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  @override
  void dispose() {
    newChatSignal.removeListener(_onNewChat);
    openConversationSignal.removeListener(_onOpenConversation);
    deletedConversationSignal.removeListener(_onConversationDeleted);
    subjectChangedSignal.removeListener(_onSubjectChanged);
    chatDraftSignal.removeListener(_onChatDraft);
    _screenshotSignal.removeListener(_onScreenshotRequest);
    _scroll.removeListener(_onScroll);
    _controller.dispose();
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant ChatScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldSignal = oldWidget.screenshotSignal ?? screenshotRequestSignal;
    final newSignal = widget.screenshotSignal ?? screenshotRequestSignal;
    if (!identical(oldSignal, newSignal)) {
      oldSignal.removeListener(_onScreenshotRequest);
      newSignal.addListener(_onScreenshotRequest);
    }
    // 极简形态切换：进入时聚焦输入一次（用户动作）；退出时仅当进入前有焦点
    // 才恢复一次（规格 §2.8/§3.5），拖动/流式不抢焦。
    if (widget.minimal && !oldWidget.minimal) {
      _hadInputFocusBeforeMinimal = _focus.hasFocus;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.minimal && widget.active) _focus.requestFocus();
      });
    } else if (!widget.minimal && oldWidget.minimal) {
      if (_hadInputFocusBeforeMinimal) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && widget.active) _focus.requestFocus();
        });
      }
    }
    // 只有“从别的页签切到对话页”才聚焦一次；浮窗↔主窗口且一直在对话页
    // 时 active 不变，不重复抢焦点（规格 §8.4 / FR-11）。
    if (widget.active && !oldWidget.active) _focus.requestFocus();
  }

  void _onScreenshotRequest() {
    final request = _screenshotSignal.value;
    if (request == null || request.nonce == _lastScreenshotNonce) return;
    _lastScreenshotNonce = request.nonce;
    if (!widget.active) return;
    if (_sending || _uploading) {
      _snack('等这条回答结束再截图');
      return;
    }
    if (_screenshotting || captureInProgress.value) return;
    unawaited(_takeScreenshot(hideLoop: request.hideLoop));
  }

  Future<void> _bootstrap() async {
    if (_bootstrapped) return;
    _bootstrapped = true;
    await _appState.refreshConversations();
    if (!mounted) return;
    final items = _appState.conversations;
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
    if (_appState.conversations.isNotEmpty) {
      _loadConversation(_appState.conversations.first.id);
    }
  }

  /// §6.2：切换学科 = 换一整套会话。旧会话一律清空（绝不串会话），
  /// 新学科有会话就载入最近一条，没有就建一条新的；回答进行中不打断。
  ///
  /// F-15：**草稿与附件按学科分别保留**——切走时暂存当前草稿+附件，切回时恢复，
  /// 避免用户写了一半的内容在切学科时被清掉（同一学科内换会话仍会清空）。
  Future<void> _onSubjectChanged() async {
    if (!mounted) return;
    if (_sending) {
      _snack('回答中，停止后再切换学科');
      return;
    }
    // 目标学科以信号为准（信号可能先于 state.activeKey 更新到达）。
    final nextKey = (subjectChangedSignal.value ?? '').trim().isNotEmpty
        ? subjectChangedSignal.value!.trim()
        : _appState.activeKey;
    _stashDraft(_draftKey);
    setState(() {
      _conversationId = null;
      _messages.clear();
      _attachments.clear();
      _followTail = true;
    });
    await _appState.refreshConversations();
    if (!mounted) return;
    final items = _appState.conversations;
    if (items.isNotEmpty) {
      await _loadConversation(items.first.id);
    } else {
      await _createConversation();
    }
    // F-15：草稿恢复必须放在会话载入**之后**（载入会话会重置输入框）。
    if (mounted) {
      setState(() {
        _lastSubjectKey = nextKey;
        _restoreDraft(nextKey);
      });
    }
  }

  /// 当前学科的草稿槽（key = 学科 key；无学科时用空串）。
  final Map<String, _ChatDraft> _drafts = {};

  /// 上一次渲染时所属的学科 key（切换时用它来暂存旧草稿）。
  String _lastSubjectKey = '';

  String get _draftKey => _lastSubjectKey.isEmpty ? _appState.activeKey : _lastSubjectKey;

  /// 把输入框文本与附件暂存到 [key] 学科的槽（F-15）。
  void _stashDraft(String key) {
    final text = _controller.text;
    if (text.trim().isEmpty && _attachments.isEmpty) {
      _drafts.remove(key);
      return;
    }
    _drafts[key] = _ChatDraft(
      text: text,
      selection: _controller.selection,
      attachments: List<_Attachment>.from(_attachments),
    );
  }

  /// 恢复 [key] 学科的草稿（没有则清空输入框）——在载入新学科会话**之后**调用（F-15）。
  void _restoreDraft(String key) {
    final draft = _drafts[key];
    _controller.text = draft?.text ?? '';
    _controller.selection = draft?.selection ??
        TextSelection.collapsed(offset: _controller.text.length);
    _attachments
      ..clear()
      ..addAll(draft?.attachments ?? const []);
  }

  @visibleForTesting
  String get draftForActiveSubject => _drafts[_draftKey]?.text ?? '';

  @visibleForTesting
  int get stashedDraftCount => _drafts.length;

  /// 学科页「去对话 / 去复习」：把文本带进输入框（不自动发送）。
  void _onChatDraft() {
    final request = chatDraftSignal.value;
    if (request == null || request.nonce == _lastDraftNonce) return;
    _lastDraftNonce = request.nonce;
    if (!mounted) return;
    final text = request.text;
    if (text.isNotEmpty) {
      _controller.text = text;
      _controller.selection = TextSelection.collapsed(offset: text.length);
    }
    if (widget.active) _focus.requestFocus();
  }

  Future<void> _createConversation() async {
    if (_sending) {
      _snack('等这条回答结束再开新对话');
      return;
    }
    try {
      final id = await _appState.api.createConversation();
      if (!mounted) return;
      setState(() {
        _conversationId = id;
        _messages.clear();
        _attachments.clear();
        _loadingMessages = false;
      });
      _appState.setCurrentConversation(id);
      await _appState.refreshConversations();
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
    _appState.setCurrentConversation(id);
    try {
      final items = await _appState.api.messages(id);
      if (!mounted || _conversationId != id) return;
      setState(() {
        _messages.addAll(items);
        _loadingMessages = false;
        _followTail = true;
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

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    final atBottom = position.maxScrollExtent - position.pixels < 80;
    if (atBottom != _followTail) {
      setState(() => _followTail = atBottom);
    }
  }

  /// 流式/发送后跟随到底部：用户上滚后不再强制拉回（规格 §6.3）。
  /// 用 jumpTo 代替 180ms 动画，避免小窗每个 delta 都抖动。
  void _scrollToEnd() {
    if (!_followTail) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients || !_followTail) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  void _scrollToBottomNow() {
    setState(() => _followTail = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
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
      await _ingestFiles([file]);
    } catch (error) {
      _snack(error.toString(), isError: true);
    }
  }

  /// 反馈 #2：文件/图片可以直接拖进对话框，也支持一次拖多个。
  Future<void> _ingestFiles(List<XFile> files) async {
    if (files.isEmpty || _sending) return;
    setState(() => _uploading = true);
    var added = 0;
    String? note;
    final errors = <String>[];
    for (final file in files.take(10)) {
      try {
        final bytes = await file.readAsBytes();
        if (bytes.length > 64 * 1024 * 1024) {
          errors.add('${file.name} 超过 64MB，已跳过');
          continue;
        }
        final result = await _appState.api.upload(bytes, file.name);
        if (!mounted) return;
        _attachments.add(_Attachment(
          id: result['id'] as String,
          name: (result['name'] ?? file.name) as String,
          isImage: result['kind'] == 'image',
        ));
        added++;
        note = result['kind'] == 'image'
            ? '图片已附上'
            : '已解析 ${result['pages']} 页，可以提问了';
      } catch (error) {
        errors.add('${file.name}: $error');
      }
    }
    if (!mounted) return;
    setState(() => _uploading = false);
    if (added > 0) {
      _snack(files.length > 1 ? '已附上 $added 个文件' : (note ?? '附件已加入'));
    }
    if (errors.isNotEmpty) {
      _snack(errors.first, isError: true);
    }
  }

  Widget _dropTarget(BuildContext context) {
    return DropTarget(
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      onDragDone: (details) {
        setState(() => _dragging = false);
        unawaited(_ingestFiles(details.files));
      },
      child: Stack(
        children: [
          _composer(context),
          if (_dragging)
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  key: const Key('chat-drop-hint'),
                  color: pal.accent.withValues(alpha: 0.10),
                  alignment: Alignment.center,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    decoration: BoxDecoration(
                      color: pal.glassFill,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: pal.accent),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.file_download_outlined, size: 17, color: pal.accent),
                        const SizedBox(width: 8),
                        Text('松开即可添加附件', style: TextStyle(fontSize: 12.5, color: pal.ink)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _takeScreenshot({required bool hideLoop}) async {
    if (_screenshotting || _sending || _uploading) return;
    if (captureInProgress.value) return;
    final hadFocus = _focus.hasFocus;
    var retakes = 0;
    setState(() => _screenshotting = true);
    try {
      while (true) {
        // 等 PopupMenu / 按钮水波纹收起，避免“直接截图”把菜单截进去。
        await Future<void>.delayed(const Duration(milliseconds: 150));
        final session = await _screenshotService.start(hideLoop: hideLoop);
        if (session == null) {
          _snack('截图仅支持 Windows 桌面版', isError: true);
          return;
        }
        if (!mounted) {
          await _screenshotService.restore(session);
          return;
        }
        ScreenshotOverlayResult? result;
        try {
          result = await Navigator.of(context).push<ScreenshotOverlayResult>(
            PageRouteBuilder(
              opaque: true,
              transitionDuration: Duration.zero,
              reverseTransitionDuration: Duration.zero,
              pageBuilder: (_, _, _) => ScreenshotOverlay(imageBytes: session.bytes),
            ),
          );
        } finally {
          // 每次 start 必须且只能 restore 一次（取消/重截/异常都恢复窗口）。
          await _screenshotService.restore(session);
        }
        if (!mounted) return;
        if (result == null) return;
        if (result.retake) {
          if (retakes >= maxRetakes) {
            _snack('重截次数已用完（最多 3 次）', isError: true);
            return;
          }
          retakes++;
          continue;
        }
        final cropped = result.bytes;
        if (cropped == null || cropped.isEmpty) return;
        final uploaded = await _appState.api.upload(
          cropped,
          '截图-${DateTime.now().millisecondsSinceEpoch}.png',
        );
        if (!mounted) return;
        setState(() {
          _attachments.add(_Attachment(
            id: uploaded['id'] as String,
            name: (uploaded['name'] ?? '截图.png') as String,
            isImage: true,
          ));
        });
        if (hadFocus) _focus.requestFocus();
        _snack('截图已加入附件');
        return;
      }
    } catch (error) {
      if (mounted) _snack(error.toString(), isError: true);
    } finally {
      if (mounted) setState(() => _screenshotting = false);
    }
  }

  Future<void> _send() async {
    if (_sending || _uploading || _generating) return;
    final text = _controller.text.trim();
    if (text.isEmpty && _attachments.isEmpty) return;

    // 回答浮窗只属于极简形态：普通窗口/普通浮窗里提问必须留在主聊天。
    // 只有极简条中提交非空文本才创建/更新回答浮窗；附件-only 仍走主聊天。
    final showInAnswerWindow = widget.minimal && text.isNotEmpty;
    final inputBarRect = this.inputBarRect;

    final userMessage = Message(
      role: 'user',
      content: text.isEmpty ? '（见附件）' : text,
      attachments: [
        for (final item in _attachments)
          AttachmentItem(id: item.id, name: item.name, isImage: item.isImage),
      ],
    );
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
      _followTail = true;
    });
    // §10.2：回答进行中禁用学科切换（侧栏切换器据此变灰 + tooltip）。
    chatBusySignal.value = true;
    _scrollToEnd();

    var submitted = false;
    try {
      var convId = _conversationId;
      if (convId == null) {
        convId = await _appState.api.createConversation();
        _conversationId = convId;
        _appState.setCurrentConversation(convId);
      }
      if (showInAnswerWindow) {
        // 用户按下发送即创建（显示“思考中”），不等首个 delta（规格 §4.1）。
        widget.answerSink?.submit(ChatSubmission(
          conversationId: convId,
          question: text,
          runId: _runId,
          inputBarRect: inputBarRect,
          themeMode: _appState.themeMode,
        ));
        submitted = true;
      }
      await for (final event in _appState.api.chat(
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
            if (submitted) widget.answerSink?.appendText(delta);
            _scrollToEnd();
          case 'run':
            final runId = (event.data['run_id'] as num?)?.toInt();
            setState(() => _runId = runId);
            if (submitted) widget.answerSink?.setRunId(runId);
          case 'plan':
            final items = (event.data['items'] as List? ?? [])
                .whereType<Map>()
                .map((e) => PlanItem.fromJson(Map<String, dynamic>.from(e)))
                .toList();
            setState(() => assistant.plan = items);
            if (submitted) widget.answerSink?.setPlan(items);
          case 'approval':
            setState(() {
              _approval = Map<String, dynamic>.from(event.data);
            });
            if (submitted) {
              widget.answerSink?.setStatus('waiting_approval', approvalRequired: true);
            }
          case 'cancelled':
            setState(() {
              _sending = false;
              _approval = null;
              _runId = null;
            });
            chatBusySignal.value = false;
            if (submitted) widget.answerSink?.stop();
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
            if (submitted) {
              if (step.status == 'running') {
                widget.answerSink?.setStatus('tool', label: step.label);
              } else if (assistant.content.isEmpty) {
                widget.answerSink?.setStatus('thinking');
              }
            }
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
            if (submitted) widget.answerSink?.complete(refs: assistant.refs);
            _appState.refreshConversations();
          case 'error':
            setState(() => _messages.remove(assistant));
            final message = (event.data['message'] ?? '出错了') as String;
            if (submitted) widget.answerSink?.fail(message);
            _snack(message, isError: true);
        }
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          if (assistant.content.isEmpty) _messages.remove(assistant);
        });
      }
      if (submitted) widget.answerSink?.fail(error.toString());
      _snack(error.toString(), isError: true);
    } finally {
      if (mounted) setState(() => _sending = false);
      chatBusySignal.value = false;
    }
  }

  Future<void> _resolveApproval(bool allow) async {
    final data = _approval;
    if (data == null) return;
    final runId = (data['run_id'] as num?)?.toInt() ?? _runId;
    setState(() => _approval = null);
    if (runId == null) return;
    try {
      await _appState.api.approveRun(runId, allow);
    } catch (error) {
      _snack(error.toString(), isError: true);
    }
  }

  Future<void> _stop() async {
    final runId = _runId;
    if (runId == null) return;
    try {
      await _appState.api.cancelRun(runId);
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
      margin: EdgeInsets.fromLTRB(widget.compact ? 12 : 24, 6, widget.compact ? 12 : 24, 0),
      padding: EdgeInsets.fromLTRB(widget.compact ? 12 : 16, 12, widget.compact ? 12 : 16, 10),
      decoration: panelDecoration(radius: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.shield_outlined, size: 16, color: pal.warm),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '需要你确认：$tool',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: pal.ink),
                ),
              ),
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
      final result = await _appState.api.generate(kind, message.id!);
      final text = kind == 'note' ? '已保存到笔记' : '已加入待办：${result['title'] ?? ''}';
      _snack(text);
    } catch (error) {
      _snack(error.toString(), isError: true);
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  String get _title {
    final conversation = _appState.conversationById(_conversationId);
    return conversation?.title ?? '新对话';
  }

  @override
  Widget build(BuildContext context) {
    if (widget.minimal) return _minimalBar(context);
    return Column(
      children: [
        // 浮窗形态使用 FloatingBar，不再渲染主窗口页头（规格 §6.1）。
        if (!widget.floating) _header(context),
        Expanded(child: _body()),
        if (_approval != null) _approvalCard(),
        KeyedSubtree(key: _inputBarKey, child: _dropTarget(context)),
      ],
    );
  }

  /// 极简条：与主聊天共用 controller/focus/附件/发送/截图，State 不重建。
  /// 高度由窗口（52 高，减 1px 边框）强制，内部无上下留白。
  Widget _minimalBar(BuildContext context) {
    final busy = _uploading || _screenshotting || captureInProgress.value;
    final screenshotEnabled =
        !_sending && !_uploading && !_screenshotting && !captureInProgress.value;
    String? firstImageUrl;
    for (final item in _attachments) {
      if (item.isImage) {
        firstImageUrl = _appState.api.imageUrl(item.id);
        break;
      }
    }
    return KeyedSubtree(
      key: _inputBarKey,
      child: MinimalBar(
        controller: _controller,
        focusNode: _focus,
        sending: _sending,
        busy: busy,
        screenshotEnabled: screenshotEnabled,
        attachmentCount: _attachments.length,
        firstImageUrl: firstImageUrl,
        onSend: () {
          unawaited(_send());
        },
        onStop: () {
          unawaited(_stop());
        },
        onScreenshot: () {
          unawaited(_takeScreenshot(hideLoop: true));
        },
        onBlockedScreenshot: () => _snack('等这条回答结束再截图'),
        onBack: () => widget.onMinimalBack?.call(),
        onExpand: () => widget.onMinimalExpand?.call(),
        onDragStart: () => widget.onMinimalDragStart?.call(),
      ),
    );
  }

  List<CustomMode> get _modes => [
        const CustomMode(id: 'answer', name: '答疑', prompt: ''),
        const CustomMode(id: 'socratic', name: '苏格拉底', prompt: ''),
        const CustomMode(id: 'read', name: '精读', prompt: ''),
        ..._appState.customModes,
      ];

  String get _modeLabel =>
      _modes.firstWhere((mode) => mode.id == _mode, orElse: () => _modes.first).name;

  CustomMode? get _currentCustom {
    for (final mode in _appState.customModes) {
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
    await _appState.saveCustomModes([..._appState.customModes, mode]);
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
    final list = _appState.customModes
        .map((mode) => mode.id == updated.id ? updated : mode)
        .toList();
    await _appState.saveCustomModes(list);
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
    await _appState.saveCustomModes(
      _appState.customModes.where((mode) => mode.id != custom.id).toList(),
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
      // AC-07 断言 3：浮窗 360×420 下页头不得溢出——窄宽时省掉模型名徽标
      // （学科 chip 已按同一阈值退化为色点，见 SubjectChip）。
      child: LayoutBuilder(
        builder: (context, constraints) {
          final narrow = constraints.maxWidth < 520;
          return Row(
            children: [
              Expanded(
                child: Text(
                  _title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w700, letterSpacing: -0.3),
                ),
              ),
              // §10.4：对话页是当前学科的作用域，页头必须显示学科名（窄宽退化为色点）。
              SubjectChip(state: _appState),
              const SizedBox(width: 10),
              _modePicker(),
              if (!narrow) ...[
                const SizedBox(width: 12),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                  decoration: BoxDecoration(
                    color: pal.chip,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    _appState.settings?.model ?? 'deepseek-flash',
                    style: TextStyle(fontSize: 11, color: pal.muted),
                  ),
                ),
              ],
              IconButton(
                tooltip: '新对话',
                onPressed: _createConversation,
                icon: Icon(Icons.add_comment_outlined, size: 19, color: pal.muted),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _body() {
    if (_loadingMessages) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2.4));
    }
    if (_messages.isEmpty) return _welcome(context);
    final padding = widget.compact
        ? const EdgeInsets.fromLTRB(12, 12, 12, 8)
        : const EdgeInsets.fromLTRB(24, 20, 24, 8);
    return Stack(
      children: [
        ListView.builder(
          key: const Key('chat-message-list'),
          controller: _scroll,
          padding: padding,
          itemCount: _messages.length,
          itemBuilder: (context, index) => Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 880),
              child: _messageView(context, _messages[index]),
            ),
          ),
        ),
        if (!_followTail)
          Positioned(
            right: widget.compact ? 10 : 16,
            bottom: 10,
            child: Material(
              color: pal.toastBg,
              borderRadius: BorderRadius.circular(99),
              elevation: 2,
              child: InkWell(
                key: const Key('chat-scroll-bottom'),
                borderRadius: BorderRadius.circular(99),
                onTap: _scrollToBottomNow,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.arrow_downward_rounded, size: 14, color: pal.toastFg),
                      const SizedBox(width: 4),
                      Text('回到底部',
                          style: TextStyle(fontSize: 11.5, color: pal.toastFg)),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _welcome(BuildContext context) {
    if (widget.floating) return _floatingWelcome(context);
    return _desktopWelcome(context);
  }

  /// 浮窗空态：紧凑时精简为可滚动的一屏（360×420 不溢出，规格 §6.3）。
  Widget _floatingWelcome(BuildContext context) {
    if (!widget.compact) {
      final examples = [
        '解释一下 Transformer 里的注意力机制，配一个小例子',
        '用贝叶斯公式讲一个生活里的例子',
      ];
      return SingleChildScrollView(
        key: const Key('floating-welcome'),
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    gradient: accentGradient,
                    borderRadius: BorderRadius.circular(13),
                  ),
                  child: Icon(Icons.loop_rounded, color: pal.onAccent, size: 23),
                ),
                const SizedBox(height: 12),
                const Text('今天想学点什么？',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, letterSpacing: -0.4)),
                const SizedBox(height: 6),
                Text(
                  'AI、数学、英语，或者任何你想弄懂的东西。\n可以发文字、贴截图、传 PDF。',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12.5, color: pal.muted, height: 1.55),
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  alignment: WrapAlignment.center,
                  children: [
                    for (final example in examples)
                      ActionChip(
                        label: Text(example, style: const TextStyle(fontSize: 12)),
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
        ),
      );
    }
    return SingleChildScrollView(
      key: const Key('floating-welcome'),
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              gradient: accentGradient,
              borderRadius: BorderRadius.circular(11),
            ),
            child: Icon(Icons.loop_rounded, color: pal.onAccent, size: 19),
          ),
          const SizedBox(height: 10),
          const Text('今天想学点什么？',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, letterSpacing: -0.3)),
          const SizedBox(height: 6),
          Text(
            '发文字、贴截图或传 PDF，都可以问。',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: pal.muted, height: 1.5),
          ),
        ],
      ),
    );
  }

  /// 主窗口空态：保持 v0.4.0 的视觉不变（规格 AC-5.4）。
  Widget _desktopWelcome(BuildContext context) {
    final examples = [
      '解释一下 Transformer 里的注意力机制，配一个小例子',
      '用贝叶斯公式讲一个生活里的例子',
      '这段英文改得更地道：…',
      '帮我把这周要做的事排成待办',
    ];
    // 窄窗（460×600 等）下空态内容会超过可用高度：改成"可滚动 + 有空间时居中"，
    // 与浮窗空态（`floating-welcome`）同一策略，避免 RenderFlex overflow。
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight - 36),
          child: Center(
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
                      style: TextStyle(
                          fontSize: 30, fontWeight: FontWeight.w700, letterSpacing: -0.8)),
                  const SizedBox(height: 6),
                  Text(
                    'AI、数学、英语，或者任何你想弄懂的东西。\n可以发文字、贴截图、传 PDF。',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 13, color: pal.muted, height: 1.6),
                  ),
                  if (_appState.conversations.isEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      '这个学科还没有对话。问一个问题就开始。',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 12, color: pal.faint),
                    ),
                  ],
                  const SizedBox(height: 22),
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
          ),
        ),
      ),
    );
  }

  Widget _attachmentTile(_Attachment item) {
    if (!item.isImage) {
      return Container(
        padding: const EdgeInsets.only(left: 8, right: 2),
        decoration: BoxDecoration(
          color: pal.chip,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: pal.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.description_outlined, size: 14, color: pal.muted),
            const SizedBox(width: 5),
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
      );
    }
    final url = _appState.api.imageUrl(item.id);
    final tile = widget.compact ? 54.0 : 66.0;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Tooltip(
          message: item.name,
          child: GestureDetector(
            onTap: () => ImagePreview.show(context, url, title: item.name),
            child: Container(
              width: tile,
              height: tile,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: pal.border),
                color: pal.chip,
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(11),
                child: Image.network(
                  url,
                  fit: BoxFit.cover,
                  errorBuilder: (context, error, stack) => Icon(
                    Icons.broken_image_outlined,
                    size: 20,
                    color: pal.faint,
                  ),
                ),
              ),
            ),
          ),
        ),
        Positioned(
          top: -6,
          right: -6,
          child: Material(
            color: pal.toastBg,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: () => setState(() => _attachments.remove(item)),
              child: SizedBox(
                width: 20,
                height: 20,
                child: Icon(Icons.close_rounded, size: 12, color: pal.toastFg),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _sentImages(List<AttachmentItem> attachments) {
    final images = attachments.where((item) => item.isImage).toList();
    return Wrap(
      alignment: WrapAlignment.end,
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final item in images)
          GestureDetector(
            onTap: () => ImagePreview.show(
              context,
              _appState.api.imageUrl(item.id),
              title: item.name,
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Image.network(
                _appState.api.imageUrl(item.id),
                width: 138,
                height: 104,
                fit: BoxFit.cover,
                errorBuilder: (context, error, stack) => Container(
                  width: 138,
                  height: 104,
                  color: Colors.white.withValues(alpha: 0.14),
                  child: const Icon(Icons.broken_image_outlined, color: Colors.white70),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _sentFiles(List<AttachmentItem> attachments) {
    final files = attachments.where((item) => !item.isImage).toList();
    return Wrap(
      alignment: WrapAlignment.end,
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final item in files)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(7),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.description_outlined, size: 13, color: Colors.white70),
                const SizedBox(width: 5),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 220),
                  child: Text(
                    item.name,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11.5, color: Colors.white),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _messageView(BuildContext context, Message message) {
    if (message.isUser) {
      return Align(
        alignment: Alignment.centerRight,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 620),
          margin: EdgeInsets.only(bottom: 14, left: widget.compact ? 20 : 48),
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
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (message.attachments.any((item) => item.isImage)) ...[
                _sentImages(message.attachments),
                const SizedBox(height: 8),
              ],
              if (message.attachments.any((item) => !item.isImage)) ...[
                _sentFiles(message.attachments),
                const SizedBox(height: 8),
              ],
              if (message.content.isNotEmpty &&
                  !(message.content == '（见附件）' &&
                      message.attachments.isNotEmpty))
                SelectableText(
                  message.content,
                  style: const TextStyle(fontSize: 14.5, height: 1.6, color: Colors.white),
                ),
            ],
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
      padding: EdgeInsets.fromLTRB(
        widget.compact ? 12 : 18,
        widget.compact ? 12 : 16,
        widget.compact ? 12 : 18,
        widget.compact ? 10 : 12,
      ),
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
    final pad = widget.compact
        ? const EdgeInsets.fromLTRB(12, 8, 12, 10)
        : const EdgeInsets.fromLTRB(24, 12, 24, 16);
    final hint = widget.compact
        ? '问点什么，或贴截图…'
        : '问点什么，或者把题目截图、PDF 附上来…';
    return Container(
      key: const Key('chat-composer'),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: pal.glassFill,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
        border: Border(top: BorderSide(color: pal.glassBorder)),
      ),
      padding: pad,
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
                      for (final item in _attachments) _attachmentTile(item),
                    ],
                  ),
                ),
              if (_uploading || _screenshotting)
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
                    // 浮窗把截图入口收进 FloatingBar，输入区只保留附件（规格 §6.4）。
                    if (!widget.floating)
                      PopupMenuButton<String>(
                        tooltip: '截图',
                        enabled: !_sending && !_uploading && !_screenshotting,
                        onSelected: (value) => _takeScreenshot(hideLoop: value == 'hide'),
                        icon: Icon(Icons.crop_free_rounded, size: 20, color: pal.muted),
                        itemBuilder: (_) => const [
                          PopupMenuItem(
                            value: 'direct',
                            child: Row(
                              children: [
                                Icon(Icons.fullscreen_rounded, size: 17),
                                SizedBox(width: 8),
                                Text('直接截图'),
                              ],
                            ),
                          ),
                          PopupMenuItem(
                            value: 'hide',
                            child: Row(
                              children: [
                                Icon(Icons.visibility_off_outlined, size: 17),
                                SizedBox(width: 8),
                                Text('隐藏 Loop 后截图'),
                              ],
                            ),
                          ),
                        ],
                      ),
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
                          key: const Key('chat-input'),
                          controller: _controller,
                          focusNode: _focus,
                          minLines: 1,
                          maxLines: widget.compact ? 4 : 6,
                          textInputAction: TextInputAction.newline,
                          style: const TextStyle(fontSize: 14.5, height: 1.55),
                          decoration: InputDecoration(
                            hintText: hint,
                            filled: false,
                            isDense: true,
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                            contentPadding: const EdgeInsets.symmetric(vertical: 10),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: IconButton.filled(
                        key: const Key('chat-send-stop'),
                        tooltip: _sending ? '停止' : '发送',
                        onPressed: _sending ? _stop : _send,
                        icon: Icon(
                          _sending ? Icons.stop_rounded : Icons.arrow_upward_rounded,
                          size: 18,
                        ),
                        style: IconButton.styleFrom(
                          backgroundColor: _sending ? pal.danger : pal.accent,
                          foregroundColor: Colors.white,
                          minimumSize: Size.square(widget.compact ? 34 : 38),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (!widget.compact) ...[
                const SizedBox(height: 6),
                Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: Text(
                    'Enter 发送 · Shift + Enter 换行 · 每个对话独立上下文',
                    style: TextStyle(fontSize: 11, color: pal.faint),
                  ),
                ),
              ],
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
