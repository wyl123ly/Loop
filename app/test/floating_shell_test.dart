import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loop/desktop/floating_signals.dart';
import 'package:loop/desktop/hotkeys.dart';
import 'package:loop/desktop/hotkeys_types.dart';
import 'package:loop/main.dart';
import 'package:loop/screens/chat_screen.dart';
import 'package:loop/state.dart';
import 'package:loop/theme.dart';
import 'package:loop/widgets/floating_bar.dart';
import 'package:loop/widgets/sidebar.dart';
import 'package:loop/widgets/title_bar.dart';

import 'support/fake_floating_host.dart';
import 'support/fake_loop_api.dart';
import 'support/fake_screenshot_service.dart';

/// Shell 使用 `screensOverride` 隔离其余页面（它们依赖全局 AppState/真实后端），
/// 但对话页仍是真实的 [ChatScreen]，以验证切换形态时 State 不重建。
Future<(FakeLoopApi, AppState, FakeFloatingHost, FakeScreenshotService, GlobalKey<ChatScreenState>)>
    _pumpShell(
  WidgetTester tester, {
  Size size = const Size(900, 600),
  FakeFloatingHost? host,
  List<Widget>? screensOverride,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final api = FakeLoopApi();
  final state = fakeAppState(api);
  final fakeHost = host ?? FakeFloatingHost();
  final screenshots = FakeScreenshotService(
    bytes: await makeTestPng(tester, size.width.round(), size.height.round()),
  );
  final chatKey = GlobalKey<ChatScreenState>();
  // Widget 测试里原生热键通道不存在；显式给一个“已注册”状态，验证 tooltip 文案
  // （完整注册状态由 t2 的 hotkey_status_test 覆盖）。
  HotkeyService.instance.status.value = HotkeyStatus.bothRegistered;
  addTearDown(() => HotkeyService.instance.status.value = HotkeyStatus.unsupported);
  final screens = screensOverride ??
      <Widget>[
        ChatScreen(
          key: chatKey,
          active: true,
          state: state,
          screenshots: screenshots,
        ),
        const Placeholder(key: Key('page-1')),
        const Placeholder(key: Key('page-2')),
        const Placeholder(key: Key('page-3')),
        const Placeholder(key: Key('page-4')),
        const Placeholder(key: Key('page-5')),
      ];
  await tester.pumpWidget(MaterialApp(
    theme: loopTheme(LoopPalette.light),
    home: Shell(
      state: state,
      modeHost: fakeHost,
      screensOverride: screens,
      screenshots: screenshots,
    ),
  ));
  await tester.pumpAndSettle();
  return (api, state, fakeHost, screenshots, chatKey);
}

void main() {
  tearDown(() {
    screenshotRequestSignal.value = null;
    captureInProgress.value = false;
  });

  testWidgets('W-SHELL-01 点击浮窗按钮进入浮窗：bar 出现、无侧栏/标题栏', (tester) async {
    final (api, state, host, _, _) = await _pumpShell(tester);
    expect(find.byType(TitleBar), findsOneWidget);
    expect(find.byType(Sidebar), findsOneWidget);
    expect(find.byKey(const Key('window-floating-toggle')), findsOneWidget);
    expect(find.byTooltip('浮窗答疑 (Alt+Q)'), findsOneWidget);

    await tester.tap(find.byKey(const Key('window-floating-toggle')));
    await tester.pumpAndSettle();

    expect(host.enterCalls, 1);
    expect(host.isFloating, isTrue);
    expect(find.byType(FloatingBar), findsOneWidget);
    expect(find.byType(TitleBar), findsNothing);
    expect(find.byType(Sidebar), findsNothing);
    expect(find.byKey(const Key('chat-input')), findsOneWidget);
    expect(find.byKey(const Key('chat-composer')), findsOneWidget);
    expect(api.chatCalls, 0);
    expect(state.conversations, isEmpty);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('W-SHELL-02 浮窗返回恢复主窗口与原页签', (tester) async {
    final pages = <Widget>[
      const Placeholder(key: Key('page-0')),
      const Placeholder(key: Key('page-1')),
      const Placeholder(key: Key('page-2')),
      const Placeholder(key: Key('page-3')),
      const Placeholder(key: Key('page-4')),
      const Placeholder(key: Key('page-5')),
    ];
    final (_, _, host, _, _) = await _pumpShell(tester, screensOverride: pages);
    expect(find.byKey(const Key('page-0')), findsOneWidget);

    // 切到“笔记”（index 2）；900 宽下侧栏自动紧凑，用 tooltip 定位。
    await tester.tap(find.byTooltip('笔记'));
    await tester.pumpAndSettle();
    final indexed = tester.widget<IndexedStack>(find.byType(IndexedStack));
    expect(indexed.index, 2);

    await tester.tap(find.byKey(const Key('window-floating-toggle')));
    await tester.pumpAndSettle();
    expect(host.isFloating, isTrue);
    expect(tester.widget<IndexedStack>(find.byType(IndexedStack)).index, 0);

    await tester.tap(find.byKey(const Key('floating-back')));
    await tester.pumpAndSettle();
    expect(host.isFloating, isFalse);
    expect(find.byType(Sidebar), findsOneWidget);
    expect(tester.widget<IndexedStack>(find.byType(IndexedStack)).index, 2);
    expect(find.byKey(const Key('page-2')), findsOneWidget);
  });

  testWidgets('W-SHELL-03/04 切换保活：State identical 且始终只有一个 ChatScreen', (tester) async {
    final (_, _, _, _, chatKey) = await _pumpShell(tester);
    final before = chatKey.currentState!;
    expect(find.byType(ChatScreen), findsOneWidget);

    await tester.tap(find.byKey(const Key('window-floating-toggle')));
    await tester.pumpAndSettle();
    final during = tester.state<ChatScreenState>(find.byType(ChatScreen));
    expect(identical(before, during), isTrue);
    expect(identical(chatKey.currentState, before), isTrue);
    expect(find.byType(ChatScreen), findsOneWidget);

    await tester.tap(find.byKey(const Key('floating-back')));
    await tester.pumpAndSettle();
    final after = tester.state<ChatScreenState>(find.byType(ChatScreen));
    expect(identical(before, after), isTrue);
    expect(find.byType(ChatScreen), findsOneWidget);
  });

  testWidgets('W-SHELL-05 host 进入失败：保持 normal 并提示一次', (tester) async {
    final host = FakeFloatingHost()..enterShouldFail = true;
    await _pumpShell(tester, host: host);

    await tester.tap(find.byKey(const Key('window-floating-toggle')));
    await tester.pumpAndSettle();

    expect(host.isFloating, isFalse);
    expect(find.byType(FloatingBar), findsNothing);
    expect(find.byType(Sidebar), findsOneWidget);
    expect(find.text('切到浮窗失败，已恢复窗口'), findsOneWidget);
    // 下一次切换仍可成功（不粘死）。
    host.enterShouldFail = false;
    await tester.tap(find.byKey(const Key('window-floating-toggle')));
    await tester.pumpAndSettle();
    expect(host.isFloating, isTrue);
  });

  testWidgets('W-UI-11 连续切换 10 次无异常、无重复 ChatScreen', (tester) async {
    final (_, _, host, _, _) = await _pumpShell(tester);
    final chat = tester.state<ChatScreenState>(find.byType(ChatScreen));

    for (var i = 0; i < 10; i++) {
      await host.toggleFloating();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(ChatScreen), findsOneWidget);
      expect(identical(chat, tester.state<ChatScreenState>(find.byType(ChatScreen))), isTrue);
    }
    expect(host.isFloating, isFalse);
    expect(host.enterCalls, 5);
    expect(host.exitCalls, 5);
  });

  testWidgets('W-FOCUS-02 每次用户切换只聚焦一次，截图覆盖期间禁止切换', (tester) async {
    final (_, _, host, _, _) = await _pumpShell(tester);

    await tester.tap(find.byKey(const Key('window-floating-toggle')));
    await tester.pumpAndSettle();
    expect(host.focusCount, 1);

    await tester.tap(find.byKey(const Key('floating-back')));
    await tester.pumpAndSettle();
    expect(host.focusCount, 2);

    host.captureInProgress = true;
    await tester.pump();
    expect(host.isFloating, isFalse);
    await tester.tap(find.byKey(const Key('window-floating-toggle')));
    await tester.pumpAndSettle();
    expect(host.isFloating, isFalse, reason: '截图覆盖期间必须忽略切换');
    expect(host.focusCount, 2);
  });

  testWidgets('W-UI-07 900×600 主窗口布局保持（标题栏/侧栏/IndexedStack）', (tester) async {
    final (_, _, host, _, _) = await _pumpShell(tester);
    expect(host.isFloating, isFalse);
    expect(find.byType(TitleBar), findsOneWidget);
    expect(find.byType(Sidebar), findsOneWidget);
    expect(find.byType(FloatingBar), findsNothing);
    expect(find.byType(IndexedStack), findsOneWidget);
    expect(find.byTooltip('浮窗答疑 (Alt+Q)'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
