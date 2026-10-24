import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loop/theme.dart';
import 'package:loop/widgets/minimal_bar.dart';

class _Harness {
  final controller = TextEditingController();
  final focus = FocusNode();
  int sends = 0;
  int stops = 0;
  int screenshots = 0;
  int blockedScreenshots = 0;
  int backs = 0;
  int expands = 0;
  int drags = 0;

  void dispose() {
    controller.dispose();
    focus.dispose();
  }
}

Future<_Harness> _pumpBar(
  WidgetTester tester, {
  Size size = const Size(360, 52),
  bool sending = false,
  bool busy = false,
  bool screenshotEnabled = true,
  int attachmentCount = 0,
  String? firstImageUrl,
  String initialText = '',
}) async {
  final harness = _Harness();
  harness.controller.text = initialText;
  await tester.pumpWidget(MaterialApp(
    theme: loopTheme(LoopPalette.light),
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: size.width,
          height: size.height,
          child: MinimalBar(
            controller: harness.controller,
            focusNode: harness.focus,
            sending: sending,
            busy: busy,
            screenshotEnabled: screenshotEnabled,
            attachmentCount: attachmentCount,
            firstImageUrl: firstImageUrl,
            onSend: () => harness.sends++,
            onStop: () => harness.stops++,
            onScreenshot: () => harness.screenshots++,
            onBlockedScreenshot: () => harness.blockedScreenshots++,
            onBack: () => harness.backs++,
            onExpand: () => harness.expands++,
            onDragStart: () => harness.drags++,
          ),
        ),
      ),
    ),
  ));
  await tester.pump();
  addTearDown(harness.dispose);
  return harness;
}

void main() {
  testWidgets('W-MIN-01 三要素齐全：输入/截图/返回，无标题栏/侧栏/消息区', (tester) async {
    final h = await _pumpBar(tester);

    expect(find.byKey(const Key('minimal-bar')), findsOneWidget);
    expect(find.byKey(const Key('minimal-drag-handle')), findsOneWidget);
    expect(find.byKey(const Key('minimal-input')), findsOneWidget);
    expect(find.byKey(const Key('minimal-send-stop')), findsOneWidget);
    expect(find.byKey(const Key('minimal-screenshot')), findsOneWidget);
    expect(find.byKey(const Key('minimal-back')), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);

    // 不存在第四个业务按钮/文字标识。
    expect(find.text('回路'), findsNothing);
    expect(find.text('浮窗'), findsNothing);
    expect(find.byTooltip('置顶窗口'), findsNothing);
    expect(find.byTooltip('关闭'), findsNothing);

    // 无留白：组件撑满 52 高，内容垂直居中。
    final rect = tester.getRect(find.byKey(const Key('minimal-bar')));
    expect(rect.width, 360);
    expect(rect.height, 52);
    expect(tester.takeException(), isNull);
    expect(h.sends, 0);
  });

  testWidgets('W-MIN-02 Enter 发送、Shift+Enter 无操作、粘贴换行归一为空格', (tester) async {
    final h = await _pumpBar(tester);
    await tester.enterText(find.byKey(const Key('minimal-input')), ' 第一行\n第二行 ');
    await tester.pump();
    // Flutter 的单行 TextField 会在 formatter 之前移除换行；极简条保证粘贴后
    // 仍是单行、不增高（README/规格 §3.8），换行不会变成多行输入。
    expect(h.controller.text.contains('\n'), isFalse);
    expect(h.controller.text.contains('\r'), isFalse);
    expect(tester.getSize(find.byKey(const Key('minimal-bar'))).height, 52);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(h.sends, 1);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(h.sends, 1, reason: 'Shift+Enter 在极简条中无操作');
    expect(h.controller.text.contains('\n'), isFalse);
  });

  testWidgets('W-MIN-03 发送/停止按钮互斥，流式时显示 2px 进度条', (tester) async {
    final h = await _pumpBar(tester, sending: true);
    expect(find.byKey(const Key('minimal-streaming-indicator')), findsOneWidget);
    expect(find.byTooltip('停止'), findsOneWidget);
    expect(find.byTooltip('发送'), findsNothing);

    await tester.tap(find.byKey(const Key('minimal-send-stop')));
    await tester.pump();
    expect(h.stops, 1);
    expect(h.sends, 0);

    final idle = await _pumpBar(tester);
    await tester.tap(find.byKey(const Key('minimal-send-stop')));
    await tester.pump();
    expect(idle.sends, 1);
    expect(find.byKey(const Key('minimal-streaming-indicator')), findsNothing);
  });

  testWidgets('W-MIN-04 上传/截图进行中：发送禁用，截图提示且不发起', (tester) async {
    final h = await _pumpBar(tester, busy: true, screenshotEnabled: false);
    await tester.tap(find.byKey(const Key('minimal-send-stop')));
    await tester.pump();
    expect(h.sends, 0, reason: '上传/截图期间发送应暂时禁用');

    await tester.tap(find.byKey(const Key('minimal-screenshot')));
    await tester.pump();
    expect(h.screenshots, 0);
    expect(h.blockedScreenshots, 1);
  });

  testWidgets('W-MIN-05 截图/返回回调；附件 badge 显示 ×N', (tester) async {
    final h = await _pumpBar(tester, attachmentCount: 2);
    expect(find.byKey(const Key('minimal-attachment-badge')), findsOneWidget);
    expect(find.text('×2'), findsOneWidget);

    await tester.tap(find.byKey(const Key('minimal-screenshot')));
    await tester.pump();
    expect(h.screenshots, 1);
    expect(h.blockedScreenshots, 0);

    await tester.tap(find.byKey(const Key('minimal-back')));
    await tester.pump();
    expect(h.backs, 1);
  });

  testWidgets('W-MIN-06 拖动区：拖动开始回调、双击退出到展开浮窗', (tester) async {
    final h = await _pumpBar(tester);
    final handle = find.byKey(const Key('minimal-drag-handle'));

    await tester.drag(handle, const Offset(30, 0));
    await tester.pump();
    expect(h.drags, greaterThanOrEqualTo(1));

    await tester.tap(handle);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tap(handle);
    await tester.pumpAndSettle();
    expect(h.expands, 1);
  });

  testWidgets('W-MIN-07 360 窄条 + 150% DPI + 超长文本：无溢出、窗口不增高', (tester) async {
    tester.view.devicePixelRatio = 1.5;
    tester.view.physicalSize = const Size(540, 78);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final h = await _pumpBar(tester, initialText: '很长的中文问题' * 40);
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.byKey(const Key('minimal-bar'))).height, 52);
    expect(find.byKey(const Key('minimal-input')), findsOneWidget);
    expect(h.sends, 0);
  });

  testWidgets('W-MIN-08 无附件时不渲染 badge；单图 URL 渲染 20px 缩略图', (tester) async {
    await _pumpBar(tester);
    expect(find.byKey(const Key('minimal-attachment-badge')), findsNothing);

    await _pumpBar(
      tester,
      attachmentCount: 1,
      firstImageUrl: 'http://127.0.0.1:1/api/uploads/1',
    );
    expect(find.byKey(const Key('minimal-attachment-badge')), findsOneWidget);
    expect(find.text('×1'), findsOneWidget);
  });
}
