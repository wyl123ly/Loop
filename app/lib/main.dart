import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'backend/job_scheduler.dart';
import 'backend/start.dart';
import 'boot_prefs.dart';
import 'desktop/floating_signals.dart';
import 'desktop/hotkeys.dart';
import 'desktop/screenshot_service.dart';
import 'desktop/window_controls.dart';
import 'desktop/window_mode.dart';
import 'diagnostics/frame_log.dart';
import 'desktop/tray_export.dart';
import 'screens/agent_screen.dart';
import 'screens/chat_screen.dart';
import 'screens/materials_screen.dart';
import 'screens/notes_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/today_screen.dart';
import 'state.dart';
import 'theme.dart';
import 'ui_tab.dart';
import 'ui_theme.dart';
import 'update/update_ui.dart';
import 'widgets/floating_bar.dart';
import 'widgets/floating_qa_scaffold.dart';
import 'widgets/sidebar.dart';
import 'widgets/title_bar.dart';
import 'widgets/window_resize_handles.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  installFrameLogger();
  final bootTheme = loadBootTheme();
  final override = themeOverride();
  appState.themeMode = override ?? bootTheme;
  LoopTheme.palette = _paletteFor(override ?? bootTheme);
  await WindowController.instance.init();
  await initTray(
    onShow: () => WindowController.instance.show(),
    onQuit: () => WindowController.instance.quit(),
    onRunJobs: () => JobScheduler.runDueNow(),
    onTrayReady: () => WindowController.instance.enableTray(),
  );
  unawaited(startBackend());
  runApp(const LoopApp());
}

LoopPalette _paletteFor(ThemeMode mode) {
  final platform = WidgetsBinding.instance.platformDispatcher.platformBrightness;
  final dark = mode == ThemeMode.dark || (mode == ThemeMode.system && platform == Brightness.dark);
  return dark ? LoopPalette.dark : LoopPalette.light;
}

class LoopApp extends StatefulWidget {
  const LoopApp({super.key});

  @override
  State<LoopApp> createState() => _LoopAppState();
}

class _LoopAppState extends State<LoopApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    appState.bootstrap();
    unawaited(checkForUpdatesOnStartup());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangePlatformBrightness() {
    if (appState.themeMode == ThemeMode.system) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: appState,
      builder: (context, _) {
        LoopTheme.palette = _paletteFor(appState.themeMode);
        return MaterialApp(
          title: '回路 Loop',
          debugShowCheckedModeBanner: false,
          navigatorKey: rootNavigatorKey,
          theme: loopTheme(LoopPalette.light),
          darkTheme: loopTheme(LoopPalette.dark),
          themeMode: appState.themeMode,
          home: appState.ready
              ? (appState.bootstrapError != null
                  ? _BootError(message: appState.bootstrapError!)
                  : const Shell())
              : const _Splash(),
        );
      },
    );
  }
}

class _Splash extends StatelessWidget {
  const _Splash();

  @override
  Widget build(BuildContext context) {
    final p = pal;
    return Scaffold(
      backgroundColor: p.bgTop,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 30,
              height: 30,
              child: CircularProgressIndicator(strokeWidth: 2.4, color: p.accent),
            ),
            const SizedBox(height: 16),
            Text('正在唤醒回路…', style: TextStyle(color: p.muted, fontSize: 13)),
          ],
        ),
      ),
    );
  }
}

