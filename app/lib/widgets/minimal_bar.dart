import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../desktop/window_mode.dart' show minimalButtonSize, minimalInputHeight;
import '../theme.dart';

/// 极简形态紧凑条（规格 §3.5）。
///
/// 三要素：输入框（含内嵌发送/停止）、截图、返回。左侧 24 宽的 Logo/拖动热区
/// 也属于“可移动”能力，不是第四个业务要素。整条高度 = 窗口高度（52），
/// 内部垂直 padding 为 0，除 1px 边框/圆角外没有装饰背景；不渲染消息区、
/// 页头、侧栏、滚动条或任何留白。
///
/// 组件只依赖注入的控制器/回调，不直接引用 `WindowController` 或
/// `AnswerWindowHost`，因此可以在 widget 测试里独立驱动。
class MinimalBar extends StatelessWidget {
  const MinimalBar({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.sending,
    required this.onSend,
    required this.onStop,
    required this.onScreenshot,
    required this.onBack,
    required this.onExpand,
    required this.onDragStart,
    this.attachmentCount = 0,
    this.firstImageUrl,
    this.busy = false,
    this.screenshotEnabled = true,
    this.onBlockedScreenshot,
    this.hint = '问点什么…',
    this.inputEnabled = true,
  });

  /// 与主聊天共用同一个 controller：提交后主窗口会话/SSE 状态不变。
  final TextEditingController controller;

  /// 与主聊天共用同一个焦点节点，形态切换时输入焦点可恢复。
  final FocusNode focusNode;

  /// 正在发送/流式：发送按钮变为停止。
  final bool sending;

  final VoidCallback onSend;
  final VoidCallback onStop;

  /// 截图：极简条默认“隐藏 Loop 后截图”（hideLoop=true 由 ChatScreen 注入）。
  final VoidCallback onScreenshot;

  /// 返回主窗口（退出浮窗），不是退出 mini 到展开浮窗。
  final VoidCallback onBack;

  /// 双击拖动区/Logo：退出极简、恢复展开浮窗。
  final VoidCallback onExpand;

  /// 拖动：注入 `WindowController.startDragging`。
  final VoidCallback onDragStart;

  /// 附件数量（输入要素的一部分，显示 `×N`）。
  final int attachmentCount;

  /// 第一张图片附件的 URL；提供时显示 20px 缩略图，否则显示计数。
  final String? firstImageUrl;

  /// 上传/截图进行中：截图禁用、发送暂不可用。
  final bool busy;

  /// 截图按钮是否可用（发送/上传/截图/覆盖层期间为 false）。
  final bool screenshotEnabled;

  /// 截图被禁用时点击的提示（规格 §3.8）。
  final VoidCallback? onBlockedScreenshot;

  final String hint;

  final bool inputEnabled;

  bool get _canSend => !busy;

  bool get _canScreenshot => screenshotEnabled && !busy;

  void _handleScreenshot() {
    if (!_canScreenshot) {
      onBlockedScreenshot?.call();
      return;
    }
    onScreenshot();
  }

  void _handleSend() {
    if (!_canSend || sending) return;
    onSend();
  }

  @override
  Widget build(BuildContext context) {
    final p = pal;
    final attachments = math.max(0, attachmentCount);
    return Container(
      key: const Key('minimal-bar'),
      // 无上下留白：撑满窗口内高（52 - 1px 边框 = 50），内容垂直居中。
      height: double.infinity,
      width: double.infinity,
      padding: EdgeInsets.zero,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          _DragHandle(onDragStart: onDragStart, onExpand: onExpand),
          const SizedBox(width: 4),
          Expanded(
            child: Container(
              height: minimalInputHeight,
              decoration: BoxDecoration(
                color: p.glassFill,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: sending ? p.accent : p.glassBorder,
                  width: sending ? 1.4 : 1,
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  if (sending)
                    Container(
                      key: const Key('minimal-streaming-indicator'),
                      width: 2,
                      height: 22,
                      margin: const EdgeInsets.only(left: 4),
                      decoration: BoxDecoration(
                        color: p.accent,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  if (attachments > 0) _AttachmentBadge(
                    count: attachments,
                    imageUrl: firstImageUrl,
                  ),
                  Expanded(
                    child: Focus(
                      onKeyEvent: (node, event) {
                        if (event is KeyDownEvent &&
                            event.logicalKey == LogicalKeyboardKey.enter) {
                          // 极简条单行：Shift+Enter 无操作（不换行、不发送）。
                          if (!HardwareKeyboard.instance.isShiftPressed) {
                            _handleSend();
                            return KeyEventResult.handled;
                          }
                          return KeyEventResult.handled;
                        }
                        return KeyEventResult.ignored;
                      },
                      child: TextField(
                        key: const Key('minimal-input'),
                        controller: controller,
                        focusNode: focusNode,
                        enabled: inputEnabled,
                        maxLines: 1,
                        minLines: 1,
                        textInputAction: TextInputAction.none,
                        style: TextStyle(fontSize: 13.5, height: 1.3, color: p.ink),
                        cursorColor: p.accent,
                        inputFormatters: const [_SingleLineFormatter()],
                        decoration: InputDecoration(
                          hintText: hint,
                          hintStyle: TextStyle(fontSize: 13, color: p.faint),
                          filled: false,
                          isDense: true,
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          disabledBorder: InputBorder.none,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 0,
                          ),
                        ),
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 30,
                    height: 30,
                    child: IconButton(
                      key: const Key('minimal-send-stop'),
                      padding: EdgeInsets.zero,
                      visualDensity: VisualDensity.compact,
                      tooltip: sending ? '停止' : '发送',
                      onPressed: sending
                          ? onStop
                          : (_canSend ? _handleSend : null),
                      icon: Icon(
                        sending ? Icons.stop_rounded : Icons.arrow_upward_rounded,
                        size: 16,
                      ),
                      style: IconButton.styleFrom(
                        backgroundColor: sending ? p.danger : p.accent,
                        foregroundColor: Colors.white,
                        disabledBackgroundColor: p.chip,
                        disabledForegroundColor: p.faint,
                        minimumSize: const Size.square(30),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        padding: EdgeInsets.zero,
                      ),
                    ),
                  ),
                  const SizedBox(width: 3),
                ],
              ),
            ),
          ),
          const SizedBox(width: 4),
          _MinimalIconButton(
            key: const Key('minimal-screenshot'),
            icon: Icons.crop_free_rounded,
            tooltip: '截图（Alt+A）',
            enabled: _canScreenshot,
            onTap: _handleScreenshot,
          ),
          _MinimalIconButton(
            key: const Key('minimal-back'),
            icon: Icons.open_in_full_rounded,
            tooltip: '返回主窗口 (Alt+Q)',
            enabled: true,
            onTap: onBack,
          ),
          const SizedBox(width: 2),
        ],
      ),
    );
  }
}

