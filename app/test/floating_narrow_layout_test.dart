import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loop/api.dart';
import 'package:loop/main.dart';
import 'package:loop/models.dart';
import 'package:loop/screens/agent_screen.dart';
import 'package:loop/screens/chat_screen.dart';
import 'package:loop/screens/materials_screen.dart';
import 'package:loop/screens/notes_screen.dart';
import 'package:loop/screens/settings_screen.dart';
import 'package:loop/screens/today_screen.dart';
import 'package:loop/state.dart';
import 'package:loop/theme.dart';

import 'support/fake_floating_host.dart';
import 'support/fake_loop_api.dart';
import 'support/fake_screenshot_service.dart';

/// 真实页面用到的全局 AppState：填入一份已加载的设置，让 Settings 页渲染
/// 真实内容（360 宽下历史上会 overflow 12px+），而不是“未加载”的空壳。
SettingsData _loadedSettings() => SettingsData(
      apiKeyMasked: 'sk-****-1234',
      hasKey: true,
      baseUrl: 'https://api.deepseek.com',
      model: 'deepseek-flash',
      reasonModel: 'deepseek-v4-pro',
      theme: 'system',
      autoCheckUpdates: true,
      sidebarCollapsed: false,
      streamOutput: true,
    );

/// t5 T5-04/T5-05 回归：不使用 `screensOverride` 占位，挂载真实六页。
class _RealShellHarness {
  late FakeLoopApi api;
  late AppState state;
  late FakeFloatingHost host;
  late FakeScreenshotService screenshots;
}

