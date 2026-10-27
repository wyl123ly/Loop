import 'dart:ui';

import 'package:flutter/material.dart';

import '../desktop/window_controls.dart';
import '../theme.dart';

/// 背景：暖色渐变 + 高斯模糊光晕，给玻璃提供可折射的底色。
class AuroraBackground extends StatelessWidget {
  const AuroraBackground({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final p = pal;
    return Stack(
      children: [
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [p.bgTop, p.bgBottom, p.bgTop],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
          ),
        ),
        Positioned(top: -160, left: -120, child: _orb(480, p.orb1)),
        Positioned(top: 80, right: -140, child: _orb(440, p.orb2)),
        Positioned(bottom: -180, left: 260, child: _orb(520, p.orb3)),
        Positioned(bottom: 120, right: 180, child: _orb(260, p.orb4)),
        Positioned.fill(child: child),
      ],
    );
  }

  Widget _orb(double size, Color color) {
    // 用径向渐变代替高斯模糊，省掉全屏级的 ImageFiltered 图层。
    return SizedBox(
      width: size,
      height: size,
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: [color, color.withValues(alpha: 0)],
            stops: const [0, 1],
          ),
        ),
      ),
    );
  }
}

/// 柔光玻璃面板（模糊版，液态玻璃不可用时的回退）。
class GlassPanel extends StatelessWidget {
  const GlassPanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.radius = 24,
    this.blur = 18,
    this.opacity,
    this.borderOpacity,
    this.shadow = true,
    this.margin,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final double blur;
  final double? opacity;
  final double? borderOpacity;
  final bool shadow;
  final EdgeInsetsGeometry? margin;

  @override
  Widget build(BuildContext context) {
    final p = pal;
    final borderRadius = BorderRadius.circular(radius);
    return ValueListenableBuilder<bool>(
      valueListenable: WindowController.instance.resizing,
      builder: (context, resizing, _) {
        final body = Container(
          padding: padding,
          decoration: BoxDecoration(
            color: resizing
                ? p.cardSolid
                : p.glassFill.withValues(alpha: p.glassFill.a * (opacity ?? 1.0)),
            borderRadius: borderRadius,
            border: Border.all(
              color: p.glassBorder.withValues(alpha: p.glassBorder.a * (borderOpacity ?? 1.0)),
            ),
          ),
          child: child,
        );
        return Container(
          margin: margin,
          decoration: BoxDecoration(
            borderRadius: borderRadius,
            boxShadow: shadow && !resizing
                ? [BoxShadow(color: p.shadow, blurRadius: 30, offset: const Offset(0, 14))]
                : null,
          ),
          child: resizing
              ? ClipRRect(borderRadius: borderRadius, child: body)
              : ClipRRect(
                  borderRadius: borderRadius,
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
                    child: body,
                  ),
                ),
        );
      },
    );
  }
}

class GlassPill extends StatelessWidget {
  const GlassPill({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
    this.radius = 999,
    this.color,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final p = pal;
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: color ?? p.chip,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: p.glassBorder),
      ),
      child: child,
    );
  }
}

class PageHeader extends StatelessWidget {
  const PageHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
    this.padding = const EdgeInsets.fromLTRB(32, 28, 28, 16),
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final p = pal;
    return Padding(
      padding: padding,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: LoopType.display,
              fontWeight: FontWeight.w700,
              color: p.ink,
              letterSpacing: -0.5,
              height: 1.2,
            ),
          ),
          if (subtitle != null) ...[
            const SizedBox(width: 12),
            Text(subtitle!, style: TextStyle(fontSize: LoopType.secondary, color: p.muted)),
          ],
          const Spacer(),
          ?trailing,
        ],
      ),
    );
  }
}

/// 渐变主按钮。
class GradientButton extends StatelessWidget {
  const GradientButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.height = 44,
    this.gradient,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final double height;
  final Gradient? gradient;

  @override
  Widget build(BuildContext context) {
    final p = pal;
    return Opacity(
      opacity: onPressed == null ? 0.5 : 1,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(LoopRadius.control),
        child: InkWell(
          borderRadius: BorderRadius.circular(LoopRadius.control),
          onTap: onPressed,
          child: Ink(
            height: height,
            decoration: BoxDecoration(
              gradient: gradient ?? p.accentFillGradient,
              borderRadius: BorderRadius.circular(LoopRadius.control),
              boxShadow: [
                BoxShadow(
                  color: p.accent.withValues(alpha: 0.25),
                  blurRadius: 18,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 18, color: p.onAccent),
                  const SizedBox(width: 6),
                ],
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: LoopSpace.x5),
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: LoopType.body,
                      fontWeight: FontWeight.w600,
                      color: p.onAccent,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
