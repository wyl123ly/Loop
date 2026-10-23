import 'package:flutter/material.dart';

import 'theme/palette.dart';

export 'theme/palette.dart';

ThemeData loopTheme(LoopPalette p) {
  final scheme = ColorScheme.fromSeed(seedColor: p.accent, brightness: p.brightness);
  return ThemeData(
    useMaterial3: true,
    fontFamily: 'NotoSC',
    brightness: p.brightness,
    colorScheme: scheme.copyWith(
      primary: p.primaryBtn,
      onPrimary: p.onPrimaryBtn,
      surface: p.cardSolid,
      onSurface: p.ink,
      error: p.danger,
    ),
    scaffoldBackgroundColor: p.bgTop,
    splashFactory: InkSparkle.splashFactory,
    textTheme: TextTheme(
      bodyMedium: TextStyle(fontSize: 14.5, height: 1.7, color: p.ink),
      bodySmall: TextStyle(fontSize: 12.5, height: 1.55, color: p.muted),
      titleMedium: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: p.ink),
      titleLarge: TextStyle(
        fontSize: 22,
        fontWeight: FontWeight.w700,
        color: p.ink,
        letterSpacing: -0.3,
      ),
    ),
    dividerTheme: DividerThemeData(color: p.border, thickness: 1, space: 1),
    scrollbarTheme: ScrollbarThemeData(
      thickness: const WidgetStatePropertyAll(6),
      radius: const Radius.circular(99),
      thumbColor: WidgetStatePropertyAll(p.muted.withValues(alpha: 0.35)),
      crossAxisMargin: 2,
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: p.glassFill,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      hintStyle: TextStyle(color: p.muted, fontSize: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: p.glassBorder),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: p.glassBorder),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: p.accent, width: 1.4),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: p.primaryBtn,
        foregroundColor: p.onPrimaryBtn,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: const TextStyle(fontFamily: 'NotoSC', fontSize: 14, fontWeight: FontWeight.w600),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: p.ink,
        textStyle: const TextStyle(fontFamily: 'NotoSC', fontSize: 13.5, fontWeight: FontWeight.w500),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: p.ink,
        side: BorderSide(color: p.glassBorder),
        backgroundColor: p.chip,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: const TextStyle(fontFamily: 'NotoSC', fontSize: 13.5),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      backgroundColor: p.toastBg,
      contentTextStyle: TextStyle(fontFamily: 'NotoSC', color: p.toastFg, fontSize: 13.5),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: p.toastBg,
        borderRadius: BorderRadius.circular(8),
      ),
      textStyle: TextStyle(fontFamily: 'NotoSC', color: p.toastFg, fontSize: 12),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: p.cardSolid,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      titleTextStyle: TextStyle(
        fontFamily: 'NotoSC',
        fontSize: 18,
        fontWeight: FontWeight.w700,
        color: p.ink,
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: p.cardSolid,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      textStyle: TextStyle(fontFamily: 'NotoSC', color: p.ink, fontSize: 13),
    ),
  );
}

BoxDecoration panelDecoration({Color? color, double radius = 22}) {
  final p = pal;
  return BoxDecoration(
    color: color ?? p.cardFill,
    borderRadius: BorderRadius.circular(radius),
    border: Border.all(color: p.glassBorder),
    boxShadow: [BoxShadow(color: p.shadow, blurRadius: 28, offset: const Offset(0, 12))],
  );
}

BoxDecoration softDecoration({Color? color, double radius = 16}) {
  final p = pal;
  return BoxDecoration(
    color: color ?? p.chip,
    borderRadius: BorderRadius.circular(radius),
    border: Border.all(color: p.glassBorder),
  );
}

LinearGradient get accentGradient => pal.accentGradient;
LinearGradient get warmGradient => pal.heroGradient;