class _BootError extends StatelessWidget {
  const _BootError({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final p = pal;
    return Scaffold(
      backgroundColor: p.bgTop,
      body: Center(
        child: Container(
          width: 460,
          padding: const EdgeInsets.all(24),
          decoration: panelDecoration(),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('连不上本地后端',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: p.ink)),
              const SizedBox(height: 8),
              Text(message, style: TextStyle(color: p.muted, fontSize: 13)),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () {
                  appState.bootstrapError = null;
                  appState.bootstrap();
    unawaited(checkForUpdatesOnStartup());
                },
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

const _pageTitles = ['对话', '今日', '笔记', '资料', '代理', '设置'];

/// 主窗口壳：normal（标题栏 + 侧栏 + 六页）与 floating（拖动栏 + 仅对话）
/// 共用同一 widget 树与槽位，保证 ChatScreen 的 State / SSE 不因切换被重建。
///
/// 规格 §5.2：`FloatingQaScaffold(floating, chrome, sidebar, content)` 在两种
/// 形态下都是同一个类、同一层 `Column(chrome, Expanded(Row(sidebar, content)))`；
/// 浮窗只替换 chrome/sidebar 与 IndexedStack.index，`ChatScreen` 保持同一
/// 树位置 + 稳定 `GlobalKey`。
class Shell extends StatefulWidget {
  const Shell({
    super.key,
    this.state,
    this.modeHost,
    this.screensOverride,
    this.screenshots,
  });

  /// 可选注入，便于 widget 测试；生产环境使用全局 [appState]。
  final AppState? state;

  /// 浮窗形态宿主；生产为 [WindowController.instance.floating]。
  final FloatingModeHost? modeHost;

  /// 测试替身：整组页面（长度可小于 6，索引会被钳制）。
  final List<Widget>? screensOverride;

  /// 截图服务；为空时 ChatScreen 使用平台实现。
  final ScreenshotService? screenshots;

  @override
  State<Shell> createState() => _ShellState();
}

class _ResponsiveSidebar extends StatelessWidget {
  const _ResponsiveSidebar({required this.index, required this.onSelect});

  final int index;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final autoCompact = MediaQuery.sizeOf(context).width < 1080;
    final manualCollapsed = appState.settings?.sidebarCollapsed ?? false;
    return Sidebar(
      index: index,
      onSelect: onSelect,
      compact: autoCompact || manualCollapsed,
      canToggle: !autoCompact,
      onToggleCollapse: () => appState.setSidebarCollapsed(!manualCollapsed),
    );
  }
}

class _ShellState extends State<Shell> with WidgetsBindingObserver {
  int _index = _initialTab();

  /// 进入浮窗前所在页签，退出后恢复（规格 §5.2 / FR-6）。
  int _indexBeforeFloating = 0;
  bool _wasFloating = false;

  /// 稳定 key：形态切换时保住 ChatScreen 的 State（消息/附件/SSE）。
  final GlobalKey<ChatScreenState> _chatKey = GlobalKey<ChatScreenState>();
  final GlobalKey _contentKey = GlobalKey();

  late FloatingModeHost _host;

  String? _lastSnackMessage;
  DateTime? _lastSnackAt;

  AppState get _state => widget.state ?? appState;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _host = widget.modeHost ?? WindowController.instance.floating;
    _wasFloating = _host.isFloating;
    _indexBeforeFloating = _index;
    _host.addListener(_onHostChanged);
    _state.addListener(_onStateChanged);
    WindowController.instance.floatingError.addListener(_onFloatingError);
  }

  @override
  void didUpdateWidget(covariant Shell oldWidget) {
    super.didUpdateWidget(oldWidget);
    final previous = oldWidget.modeHost ?? WindowController.instance.floating;
    final next = widget.modeHost ?? WindowController.instance.floating;
    if (!identical(previous, next)) {
      previous.removeListener(_onHostChanged);
      _host = next;
      _wasFloating = next.isFloating;
      _indexBeforeFloating = _index;
      next.addListener(_onHostChanged);
    }
    final previousState = oldWidget.state ?? appState;
    if (!identical(previousState, _state)) {
      previousState.removeListener(_onStateChanged);
      _state.addListener(_onStateChanged);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _host.removeListener(_onHostChanged);
    _state.removeListener(_onStateChanged);
    WindowController.instance.floatingError.removeListener(_onFloatingError);
    super.dispose();
  }

  /// DPI/缩放变化：交给 WindowController 去抖钳制，不 focus、不改 mode（FR-4）。
  @override
  void didChangeMetrics() {
    if (WindowController.instance.ready) {
      WindowController.instance.onMetricsChanged();
    }
  }

  void _onStateChanged() {
    if (mounted) setState(() {});
  }

  void _onHostChanged() {
    if (!mounted) return;
    final floating = _host.isFloating;
    if (floating && !_wasFloating) {
      _indexBeforeFloating = _index;
    } else if (!floating && _wasFloating) {
      _index = _indexBeforeFloating;
    }
    _wasFloating = floating;
    setState(() {});
  }

  void _onFloatingError() {
    final message = WindowController.instance.floatingError.value;
    if (message == null) return;
    WindowController.instance.floatingError.value = null;
    if (mounted) _snack(message, isError: true);
  }

  void _snack(String message, {bool isError = false}) {
    if (!mounted) return;
    // 形态切换失败时 host.onError 与 enter/exit 返回值可能各触发一次，
    // 这里对同一文案做 1.2s 去重，保证“提示一次”（规格 §4.7）。
    final now = DateTime.now();
    final last = _lastSnackAt;
    if (_lastSnackMessage == message &&
        last != null &&
        now.difference(last) < const Duration(milliseconds: 1200)) {
      return;
    }
    _lastSnackMessage = message;
    _lastSnackAt = now;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message, style: TextStyle(color: pal.toastFg, fontSize: 13)),
      backgroundColor: isError ? pal.danger : pal.toastBg,
      duration: const Duration(seconds: 3),
    ));
  }

  static int _initialTab() {
    if (kIsWeb) {
      final value = int.tryParse(Uri.base.queryParameters['tab'] ?? '');
      if (value != null && value >= 0 && value <= 5) return value;
    } else {
      final value = initialTabOverride();
      if (value >= 0 && value <= 5) return value;
    }
    return 0;
  }

  void _select(int index) {
    if (_host.isFloating) return;
    setState(() => _index = index);
  }

  Future<void> _enterFloating() async {
    if (_host.transitioning || _host.captureInProgress) return;
    final ok = await _host.enterFloating(focus: true);
    if (!mounted || ok || _host.isFloating) return;
    _snack('切到浮窗失败，已恢复窗口', isError: true);
  }

  String get _sessionTitle {
    final conversation = _state.conversationById(_state.currentConversationId);
    final title = conversation?.title.trim() ?? '';
    return title.isEmpty ? '新对话' : title;
  }

  List<Widget> _buildScreens({required bool floating, required bool compact}) {
    final override = widget.screensOverride;
    if (override != null) return override;
    final pages = <Widget>[
      ChatScreen(
        key: _chatKey,
        active: floating || _index == 0,
        state: _state,
        floating: floating,
        compact: compact,
        screenshots: widget.screenshots,
      ),
      TodayScreen(active: !floating && _index == 1),
      NotesScreen(active: !floating && _index == 2),
      MaterialsScreen(active: !floating && _index == 3),
      AgentScreen(active: !floating && _index == 4),
      SettingsScreen(active: !floating && _index == 5),
    ];
    if (!floating) return pages;
    // 浮窗只显示对话页，但其余五页仍需“常驻”以保留状态（规格 §5.2）。
    // 它们在 360×420 的窄约束下会 overflow（t5 T5-04：Settings/Materials 等），
    // 因此让隐藏页按普通窗口最小尺寸 900×600 完成布局，再由 IndexedStack 裁剪；
    // 返回普通窗口时恢复真实约束（内容与 v0.4.0 一致）。
    return <Widget>[
      pages.first,
      for (final page in pages.skip(1)) _desktopSized(page),
    ];
  }

  /// 隐藏页按普通窗口最小尺寸布局，避免窄浮窗约束下产生 RenderFlex overflow。
  static Widget _desktopSized(Widget page) {
    return OverflowBox(
      alignment: Alignment.topLeft,
      minWidth: normalMinSize.width,
      maxWidth: normalMinSize.width,
      minHeight: normalMinSize.height,
      maxHeight: normalMinSize.height,
      child: SizedBox(
        width: normalMinSize.width,
        height: normalMinSize.height,
        child: page,
      ),
    );
  }

  Widget _chrome({
    required bool floating,
    required bool compact,
  }) {
    if (floating) {
      return FloatingBar(
        host: _host,
        title: _sessionTitle,
        compact: compact,
        onDragStart: () => WindowController.instance.startDragging(),
        onClose: () => WindowController.instance.close(),
        onScreenshot: (hideLoop) => requestScreenshot(hideLoop: hideLoop),
      );
    }
    return TitleBar(
      pageTitle: _pageTitles[_index.clamp(0, _pageTitles.length - 1)],
      modeHost: _host,
      onFloatingToggle: _enterFloating,
      hotkeyStatus: HotkeyService.instance.status,
    );
  }

  @override
  Widget build(BuildContext context) {
    final floating = _host.isFloating;
    final size = MediaQuery.sizeOf(context);
    final compact = floating &&
        (size.width < compactWidth || size.height < compactHeight);
    final screens = _buildScreens(floating: floating, compact: compact);
    final contentIndex = floating ? 0 : _index.clamp(0, screens.length - 1);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: ValueListenableBuilder<bool>(
        valueListenable: WindowController.instance.readyNotifier,
        builder: (context, ready, _) => ValueListenableBuilder<bool>(
          valueListenable: WindowController.instance.maximized,
          builder: (context, maximized, _) {
            final framed = WindowController.instance.ready;
            return Stack(
              fit: StackFit.expand,
              children: [
                FloatingQaScaffold(
                  floating: floating,
                  framed: framed,
                  maximized: maximized,
                  chrome: _chrome(floating: floating, compact: compact),
                  sidebar: floating
                      ? const SizedBox.shrink()
                      : _ResponsiveSidebar(index: _index, onSelect: _select),
                  content: IndexedStack(
                    key: _contentKey,
                    index: contentIndex,
                    children: screens,
                  ),
                ),
                if (framed && !maximized)
                  const Positioned.fill(child: WindowResizeHandles()),
              ],
            );
          },
        ),
      ),
    );
  }
}
