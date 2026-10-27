import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../desktop/hotkeys_types.dart';
import '../desktop/window_controls.dart';
import '../desktop/window_mode.dart';
import '../theme.dart';

/// 自绘标题栏：透明，融入 Aurora；左侧可拖拽，右侧窗口控制。
///
/// 主窗口在最小化按钮左侧提供“浮窗答疑”按钮（规格 §6.2 / FR-5）。
/// 浮窗形态使用 `FloatingBar`，不渲染本组件。
class TitleBar extends StatelessWidget {
  const TitleBar({
    super.key,
    required this.pageTitle,
    this.modeHost,
    this.onFloatingToggle,
    this.hotkeyStatus,
  });

  final String pageTitle;

  /// 浮窗形态宿主；为空或 `supported=false` 时不显示浮窗按钮。
  final FloatingModeHost? modeHost;

  /// 进入浮窗（Shell 注入，负责失败提示）；为空时退化为直接调用 host。
  final VoidCallback? onFloatingToggle;

  /// 快捷键状态：冲突/不支持时只改 tooltip，按钮始终可用（规格 §8.3）。
  final ValueListenable<HotkeyStatus>? hotkeyStatus;

  /// 快捷键状态未知时的按钮 tooltip（含 Alt+Q，便于 M-16 手工核对）。
  static const String _defaultTooltip = '浮窗答疑 (Alt+Q)';

  Widget _floatingButton(FloatingModeHost host, String tooltip) {
    return _WindowButton(
      key: const Key('window-floating-toggle'),
      icon: Icons.picture_in_picture_alt_rounded,
      tooltip: tooltip,
      enabled: !host.transitioning && !host.captureInProgress,
      onTap: () {
        final toggle = onFloatingToggle;
        if (toggle != null) {
          toggle();
        } else {
          host.enterFloating(focus: true);
        }
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final host = modeHost;
    // Web/stub：既没有真实窗口，也不支持浮窗，保持 v0.4.0 的“无标题栏”外观；
    // 测试注入 supported=true 的 fake host 时仍然渲染标题栏。
    if (!WindowController.instance.ready && !(host?.supported ?? false)) {
      return const SizedBox.shrink();
    }
    final p = pal;
    return SizedBox(
      height: 44,
      child: Row(
        children: [
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanStart: (_) => WindowController.instance.startDragging(),
              onDoubleTap: () => WindowController.instance.toggleMaximize(),
              child: Padding(
                padding: const EdgeInsets.only(left: 20),
                child: Row(
                  children: [
                    Container(
                      width: 20,
                      height: 20,
                      decoration: BoxDecoration(
                        gradient: p.accentGradient,
                        borderRadius: BorderRadius.circular(LoopRadius.small),
                      ),
                      child: Icon(Icons.loop_rounded, color: p.onAccent, size: 13),
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
                    const SizedBox(width: 10),
                    Text(pageTitle, style: TextStyle(fontSize: LoopType.caption, color: p.muted)),
                  ],
                ),
              ),
            ),
          ),
          if (host != null && host.supported)
            AnimatedBuilder(
              animation: host,
              builder: (context, _) {
                final status = hotkeyStatus;
                final fallback = _defaultTooltip;
                return status == null
                    ? _floatingButton(host, fallback)
                    : ValueListenableBuilder<HotkeyStatus>(
                        valueListenable: status,
                        builder: (context, value, _) =>
                            _floatingButton(host, value.toggleTooltip),
                      );
              },
            ),
          ValueListenableBuilder<bool>(
            valueListenable: WindowController.instance.maximized,
            builder: (context, maximized, _) => Row(
              children: [
                _WindowButton(
                  icon: Icons.remove_rounded,
                  tooltip: '最小化',
                  onTap: WindowController.instance.minimize,
                ),
                _WindowButton(
                  icon: maximized ? Icons.filter_none_rounded : Icons.crop_square_rounded,
                  tooltip: maximized ? '还原' : '最大化',
                  iconSize: maximized ? 13 : 12,
                  onTap: WindowController.instance.toggleMaximize,
                ),
                _WindowButton(
                  icon: Icons.close_rounded,
                  tooltip: '关闭',
                  danger: true,
                  onTap: WindowController.instance.close,
                ),
                const SizedBox(width: 4),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _WindowButton extends StatefulWidget {
  const _WindowButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.iconSize = 14,
    this.danger = false,
    this.enabled = true,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final double iconSize;
  final bool danger;
  final bool enabled;

  @override
  State<_WindowButton> createState() => _WindowButtonState();
}

class _WindowButtonState extends State<_WindowButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = pal;
    final bg = widget.danger
        ? (p.dangerInk)
        : p.hover;
    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 600),
      child: MouseRegion(
        cursor: widget.enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.enabled ? widget.onTap : null,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            width: 42,
            height: 30,
            margin: const EdgeInsets.symmetric(horizontal: 4),
            decoration: BoxDecoration(
              color: _hover && widget.enabled ? bg : Colors.transparent,
              borderRadius: BorderRadius.circular(LoopRadius.small),
            ),
            child: Icon(
              widget.icon,
              size: widget.iconSize,
              color: widget.enabled
                  ? (_hover && widget.danger ? p.onAccent : p.ink)
                  : p.faint,
            ),
          ),
        ),
      ),
    );
  }
}
