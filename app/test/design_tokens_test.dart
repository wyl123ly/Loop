import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loop/theme.dart';

double _luminance(Color color) {
  double channel(double value) {
    final v = value / 255.0;
    return v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  }

  return 0.2126 * channel(color.r * 255) +
      0.7152 * channel(color.g * 255) +
      0.0722 * channel(color.b * 255);
}

double _contrast(Color a, Color b) {
  final l1 = _luminance(a);
  final l2 = _luminance(b);
  final hi = l1 > l2 ? l1 : l2;
  final lo = l1 > l2 ? l2 : l1;
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  group('v0.8.11 design tokens', () {
    test('D1 浅色文字 token 在卡片底上达到 AA', () {
      final p = LoopPalette.light;
      expect(_contrast(p.muted, p.cardSolid), greaterThanOrEqualTo(4.5));
      expect(_contrast(p.accentInk, p.cardSolid), greaterThanOrEqualTo(4.5));
      expect(_contrast(p.dangerInk, p.cardSolid), greaterThanOrEqualTo(4.5));
      expect(_contrast(p.success, p.cardSolid), greaterThanOrEqualTo(4.5));
      expect(_contrast(p.warningInk, p.cardSolid), greaterThanOrEqualTo(4.5));
      // faint 只允许装饰用途。
      expect(_contrast(p.faint, p.cardSolid), greaterThanOrEqualTo(3.0));
    });

    test('D2 深色文字 token 在卡片底上达到 AA', () {
      final p = LoopPalette.dark;
      expect(_contrast(p.muted, p.cardSolid), greaterThanOrEqualTo(4.5));
      expect(_contrast(p.faint, p.cardSolid), greaterThanOrEqualTo(4.5));
      expect(_contrast(p.accentInk, p.cardSolid), greaterThanOrEqualTo(4.5));
      expect(_contrast(p.dangerInk, p.cardSolid), greaterThanOrEqualTo(4.5));
      expect(_contrast(p.success, p.cardSolid), greaterThanOrEqualTo(4.5));
      expect(_contrast(p.warningInk, p.cardSolid), greaterThanOrEqualTo(4.5));
    });

    test('D3 渐变承载文字达到 AA', () {
      for (final p in [LoopPalette.light, LoopPalette.dark]) {
        for (final fill in p.accentFill) {
          expect(_contrast(p.onAccent, fill), greaterThanOrEqualTo(4.5),
              reason: '${p.brightness} accentFill $fill');
        }
        for (final bubble in p.userBubble) {
          expect(_contrast(p.onAccent, bubble), greaterThanOrEqualTo(4.5),
              reason: '${p.brightness} userBubble $bubble');
        }
      }
    });

    test('D4 字号、圆角、间距档位收敛', () {
      const fonts = <double>[
        LoopType.micro,
        LoopType.caption,
        LoopType.secondary,
        LoopType.body,
        LoopType.reading,
        LoopType.title,
        LoopType.display,
      ];
      expect(fonts.toSet(), hasLength(7));
      const radii = <double>[
        LoopRadius.small,
        LoopRadius.control,
        LoopRadius.card,
        LoopRadius.panel,
        LoopRadius.pill,
      ];
      expect(radii.toSet(), hasLength(5));
      const spaces = <double>[
        LoopSpace.x1,
        LoopSpace.x2,
        LoopSpace.x3,
        LoopSpace.x4,
        LoopSpace.x5,
        LoopSpace.x6,
        LoopSpace.x8,
        LoopSpace.x12,
      ];
      expect(spaces.toSet(), hasLength(8));
    });

    test('D5 默认控件使用 accent，主按钮保持 ink', () {
      final light = loopTheme(LoopPalette.light);
      expect(light.colorScheme.primary, LoopPalette.light.accent);
      expect(light.progressIndicatorTheme.color, LoopPalette.light.accent);
      expect(light.filledButtonTheme.style?.backgroundColor?.resolve({}), LoopPalette.light.primaryBtn);
      final dark = loopTheme(LoopPalette.dark);
      expect(dark.colorScheme.primary, LoopPalette.dark.accent);
      expect(dark.progressIndicatorTheme.color, LoopPalette.dark.accent);
    });

    test('D6 hero 与错误 SnackBar 在真实前后景上达到 AA', () {
      final light = LoopPalette.light;
      for (final bg in light.hero) {
        expect(_contrast(light.ink, bg), greaterThanOrEqualTo(4.5),
            reason: 'light hero $bg');
      }
      final dark = LoopPalette.dark;
      for (final bg in dark.hero) {
        expect(_contrast(dark.onPrimaryBtn, bg), greaterThanOrEqualTo(4.5),
            reason: 'dark hero $bg');
      }
      for (final p in [light, dark]) {
        expect(_contrast(p.onPrimaryBtn, p.dangerInk), greaterThanOrEqualTo(4.5),
            reason: '${p.brightness} error snackbar');
      }
    });
  });
}