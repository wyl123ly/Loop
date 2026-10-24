import 'dart:async';

import 'package:flutter/material.dart';

import '../desktop/answer_host/answer_protocol.dart';
import '../theme.dart';
import 'answer_client.dart';
import 'answer_widgets.dart';

/// 第二引擎拖动代理：由平台桥接（t3 `answer_drag_io.dart` → t2 Win32 FFI）。
///
/// 接口保持平台无关，避免 `answer_ui` 直接 import `dart:ffi`/`dart:io`。
abstract class AnswerDragDelegate {
  bool get available;

  /// 开始拖动；`hwnd` 来自 hello（不可用时返回 false）。
  bool start(int? hwnd);

  /// 用当前鼠标物理坐标移动窗口（无激活）。
  void update();

  /// 结束拖动，返回最终物理矩形（`moved` 上报）。
  Rect? finish();

  void cancel();
}

/// 回答浮窗根组件（第二 FlutterEngine 的唯一 widget 树）。
///
/// - 只读：数据来自 [session] 的 transport（主窗口唯一数据源）；
/// - 主题/字体：首帧用 `AnswerLaunchPayload.dark`，随后跟随 `theme` 消息，
///   不读 DB/设置；
/// - 尺寸：面板测高后经 [AnswerClient.reportContentHeight] 上报，主引擎无激活改高。
class AnswerWindowApp extends StatefulWidget {
  const AnswerWindowApp({
    super.key,
    required this.session,
    this.dragDelegate,
    this.onDragStart,
    this.onDragUpdate,
    this.onDragEnd,
    this.readyWorkArea,
  });

  final AnswerEngineSession session;

  /// 真实窗口拖动（Win32 FFI）；为空时只回调测试注入的 onDrag*。
  final AnswerDragDelegate? dragDelegate;

  /// 标题条拖动（真实移动由第二引擎 Win32 FFI 会话完成，见 t2）。
  final VoidCallback? onDragStart;
  final ValueChanged<Offset>? onDragUpdate;
  final VoidCallback? onDragEnd;

  /// 可选：目标显示器工作区（逻辑 px）；默认用窗口自身逻辑矩形。
  final Rect Function(BuildContext context)? readyWorkArea;

  @override
  State<AnswerWindowApp> createState() => _AnswerWindowAppState();
}

class _AnswerWindowAppState extends State<AnswerWindowApp> {
  late final AnswerClient _client;
  bool _readyScheduled = false;
  bool _dragging = false;

  @override
  void initState() {
    super.initState();
    final payload = widget.session.payload;
    LoopTheme.palette = payload.dark ? LoopPalette.dark : LoopPalette.light;
    _client = AnswerClient(
      transport: widget.session.transport,
      payload: payload,
      windowId: widget.session.windowId,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => _sendReady());
  }

  @override
  void dispose() {
    _client.dispose();
    super.dispose();
  }

  Future<void> _sendReady() async {
    if (!mounted || _readyScheduled) return;
    _readyScheduled = true;
    final media = MediaQuery.maybeOf(context);
    final view = View.maybeOf(context);
    final size = media?.size ?? const Size(420, 180);
    final dpr = view?.devicePixelRatio ?? media?.devicePixelRatio ?? 1.0;
    final workArea = widget.readyWorkArea?.call(context) ?? Offset.zero & size;
    await _client.sendReady(
      dpr: dpr,
      workAreaLogical: workArea,
      contentHeightLogical: 0,
    );
  }

  void _handleDragStart() {
    final delegate = widget.dragDelegate;
    if (delegate != null && delegate.available) {
      _dragging = delegate.start(_client.windowHandle);
    } else {
      _dragging = false;
    }
    if (widget.dragDelegate != null) unawaited(_client.reportDragStarted());
    widget.onDragStart?.call();
  }

  void _handleDragUpdate(Offset delta) {
    final delegate = widget.dragDelegate;
    if (_dragging && delegate != null) delegate.update();
    widget.onDragUpdate?.call(delta);
  }

  void _handleDragEnd() {
    final delegate = widget.dragDelegate;
    if (_dragging && delegate != null) {
      final rect = delegate.finish();
      if (rect != null) unawaited(_client.reportMoved(rect));
      unawaited(_client.reportDragEnded());
    }
    _dragging = false;
    widget.onDragEnd?.call();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _client,
      builder: (context, _) {
        final state = _client.state;
        LoopTheme.palette = state.dark ? LoopPalette.dark : LoopPalette.light;
        return MaterialApp(
          title: '回路 · 回答',
          debugShowCheckedModeBanner: false,
          color: Colors.transparent,
          theme: loopTheme(LoopPalette.light),
          darkTheme: loopTheme(LoopPalette.dark),
          themeMode: state.dark ? ThemeMode.dark : ThemeMode.light,
          home: Scaffold(
            backgroundColor: Colors.transparent,
            body: AnswerPanel(
              state: state,
              onClose: () {
                unawaited(_client.requestClose());
              },
              onCollapse: () {
                unawaited(_client.requestCollapse());
              },
              onExpand: () {
                unawaited(_client.requestExpand());
              },
              onDragStart: widget.dragDelegate != null || widget.onDragStart != null
                  ? _handleDragStart
                  : null,
              onDragUpdate:
                  widget.dragDelegate != null || widget.onDragUpdate != null
                      ? _handleDragUpdate
                      : null,
              onDragEnd: widget.dragDelegate != null || widget.onDragEnd != null
                  ? _handleDragEnd
                  : null,
              onDesiredHeight: _client.reportContentHeight,
            ),
          ),
        );
      },
    );
  }
}
