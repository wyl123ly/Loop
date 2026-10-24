import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loop/desktop/screenshot_plan.dart';
import 'package:loop/desktop/win32_display.dart';

/// Win32/DPI FFI 冒烟测试（Windows 上验证结构体布局与回退）。
///
/// 这些调用发生在 Flutter test 的 Dart VM 里，不需要真实窗口；主要防止
/// `MONITORINFOEXW/RECT` 布局错误、shcore 缺失、DPI 回退等回归。
void main() {
  final onWindows = Platform.isWindows;

  group('Win32Display FFI', () {
    test('枚举显示器：至少 1 个、工作区/主屏/DPI 合法', () {
      if (!onWindows) return;
      final displays = Win32Display.displays();
      expect(displays, isNotEmpty);
      for (final display in displays) {
        expect(display.id, isNotEmpty);
        expect(display.physicalBounds.width, greaterThan(0));
        expect(display.physicalBounds.height, greaterThan(0));
        expect(display.physicalWorkArea.width, greaterThan(0));
        expect(display.physicalWorkArea.height, greaterThan(0));
        expect(display.scaleFactor, inInclusiveRange(0.5, 4.0));
        // 工作区必须包含在显示器矩形内（allow ±1 rounding）。
        expect(
          display.physicalWorkArea.left,
          greaterThanOrEqualTo(display.physicalBounds.left - 1),
        );
        expect(
          display.physicalWorkArea.top,
          greaterThanOrEqualTo(display.physicalBounds.top - 1),
        );
        expect(
          display.physicalWorkArea.right,
          lessThanOrEqualTo(display.physicalBounds.right + 1),
        );
        expect(
          display.physicalWorkArea.bottom,
          lessThanOrEqualTo(display.physicalBounds.bottom + 1),
        );
      }
      expect(displays.where((display) => display.isPrimary), hasLength(1));
    });

    test('显示器命中/截图计划使用真实工作区', () {
      if (!onWindows) return;
      final displays = Win32Display.displays();
      final report = displays
          .map((display) =>
              '${display.id} work=${display.physicalWorkArea} scale=${display.scaleFactor} primary=${display.isPrimary}')
          .join(' | ');
      final primary = displays.firstWhere((display) => display.isPrimary);
      final center = primary.physicalWorkArea.center;
      expect(primary.physicalWorkArea.contains(center), isTrue, reason: report);

      // MonitorFromPoint 的坐标空间取决于进程 DPI 感知级别（flutter_tester
      // 可能是 system-aware），只做“可调用、有返回值”的冒烟断言；几何选择逻辑
      // 由纯函数 chooseDisplay 的用例覆盖。
      final hit = Win32Display.displayAt(center);
      expect(hit, isNotNull, reason: report);
      expect(hit!.id, isNotEmpty);
      expect(
        Win32Display.displayIdAt(center),
        isNotNull,
        reason: report,
      );

      // 生产路径（chooseDisplay 用枚举结果，不用 MonitorFromPoint）必须命中主屏。
      final plan = planCapture(
        displays: displays,
        windowPhysicalRect: Rect.fromCenter(
          center: center,
          width: 460,
          height: 600,
        ),
      );
      expect(plan, isNotNull);
      expect(plan!.display.id, primary.id, reason: report);
      expect(
        plan.arguments[1],
        primary.physicalWorkArea.left.round().toString(),
      );
      expect(
        plan.arguments[3],
        primary.physicalWorkArea.top.round().toString(),
      );
      expect(plan.pixelWidth, primary.physicalWorkArea.width.round());
      expect(plan.pixelHeight, primary.physicalWorkArea.height.round());
    });

    test('无有效 HWND 时安全返回（不崩溃、可回退）', () {
      if (!onWindows) return;
      expect(Win32Display.windowRect(0), isNull);
      // MonitorFromPoint(MONITOR_DEFAULTTONEAREST) 总是返回最近显示器。
      expect(
        Win32Display.displayAt(const Offset(-999999, -999999)),
        isNotNull,
      );
      expect(
        Win32Display.setWindowPos(
          0,
          const Rect.fromLTWH(0, 0, 100, 100),
          topmost: false,
        ),
        isFalse,
      );
      expect(Win32Display.isAlwaysOnTop(0), isFalse);
      expect(Win32Display.isMinimized(0), isFalse);
      expect(Win32Display.showNoActivate(0), isFalse);
      expect(Win32Display.restoreNoActivate(0), isFalse);
      expect(Win32Display.normalPlacement(0), isNull);
      expect(
        Win32Display.setWindowPlacement(
          0,
          const Rect.fromLTWH(0, 0, 900, 600),
          maximized: true,
        ),
        isFalse,
      );
      expect(Win32Display.scaleForWindow(0), greaterThan(0));
    });
  });
}
