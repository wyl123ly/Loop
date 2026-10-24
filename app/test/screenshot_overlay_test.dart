import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loop/screens/screenshot_overlay.dart';

/// 生成与视口同宽高比的 PNG，避免触发“截图尺寸与窗口不匹配”保护。
Future<Uint8List> _png(WidgetTester tester, int width, int height) async {
  late Uint8List bytes;
  await tester.runAsync(() async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(
      Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      Paint()..color = const Color(0xFF3355AA),
    );
    final picture = recorder.endRecording();
    final image = await picture.toImage(width, height);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    bytes = data!.buffer.asUint8List();
    image.dispose();
  });
  return bytes;
}

class _OverlayHandle {
  ScreenshotOverlayResult? result;
  bool opened = false;
}

Future<_OverlayHandle> _openOverlay(
  WidgetTester tester,
  Uint8List png, {
  bool allowRetake = true,
}) async {
  final handle = _OverlayHandle();
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: ElevatedButton(
            onPressed: () async {
              handle.opened = true;
              handle.result = await Navigator.of(context).push<ScreenshotOverlayResult>(
                PageRouteBuilder(
                  transitionDuration: Duration.zero,
                  pageBuilder: (_, _, _) => ScreenshotOverlay(
                    imageBytes: png,
                    allowRetake: allowRetake,
                  ),
                ),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pump();
  expect(handle.opened, isTrue);
  await tester.runAsync(() async {
    await Future<void>.delayed(const Duration(milliseconds: 250));
  });
  await tester.pump();
  return handle;
}

void main() {
  testWidgets('截图选框可以拖拽选择并取消', (tester) async {
    final png = await _png(tester, 800, 600);
    final handle = await _openOverlay(tester, png);

    expect(find.byType(ScreenshotOverlay), findsOneWidget);
    expect(find.text('拖拽选择截图区域 · Esc 取消'), findsOneWidget);

    await tester.dragFrom(const Offset(120, 120), const Offset(260, 180));
    await tester.pump();
    final doneButton = tester.widget<FilledButton>(
      find.byKey(const Key('screenshot-done')),
    );
    expect(doneButton.onPressed, isNotNull);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(handle.result, isNull);
    expect(find.byType(ScreenshotOverlay), findsNothing);
  });

  testWidgets('全屏选择后完成返回 done(bytes)', (tester) async {
    final png = await _png(tester, 800, 600);
    final handle = await _openOverlay(tester, png);

    await tester.tap(find.byKey(const Key('screenshot-select-all')));
    await tester.pump();
    expect(
      tester.widget<FilledButton>(find.byKey(const Key('screenshot-done'))).onPressed,
      isNotNull,
    );
    await tester.tap(find.byKey(const Key('screenshot-done')));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();

    expect(find.byType(ScreenshotOverlay), findsNothing);
    expect(handle.result, isNotNull);
    expect(handle.result!.retake, isFalse);
    expect(handle.result!.bytes, isNotNull);
    expect(handle.result!.bytes, isNotEmpty);
  });

  testWidgets('重截返回 retake 结果；次数用尽隐藏按钮', (tester) async {
    final png = await _png(tester, 800, 600);
    final handle = await _openOverlay(tester, png);

    await tester.tap(find.byKey(const Key('screenshot-retake')));
    await tester.pumpAndSettle();
    expect(handle.result, isNotNull);
    expect(handle.result!.retake, isTrue);
    expect(handle.result!.bytes, isNull);

    final second = await _openOverlay(tester, png, allowRetake: false);
    expect(find.byKey(const Key('screenshot-retake')), findsNothing);
    expect(find.byKey(const Key('screenshot-cancel')), findsOneWidget);
    await tester.tap(find.byKey(const Key('screenshot-cancel')));
    await tester.pumpAndSettle();
    expect(second.result, isNull);
  });

  testWidgets('截图宽高比与视口不符时禁用完成并提示', (tester) async {
    final png = await _png(tester, 200, 200); // 1:1 vs 800×600 视口
    final handle = await _openOverlay(tester, png);

    expect(find.text('截图尺寸与窗口不匹配，请重截'), findsOneWidget);
    await tester.tap(find.byKey(const Key('screenshot-select-all')));
    await tester.pump();
    final done = tester.widget<FilledButton>(find.byKey(const Key('screenshot-done')));
    expect(done.onPressed, isNull);
    await tester.tap(find.byKey(const Key('screenshot-cancel')));
    await tester.pumpAndSettle();
    expect(handle.result, isNull);
  });

  testWidgets('Esc 取消截图覆盖层，不上传', (tester) async {
    final png = await _png(tester, 800, 600);
    final handle = await _openOverlay(tester, png);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(handle.result, isNull);
    expect(find.byType(ScreenshotOverlay), findsNothing);
  });

  testWidgets('360×420 紧凑覆盖层按钮不溢出、可取消', (tester) async {
    tester.view.physicalSize = const Size(360, 420);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final png = await _png(tester, 360, 420);
    final handle = await _openOverlay(tester, png);

    expect(tester.takeException(), isNull);
    for (final key in const [
      'screenshot-cancel',
      'screenshot-select-all',
      'screenshot-retake',
      'screenshot-done',
    ]) {
      expect(find.byKey(Key(key)), findsOneWidget);
    }
    await tester.tap(find.byKey(const Key('screenshot-cancel')));
    await tester.pumpAndSettle();
    expect(handle.result, isNull);
  });
}