Future<_RealShellHarness> _pumpRealShell(
  WidgetTester tester, {
  required Size size,
  required bool floating,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final harness = _RealShellHarness();
  harness.api = FakeLoopApi();
  harness.state = fakeAppState(harness.api);
  harness.host = FakeFloatingHost();
  if (floating) await harness.host.enterFloating();
  harness.screenshots = FakeScreenshotService(
    bytes: await makeTestPng(tester, size.width.round(), size.height.round()),
  );
  await tester.pumpWidget(MaterialApp(
    theme: loopTheme(LoopPalette.light),
    home: Shell(
      state: harness.state,
      modeHost: harness.host,
      screenshots: harness.screenshots,
    ),
  ));
  await tester.pumpAndSettle();
  return harness;
}

/// 取走当前已记录的所有 framework 异常（可见页的 RenderFlex/ListTile 等错误）。
List<Object> _takeExceptions(WidgetTester tester) {
  final errors = <Object>[];
  while (true) {
    final error = tester.takeException();
    if (error == null) break;
    errors.add(error);
  }
  return errors;
}

/// RenderFlex 的 overflow 错误只在 paint 阶段上报，而 IndexedStack 不绘制隐藏页；
/// 隐藏页的 overflow 需要通过扫描渲染树的 OVERFLOWING 标记发现（与 t4/t5 真实
/// 进程 RenderFlex 扫描方式一致）。返回每个溢出 RenderFlex 的摘要。
List<String> _overflowMarkers(WidgetTester tester) {
  final markers = <String>[];
  for (final flex in tester.allRenderObjects.whereType<RenderFlex>()) {
    final description = flex.toString();
    if (description.contains('OVERFLOWING')) {
      markers.add(description.split('\n').first);
    }
  }
  return markers;
}

void _expectNoOverflow(WidgetTester tester, String stage) {
  final errors = _takeExceptions(tester);
  final markers = _overflowMarkers(tester);
  expect(errors, isEmpty, reason: '$stage 出现布局异常：\n${errors.join('\n---\n')}');
  expect(markers, isEmpty,
      reason: '$stage 渲染树存在 RenderFlex overflow：\n${markers.join('\n')}');
}

Future<void> _finish(WidgetTester tester, FakeLoopApi api) async {
  if (!api.events.isClosed) await api.events.close();
  await tester.pump();
  await _flushSnack(tester);
}

/// 真实页面在无后端时会走错误分支并可能弹一次 snackbar；推进时间避免残留计时器。
Future<void> _flushSnack(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 4));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    appState.settings = _loadedSettings();
  });

  tearDown(() {
    appState.settings = null;
  });

  testWidgets('T5-04 360×420 浮窗真实六页：隐藏页不产生 overflow 且仍常驻', (tester) async {
    final h = await _pumpRealShell(tester, size: const Size(360, 420), floating: true);
    _expectNoOverflow(tester, '360×420 浮窗首次布局');

    // 真实六页全部挂载（其余页“常驻但不接收事件”，规格 §5.2）。
    // IndexedStack 会跳过隐藏页的 onstage 遍历，因此这里显式 skipOffstage: false。
    expect(find.byType(ChatScreen), findsOneWidget);
    for (final finder in <Finder>[
      find.byType(TodayScreen, skipOffstage: false),
      find.byType(NotesScreen, skipOffstage: false),
      find.byType(MaterialsScreen, skipOffstage: false),
      find.byType(AgentScreen, skipOffstage: false),
      find.byType(SettingsScreen, skipOffstage: false),
    ]) {
      expect(finder, findsOneWidget);
      final pageSize = tester.getSize(finder);
      expect(pageSize, const Size(900, 600), reason: '隐藏页应在桌面最小尺寸下布局');
    }
    // 可见对话页接近 360 宽（窗口 1px 边框各占 1px）。
    expect(tester.getSize(find.byType(ChatScreen)).width, closeTo(358, 2));

    // 输入/滚动可用（先清掉真实页面在无后端时弹出的 snackbar，避免遮住输入区）。
    await _flushSnack(tester);
    await tester.enterText(find.byKey(const Key('chat-input')), '窄窗真实页测试');
    await tester.pump();
    await tester.tap(find.byKey(const Key('chat-send-stop')));
    await tester.pump();
    expect(h.api.chatCalls, 1);
    h.api.events.add(SseEvent('run', {'run_id': 1}));
    h.api.events.add(SseEvent('delta', {'text': '窄窗回答'}));
    await tester.pump();
    expect(find.text('窄窗回答'), findsOneWidget);
    expect(find.byKey(const Key('chat-message-list')), findsOneWidget);
    _expectNoOverflow(tester, '360×420 浮窗发送后');

    // 滚动可用：长回答后上滚、回到底部，隐藏页依然不 overflow。
    h.api.events.add(SseEvent('delta', {
      'text': List.generate(60, (index) => '第 $index 段：窄窗滚动内容，用来撑开消息区高度。').join('\n\n'),
    }));
    await tester.pump();
    final controller =
        tester.widget<ListView>(find.byKey(const Key('chat-message-list'))).controller!;
    controller.jumpTo(controller.position.maxScrollExtent);
    await tester.pump();
    await tester.drag(find.byKey(const Key('chat-message-list')), const Offset(0, 220));
    await tester.pump();
    expect(controller.offset, lessThan(controller.position.maxScrollExtent));
    expect(find.byKey(const Key('chat-scroll-bottom')), findsOneWidget);
    _expectNoOverflow(tester, '360×420 浮窗上滚后');
    await tester.tap(find.byKey(const Key('chat-scroll-bottom')));
    await tester.pump();
    expect(controller.offset, closeTo(controller.position.maxScrollExtent, 1));
    _expectNoOverflow(tester, '360×420 浮窗回到底部后');

    await _finish(tester, h.api);
    _expectNoOverflow(tester, '360×420 浮窗收尾');
  });

  testWidgets('T5-04 460×600 浮窗真实六页无 overflow、隐藏页 900×600', (tester) async {
    await _pumpRealShell(tester, size: const Size(460, 600), floating: true);
    _expectNoOverflow(tester, '460×600 浮窗');
    expect(
      tester.getSize(find.byType(SettingsScreen, skipOffstage: false)),
      const Size(900, 600),
    );
    expect(tester.getSize(find.byType(ChatScreen)).width, closeTo(458, 2));
    expect(find.byKey(const Key('chat-input')), findsOneWidget);
    await _flushSnack(tester);
  });

  testWidgets('T5-04 900×600 主窗口真实六页无 overflow、布局保持', (tester) async {
    await _pumpRealShell(tester, size: const Size(900, 600), floating: false);
    _expectNoOverflow(tester, '900×600 主窗口');
    expect(find.byType(ChatScreen), findsOneWidget);
    expect(find.byType(SettingsScreen, skipOffstage: false), findsOneWidget);
    expect(find.byKey(const Key('window-floating-toggle')), findsOneWidget);
    expect(find.byKey(const Key('chat-input')), findsOneWidget);
    // 主窗口下隐藏页按真实内容宽度布局（不是 900 强制盒）。
    final settingsWidth = tester
        .getSize(find.byType(SettingsScreen, skipOffstage: false))
        .width;
    expect(settingsWidth, lessThan(900));
    expect(settingsWidth, greaterThan(700));
    await _flushSnack(tester);
  });

  testWidgets('T5-05 normal→floating 过渡帧（含 150 宽）无页头/工具栏 overflow', (tester) async {
    final h = await _pumpRealShell(tester, size: const Size(900, 600), floating: false);
    _expectNoOverflow(tester, '900×600 初始');

    // 复现 t5：Windows 先把窗口缩到 460，mode 仍是 normal 的 1–2 帧；
    // 页头 Row 曾在 150 宽约束下 overflow 81px。
    for (final width in <double>[800, 700, 600, 500, 460, 300, 150]) {
      tester.view.physicalSize = Size(width, 600);
      await tester.pump();
      _expectNoOverflow(tester, 'normal 过渡帧 width=$width');
    }
    expect(find.byTooltip('问答模式'), findsOneWidget, reason: '过渡帧仍为 normal 页头');

    // mode 切换后继续缩到浮窗最小尺寸/异常小尺寸，均不得 overflow。
    await h.host.enterFloating();
    await tester.pump();
    _expectNoOverflow(tester, 'enterFloating 一帧');
    for (final size in <Size>[const Size(460, 600), const Size(360, 420), const Size(200, 150)]) {
      tester.view.physicalSize = size;
      await tester.pump();
      _expectNoOverflow(tester, 'floating 过渡帧 $size');
    }

    // 稳定 360×420 可输入。
    tester.view.physicalSize = const Size(360, 420);
    await tester.pump();
    expect(find.byKey(const Key('chat-input')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('chat-input')), '过渡后输入');
    await tester.pump();
    _expectNoOverflow(tester, '过渡后稳定 360×420');

    // 反向过渡：浮窗被拉大 → 恢复 normal（Windows 先放 bounds、后切 mode），
    // 以及 normal 大窗口（1440×900）帧均不得 overflow。
    for (final size in <Size>[const Size(700, 800), const Size(1440, 900)]) {
      tester.view.physicalSize = size;
      await tester.pump();
      _expectNoOverflow(tester, 'floating→normal 放大帧 $size');
    }
    await h.host.exitFloating();
    await tester.pump();
    _expectNoOverflow(tester, 'exitFloating 一帧');
    tester.view.physicalSize = const Size(1440, 900);
    await tester.pump();
    _expectNoOverflow(tester, 'normal 1440×900');
    expect(find.byKey(const Key('window-floating-toggle')), findsOneWidget);
    await _flushSnack(tester);
  });
}
