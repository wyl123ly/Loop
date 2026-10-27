import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../desktop/window_mode.dart'
    show
        answerHeaderHeight,
        answerHeightEpsilon,
        answerMaxHeightCap,
        answerMinHeight,
        answerRadius;
import '../models.dart';
import '../theme.dart';
import '../widgets/markdown_text.dart';

/// 回答浮窗的只读视图状态（第二引擎侧；不依赖 AppState / LoopApi / DB）。
///
/// 数据只来自主窗口经 IPC 推送的快照/增量（规格 §2.6）；本类只做 UI 需要的
/// 解码与派生，不持有任何写能力。
@immutable
class AnswerViewState {
  const AnswerViewState({
    this.question = '',
    this.answer = '',
    this.status = 'thinking',
    this.statusLabel,
    this.approvalRequired = false,
    this.plan = const [],
    this.refs = const [],
    this.error,
    this.elapsedMs,
    this.collapsed = false,
    this.hasSnapshot = false,
    this.revision = 0,
    this.scrollResetToken = 0,
    this.minHeight = answerMinHeight,
    this.maxHeight = answerMaxHeightCap,
    this.dark = false,
    this.fontFamily = 'NotoSC',
    this.resyncing = false,
  });

  final String question;
  final String answer;

  /// 协议 wire 状态：thinking/streaming/tool/waiting_approval/done/stopped/error。
  final String status;

  /// 主窗口给出的状态文案；为空时按 [status] 派生。
  final String? statusLabel;
  final bool approvalRequired;
  final List<PlanItem> plan;
  final List<RefItem> refs;
  final String? error;
  final int? elapsedMs;

  /// 收起为 36px 标题条。
  final bool collapsed;

  /// 是否已收到首个 snapshot（之前窗口不应显示内容，这里给“等待问题”占位）。
  final bool hasSnapshot;

  /// 每次 snapshot 自增（IPC 观测/诊断用）。
  final int revision;

  /// 只有真正“新问题/新 run/新会话”的替换才自增；plan/refs/resync 的
  /// 非替换全量 snapshot 不变。AnswerPanel 用它决定是否重置用户滚动（T5-09）。
  final int scrollResetToken;

  final double minHeight;
  final double maxHeight;
  final bool dark;
  final String fontFamily;

  /// 增量 seq 断档，正在等待主窗重同步。
  final bool resyncing;

  bool get busy => status == 'thinking' || status == 'streaming' || status == 'tool';

  bool get waitingApproval => status == 'waiting_approval' || approvalRequired;

  String get label => (statusLabel?.trim().isNotEmpty ?? false)
      ? statusLabel!.trim()
      : switch (status) {
          'thinking' => '思考中',
          'streaming' => '生成中',
          'tool' => '使用工具',
          'waiting_approval' => '等待审批',
          'done' => '完成',
          'stopped' => '已停止',
          'error' => '出错',
          _ => '准备中',
        };

  /// 正文为空时的占位文案：任何时刻都不出现空白窗口（规格 §4.3）。
  String get placeholder {
    if (!hasSnapshot && question.isEmpty) return '等待问题…';
    if (busy) {
      return switch (status) {
        'streaming' => '正在生成…',
        'tool' => '正在使用工具…',
        _ => '正在思考…',
      };
    }
    if (waitingApproval) return '需要审批，请回主窗口处理';
    if (status == 'stopped') return '已停止';
    return '（无内容）';
  }

