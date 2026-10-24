import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loop/theme.dart';
import 'package:loop/widgets/floating_bar.dart';
import 'package:loop/widgets/floating_qa_scaffold.dart';
import 'package:loop/widgets/image_preview.dart';
import 'package:loop/widgets/markdown_text.dart';

import 'support/fake_floating_host.dart';

Widget _bar(
  FakeFloatingHost host, {
  bool compact = false,
  String title = '特征值是什么',
  List<bool>? requests,
  VoidCallback? onClose,
  VoidCallback? onDragStart,
}) {
  return MaterialApp(
    theme: loopTheme(LoopPalette.light),
    home: Scaffold(
      body: SizedBox(
        width: compact ? 360 : 460,
        child: FloatingBar(
          host: host,
          title: title,
          compact: compact,
          onDragStart: onDragStart ?? () {},
          onClose: onClose ?? () {},
          onScreenshot: (hideLoop) => requests?.add(hideLoop),
        ),
      ),
    ),
  );
}

Future<FakeFloatingHost> _floatingHost() async {
  final host = FakeFloatingHost();
  await host.enterFloating();
  return host;
}

void main() {
  testWidgets('W-UI-01 460×600 拖动栏元素/key/tooltip 齐全', (tester) async {
    tester.view.physicalSize = const Size(460, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final host = await _floatingHost();
    await tester.pumpWidget(_bar(host));
    await tester.pump();

    expect(find.byKey(const Key('floating-bar')), findsOneWidget);
    expect(find.byKey(const Key('floating-drag-area')), findsOneWidget);
    expect(find.byKey(const Key('floating-screenshot')), findsOneWidget);
    expect(find.byKey(const Key('floating-pin')), findsOneWidget);
    expect(find.byKey(const Key('floating-back')), findsOneWidget);
    expect(find.byKey(const Key('floating-close')), findsOneWidget);
    expect(find.text('回路'), findsOneWidget);
    expect(find.text('浮窗'), findsOneWidget);
    expect(find.text('特征值是什么'), findsOneWidget);
    expect(find.byTooltip('返回主窗口 (Alt+Q)'), findsOneWidget);
    expect(find.byTooltip('取消置顶'), findsOneWidget);
    expect(
      find.byTooltip('截图（Alt+A）· 默认隐藏 Loop 后截图；右键可切换直接截图'),
      findsOneWidget,
    );
    expect(tester.getSize(find.byKey(const Key('floating-bar'))).height, 44);
    for (final key in const ['floating-screenshot', 'floating-pin', 'floating-back', 'floating-close']) {
      final size = tester.getSize(find.byKey(Key(key)));
      expect(size.width, greaterThanOrEqualTo(32));
      expect(size.height, greaterThanOrEqualTo(32));
    }
  });

  testWidgets('W-UI-02 360×420 紧凑：隐藏标题与浮窗标签、按钮可见、无溢出', (tester) async {
    tester.view.physicalSize = const Size(360, 420);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final host = await _floatingHost();
    await tester.pumpWidget(_bar(host, compact: true));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('特征值是什么'), findsNothing);
    expect(find.text('浮窗'), findsNothing);
    expect(find.text('回路'), findsOneWidget);
    expect(tester.getSize(find.byKey(const Key('floating-bar'))).height, 40);
    for (final key in const ['floating-screenshot', 'floating-pin', 'floating-back', 'floating-close']) {
      expect(find.byKey(Key(key)), findsOneWidget);
      expect(tester.getSize(find.byKey(Key(key))).width, greaterThanOrEqualTo(30));
    }
  });

  testWidgets('W-UI-03 置顶调用 setPinned，返回调用 exitFloating', (tester) async {
    final host = await _floatingHost();
    await tester.pumpWidget(_bar(host));
    await tester.pump();

    await tester.tap(find.byKey(const Key('floating-pin')));
    await tester.pump();
    expect(host.pinCalls, 1);
    expect(host.pinned, isFalse);
    expect(find.byTooltip('置顶窗口'), findsOneWidget);

    await tester.tap(find.byKey(const Key('floating-pin')));
    await tester.pump();
    expect(host.pinned, isTrue);

    await tester.tap(find.byKey(const Key('floating-back')));
    await tester.pump();
    await tester.pump();
    expect(host.exitCalls, 1);
    expect(host.isFloating, isFalse);
  });

  testWidgets('W-UI-04 截图主点击 hideLoop=true；右键菜单“直接截图”=false', (tester) async {
    final host = await _floatingHost();
    final requests = <bool>[];
    await tester.pumpWidget(_bar(host, requests: requests));
    await tester.pump();

    await tester.tap(find.byKey(const Key('floating-screenshot')));
    await tester.pump();
    expect(requests, [true]);

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('floating-screenshot'))),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.text('直接截图'), findsOneWidget);
    await tester.tap(find.text('直接截图'));
    await tester.pumpAndSettle();
    expect(requests, [true, false]);
  });

  testWidgets('W-UI-05 拖动区 pan 触发拖动，双击不最大化', (tester) async {
    final host = await _floatingHost();
    var dragStarts = 0;
    await tester.pumpWidget(_bar(host, onDragStart: () => dragStarts++));
    await tester.pump();

    await tester.drag(find.byKey(const Key('floating-drag-area')), const Offset(24, 30));
    await tester.pumpAndSettle();
    expect(dragStarts, greaterThanOrEqualTo(1));

    final before = dragStarts;
    await tester.tap(find.byKey(const Key('floating-drag-area')));
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tap(find.byKey(const Key('floating-drag-area')));
    await tester.pumpAndSettle();
    expect(dragStarts, greaterThanOrEqualTo(before));
    expect(host.toggleCalls, 0);
    expect(host.isFloating, isTrue);
  });

  testWidgets('W-UI-12 关闭按钮调用注入的 onClose', (tester) async {
    final host = await _floatingHost();
    var closed = 0;
    await tester.pumpWidget(_bar(host, onClose: () => closed++));
    await tester.pump();
    await tester.tap(find.byKey(const Key('floating-close')));
    await tester.pump();
    expect(closed, 1);
  });

  testWidgets('W-UI-06 亮/暗主题下拖动栏可读', (tester) async {
    final host = await _floatingHost();
    await tester.pumpWidget(_bar(host));
    await tester.pump();
    expect(tester.widget<Text>(find.text('回路')).style?.color, LoopPalette.light.ink);

    LoopTheme.palette = LoopPalette.dark;
    addTearDown(() => LoopTheme.palette = LoopPalette.light);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(MaterialApp(
      theme: loopTheme(LoopPalette.dark),
      home: Scaffold(
        body: SizedBox(
          width: 460,
          child: FloatingBar(
            host: host,
            title: '暗色会话',
            onDragStart: () {},
            onClose: () {},
            onScreenshot: (_) {},
          ),
        ),
      ),
    ));
    await tester.pump();
    expect(tester.widget<Text>(find.text('回路')).style?.color, LoopPalette.dark.ink);
    expect(tester.takeException(), isNull);
  });

  testWidgets('W-UI-02b FloatingQaScaffold 浮窗圆角 16、普通 18', (tester) async {    final host = await _floatingHost();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: FloatingQaScaffold(
          floating: false,
          chrome: const SizedBox(height: 44),
          sidebar: const SizedBox(width: 76),
          content: const SizedBox.expand(),
        ),
      ),
    ));
    var container = tester.widget<Container>(find.byKey(const Key('floating-qa-scaffold')));
    var decoration = container.decoration! as BoxDecoration;
    expect(decoration.borderRadius, BorderRadius.circular(FloatingQaScaffold.normalRadius));

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: FloatingQaScaffold(
          floating: true,
          chrome: SizedBox(height: 44, child: FloatingBar(
            host: host,
            title: 't',
            onDragStart: () {},
            onClose: () {},
            onScreenshot: (_) {},
          )),
          sidebar: const SizedBox.shrink(),
          content: const SizedBox.expand(),
        ),
      ),
    ));
    container = tester.widget<Container>(find.byKey(const Key('floating-qa-scaffold')));
    decoration = container.decoration! as BoxDecoration;
    expect(decoration.borderRadius, BorderRadius.circular(FloatingQaScaffold.floatingRadius));
  });

  testWidgets('W-UI-09 360 宽 Markdown：宽表格/块公式横向滚动、无溢出', (tester) async {
    tester.view.physicalSize = const Size(360, 420);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const markdown = '''
| 列一 | 列二 | 列三 | 列四 |
| --- | --- | --- | --- |
| 一段很长的中文内容用于撑宽表格 | 值二 | 值三 | 值四 |

\$\$
\\int_{0}^{\\infty} e^{-x^2} dx = \\frac{\\sqrt{\\pi}}{2} + \\sum_{k=1}^{n} \\frac{1}{k^2} + \\frac{a}{b}
\$\$

```
for (var i = 0; i < 10; i++) { print('一段很长很长的代码行，用来测试横向滚动'); }
```
''';
    await tester.pumpWidget(MaterialApp(
      theme: loopTheme(LoopPalette.light),
      home: const Scaffold(
        body: SingleChildScrollView(
          child: SizedBox(
            width: 324,
            child: MarkdownText(markdown),
          ),
        ),
      ),
    ));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.byType(Table), findsOneWidget);
    // 表格/公式/代码块都带横向滚动容器。
    expect(find.byType(SingleChildScrollView), findsWidgets);
    final horizontal = tester
        .widgetList<SingleChildScrollView>(find.byType(SingleChildScrollView))
        .where((widget) => widget.scrollDirection == Axis.horizontal)
        .length;
    expect(horizontal, greaterThanOrEqualTo(3));
  });

  testWidgets('W-UI-10 360×420 图片预览尺寸受限、可关闭、无溢出', (tester) async {
    tester.view.physicalSize = const Size(360, 420);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(MaterialApp(
      theme: loopTheme(LoopPalette.light),
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () => ImagePreview.show(
                context,
                'http://127.0.0.1:1/api/uploads/1',
                title: '截图-1.png',
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump();

    final size = tester.getSize(find.byKey(const Key('image-preview-box')));
    expect(size.width, lessThanOrEqualTo(336));
    expect(size.height, lessThanOrEqualTo(396));
    expect(size.width, greaterThan(240));
    expect(tester.takeException(), isNull);

    await tester.tap(find.descendant(
      of: find.byType(ImagePreview),
      matching: find.byTooltip('关闭'),
    ));
    await tester.pumpAndSettle();
    expect(find.byType(ImagePreview), findsNothing);
  });
}
