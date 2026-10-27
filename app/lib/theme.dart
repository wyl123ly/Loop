import 'package:flutter/material.dart';

import 'theme/palette.dart';

export 'theme/palette.dart';

/// v0.8.11 收敛后的排版、间距、圆角 token。
/// 只收敛取值，不改动设计风格。
class LoopType {
  const LoopType._();

  /// 时间戳、徽标、栏目标签。
  static const double micro = 10.0;

  /// 元信息、辅助说明。
  static const double caption = 11.5;

  /// 列表副标题、空态正文。
  static const double secondary = 12.5;

  /// 默认 UI 文字：按钮、导航、列表标题。
  static const double body = 13.5;

  /// 阅读正文：对话、Markdown、笔记。
  static const double reading = 15.0;

  /// 区块 / 卡片 / 对话框标题。
  static const double title = 18.0;

  /// 页面标题、数据主值。
  static const double display = 24.0;
}

class LoopSpace {
  const LoopSpace._();

  static const double x1 = 4;
  static const double x2 = 8;
  static const double x3 = 12;
  static const double x4 = 16;
  static const double x5 = 20;
  static const double x6 = 24;
  static const double x8 = 32;
  static const double x12 = 48;
}

class LoopRadius {
  const LoopRadius._();

  static const double small = 8;
  static const double control = 12;
  static const double card = 16;
  static const double panel = 24;
  static const double pill = 999;
}

ThemeData loopTheme(LoopPalette p) {
  final scheme = ColorScheme.fromSeed(seedColor: p.accent, brightness: p.brightness);
  return ThemeData(
    useMaterial3: true,
    fontFamily: 'NotoSC',
    brightness: p.brightness,
    colorScheme: scheme.copyWith(
      // 默认控件（Switch/Checkbox/进度圈）应使用品牌紫，而不是主按钮的墨色。
      primary: p.accent,
      onPrimary: p.onAccent,
      surface: p.cardSolid,
      onSurface: p.ink,
      error: p.dangerInk,
      onError: p.onAccent,
    ),
    scaffoldBackgroundColor: p.bgTop,
    splashFactory: InkSparkle.splashFactory,
    textTheme: TextTheme(
      bodyMedium: TextStyle(fontSize: LoopType.reading, height: 1.6, color: p.ink),
      bodySmall: TextStyle(fontSize: LoopType.secondary, height: 1.6, color: p.muted),
      titleMedium: TextStyle(
        fontSize: LoopType.reading,
        fontWeight: FontWeight.w600,
        color: p.ink,
      ),
      titleLarge: TextStyle(
        fontSize: LoopType.display,
        fontWeight: FontWeight.w700,
        color: p.ink,
        letterSpacing: -0.5,
        height: 1.2,
      ),
    ),
    dividerTheme: DividerThemeData(color: p.border, thickness: 1, space: 1),
    scrollbarTheme: ScrollbarThemeData(
      thickness: const WidgetStatePropertyAll(6),
      radius: const Radius.circular(LoopRadius.pill),
      thumbColor: WidgetStatePropertyAll(p.muted.withValues(alpha: 0.35)),
      crossAxisMargin: 2,
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: p.glassFill,
      contentPadding: const EdgeInsets.symmetric(
        horizontal: LoopSpace.x4,
        vertical: LoopSpace.x3,
      ),
      hintStyle: TextStyle(color: p.muted, fontSize: LoopType.body),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(LoopRadius.control),
        borderSide: BorderSide(color: p.glassBorder),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(LoopRadius.control),
        borderSide: BorderSide(color: p.glassBorder),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(LoopRadius.control),
        borderSide: BorderSide(color: p.accent, width: 1.4),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: p.primaryBtn,
        foregroundColor: p.onPrimaryBtn,
        padding: const EdgeInsets.symmetric(
          horizontal: LoopSpace.x5,
          vertical: LoopSpace.x3,
        ),
        minimumSize: const Size(0, 44),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(LoopRadius.control),
        ),
        textStyle: const TextStyle(
          fontFamily: 'NotoSC',
          fontSize: LoopType.body,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: p.ink,
        textStyle: const TextStyle(
          fontFamily: 'NotoSC',
          fontSize: LoopType.body,
          fontWeight: FontWeight.w500,
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: p.ink,
        side: BorderSide(color: p.glassBorder),
        backgroundColor: p.chip,
        minimumSize: const Size(0, 44),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(LoopRadius.control),
        ),
        textStyle: const TextStyle(fontFamily: 'NotoSC', fontSize: LoopType.body),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(LoopRadius.card)),
      backgroundColor: p.toastBg,
      contentTextStyle: TextStyle(
        fontFamily: 'NotoSC',
        color: p.toastFg,
        fontSize: LoopType.body,
      ),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: p.toastBg,
        borderRadius: BorderRadius.circular(LoopRadius.small),
      ),
      textStyle: TextStyle(
        fontFamily: 'NotoSC',
        color: p.toastFg,
        fontSize: LoopType.caption,
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: p.cardSolid,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(LoopRadius.panel)),
      titleTextStyle: TextStyle(
        fontFamily: 'NotoSC',
        fontSize: LoopType.title,
        fontWeight: FontWeight.w700,
        color: p.ink,
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: p.cardSolid,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(LoopRadius.control)),
      textStyle: TextStyle(
        fontFamily: 'NotoSC',
        color: p.ink,
        fontSize: LoopType.body,
      ),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: p.accent,
      linearTrackColor: p.accent.withValues(alpha: 0.18),
      circularTrackColor: p.accent.withValues(alpha: 0.18),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return p.onAccent;
        return p.muted;
      }),
      trackColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return p.accent;
        return p.border;
      }),
    ),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return p.accent;
        return Colors.transparent;
      }),
      checkColor: WidgetStatePropertyAll(p.onAccent),
      side: BorderSide(color: p.muted, width: 1.4),
    ),
    sliderTheme: SliderThemeData(
      activeTrackColor: p.accent,
      thumbColor: p.accent,
      inactiveTrackColor: p.accent.withValues(alpha: 0.18),
    ),
  );
}

BoxDecoration panelDecoration({Color? color, double radius = LoopRadius.panel}) {
  final p = pal;
  return BoxDecoration(
    color: color ?? p.cardFill,
    borderRadius: BorderRadius.circular(radius),
    border: Border.all(color: p.glassBorder),
    boxShadow: [BoxShadow(color: p.shadow, blurRadius: 28, offset: const Offset(0, 12))],
  );
}

BoxDecoration softDecoration({Color? color, double radius = LoopRadius.card}) {
  final p = pal;
  return BoxDecoration(
    color: color ?? p.chip,
    borderRadius: BorderRadius.circular(radius),
    border: Border.all(color: p.glassBorder),
  );
}

LinearGradient get accentGradient => pal.accentGradient;
LinearGradient get accentFillGradient => pal.accentFillGradient;
LinearGradient get warmGradient => pal.heroGradient;