/// 单行输入：粘贴带来的换行归一为空格，窗口不增高（规格 §3.8）。
class _SingleLineFormatter extends TextInputFormatter {
  const _SingleLineFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    if (!newValue.text.contains('\n') && !newValue.text.contains('\r')) {
      return newValue;
    }
    final text = newValue.text.replaceAll('\r\n', ' ').replaceAll('\n', ' ').replaceAll('\r', ' ');
    return newValue.copyWith(text: text);
  }
}

class _DragHandle extends StatelessWidget {
  const _DragHandle({required this.onDragStart, required this.onExpand});

  final VoidCallback onDragStart;
  final VoidCallback onExpand;

  @override
  Widget build(BuildContext context) {
    final p = pal;
    return Tooltip(
      message: '拖动；双击展开浮窗',
      waitDuration: const Duration(milliseconds: 700),
      child: MouseRegion(
        cursor: SystemMouseCursors.move,
        child: GestureDetector(
          key: const Key('minimal-drag-handle'),
          behavior: HitTestBehavior.opaque,
          onPanStart: (_) => onDragStart(),
          onDoubleTap: onExpand,
          child: SizedBox(
            width: 24,
            height: minimalInputHeight,
            child: Center(
              child: Container(
                width: 18,
                height: 18,
                decoration: BoxDecoration(
                  gradient: p.accentGradient,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Icon(Icons.loop_rounded, size: 11, color: p.onAccent),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AttachmentBadge extends StatelessWidget {
  const _AttachmentBadge({required this.count, this.imageUrl});

  final int count;
  final String? imageUrl;

  @override
  Widget build(BuildContext context) {
    final p = pal;
    final url = imageUrl;
    return Tooltip(
      message: '已附 $count 个附件；展开浮窗后可管理',
      child: Container(
        key: const Key('minimal-attachment-badge'),
        height: 20,
        margin: const EdgeInsets.only(left: 4, right: 2),
        padding: url == null
            ? const EdgeInsets.symmetric(horizontal: 4)
            : EdgeInsets.zero,
        decoration: BoxDecoration(
          color: p.chip,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: p.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (url != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(5),
                child: Image.network(
                  url,
                  width: 20,
                  height: 20,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => Icon(
                    Icons.attach_file_rounded,
                    size: 12,
                    color: p.muted,
                  ),
                ),
              )
            else
              Icon(Icons.attach_file_rounded, size: 11, color: p.muted),
            if (url != null) const SizedBox(width: 2),
            Text(
              '×$count',
              style: TextStyle(fontSize: 9.5, color: p.muted, height: 1.1),
            ),
            if (url == null) const SizedBox(width: 1),
          ],
        ),
      ),
    );
  }
}

class _MinimalIconButton extends StatefulWidget {
  const _MinimalIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.enabled,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final bool enabled;
  final VoidCallback onTap;

  @override
  State<_MinimalIconButton> createState() => _MinimalIconButtonState();
}

class _MinimalIconButtonState extends State<_MinimalIconButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = pal;
    final color = widget.enabled ? p.ink : p.faint;
    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 600),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 100),
            width: minimalButtonSize,
            height: minimalButtonSize,
            decoration: BoxDecoration(
              color: _hover ? p.hover : Colors.transparent,
              borderRadius: BorderRadius.circular(7),
            ),
            child: Icon(widget.icon, size: 16, color: color),
          ),
        ),
      ),
    );
  }
}
