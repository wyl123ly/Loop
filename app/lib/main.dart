import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'answer_ui/answer_drag_stub.dart'
    if (dart.library.io) 'answer_ui/answer_drag_io.dart';
import 'answer_ui/answer_window_app.dart';
import 'backend/job_scheduler.dart';
import 'backend/start.dart';
import 'boot_prefs.dart';
import 'desktop/answer_host/answer_protocol.dart' show AnswerStatus;
import 'desktop/answer_host/answer_transport_stub.dart'
    if (dart.library.io) 'desktop/answer_host/answer_transport_io.dart';
import 'desktop/answer_host/answer_window_host.dart';
import 'desktop/floating_signals.dart';
import 'desktop/hotkeys.dart';
import 'desktop/screenshot_service.dart';
import 'desktop/window_controls.dart';
import 'desktop/window_mode.dart';
import 'diagnostics/frame_log.dart';
import 'desktop/tray_export.dart';
import 'models.dart';
import 'screens/agent_screen.dart';
import 'screens/chat_screen.dart';
import 'screens/materials_screen.dart';
import 'screens/notes_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/subject_screen.dart';
import 'screens/today_screen.dart';
import 'state.dart';
import 'theme.dart';
import 'ui_tab.dart';
import 'ui_theme.dart';
import 'update/update_ui.dart';
import 'widgets/floating_bar.dart';
import 'widgets/floating_qa_scaffold.dart';
import 'widgets/sidebar.dart';
import 'widgets/subject_switcher.dart';
import 'widgets/title_bar.dart';
import 'widgets/window_resize_handles.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  // 第二引擎（回答浮窗）：由 desktop_multi_window 以
  // `["multi_window", windowId, payload]` 启动。这里不得初始化
  // DB/后端/托盘/WindowController/热键，也不得使用 window_manager
  // （规格 §2.4/§9.1；子引擎注册 window_manager 会导致崩溃）。
  if (args.isNotEmpty && args.first == 'multi_window') {
    final session = await prepareAnswerEngine();
    if (session == null) return;
    runApp(AnswerWindowApp(
      session: session,
      dragDelegate: createAnswerDragDelegate(),
    ));
    return;
  }

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
  const LoopApp({super.key, this.state, this.home});

  /// 可选注入，便于 widget 测试；生产环境使用全局 [appState]。
  final AppState? state;

  /// 测试替身：替换启动完成后的 home（生产为 [Shell]）。
  final Widget? home;

  @override
  State<LoopApp> createState() => _LoopAppState();
}

class _LoopAppState extends State<LoopApp> with WidgetsBindingObserver {
  // 两份主题只构造一次；此前每次 build 都会重新生成两份 ThemeData。
  late final ThemeData _lightTheme = loopTheme(LoopPalette.light);
  late final ThemeData _darkTheme = loopTheme(LoopPalette.dark);