  AnswerViewState copyWith({
    String? question,
    String? answer,
    String? status,
    String? statusLabel,
    bool? approvalRequired,
    List<PlanItem>? plan,
    List<RefItem>? refs,
    String? error,
    bool clearError = false,
    int? elapsedMs,
    bool? collapsed,
    bool? hasSnapshot,
    int? revision,
    int? scrollResetToken,
    double? minHeight,
    double? maxHeight,
    bool? dark,
    String? fontFamily,
    bool? resyncing,
  }) {
    return AnswerViewState(
      question: question ?? this.question,
      answer: answer ?? this.answer,
      status: status ?? this.status,
      statusLabel: statusLabel ?? this.statusLabel,
      approvalRequired: approvalRequired ?? this.approvalRequired,
      plan: plan ?? this.plan,
      refs: refs ?? this.refs,
      error: clearError ? null : (error ?? this.error),
      elapsedMs: elapsedMs ?? this.elapsedMs,
      collapsed: collapsed ?? this.collapsed,
      hasSnapshot: hasSnapshot ?? this.hasSnapshot,
      revision: revision ?? this.revision,
      scrollResetToken: scrollResetToken ?? this.scrollResetToken,
      minHeight: minHeight ?? this.minHeight,
      maxHeight: maxHeight ?? this.maxHeight,
      dark: dark ?? this.dark,
      fontFamily: fontFamily ?? this.fontFamily,
      resyncing: resyncing ?? this.resyncing,
    );
  }
}

/// 只读回答面板：标题条（拖动/收起/关闭）+ 正文（Markdown/公式/代码块）。
///
/// 高度不在本组件内设置窗口尺寸：它测量**可变正文内容**的高度并上报
/// （[onDesiredHeight]，单位逻辑 px，不含标题条/问题/状态/padding）。
/// 主引擎 `AnswerWindowPlanner.desiredHeightLogical` 加上固定 chrome 后按
/// minH/maxH 钳制并执行无激活改高。达到 maxH 后正文在
/// [SingleChildScrollView] 内部滚动，并出现“回到底部”。
class AnswerPanel extends StatefulWidget {
  const AnswerPanel({
    super.key,
    required this.state,
    required this.onClose,
    required this.onCollapse,
    required this.onExpand,
    this.onDragStart,
    this.onDragUpdate,
    this.onDragEnd,
    this.onDesiredHeight,
  });

  final AnswerViewState state;

  final VoidCallback onClose;
  final VoidCallback onCollapse;
  final VoidCallback onExpand;

  /// 标题条拖动（第二引擎由 t2 的 Dart FFI 实现真实移动）。
  final VoidCallback? onDragStart;
  final ValueChanged<Offset>? onDragUpdate;
  final VoidCallback? onDragEnd;

  /// 可变正文内容高度（逻辑像素，不含标题条/问题/状态/padding）。
  /// 主引擎负责 +chrome 与 minH/maxH 钳制。
  final ValueChanged<double>? onDesiredHeight;

  @override
  State<AnswerPanel> createState() => _AnswerPanelState();
}

class _AnswerPanelState extends State<AnswerPanel> {
  final ScrollController _scroll = ScrollController();
  final GlobalKey _contentKey = GlobalKey(debugLabel: 'answer-content');

