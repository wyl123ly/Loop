import 'dart:ui';

import 'package:flutter/material.dart';

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
        Positioned(top: -160, left: -120, child: _orb(480, p.orb1, 110)),
        Positioned(top: 80, right: -140, child: _orb(440, p.orb2, 120)),
        Positioned(bottom: -180, left: 260, child: _orb(520, p.orb3, 130)),
        Positioned(bottom: 120, right: 180, child: _orb(260, p.orb4, 90)),
        Positioned.fill(child: child),
      ],
    );
  }

  Widget _orb(double size, Color color, double blur) {
    return ImageFiltered(
      imageFilter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
    );
  }
}

/// 柔光玻璃面板（模糊版，液态玻璃不可用时的回退）。
class GlassPanel extends StatelessWidget {
  const GlassPanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(18),
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
    return Container(
      margin: margin,
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        boxShadow: shadow
            ? [BoxShadow(color: p.shadow, blurRadius: 30, offset: const Offset(0, 14))]
            : null,
      ),
      child: ClipRRect(
        borderRadius: borderRadius,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
          child: Container(
            padding: padding,
            decoration: BoxDecoration(
              color: p.glassFill.withValues(alpha: p.glassFill.a * (opacity ?? 1.0)),
              borderRadius: borderRadius,
              border: Border.all(color: p.glassBorder.withValues(alpha: p.glassBorder.a * (borderOpacity ?? 1.0))),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

class GlassPill extends StatelessWidget {
  const GlassPill({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
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
              fontSize: 26,
              fontWeight: FontWeight.w700,
              color: p.ink,
              letterSpacing: -0.6,
              height: 1.1,
            ),
          ),
          if (subtitle != null) ...[
            const SizedBox(width: 12),
            Text(subtitle!, style: TextStyle(fontSize: 12.5, color: p.muted)),
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
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onPressed,
          child: Ink(
            height: height,
            decoration: BoxDecoration(
              gradient: gradient ?? p.accentGradient,
              borderRadius: BorderRadius.circular(14),
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
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 14,
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
