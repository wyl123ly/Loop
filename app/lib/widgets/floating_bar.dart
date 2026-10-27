import 'dart:async';

import 'package:flutter/material.dart';

import '../desktop/window_mode.dart';
import '../theme.dart';

/// 浮窗自绘拖动栏（替代主窗口 TitleBar / 原生标题栏）。
///
/// 左侧是拖动区（Loop 标识、当前会话标题、“浮窗”标签），右侧依次是
/// 截图 / 置顶 / 返回主窗口 / 关闭。拖动、置顶、返回、截图全部由注入的
/// 回调或 [FloatingModeHost] 完成，本组件不直接依赖窗口插件，便于 widget 测试。
///
/// 规格 §6.2：栏高 44（紧凑 40）；按钮热区 ≥32×32（紧凑 ≥30×30）；
/// tooltip 含 Alt+Q / Alt+A；截图主点击 = 隐藏 Loop 后截图，右键菜单可
/// “直接截图”；双击拖动栏不最大化。
class FloatingBar extends StatelessWidget {
  const FloatingBar({
    super.key,
    required this.host,
    required this.title,
    required this.onDragStart,
    required this.onClose,
    required this.onScreenshot,
    this.onMinimize,
    this.compact = false,
  });

  final FloatingModeHost host;

  /// 当前会话标题（省略号截断）。
  final String title;

  /// 拖动栏空白区按下时调用（Shell 注入 `WindowController.startDragging`）。
  final VoidCallback onDragStart;

  /// 关闭/隐藏到托盘。
  final VoidCallback onClose;

  /// 发起截图：`true`=隐藏 Loop 后截图（默认），`false`=直接截图。
  final ValueChanged<bool> onScreenshot;

  /// 最小化到极简条（规格 §3.3）。为空时不渲染该按钮（兼容旧测试构造）。
  final VoidCallback? onMinimize;

  final bool compact;

  double get _barHeight => compact ? 40 : 44;
  double get _buttonWidth => compact ? 32 : 36;
  double get _buttonHeight => compact ? 30 : 32;

  Future<void> _showScreenshotMenu(BuildContext context, Offset position) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;
    final selected = await showMenu<bool>(
      context: context,
      position: RelativeRect.fromRect(
        position & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      items: const [
        PopupMenuItem(
          value: true,
          child: Row(
            children: [
              Icon(Icons.visibility_off_outlined, size: 17),
              SizedBox(width: 8),
              Text('隐藏 Loop 后截图'),
            ],
          ),
        ),
        PopupMenuItem(
          value: false,
          child: Row(
            children: [
              Icon(Icons.fullscreen_rounded, size: 17),
              SizedBox(width: 8),
              Text('直接截图'),
            ],
          ),
        ),
      ],
    );
    if (selected != null) onScreenshot(selected);
  }

  void _togglePin() {
    unawaited(host.setPinned(!host.pinned));
  }

  void _back() {
    unawaited(host.exitFloating(focus: true));
  }