  bool _atBottom = true;
  bool _showBottomCapsule = false;
  bool _measureScheduled = false;
  double? _lastReported;
  int _seenScrollResetToken = -1;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _seenScrollResetToken = widget.state.scrollResetToken;
    _scheduleMeasure();
    // 首帧若内容已超过 maxH，默认显示正文末尾（与流式跟随一致）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || widget.state.collapsed) return;
      _followBottomSoon();
    });
  }

  @override
  void didUpdateWidget(covariant AnswerPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final next = widget.state;
    // T5-09：只有真正的新问题/新 run/新会话（scrollResetToken 变化）才回到
    // 底部跟随；plan/refs/resync 等非替换全量 snapshot 保留用户滚动位置与
    // “已上滚暂停跟随”状态。
    if (next.scrollResetToken != _seenScrollResetToken) {
      _seenScrollResetToken = next.scrollResetToken;
      _atBottom = true;
      _showBottomCapsule = false;
    }
    _scheduleMeasure();
    if (_atBottom) _followBottomSoon();
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    final atBottom = position.maxScrollExtent - position.pixels < 24;
    final showCapsule = position.maxScrollExtent > 1 &&
        position.pixels < position.maxScrollExtent - 24;
    if (atBottom != _atBottom || showCapsule != _showBottomCapsule) {
      setState(() {
        _atBottom = atBottom;
        _showBottomCapsule = showCapsule;
      });
    }
  }

  void _followBottomSoon() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients || !_atBottom) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  void _jumpToBottom() {
    if (!_scroll.hasClients) return;
    setState(() {
      _atBottom = true;
      _showBottomCapsule = false;
    });
    _scroll.jumpTo(_scroll.position.maxScrollExtent);
  }

  void _scheduleMeasure() {
    if (_measureScheduled || widget.state.collapsed) return;
    _measureScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _measureScheduled = false;
      if (!mounted || widget.state.collapsed) return;
      final context = _contentKey.currentContext;
      final box = context?.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) return;
      // 只上报可变正文内容高度；主窗 planner 负责 +chrome 与 minH/maxH 钳制
      // （规格 §4.3）。
      final content = box.size.height;
      final last = _lastReported;
      if (last != null && (content - last).abs() < answerHeightEpsilon) return;
      _lastReported = content;
      widget.onDesiredHeight?.call(content);
    });
  }

  /// T5-11：回答窗是永久不激活窗口，滚轮/命中路由要覆盖整个面板。
  ///
  /// 正文区域由内层 [Scrollable] 通过 `PointerSignalResolver` 正常处理
  /// （最深注册者优先）；标题条/空白边距/嵌套横向代码块（纵向 delta=0 不
  /// 注册）等没有可滚动目标的位置，由面板级 Listener 作为兜底把纵向滚轮
  /// 转给正文滚动控制器，避免“只有部分区域滚得动”。
  void _handlePointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || widget.state.collapsed) return;
    final dy = event.scrollDelta.dy;
    if (dy == 0 || !dy.isFinite) return;
    GestureBinding.instance.pointerSignalResolver.register(event, (resolved) {
      if (!mounted || !_scroll.hasClients || widget.state.collapsed) return;
      final position = _scroll.position;
      if (position.maxScrollExtent <= 0) return;
      _scroll.position.pointerScroll(dy);
      resolved.respond(allowPlatformDefault: false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = pal;
    final state = widget.state;
    return Listener(
      onPointerSignal: _handlePointerSignal,
      child: Container(
        key: const Key('answer-window'),
        decoration: BoxDecoration(
          color: p.bgTop,
          borderRadius: BorderRadius.circular(answerRadius),
          border: Border.all(color: p.windowBorder),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            AnswerHeader(
              state: state,
              onClose: widget.onClose,
              onCollapse: widget.onCollapse,
              onExpand: widget.onExpand,
              onDragStart: widget.onDragStart,
              onDragUpdate: widget.onDragUpdate,
              onDragEnd: widget.onDragEnd,
            ),
            if (!state.collapsed)
              Expanded(
                child: Stack(
                  children: [
                    Scrollbar(
                      controller: _scroll,
                      child: SingleChildScrollView(
                        key: const Key('answer-scroll'),
                        controller: _scroll,
                        padding: EdgeInsets.zero,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                          child: Column(
                            key: const Key('answer-body'),
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (state.question.trim().isNotEmpty)
                                _QuestionLine(question: state.question),
                              _StatusLine(state: state),
                              Column(
                                key: _contentKey,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  if (state.error != null &&
                                      state.error!.trim().isNotEmpty)
                                    _ErrorBanner(message: state.error!),
                                  if (state.plan.isNotEmpty)
                                    _PlanSection(plan: state.plan),
                                  const SizedBox(height: 6),
                                  _AnswerBody(state: state),
                                  if (state.refs.isNotEmpty)
                                    _RefsSection(refs: state.refs),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    if (_showBottomCapsule)
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 8,
                        child: Center(
                          child: _ScrollBottomCapsule(onTap: _jumpToBottom),
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class AnswerHeader extends StatelessWidget {
  const AnswerHeader({
    super.key,
    required this.state,
    required this.onClose,
    required this.onCollapse,
    required this.onExpand,
    this.onDragStart,
    this.onDragUpdate,
    this.onDragEnd,
  });

  final AnswerViewState state;
  final VoidCallback onClose;
  final VoidCallback onCollapse;
  final VoidCallback onExpand;
  final VoidCallback? onDragStart;
  final ValueChanged<Offset>? onDragUpdate;
  final VoidCallback? onDragEnd;

  @override
  Widget build(BuildContext context) {
    final p = pal;
    return Container(
      key: const Key('answer-header'),
      height: answerHeaderHeight,
      padding: const EdgeInsets.only(left: 12, right: 4),
      decoration: BoxDecoration(
        color: p.cardFill,
        border: Border(bottom: BorderSide(color: p.border)),
      ),
      child: Row(
        children: [
          _StatusDot(state: state),
          const SizedBox(width: 6),
          Text(
            '回答',
            style: TextStyle(fontSize: LoopType.secondary, fontWeight: FontWeight.w700, color: p.ink),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: GestureDetector(
              key: const Key('answer-drag'),
              behavior: HitTestBehavior.opaque,
              onTap: state.collapsed ? onExpand : null,
              onPanStart: onDragStart == null ? null : (_) => onDragStart!(),
              onPanUpdate:
                  onDragUpdate == null ? null : (details) => onDragUpdate!(details.delta),
              onPanEnd: onDragEnd == null ? null : (_) => onDragEnd!(),
              child: MouseRegion(
                cursor: SystemMouseCursors.move,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '${state.label}${_elapsedText(state.elapsedMs)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: LoopType.micro, color: p.muted),
                  ),
                ),
              ),
            ),
          ),
          _HeaderButton(
            key: const Key('answer-collapse'),
            icon: state.collapsed
                ? Icons.unfold_more_rounded
                : Icons.unfold_less_rounded,
            tooltip: state.collapsed ? '展开' : '收起',
            onTap: state.collapsed ? onExpand : onCollapse,
          ),
          _HeaderButton(
            key: const Key('answer-close'),
            icon: Icons.close_rounded,
            tooltip: '关闭',
            onTap: onClose,
          ),
        ],
      ),
    );
  }

  static String _elapsedText(int? elapsedMs) {
    if (elapsedMs == null || elapsedMs <= 0) return '';
    final seconds = elapsedMs / 1000;
    return seconds < 10 ? ' · ${seconds.toStringAsFixed(1)}s' : ' · ${seconds.round()}s';
  }
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.state});

  final AnswerViewState state;

  @override
  Widget build(BuildContext context) {
    final p = pal;
    final color = switch (state.status) {
      'error' => p.danger,
      'waiting_approval' => p.warm,
      'tool' => p.warm,
      'stopped' => p.faint,
      'thinking' || 'streaming' => p.accent,
      _ => p.accent,
    };
    return Container(
      width: 7,
      height: 7,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

class _QuestionLine extends StatelessWidget {
  const _QuestionLine({required this.question});

  final String question;

  @override
  Widget build(BuildContext context) {
    final p = pal;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            margin: const EdgeInsets.only(top: 1),
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            decoration: BoxDecoration(
              color: p.chip,
              borderRadius: BorderRadius.circular(LoopRadius.small),
              border: Border.all(color: p.border),
            ),
            child: Text('问', style: TextStyle(fontSize: LoopType.micro, color: p.muted)),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              question.trim(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: LoopType.secondary, height: 1.3, color: p.ink),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.state});

  final AnswerViewState state;

  @override
  Widget build(BuildContext context) {
    final p = pal;
    final label = state.resyncing ? '同步中…' : state.label;
    final color = switch (state.status) {
      'error' => p.danger,
      'stopped' => p.faint,
      _ => p.muted,
    };
    return Padding(
      key: const Key('answer-status'),
      padding: const EdgeInsets.only(bottom: 2),
      child: Row(
        children: [
          if (state.waitingApproval) ...[
            Icon(Icons.shield_outlined, size: 12, color: p.warm),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                '需要审批，请回主窗口处理',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: LoopType.caption, color: p.warm),
              ),
            ),
          ] else
            Text(label, style: TextStyle(fontSize: LoopType.micro, color: color)),
        ],
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final p = pal;
    final text = message.length > 200 ? '${message.substring(0, 200)}…' : message;
    return Container(
      key: const Key('answer-error'),
      margin: const EdgeInsets.only(top: 4, bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: p.danger.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(LoopRadius.small),
        border: Border.all(color: p.danger.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline_rounded, size: 13, color: p.danger),
          const SizedBox(width: 5),
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: LoopType.caption, height: 1.4, color: p.danger),
            ),
          ),
        ],
      ),
    );
  }
}

class _PlanSection extends StatelessWidget {
  const _PlanSection({required this.plan});

  final List<PlanItem> plan;

  @override
  Widget build(BuildContext context) {
    final p = pal;
    return Container(
      margin: const EdgeInsets.only(top: 4),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: p.chip,
        borderRadius: BorderRadius.circular(LoopRadius.small),
        border: Border.all(color: p.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '执行计划',
            style: TextStyle(fontSize: LoopType.micro, fontWeight: FontWeight.w600, color: p.muted),
          ),
          const SizedBox(height: 3),
          for (final item in plan.take(5))
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Row(
                children: [
                  Icon(
                    item.status == 'done'
                        ? Icons.check_circle_outline_rounded
                        : Icons.radio_button_unchecked_rounded,
                    size: 11,
                    color: item.status == 'done' ? p.accent : p.faint,
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: LoopType.micro, color: p.ink),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _AnswerBody extends StatelessWidget {
  const _AnswerBody({required this.state});

  final AnswerViewState state;

  @override
  Widget build(BuildContext context) {
    final p = pal;
    if (state.answer.trim().isEmpty) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (state.busy)
            Padding(
              padding: const EdgeInsets.only(top: 2, right: 6),
              child: Icon(Icons.hourglass_top_rounded, size: 12, color: p.accent),
            ),
          Expanded(
            child: Text(
              state.placeholder,
              style: TextStyle(fontSize: LoopType.secondary, height: 1.5, color: p.muted),
            ),
          ),
        ],
      );
    }
    return MarkdownText(
      state.answer,
      baseStyle: TextStyle(fontSize: LoopType.body, height: 1.62, color: p.ink),
    );
  }
}

class _RefsSection extends StatelessWidget {
  const _RefsSection({required this.refs});

  final List<RefItem> refs;

  @override
  Widget build(BuildContext context) {
    final p = pal;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Wrap(
        spacing: 4,
        runSpacing: 4,
        children: [
          for (final ref in refs.take(6))
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: p.chip,
                borderRadius: BorderRadius.circular(LoopRadius.small),
                border: Border.all(color: p.border),
              ),
              child: Text(
                ref.page > 0 ? '${ref.name} p.${ref.page}' : ref.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: LoopType.micro, color: p.muted),
              ),
            ),
        ],
      ),
    );
  }
}

class _ScrollBottomCapsule extends StatelessWidget {
  const _ScrollBottomCapsule({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = pal;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: const Key('answer-scroll-bottom'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(LoopRadius.pill),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: p.cardSolid,
            borderRadius: BorderRadius.circular(LoopRadius.pill),
            border: Border.all(color: p.border),
            boxShadow: [BoxShadow(color: p.shadow, blurRadius: 10, offset: const Offset(0, 3))],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.arrow_downward_rounded, size: 12, color: p.ink),
              const SizedBox(width: 3),
              Text('回到底部', style: TextStyle(fontSize: LoopType.micro, color: p.ink)),
            ],
          ),
        ),
      ),
    );
  }
}

class _HeaderButton extends StatefulWidget {
  const _HeaderButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  State<_HeaderButton> createState() => _HeaderButtonState();
}

class _HeaderButtonState extends State<_HeaderButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = pal;
    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 500),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: _hover ? p.hover : Colors.transparent,
              borderRadius: BorderRadius.circular(LoopRadius.small),
            ),
            child: Icon(widget.icon, size: 15, color: p.muted),
          ),
        ),
      ),
    );
  }
}
