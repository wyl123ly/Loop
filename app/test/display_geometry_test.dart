import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loop/desktop/screenshot_plan.dart';
import 'package:loop/desktop/window_mode.dart';

/// t2 纯几何/显示器选择/截图参数测试：U-GEO-01~08、U-CAP-01/05。
void main() {
  const primary1080 = DisplayInfo(
    id: r'\\.\DISPLAY1',
    physicalBounds: Rect.fromLTWH(0, 0, 1920, 1080),
    physicalWorkArea: Rect.fromLTWH(0, 0, 1920, 1040),
    scaleFactor: 1.0,
    isPrimary: true,
  );
  const right1080 = DisplayInfo(
    id: r'\\.\DISPLAY2',
    physicalBounds: Rect.fromLTWH(1920, 0, 1920, 1080),
    physicalWorkArea: Rect.fromLTWH(1920, 0, 1920, 1040),
    scaleFactor: 1.0,
  );

  group('FloatingWindowPlanner.placeFloating', () {
    test('U-GEO-01 1920x1040@1 -> (1436,220,460,600)', () {
      final rect = FloatingWindowPlanner.placeFloating(
        primary1080.physicalWorkArea,
        1.0,
        floatingDefaultSize,
        floatingMinSize,
        floatingMargin,
      );
      expect(rect.left, closeTo(1436, 0.01));
      expect(rect.top, closeTo(220, 0.01));
      expect(rect.width, closeTo(460, 0.01));
      expect(rect.height, closeTo(600, 0.01));
    });

    test('U-GEO-02 2560x1440@150%：逻辑工作区换算正确', () {
      const work = Rect.fromLTWH(0, 0, 3840, 2080);
      final rect = FloatingWindowPlanner.placeFloating(
        work,
        1.5,
        floatingDefaultSize,
        floatingMinSize,
        floatingMargin,
      );
      // 逻辑工作区 2560 x 1386.67；右边缘内缩 24；垂直居中。
      expect(rect.left, closeTo(2076, 0.01));
      expect(rect.width, closeTo(460, 0.01));
      expect(rect.height, closeTo(600, 0.01));
      expect(rect.top, closeTo((2080 / 1.5 - 600) / 2, 0.01));
      expect(rect.right, lessThanOrEqualTo(2560 - 24 + 0.01));
    });

    test('U-GEO-03 800x500 小屏：高度被工作区限制', () {
      final rect = FloatingWindowPlanner.placeFloating(
        const Rect.fromLTWH(0, 0, 800, 500),
        1.0,
        floatingDefaultSize,
        floatingMinSize,
        floatingMargin,
      );
      expect(rect.left, closeTo(316, 0.01));
      expect(rect.top, closeTo(24, 0.01));
      expect(rect.width, closeTo(460, 0.01));
      expect(rect.height, closeTo(452, 0.01));
      expect(rect.bottom, lessThanOrEqualTo(500 - 24 + 0.01));
    });

    test('U-GEO-04 300x300 极小屏：保持 360x420 并钉在 margin', () {
      final rect = FloatingWindowPlanner.placeFloating(
        const Rect.fromLTWH(0, 0, 300, 300),
        1.0,
        floatingDefaultSize,
        floatingMinSize,
        floatingMargin,
      );
      expect(rect.width, closeTo(360, 0.01));
      expect(rect.height, closeTo(420, 0.01));
      expect(rect.left, closeTo(24, 0.01));
      expect(rect.top, closeTo(24, 0.01));
    });

    test('U-GEO-05 左/上负坐标副屏', () {
      final left = FloatingWindowPlanner.placeFloating(
        const Rect.fromLTWH(-1920, 0, 1920, 1040),
        1.0,
        floatingDefaultSize,
        floatingMinSize,
        floatingMargin,
      );
      expect(left.left, closeTo(-484, 0.01));
      expect(left.top, closeTo(220, 0.01));

      final top = FloatingWindowPlanner.placeFloating(
        const Rect.fromLTWH(0, -1080, 1920, 1040),
        1.0,
        floatingDefaultSize,
        floatingMinSize,
        floatingMargin,
      );
      expect(top.left, closeTo(1436, 0.01));
      expect(top.top, closeTo(-860, 0.01));
    });

    test('U-GEO-08 dpr 缺失/0/NaN/越界 -> 1.0', () {
      expect(FloatingWindowPlanner.normalizedDpr(null), 1.0);
      expect(FloatingWindowPlanner.normalizedDpr(0), 1.0);
      expect(FloatingWindowPlanner.normalizedDpr(double.nan), 1.0);
      expect(FloatingWindowPlanner.normalizedDpr(double.infinity), 1.0);
      expect(FloatingWindowPlanner.normalizedDpr(-2), 1.0);
      expect(FloatingWindowPlanner.normalizedDpr(5), 1.0);
      expect(FloatingWindowPlanner.normalizedDpr(1.25), 1.25);
    });
  });

  group('FloatingWindowPlanner.chooseDisplay', () {
    test('U-GEO-06 窗口中心命中副屏', () {
      final chosen = FloatingWindowPlanner.chooseDisplay(
        const [primary1080, right1080],
        const Rect.fromLTWH(2200, 100, 400, 300),
      );
      expect(chosen?.id, right1080.id);
    });

    test('U-GEO-06 交集最大优先', () {
      final chosen = FloatingWindowPlanner.chooseDisplay(
        const [primary1080, right1080],
        const Rect.fromLTWH(1750, 100, 300, 300),
      );
      expect(chosen?.id, primary1080.id);
    });

    test('U-GEO-06 完全离屏 -> 主屏回退', () {
      final chosen = FloatingWindowPlanner.chooseDisplay(
        const [right1080, primary1080],
        const Rect.fromLTWH(-5000, -5000, 100, 100),
      );
      expect(chosen?.id, primary1080.id);
    });

    test('U-GEO-06 空列表 -> null', () {
      expect(
        FloatingWindowPlanner.chooseDisplay(
          const [],
          const Rect.fromLTWH(0, 0, 100, 100),
        ),
        isNull,
      );
    });
  });

  group('离屏校正', () {
    test('U-GEO-07 离屏普通窗口 -> 主屏居中 900x600', () {
      final bounds = FloatingWindowPlanner.defaultNormalBounds(primary1080);
      expect(bounds.size, const Size(900, 600));
      expect(bounds.left, closeTo(510, 0.01));
      expect(bounds.top, closeTo(220, 0.01));
    });

    test('U-GEO-07 浮窗钳制回工作区', () {
      final clamped = FloatingWindowPlanner.clampToWorkArea(
        const Rect.fromLTWH(1900, 1000, 460, 600),
        primary1080.physicalWorkArea,
        1.0,
      );
      expect(clamped.right, lessThanOrEqualTo(1920));
      expect(clamped.bottom, lessThanOrEqualTo(1040));
      expect(clamped.width, closeTo(460, 0.01));
      expect(clamped.height, closeTo(600, 0.01));
    });
  });

  group('截图参数（U-CAP-01）', () {
    test('负坐标副屏传 -X/-Y/-W/-H', () {
      const leftDisplay = DisplayInfo(
        id: r'\\.\DISPLAY2',
        physicalBounds: Rect.fromLTWH(-1920, 0, 1920, 1080),
        physicalWorkArea: Rect.fromLTWH(-1920, 0, 1920, 1040),
        scaleFactor: 1.0,
      );
      final plan = planCapture(
        displays: const [primary1080, leftDisplay],
        windowPhysicalRect: const Rect.fromLTWH(-1700, 200, 460, 600),
      );
      expect(plan, isNotNull);
      expect(plan!.display.id, leftDisplay.id);
      expect(
        plan.arguments,
        ['-X', '-1920', '-Y', '0', '-W', '1920', '-H', '1040'],
      );
    });

    test('按窗口中心选择显示器（副屏）', () {
      final plan = planCapture(
        displays: const [primary1080, right1080],
        windowPhysicalRect: const Rect.fromLTWH(2200, 100, 460, 600),
      );
      expect(plan!.display.id, right1080.id);
      expect(plan.arguments, ['-X', '1920', '-Y', '0', '-W', '1920', '-H', '1040']);
    });

    test('显示器列表为空 -> null（调用方回退主屏）', () {
      expect(
        planCapture(
          displays: const [],
          windowPhysicalRect: const Rect.fromLTWH(0, 0, 460, 600),
        ),
        isNull,
      );
    });

    test('工作区取整并保证非空', () {
      const fractional = DisplayInfo(
        id: 'd',
        physicalBounds: Rect.fromLTWH(0, 0, 1000, 800),
        physicalWorkArea: Rect.fromLTWH(0.4, 0.6, 999.6, 799.4),
        scaleFactor: 1.25,
      );
      final plan = planCaptureForDisplay(fractional);
      expect(plan.physicalRect.left, 0);
      expect(plan.physicalRect.top, 1);
      expect(plan.pixelWidth, 1000);
      expect(plan.pixelHeight, 799);
    });
  });

  group('PNG 尺寸校验（U-CAP-05）', () {
    Uint8List pngHeader(int width, int height) {
      final bytes = Uint8List(33);
      const signature = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
      for (var i = 0; i < signature.length; i++) {
        bytes[i] = signature[i];
      }
      bytes[12] = 0x49; // I
      bytes[13] = 0x48; // H
      bytes[14] = 0x44; // D
      bytes[15] = 0x52; // R
      void writeInt(int offset, int value) {
        bytes[offset] = (value >> 24) & 0xFF;
        bytes[offset + 1] = (value >> 16) & 0xFF;
        bytes[offset + 2] = (value >> 8) & 0xFF;
        bytes[offset + 3] = value & 0xFF;
      }

      writeInt(16, width);
      writeInt(20, height);
      return bytes;
    }

    test('尺寸匹配通过；偏差超过容差失败', () {
      final plan = planCaptureForDisplay(primary1080);
      expect(pngMatchesPlan(pngHeader(1920, 1040), plan), isTrue);
      expect(pngMatchesPlan(pngHeader(1919, 1041), plan), isTrue);
      expect(pngMatchesPlan(pngHeader(1900, 1040), plan), isFalse);
      expect(pngDimensions(pngHeader(1920, 1040)), (width: 1920, height: 1040));
      expect(pngDimensions(Uint8List.fromList([1, 2, 3])), isNull);
    });
  });
}