  @override
  Widget build(BuildContext context) {
    final p = pal;
    return AnimatedBuilder(
      animation: host,
      builder: (context, _) {
        final busy = host.transitioning || host.captureInProgress;
        return Container(
          key: const Key('floating-bar'),
          height: _barHeight,
          padding: EdgeInsets.only(left: compact ? 10 : 14, right: 6),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: p.glassBorder)),
          ),
          child: Row(
            children: [
              Expanded(
                child: GestureDetector(
                  key: const Key('floating-drag-area'),
                  behavior: HitTestBehavior.opaque,
                  onPanStart: (_) => onDragStart(),
                  // 浮窗双击拖动栏不做任何事（规格 §4.5）。
                  onDoubleTap: () {},
                  child: MouseRegion(
                    cursor: SystemMouseCursors.move,
                    child: Row(
                      children: [
                        Container(
                          width: compact ? 18 : 20,
                          height: compact ? 18 : 20,
                          decoration: BoxDecoration(
                            gradient: p.accentGradient,
                            borderRadius: BorderRadius.circular(LoopRadius.small),
                          ),
                          child: Icon(
                            Icons.loop_rounded,
                            color: p.onAccent,
                            size: compact ? 12 : 13,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '回路',
                          style: TextStyle(
                            fontSize: LoopType.secondary,
                            fontWeight: FontWeight.w700,
                            color: p.ink,
                            letterSpacing: 0.2,
                          ),
                        ),
                        if (!compact) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: p.chip,
                              borderRadius: BorderRadius.circular(LoopRadius.small),
                              border: Border.all(color: p.border),
                            ),
                            child: Text(
                              '浮窗',
                              style: TextStyle(fontSize: LoopType.micro, color: p.muted),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: LoopType.caption, color: p.muted),
                            ),
                          ),
                        ] else
                          const Spacer(),
                      ],
                    ),
                  ),
                ),
              ),
              _BarButton(
                key: const Key('floating-screenshot'),
                icon: Icons.crop_free_rounded,
                tooltip: '截图（Alt+A）· 默认隐藏 Loop 后截图；右键可切换直接截图',
                width: _buttonWidth,
                height: _buttonHeight,
                enabled: !busy,
                onTap: () => onScreenshot(true),
                onSecondaryTapDown: busy
                    ? null
                    : (details) => _showScreenshotMenu(context, details.globalPosition),
              ),
              _BarButton(
                key: const Key('floating-pin'),
                icon: host.pinned ? Icons.push_pin_rounded : Icons.push_pin_outlined,
                tooltip: host.pinned ? '取消置顶' : '置顶窗口',
                width: _buttonWidth,
                height: _buttonHeight,
                enabled: !busy,
                active: host.pinned,
                onTap: _togglePin,
              ),
              if (onMinimize != null)
                _BarButton(
                  key: const Key('floating-minimize'),
                  icon: Icons.unfold_less_rounded,
                  tooltip: '收起为极简条',
                  width: _buttonWidth,
                  height: _buttonHeight,
                  enabled: !busy,
                  onTap: onMinimize!,
                ),
              _BarButton(
                key: const Key('floating-back'),
                icon: Icons.open_in_full_rounded,
                tooltip: '返回主窗口 (Alt+Q)',
                width: _buttonWidth,
                height: _buttonHeight,
                enabled: !busy,
                onTap: _back,
              ),
              _BarButton(
                key: const Key('floating-close'),
                icon: Icons.close_rounded,
                tooltip: '关闭',
                width: _buttonWidth,
                height: _buttonHeight,
                danger: true,
                onTap: onClose,
              ),
            ],
          ),
        );
      },
    );
  }
}

class _BarButton extends StatefulWidget {
  const _BarButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.width,
    required this.height,
    required this.onTap,
    this.enabled = true,
    this.active = false,
    this.danger = false,
    this.onSecondaryTapDown,
  });

  final IconData icon;
  final String tooltip;
  final double width;
  final double height;
  final VoidCallback onTap;
  final bool enabled;
  final bool active;
  final bool danger;
  final GestureTapDownCallback? onSecondaryTapDown;

  @override
  State<_BarButton> createState() => _BarButtonState();
}

class _BarButtonState extends State<_BarButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = pal;
    final bg = widget.danger
        ? (p.dangerInk)
        : p.hover;
    final iconColor = !widget.enabled
        ? p.faint
        : widget.danger
            ? (_hover ? Colors.white : p.muted)
            : (widget.active ? p.accent : p.ink);
    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 600),
      child: MouseRegion(
        cursor: widget.enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.enabled ? widget.onTap : null,
          onSecondaryTapDown: widget.onSecondaryTapDown,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: widget.width,
            height: widget.height,
            margin: const EdgeInsets.symmetric(horizontal: 1),
            decoration: BoxDecoration(
              color: _hover && widget.enabled ? bg : Colors.transparent,
              borderRadius: BorderRadius.circular(LoopRadius.small),
            ),
            child: Icon(widget.icon, size: 16, color: iconColor),
          ),
        ),
      ),
    );
  }
}
