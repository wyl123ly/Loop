import 'package:flutter/material.dart';

import '../desktop/window_controls.dart';
import '../theme.dart';

/// 自绘标题栏：透明，融入 Aurora；左侧可拖拽，右侧窗口控制。
class TitleBar extends StatelessWidget {
  const TitleBar({super.key, required this.pageTitle});

  final String pageTitle;

  @override
  Widget build(BuildContext context) {
    if (!WindowController.instance.ready) return const SizedBox.shrink();
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
                padding: const EdgeInsets.only(left: 18),
                child: Row(
                  children: [
                    Container(
                      width: 20,
                      height: 20,
                      decoration: BoxDecoration(
                        gradient: p.accentGradient,
                        borderRadius: BorderRadius.circular(7),
                      ),
                      child: Icon(Icons.loop_rounded, color: p.onAccent, size: 13),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '回路',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: p.ink,
                        letterSpacing: 0.2,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(pageTitle, style: TextStyle(fontSize: 11, color: p.muted)),
                  ],
                ),
              ),
            ),
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
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.iconSize = 14,
    this.danger = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final double iconSize;
  final bool danger;

  @override
  State<_WindowButton> createState() => _WindowButtonState();
}

class _WindowButtonState extends State<_WindowButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = pal;
    final bg = widget.danger
        ? (p.isDark ? const Color(0xFFC93B40) : p.danger)
        : p.hover;
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
            duration: const Duration(milliseconds: 140),
            width: 42,
            height: 30,
            margin: const EdgeInsets.symmetric(horizontal: 1),
            decoration: BoxDecoration(
              color: _hover ? bg : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              widget.icon,
              size: widget.iconSize,
              color: _hover && widget.danger ? Colors.white : p.ink,
            ),
          ),
        ),
      ),
    );
  }
}