  AppState get _state => widget.state ?? appState;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _state.appearanceRevision.addListener(_onAppearanceChanged);
    _state.bootRevision.addListener(_onBootChanged);
    WindowController.instance.readyNotifier.addListener(_onHostReady);
    _state.bootstrap();
    if (widget.state == null) unawaited(checkForUpdatesOnStartup());
    // 首帧后补一次回答窗主题同步（host 可能在 initState 前就已 ready）。
    WidgetsBinding.instance.addPostFrameCallback((_) => _scheduleAnswerThemeSync());
  }

  @override
  void dispose() {
    _state.appearanceRevision.removeListener(_onAppearanceChanged);
    _state.bootRevision.removeListener(_onBootChanged);
    WindowController.instance.readyNotifier.removeListener(_onHostReady);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _onAppearanceChanged() {
    if (mounted) setState(() {});
    _scheduleAnswerThemeSync();
  }

  void _onBootChanged() {
    if (mounted) setState(() {});
    _scheduleAnswerThemeSync();
  }

  void _onHostReady() {
    if (WindowController.instance.ready) _scheduleAnswerThemeSync();
  }

  @override
  void didChangePlatformBrightness() {
    // 只更新调色板；是否重刷由 AppState 判断（跟随系统才需要）。
    _state.notifySystemBrightnessChanged();
  }

  /// F-02：主题变化同步到已打开的回答窗（第二引擎不读设置/DB）。
  ///
  /// 在 post-frame 调用，避免 build 期间发 IPC；重复值由 host 去重。
  void _scheduleAnswerThemeSync() {
    if (!WindowController.instance.ready) return;
    final mode = _state.themeMode.name;
    final dark = LoopTheme.palette.isDark;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!WindowController.instance.ready) return;
      unawaited(WindowController.instance.answers.setTheme(
        themeMode: mode,
        dark: dark,
      ));
    });
  }

  @override
  Widget build(BuildContext context) {
    // 只监听“外观”和“启动状态”两个低频信号：
    // 会话/学科/流式输出等高频 appState 通知不再重建整个 MaterialApp。
    return ListenableBuilder(
      listenable: Listenable.merge([
        _state.appearanceRevision,
        _state.bootRevision,
      ]),
      builder: (context, _) {
        LoopTheme.palette = _paletteFor(_state.themeMode);
        return MaterialApp(
          title: '回路 Loop',
          debugShowCheckedModeBanner: false,
          navigatorKey: rootNavigatorKey,
          theme: _lightTheme,
          darkTheme: _darkTheme,
          themeMode: _state.themeMode,
          // 关闭整棵树的主题插值动画：切换瞬间完成，不再逐帧 lerp 造成卡顿。
          themeAnimationDuration: Duration.zero,
          home: widget.home ??
              (_state.ready
                  ? (_state.bootstrapError != null
                      ? _BootError(message: _state.bootstrapError!, state: _state)
                      : const Shell())
                  : const _Splash()),
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
  const _BootError({required this.message, this.state});

  final String message;
  final AppState? state;

  AppState get _state => state ?? appState;

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
                  _state.bootstrapError = null;
                  _state.bootstrap();
                  if (state == null) unawaited(checkForUpdatesOnStartup());
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

/// 页签标题（§10.1）：对话 / 今日 / 笔记 / 资料 / 学科 / 代理 / 设置。
/// 与 `widgets/subject_switcher.dart` 的 `chatPageIndex`/`subjectPageIndex`/
/// `settingsPageIndex` 必须一致。
const _pageTitles = ['对话', '今日', '笔记', '资料', '学科', '代理', '设置'];

/// 页签索引上界（`LOOP_TAB` / `?tab=` 允许范围 0..6，AC-11）。
const int _lastPageIndex = 6;

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
    this.answerSink,
    this.pageBuilder,
  });

  /// 可选注入，便于 widget 测试；生产环境使用全局 [appState]。
  final AppState? state;

  /// 浮窗形态宿主；生产为 [WindowController.instance.floating]。
  final FloatingModeHost? modeHost;

  /// 测试替身：整组页面（长度可小于 6，索引会被钳制）。
  final List<Widget>? screensOverride;

  /// 截图服务；为空时 ChatScreen 使用平台实现。
  final ScreenshotService? screenshots;

  /// 回答浮窗数据源；生产为 [WindowController.instance.answers] 的适配器。
  final ChatAnswerSink? answerSink;

  /// 测试替身：只替换对话页以外的 5 页，对话页仍由 Shell 构建，用于验证
  /// 极简形态的真实接线（screensOverride 会绕过 Shell 的 ChatScreen 参数）。
  final Widget Function(int index, bool active)? pageBuilder;

  @override
  State<Shell> createState() => _ShellState();
}

class _ResponsiveSidebar extends StatelessWidget {
  const _ResponsiveSidebar({required this.index, required this.onSelect, required this.state});

  final int index;
  final ValueChanged<int> onSelect;
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final autoCompact = MediaQuery.sizeOf(context).width < 1080;
    final manualCollapsed = state.settings?.sidebarCollapsed ?? false;
    return Sidebar(
      index: index,
      onSelect: onSelect,
      compact: autoCompact || manualCollapsed,
      canToggle: !autoCompact,
      state: state,
      onToggleCollapse: () => state.setSidebarCollapsed(!manualCollapsed),
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

  /// 回答窗宿主适配器（生产在 WindowController 就绪后解析；测试可直接注入）。
  ChatAnswerSink? _resolvedAnswerSink;
  bool _answerHostResolved = false;

  String? _lastSnackMessage;
  DateTime? _lastSnackAt;

  /// F-05：周期性把输入条/主窗物理矩形同步给回答窗（覆盖程序化
  /// SetWindowPos/显示器变化等不触发 window_manager onWindowMoved 的路径）。
  Timer? _answerAnchorTimer;

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
    WindowController.instance.answerError.addListener(_onAnswerError);
    newChatSignal.addListener(_onConversationSwitched);
    openConversationSignal.addListener(_onConversationSwitched);
    deletedConversationSignal.addListener(_onConversationSwitched);
    subjectPageSignal.addListener(_onSubjectPageRequested);
    chatDraftSignal.addListener(_onChatDraftRequested);
    WindowController.instance.geometryEpoch.addListener(_onMainGeometryEpoch);
    _answerAnchorTimer = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => unawaited(_syncAnswerAnchors()),
    );
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
    WindowController.instance.answerError.removeListener(_onAnswerError);
    newChatSignal.removeListener(_onConversationSwitched);
    openConversationSignal.removeListener(_onConversationSwitched);
    deletedConversationSignal.removeListener(_onConversationSwitched);
    subjectPageSignal.removeListener(_onSubjectPageRequested);
    chatDraftSignal.removeListener(_onChatDraftRequested);
    WindowController.instance.geometryEpoch
        .removeListener(_onMainGeometryEpoch);
    _answerAnchorTimer?.cancel();
    _answerAnchorTimer = null;
    super.dispose();
  }

  /// T5-05：主窗 resize/move/DPI/最大化/形态切换 tick → 下一帧重报 anchor。
  void _onMainGeometryEpoch() {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_syncAnswerAnchors());
    });
  }

  /// F-05：把当前输入条/主窗物理矩形同步给回答窗（幂等，host 去重）。
  Future<void> _syncAnswerAnchors() async {
    if (!WindowController.instance.ready) return;
    final answers = WindowController.instance.answers;
    if (!answers.supported || !answers.visible) return;
    final rect = _chatKey.currentState?.inputBarRect;
    if (rect == null) return;
    try {
      final snapshot = await _host.snapshot();
      final dpr = snapshot.dpr;
      final main = snapshot.physicalBounds;
      final input = Rect.fromLTWH(
        main.left + rect.left * dpr,
        main.top + rect.top * dpr,
        rect.width * dpr,
        rect.height * dpr,
      );
      await answers.updateAnchors(
        inputBarPhysical: input,
        mainWindowPhysical: main,
      );
    } catch (error) {
      debugPrint('answer anchor sync failed: $error');
    }
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
      // 返回主窗口（返回按钮/Alt+Q）时自动关闭回答窗（规格 §0-12）；
      // 回答内容仍完整保留在主聊天中。
      unawaited(_closeAnswerWindow());
    }
    // 回答浮窗只属于极简形态；展开回普通浮窗/返回主窗口时关闭，避免
    // 置顶回答窗继续遮挡非极简界面。
    if (!_host.minimal) {
      unawaited(_closeAnswerWindow());
    }
    _wasFloating = floating;
    setState(() {});
    // T5-05：normal/floating/minimal 切换后下一帧重报输入条矩形。
    _onMainGeometryEpoch();
  }

  void _onFloatingError() {
    final message = WindowController.instance.floatingError.value;
    if (message == null) return;
    WindowController.instance.floatingError.value = null;
    if (mounted) _snack(message, isError: true);
  }

  void _onAnswerError() {
    final message = WindowController.instance.answerError.value;
    if (message == null) return;
    WindowController.instance.answerError.value = null;
    // 显式失败：主聊天不受影响，用户可见一次提示（规格 §0.2）。
    if (mounted) _snack(message, isError: true);
  }

  /// 切换/新建/删除会话时关闭回答窗（旧回答已失效，规格 §4.8）。
  void _onConversationSwitched() {
    unawaited(_closeAnswerWindow());
  }

  /// 侧栏/切换器菜单里的「管理学科…」→ 切到学科页（§10.2）。
  void _onSubjectPageRequested() {
    if (!mounted || _host.isFloating) return;
    setState(() => _index = subjectPageIndex);
  }

  /// 学科页「去对话 / 去复习」→ 切到对话页；输入框预填由 ChatScreen 处理。
  void _onChatDraftRequested() {
    if (!mounted || _host.isFloating) return;
    setState(() => _index = chatPageIndex);
  }

  /// 生产环境解析回答窗 host（测试未初始化 WindowController 时为 null）。
  void _resolveAnswerHost() {
    if (_answerHostResolved) return;
    if (!WindowController.instance.ready) return;
    _answerHostResolved = true;
    final answers = WindowController.instance.answers;
    if (!answers.supported) return;
    answers.onFocusCompensation = () {
      _chatKey.currentState?.focusInput();
    };
    _resolvedAnswerSink = _ShellChatAnswerSink(
      host: answers,
      modeHost: _host,
      isDark: () => pal.isDark,
    );
  }

  ChatAnswerSink? get _answerSink => widget.answerSink ?? _resolvedAnswerSink;

  Future<void> _closeAnswerWindow() async {
    if (!_answerHostResolved || !WindowController.instance.ready) return;
    final answers = WindowController.instance.answers;
    if (!answers.hasWindow) return;
    await answers.closeWindow();
  }

  Future<void> _enterMinimal() async {
    if (_host.transitioning || _host.captureInProgress || _host.minimal) return;
    final ok = await _host.enterMinimal(focus: true);
    if (!mounted || ok || _host.minimal) return;
    _snack('收起为极简条失败，已恢复浮窗', isError: true);
  }

  Future<void> _expandFromMinimal() async {
    if (!_host.minimal || _host.transitioning || _host.captureInProgress) return;
    final ok = await _host.exitMinimal(focus: true);
    if (!mounted || ok || !_host.minimal) return;
    _snack('展开浮窗失败，已保持极简条', isError: true);
  }

  Future<void> _returnFromMinimal() async {
    if (!_host.isFloating) return;
    final ok = await _host.exitFloating(focus: true);
    if (!mounted || ok || !_host.isFloating) return;
    _snack('返回主窗口失败，已保持极简条', isError: true);
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
      if (value != null && value >= 0 && value <= _lastPageIndex) return value;
    } else {
      final value = initialTabOverride();
      if (value >= 0 && value <= _lastPageIndex) return value;
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

  List<Widget> _buildScreens({
    required bool floating,
    required bool compact,
    required bool minimal,
  }) {
    final override = widget.screensOverride;
    if (override != null) return override;
    final pages = <Widget>[
      ChatScreen(
        key: _chatKey,
        active: floating || _index == 0,
        state: _state,
        floating: floating,
        compact: compact,
        minimal: minimal,
        screenshots: widget.screenshots,
        answerSink: _answerSink,
        onMinimalBack: () {
          unawaited(_returnFromMinimal());
        },
        onMinimalExpand: () {
          unawaited(_expandFromMinimal());
        },
        onMinimalDragStart: () {
          unawaited(WindowController.instance.startDragging());
        },
      ),
      TodayScreen(
        active: !floating && _index == 1,
        state: _state,
      ),
      NotesScreen(active: !floating && _index == 2, state: _state),
      MaterialsScreen(active: !floating && _index == 3, state: _state),
      SubjectScreen(active: !floating && _index == subjectPageIndex, state: _state),
      AgentScreen(active: !floating && _index == 5),
      SettingsScreen(active: !floating && _index == settingsPageIndex),
    ];
    final builder = widget.pageBuilder;
    if (builder != null) {
      for (var index = 1; index < pages.length; index++) {
        pages[index] = builder(index, !floating && _index == index);
      }
    }
    if (!floating) return pages;
    // 浮窗只显示对话页，但其余六页仍需“常驻”以保留状态（规格 §5.2）。
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
    required bool minimal,
  }) {
    if (minimal) {
      // 极简条本身由 ChatScreen 渲染（三要素）；不显示 FloatingBar/TitleBar。
      return const SizedBox.shrink();
    }
    if (floating) {
      return FloatingBar(
        host: _host,
        title: _sessionTitle,
        compact: compact,
        onDragStart: () => WindowController.instance.startDragging(),
        onClose: () => WindowController.instance.close(),
        onScreenshot: (hideLoop) => requestScreenshot(hideLoop: hideLoop),
        onMinimize: () {
          unawaited(_enterMinimal());
        },
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
    _resolveAnswerHost();
    final floating = _host.isFloating;
    final minimal = floating && _host.minimal;
    final size = MediaQuery.sizeOf(context);
    final compact = floating &&
        !minimal &&
        (size.width < compactWidth || size.height < compactHeight);
    final screens = _buildScreens(
      floating: floating,
      compact: compact,
      minimal: minimal,
    );
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
                ColoredBox(
                  // 主窗口：圆角面板外的像素必须是主题底色，不能让桌面/引擎
                  // 背景从圆角与 DWM 裁剪之间透出来（表现为右上角白弧）。
                  // 浮窗/极简仍保持透明，避免破坏它们自己的圆角形态。
                  color: !floating && !minimal ? pal.bgTop : Colors.transparent,
                  child: FloatingQaScaffold(
                    floating: floating,
                    minimal: minimal,
                    framed: framed,
                    maximized: maximized,
                    chrome: _chrome(
                      floating: floating,
                      compact: compact,
                      minimal: minimal,
                    ),
                    sidebar: floating
                        ? const SizedBox.shrink()
                        : _ResponsiveSidebar(
                            index: _index,
                            onSelect: _select,
                            state: _state,
                          ),
                    content: IndexedStack(
                      key: _contentKey,
                      index: contentIndex,
                      children: screens,
                    ),
                  ),
                ),
                if (framed && !maximized && !minimal)
                  const Positioned.fill(child: WindowResizeHandles()),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// ChatAnswerSink → t2 `AnswerWindowHost` 的适配器（主窗口唯一数据源）。
class _ShellChatAnswerSink implements ChatAnswerSink {
  _ShellChatAnswerSink({
    required this.host,
    required this.modeHost,
    required this.isDark,
  });

  final AnswerWindowHost host;
  final FloatingModeHost modeHost;
  final bool Function() isDark;

  /// ChatScreen 只提供窗口内逻辑矩形；这里结合主窗物理 bounds/dpr 换算成
  /// 屏幕物理矩形（主机/多屏/DPI 由 host 再做钳制）。
  Future<void> _submit(ChatSubmission submission) async {
    Rect? inputBarPhysical;
    Rect? mainWindowPhysical;
    try {
      final snapshot = await modeHost.snapshot();
      mainWindowPhysical = snapshot.physicalBounds;
      final rect = submission.inputBarRect;
      if (rect != null) {
        final dpr = snapshot.dpr;
        inputBarPhysical = Rect.fromLTWH(
          snapshot.physicalBounds.left + rect.left * dpr,
          snapshot.physicalBounds.top + rect.top * dpr,
          rect.width * dpr,
          rect.height * dpr,
        );
      }
    } catch (_) {
      // 几何不可用也继续创建：host 会退化为窗口底部 120px 排除带（规格 §4.5）。
    }
    await host.showOrReplace(AnswerSubmission(
      question: submission.question,
      conversationId: '${submission.conversationId}',
      runId: submission.runId?.toString(),
      inputBarPhysical: inputBarPhysical,
      mainWindowPhysical: mainWindowPhysical,
      themeMode: submission.themeMode.name,
      dark: submission.themeMode == ThemeMode.dark ||
          (submission.themeMode == ThemeMode.system && isDark()),
      fontFamily: 'NotoSC',
    ));
  }

  @override
  void submit(ChatSubmission submission) {
    unawaited(_submit(submission));
  }

  @override
  void appendText(String delta) => host.pushTextDelta(delta);

  @override
  void setRunId(int? runId) {
    // 回答窗快照的 runId 在 submit 时已带上；SSE 迟到的 run 事件无需改写。
  }

  @override
  void setPlan(List<PlanItem> plan) {
    host.setPlan([for (final item in plan) item.toJson()]);
  }

  @override
  void setStatus(
    String state, {
    String? label,
    bool approvalRequired = false,
  }) {
    final status = AnswerStatus.tryParse(state);
    if (status == null) return;
    host.setStatus(status, label: label, approvalRequired: approvalRequired);
  }

  @override
  void complete({List<RefItem> refs = const []}) {
    host.setRefs([
      for (final ref in refs) <String, Object?>{'name': ref.name, 'page': ref.page},
    ]);
    host.finish(AnswerStatus.done);
  }

  @override
  void stop() => host.finish(AnswerStatus.stopped);

  @override
  void fail(String message) => host.finish(AnswerStatus.error, error: message);
}
