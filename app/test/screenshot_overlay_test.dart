import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loop/screens/screenshot_overlay.dart';

Uint8List _png() => base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAEklEQVR4nGN0Kf/PwMDAxAAGABQnAb5Vz6Z2AAAAAElFTkSuQmCC',
    );

void main() {
  testWidgets('截图选框可以拖拽选择并取消', (tester) async {
    final png = _png();
    Uint8List? result;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () async {
                result = await Navigator.of(context).push<Uint8List>(
                  PageRouteBuilder(
                    transitionDuration: Duration.zero,
                    pageBuilder: (_, _, _) => ScreenshotOverlay(imageBytes: png),
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
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    });
    await tester.pump();

    expect(find.byType(ScreenshotOverlay), findsOneWidget);
    expect(find.text('拖拽选择截图区域 · Esc 取消'), findsOneWidget);

    await tester.dragFrom(const Offset(120, 120), const Offset(260, 180));
    await tester.pump();
    final doneButton = tester.widget<FilledButton>(find.widgetWithText(FilledButton, '完成'));
    expect(doneButton.onPressed, isNotNull);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(result, isNull);
    expect(find.byType(ScreenshotOverlay), findsNothing);
  });
}
