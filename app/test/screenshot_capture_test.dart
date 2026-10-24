import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loop/desktop/screenshot_plan.dart';
import 'package:loop/desktop/window_mode.dart';

/// t2 截图契约测试（脚本参数/尺寸校验/禁止项静态检查）。
void main() {
  const primary = DisplayInfo(
    id: r'\\.\DISPLAY1',
    physicalBounds: Rect.fromLTWH(0, 0, 1920, 1080),
    physicalWorkArea: Rect.fromLTWH(0, 0, 1920, 1040),
    scaleFactor: 1.0,
    isPrimary: true,
  );

  group('截图计划', () {
    test('U-CAP-01 物理工作区 -> -X/-Y/-W/-H（含负数）', () {
      final plan = planCaptureForDisplay(
        const DisplayInfo(
          id: 'left',
          physicalBounds: Rect.fromLTWH(-1920, 0, 1920, 1080),
          physicalWorkArea: Rect.fromLTWH(-1920, 0, 1920, 1040),
        ),
      );
      expect(
        plan.arguments,
        ['-X', '-1920', '-Y', '0', '-W', '1920', '-H', '1040'],
      );
      expect(plan.pixelWidth, 1920);
      expect(plan.pixelHeight, 1040);
      expect(plan.isEmpty, isFalse);
    });

    test('主屏回退计划（显示器解析失败时使用）', () {
      final plan = planCaptureForDisplay(primary);
      expect(plan.arguments, ['-X', '0', '-Y', '0', '-W', '1920', '-H', '1040']);
      expect(plan.display.isPrimary, isTrue);
    });

    test('U-CAP-05 非 PNG / 尺寸偏差 -> 判失败', () {
      final plan = planCaptureForDisplay(primary);
      expect(pngMatchesPlan(Uint8List.fromList([1, 2, 3]), plan), isFalse);
      final header = _pngHeader(1920, 1040);
      expect(pngMatchesPlan(header, plan), isTrue);
      expect(pngMatchesPlan(_pngHeader(1920, 900), plan), isFalse);
      expect(pngDimensions(_pngHeader(460, 600)), (width: 460, height: 600));
    });
  });

  group('assets/screenshot.ps1 v2 契约', () {
    late String script;

    setUpAll(() {
      script = File('assets/screenshot.ps1').readAsStringSync();
    });

    test('支持显式物理矩形与主屏回退参数', () {
      expect(script, contains(r'[int]$X = 0'));
      expect(script, contains(r'[int]$Y = 0'));
      expect(script, contains(r'[int]$W = 0'));
      expect(script, contains(r'[int]$H = 0'));
      expect(script, contains(r'CopyFromScreen($source, $target, $size)'));
      expect(script, contains('PrimaryScreen.Bounds'));
    });

    test('DPI：优先 Per-Monitor-V2，再回退 system aware', () {
      expect(script, contains('SetProcessDpiAwarenessContext'));
      expect(script, contains('SetProcessDPIAware'));
      expect(script, contains('[IntPtr](-4)'));
    });

    test('错误码 0/2/3/4 与临时目录无周期性行为', () {
      expect(script, contains('exit 2'));
      expect(script, contains('exit 3'));
      expect(script, contains('exit 4'));
      expect(script.toLowerCase(), isNot(contains('while (')));
      expect(script.toLowerCase(), isNot(contains('while(')));
    });

    test('脚本必须纯 ASCII（Windows PowerShell 5.1 无 BOM 以 ANSI 解析）', () {
      final nonAscii = script.codeUnits.where((unit) => unit > 127).length;
      expect(nonAscii, 0, reason: '非 ASCII 注释会破坏 powershell.exe 解析');
    });
  });

  group('禁止项静态检查（AC-1.3 / AC-8.5 / AC-1.1）', () {
    test('lib 无 setFullScreen / 仅主入口+multi_window 分支两个 runApp / 无 FlutterEngine', () {
      final dartFiles = Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => file.path.endsWith('.dart'))
          .toList();
      expect(dartFiles, isNotEmpty);
      var runAppCount = 0;
      var engineCount = 0;
      for (final file in dartFiles) {
        final source = file.readAsStringSync();
        expect(
          source.contains('setFullScreen'),
          isFalse,
          reason: '${file.path} 不得调用 setFullScreen',
        );
        // 只统计真实代码：注释里的 `runApp`/`FlutterEngine` 描述不算调用/实例化。
        final code = source
            .replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '')
            .replaceAll(RegExp(r'//[^\n]*'), '');
        runAppCount += 'runApp('.allMatches(code).length;
        engineCount += 'FlutterEngine'.allMatches(code).length;
      }
      // v0.6.0：允许主入口 + `multi_window` 第二引擎分支各 1 个 runApp；
      // 第二个入口必须走 desktop_multi_window（不手建 FlutterEngine），
      // 由 t2 的 prepareAnswerEngine 统一分流（规格 §2.4/§9.1）。
      final mainSource = File('lib/main.dart').readAsStringSync();
      final hasMultiWindowBranch = mainSource.contains("'multi_window'") ||
          mainSource.contains('"multi_window"');
      if (hasMultiWindowBranch) {
        expect(
          mainSource.contains('prepareAnswerEngine'),
          isTrue,
          reason: 'multi_window 分支必须走 t2 的第二引擎入口 helper',
        );
        expect(runAppCount, 2, reason: '只允许主入口与 multi_window 分支各一个 runApp');
      } else {
        expect(runAppCount, 1, reason: '无第二引擎时只允许一个 runApp 入口');
      }
      expect(engineCount, 0, reason: '不得手建第二个 FlutterEngine');
    });
  });
}

Uint8List _pngHeader(int width, int height) {
  final bytes = Uint8List(33);
  const signature = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
  for (var i = 0; i < signature.length; i++) {
    bytes[i] = signature[i];
  }
  bytes[12] = 0x49;
  bytes[13] = 0x48;
  bytes[14] = 0x44;
  bytes[15] = 0x52;
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
