import 'package:flutter/material.dart';

/// 全局主题调色板。通过 [LoopTheme.palette] 切换，所有界面构建时读取。
class LoopPalette {
  const LoopPalette({
    required this.brightness,
    required this.bgTop,
    required this.bgBottom,
    required this.ink,
    required this.muted,
    required this.faint,
    required this.glassFill,
    required this.glassBorder,
    required this.cardFill,
    required this.cardSolid,
    required this.border,
    required this.accent,
    required this.accent2,
    required this.warm,
    required this.danger,
    required this.chip,
    required this.hover,
    required this.primaryBtn,
    required this.onPrimaryBtn,
    required this.onAccent,
    required this.toastBg,
    required this.toastFg,
    required this.shadow,
    required this.codeBg,
    required this.codeFg,
    required this.windowBorder,
    required this.orb1,
    required this.orb2,
    required this.orb3,
    required this.orb4,
    required this.userBubble,
    required this.hero,
  });

  final Brightness brightness;
  final Color bgTop;
  final Color bgBottom;
  final Color ink;
  final Color muted;
  final Color faint;
  final Color glassFill;
  final Color glassBorder;
  final Color cardFill;
  final Color cardSolid;
  final Color border;
  final Color accent;
  final Color accent2;
  final Color warm;
  final Color danger;
  final Color chip;
  final Color hover;
  final Color primaryBtn;
  final Color onPrimaryBtn;
  final Color onAccent;
  final Color toastBg;
  final Color toastFg;
  final Color shadow;
  final Color codeBg;
  final Color codeFg;
  final Color windowBorder;
  final Color orb1;
  final Color orb2;
  final Color orb3;
  final Color orb4;
  final List<Color> userBubble;
  final List<Color> hero;

  bool get isDark => brightness == Brightness.dark;

  LinearGradient get accentGradient => LinearGradient(
        colors: [accent, accent2],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      );

  LinearGradient get userBubbleGradient => LinearGradient(
        colors: userBubble,
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      );

  LinearGradient get heroGradient => LinearGradient(
        colors: hero,
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      );

  static const light = LoopPalette(
    brightness: Brightness.light,
    bgTop: Color(0xFFF8F3EC),
    bgBottom: Color(0xFFF0EDF9),
    ink: Color(0xFF1F1D24),
    muted: Color(0xFF7B7884),
    faint: Color(0xFFA9A5B2),
    glassFill: Color(0x8CFFFFFF),
    glassBorder: Color(0xCCFFFFFF),
    cardFill: Color(0x94FFFFFF),
    cardSolid: Color(0xFFFCFAF6),
    border: Color(0x66FFFFFF),
    accent: Color(0xFF6C7BFF),
    accent2: Color(0xFFC08CFF),
    warm: Color(0xFFF2A46F),
    danger: Color(0xFFE5484D),
    chip: Color(0x8CFFFFFF),
    hover: Color(0x14FFFFFF),
    primaryBtn: Color(0xFF1F1D24),
    onPrimaryBtn: Colors.white,
    onAccent: Colors.white,
    toastBg: Color(0xFF1F1D24),
    toastFg: Colors.white,
    shadow: Color(0x12000000),
    codeBg: Color(0xFFF0EEFB),
    codeFg: Color(0xFF4E4A8A),
    windowBorder: Color(0x33FFFFFF),
    orb1: Color(0x77FFC6A3),
    orb2: Color(0x5A9BA8FF),
    orb3: Color(0x4AD3A6FF),
    orb4: Color(0x40FFE0A8),
    userBubble: [Color(0xFF7B8CFF), Color(0xFFB98CFF)],
    hero: [Color(0xFFF2B58C), Color(0xFFB79CFF)],
  );

  static const dark = LoopPalette(
    brightness: Brightness.dark,
    bgTop: Color(0xFF121119),
    bgBottom: Color(0xFF171326),
    ink: Color(0xFFF2EFE8),
    muted: Color(0xFFA7A3B3),
    faint: Color(0xFF6F6B7A),
    glassFill: Color(0x14FFFFFF),
    glassBorder: Color(0x24FFFFFF),
    cardFill: Color(0x12FFFFFF),
    cardSolid: Color(0xFF1C1A24),
    border: Color(0x1FFFFFFF),
    accent: Color(0xFF9AA8FF),
    accent2: Color(0xFFC9A2FF),
    warm: Color(0xFFF0B58C),
    danger: Color(0xFFFF6B70),
    chip: Color(0x14FFFFFF),
    hover: Color(0x1FFFFFFF),
    primaryBtn: Color(0xFFF2EFE8),
    onPrimaryBtn: Color(0xFF15131A),
    onAccent: Colors.white,
    toastBg: Color(0xFF2B2836),
    toastFg: Color(0xFFF7F4EC),
    shadow: Color(0x73000000),
    codeBg: Color(0xFF28243A),
    codeFg: Color(0xFFD8D3FF),
    windowBorder: Color(0x26FFFFFF),
    orb1: Color(0x33FF9E6D),
    orb2: Color(0x2E7E8CFF),
    orb3: Color(0x29B07CFF),
    orb4: Color(0x1FFFC97A),
    userBubble: [Color(0xFF6F7BFF), Color(0xFFA57CFF)],
    hero: [Color(0xFFC9855F), Color(0xFF8A6BD6)],
  );
}

class LoopTheme {
  static LoopPalette palette = LoopPalette.light;
}

/// 简写：所有界面文件用 `pal.xxx`。
LoopPalette get pal => LoopTheme.palette;
