import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'backend/job_scheduler.dart';
import 'backend/start.dart';
import 'boot_prefs.dart';
import 'desktop/window_controls.dart';
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
import 'widgets/glass.dart';
import 'widgets/sidebar.dart';
import 'widgets/title_bar.dart';
import 'widgets/window_resize_handles.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
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

class Shell extends StatefulWidget {
  const Shell({super.key});

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int _index = _initialTab();

  @override
  void initState() {
    super.initState();
    appState.addListener(_onStateChanged);
  }

  @override
  void dispose() {
    appState.removeListener(_onStateChanged);
    super.dispose();
  }

  void _onStateChanged() {
    if (mounted) setState(() {});
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

  void _select(int index) => setState(() => _index = index);

  @override
  Widget build(BuildContext context) {
    final p = pal;
    final screens = <Widget>[
      ChatScreen(active: _index == 0),
      TodayScreen(active: _index == 1),
      NotesScreen(active: _index == 2),
      MaterialsScreen(active: _index == 3),
      AgentScreen(active: _index == 4),
      SettingsScreen(active: _index == 5),
    ];

    final autoCompact = MediaQuery.sizeOf(context).width < 1080;
    final manualCollapsed = appState.settings?.sidebarCollapsed ?? false;
    final compact = autoCompact || manualCollapsed;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: ValueListenableBuilder<bool>(
        valueListenable: WindowController.instance.readyNotifier,
        builder: (context, ready, _) => ValueListenableBuilder<bool>(
        valueListenable: WindowController.instance.maximized,
        builder: (context, maximized, _) {
          final framed = WindowController.instance.ready;
          final radius = framed && !maximized ? 18.0 : 0.0;
          final borderRadius = BorderRadius.circular(radius);
          final content = Container(
            decoration: BoxDecoration(
              color: p.bgTop,
              borderRadius: borderRadius,
              border: Border.all(
                color: framed ? p.windowBorder : Colors.transparent,
                width: 1,
              ),
            ),
            child: ClipRRect(
              borderRadius: borderRadius,
              child: AuroraBackground(
                child: Column(
                  children: [
                    TitleBar(pageTitle: _pageTitles[_index]),
                    Expanded(
                      child: Row(
                        children: [
                          Sidebar(
                            index: _index,
                            onSelect: _select,
                            compact: compact,
                            canToggle: !autoCompact,
                            onToggleCollapse: () =>
                                appState.setSidebarCollapsed(!manualCollapsed),
                          ),
                          Expanded(child: IndexedStack(index: _index, children: screens)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
          return Stack(
            fit: StackFit.expand,
            children: [
              content,
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
