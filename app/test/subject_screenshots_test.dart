// AC-07 截图证据（F-17）：用真实 widget + 注入假后端渲染 12 张图并落盘到
// docs/evidence/subject-v0.8.0/screens/。不联网、不落业务数据。
//
// 运行：flutter test test/subject_screenshots_test.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loop/api.dart';
import 'package:loop/models.dart';
import 'package:loop/screens/chat_screen.dart';
import 'package:loop/screens/materials_screen.dart';
import 'package:loop/screens/settings_screen.dart';
import 'package:loop/screens/subject_screen.dart';
import 'package:loop/state.dart';
import 'package:loop/theme.dart';
import 'package:loop/widgets/sidebar.dart';
import 'package:loop/widgets/subject_skills_panel.dart';

// 测试进程 cwd = app/，证据目录在仓库根的 docs/ 下。
const _screenDir = '../docs/evidence/subject-v0.8.0/screens';

/// 极简假后端：只提供截图需要的静态数据。
class _ShotApi extends LoopApi {
  _ShotApi() : super(baseUrl: 'http://127.0.0.1:1');

  final Subject subject = Subject(
    id: 1,
    key: 's_lin',
    name: '线性代数',
    description: '',
    icon: '',
    color: 'violet',
    goal: '考研数学一 · 每天 60 分钟',
    examDate: '2026-12-20',
    dailyMinutes: 60,
    level: 'intermediate',
    status: 'active',
    isDefault: true,
    sortOrder: 1,
    integrity: 'ok',
    lastOpenedAt: '2026-10-25T09:00:00+08:00',
    createdAt: '2026-10-01T09:00:00+08:00',
    archivedAt: '',
    counts: const {
      'conversations': 3,
      'materials': 12,
      'topics': 18,
      'notes': 5,
      'tasks': 4,
    },
  );

  @override
  Future<List<Subject>> subjects({bool includeArchived = false, bool counts = false}) async =>
      [subject];

  @override
  Future<Subject> activeSubject() async => subject;

  @override
  Future<List<Conversation>> conversations() async => [
        Conversation(
          id: 11,
          title: '特征值与特征向量答疑',
          preview: '把 A-λI 的行列式展开…',
          messages: 6,
          updatedAt: '2026-10-25T09:00:00+08:00',
        ),
        Conversation(
          id: 12,
          title: '相似矩阵复习',
          preview: '今天先做 3 道题',
          messages: 4,
          updatedAt: '2026-10-24T20:00:00+08:00',
        ),
      ];

  @override
  Future<List<Message>> messages(int conversationId) async => [
        Message(
          id: 1,
          role: 'user',
          content: '特征值和特征向量到底在讲什么？',
        ),
        Message(
          id: 2,
          role: 'assistant',
          content: '一句话：特征向量是「方向不变」的方向，特征值是缩放倍数。\n'
              '由 Ax=λx 得 (A-λI)x=0，要有非零解必须 det(A-λI)=0。\n\n'
              '自测：A=[[2,0],[0,3]] 的特征值是多少？',
        ),
      ];

  @override
  Future<List<MaterialItem>> materials({String? subject}) async => [
        MaterialItem(id: 1, name: '线代讲义-第5章.pdf', kind: 'pdf', status: 'ready', pages: 24, chars: 18000),
        MaterialItem(id: 2, name: '真题-2024.md', kind: 'md', status: 'ready', pages: 8, chars: 6000),
      ];

  @override
  Future<List<MaterialFolder>> materialFolders() async => const [];

  @override
  Future<TodayData> today({String? subject}) async => TodayData(
        date: '2026-10-25',
        tasks: [
          TaskItem(
            id: 1,
            title: '复习特征值 3 道题',
            due: '2026-10-25',
            estimateMin: 40,
            status: 'todo',
          ),
        ],
        doneToday: 2,
        openTotal: 4,
        overdue: 0,
      );

  @override
  Future<List<TaskItem>> tasks({String? date, String? status, String? subject}) async => [
        TaskItem(
          id: 1,
          title: '复习特征值 3 道题',
          due: '2026-10-25',
          estimateMin: 40,
          status: 'todo',
        ),
      ];

  @override
  Future<List<NoteItem>> notes({String? subject}) async => const [];

  final SubjectProgress snapshot = const SubjectProgress(
    profile: {'goal': '考研数学一', 'exam_date': '2026-12-20', 'daily_minutes': 60},
    summary: {
      'topics_total': 18,
      'studied_topics': 9,
      'mastered': 4,
      'review_due': 3,
      'mastery_avg': 0.52,
      'coverage_percent': 50,
      'last_studied_at': '2026-10-25T09:12:00+08:00',
    },
    topics: [
      TopicItem(
        id: 1,
        name: '特征值与特征向量',
        status: 'learning',
        mastery: 0.62,
        nextReviewAt: '2026-10-27',
        evidenceCount: 6,
      ),
      TopicItem(
        id: 2,
        name: '矩阵相似与对角化',
        status: 'review_due',
        mastery: 0.45,
      ),
      TopicItem(
        id: 3,
        name: '二次型标准化',
        status: 'mastered',
        mastery: 0.88,
      ),
    ],
    daily: [ProgressDailyPoint(day: '2026-10-25', minutes: 62, events: 5, mastered: 1)],
  );

  @override
  Future<SubjectProgress> subjectProgress(int id, {int? limit, int? offset}) async => snapshot;

  @override
  Future<Map<String, dynamic>> recomputeSubjectProgress(int id) async => {'ok': true};

  @override
  Future<SkillLibraryData> skillLibrary() async => SkillLibraryData(
        subjectKey: subject.key,
        hub: 'eduhub',
        hubLabel: 'EduHub',
        webUrl: 'https://eduhub.deeptutor.info',
        installed: const [
          InstalledSkillInfo(
            slug: 'learn-ai-architect',
            version: '1.0.0',
            name: 'AI 架构学习教练',
            description: '用提问式教学带你理解 Transformer 架构（文档型技能）。',
            hub: 'eduhub',
            enabled: true,
            pinned: false,
            license: 'MIT-0',
            owner: 'deeptutor',
            installedAt: '2026-10-25T13:00:00+08:00',
            verdict: SkillVerdictInfo(
              status: 'ok',
              decision: 'pass',
              confidence: 'low',
              signature: 'unsigned',
              summary: 'Static scan found no high-signal malicious patterns. '
                  'Not a full malware scan.',
            ),
          ),
        ],
        policy: const SkillPolicyInfo(
          verifyNote: 'verify 只是 registry 侧静态扫描的参考信号，不是安全保证。',
        ),
      );

  @override
  Future<Map<String, dynamic>> migrationStatus() async => {
        'applied': [
          {'id': 'v0.8.0-subjects', 'applied_at': '2026-10-25T13:00:00+08:00'},
        ],
        'pending': [],
        'running': false,
        'report': {
          'result': 'ok',
          'counts': {'conversations': 3, 'messages': 54, 'materials': 532, 'chunks': 27457},
          'files_moved': 540,
          'files_failed': 0,
          'files_leftover': 0,
          'files_missing': 0,
          'file_errors': [],
        },
      };

  @override
  Future<SettingsData> settings() async => SettingsData(
        apiKeyMasked: 'sk-••••',
        hasKey: true,
        baseUrl: 'https://api.deepseek.com',
        model: 'deepseek-flash',
        reasonModel: 'deepseek-v4-pro',
        activeSubject: subject.key,
        skillHubUrl: 'https://eduhub.deeptutor.info/api/v1',
        subjectMigrationNoticeSeen: false,
      );
}

Future<void> _loadSystemFonts() async {
  final tried = <String>[];
  for (final path in [
    // 产品自带字体（与真机同源，Noto Sans SC 含拉丁 + CJK）。
    'assets/fonts/NotoSansSC-Loop.ttf',
    r'assets\fonts\NotoSansSC-Loop.ttf',
    r'C:\Windows\Fonts\msyh.ttc',
    r'C:\Windows\Fonts\Deng.ttf',
    r'C:\Windows\Fonts\simhei.ttf',
    r'C:\Windows\Fonts\msyhl.ttc',
    r'C:\Windows\Fonts\segoeui.ttf',
  ]) {
    final file = File(path);
    if (!file.existsSync()) continue;
    try {
      final bytes = file.readAsBytesSync();
      // 把系统字体注册成默认族（Roboto），让截图里的中文可读。
      // T17-1：同时注册成 flutter_test 兜底族 'Ahem'（每个字形都是实心块）
// 与产品里唯一的显式族 'monospace'（app/lib 里只有这一处显式 family）。
      // 覆盖它们为 CJK 字体后，兜底路径与 monospace 路径都能渲染出真实字形。
      for (final family in [_shotFontFamily, 'Segoe UI', 'Ahem', 'monospace']) {
        final loader = FontLoader(family)
          ..addFont(Future<ByteData>.value(ByteData.view(Uint8List.fromList(bytes).buffer)));
        await loader.load();
      }
      tried.add(path);
    } catch (_) {
      // TTC/权限等问题：换下一个候选。
    }
  }
  // Material 图标字体（widget 测试默认不加载 → 图标会显示成方框）。
  for (final path in [
    r'D:\DSH_Workspace\Prog2_app\.tools\flutter\bin\cache\artifacts\material_fonts\MaterialIcons-Regular.otf',
    r'C:\flutter\bin\cache\artifacts\material_fonts\MaterialIcons-Regular.otf',
  ]) {
    final file = File(path);
    if (!file.existsSync()) continue;
    try {
      final bytes = file.readAsBytesSync();
      final loader = FontLoader('MaterialIcons')
        ..addFont(Future<ByteData>.value(ByteData.view(Uint8List.fromList(bytes).buffer)));
      await loader.load();
      _iconsLoaded = true;
      break;
    } catch (_) {
      // 忽略：图标方框在 README 里如实标注。
    }
  }
  _fontsLoaded = tried.isNotEmpty;
}

/// 图标字体是否加载成功（README 的证据描述用）。
bool _iconsLoaded = false;

/// 截图统一使用的已加载 CJK 族名（T17-1：所有文字槽位都钉到它）。
const String _shotFontFamily = 'Roboto';

/// 系统 CJK 字体是否加载成功（README 的证据描述用）。
bool _fontsLoaded = false;

/// 截图用主题（T17-1）：把已加载的 CJK 族钉到**所有**会出现在界面上的文字样式。
///
/// 之前只覆盖 textTheme/primaryTextTheme，导致 ButtonStyle.textStyle、tab、
/// popupMenu、chip、dialog、snackBar、inputDecoration、listTile、navigationBar/
/// Rail 等槽位仍走 flutter_test 的兜底测试字体（Ahem = 实心块）→ 截图里的
/// 动作按钮变成空心方框/实心块。
ThemeData _shotTheme(bool dark) {
  final base = loopTheme(dark ? LoopPalette.dark : LoopPalette.light);
  TextStyle? f(TextStyle? style) => style?.copyWith(fontFamily: _shotFontFamily);
  WidgetStateProperty<TextStyle?>? fs(WidgetStateProperty<TextStyle?>? property) =>
      property == null
          ? const WidgetStatePropertyAll<TextStyle>(TextStyle(fontFamily: _shotFontFamily))
          : WidgetStateProperty.resolveWith<TextStyle?>(
              (states) => f(property.resolve(states)));
  ButtonStyle? fb(ButtonStyle? style) =>
      (style ?? const ButtonStyle()).copyWith(textStyle: fs(style?.textStyle));

  return base.copyWith(
    textTheme: base.textTheme.apply(fontFamily: _shotFontFamily),
    primaryTextTheme: base.primaryTextTheme.apply(fontFamily: _shotFontFamily),
    filledButtonTheme: FilledButtonThemeData(style: fb(base.filledButtonTheme.style)),
    elevatedButtonTheme: ElevatedButtonThemeData(style: fb(base.elevatedButtonTheme.style)),
    outlinedButtonTheme: OutlinedButtonThemeData(style: fb(base.outlinedButtonTheme.style)),
    textButtonTheme: TextButtonThemeData(style: fb(base.textButtonTheme.style)),
    iconButtonTheme: IconButtonThemeData(style: base.iconButtonTheme.style),
    chipTheme: base.chipTheme.copyWith(
      labelStyle: f(base.chipTheme.labelStyle),
      secondaryLabelStyle: f(base.chipTheme.secondaryLabelStyle),
    ),
    tabBarTheme: base.tabBarTheme.copyWith(
      labelStyle: f(base.tabBarTheme.labelStyle),
      unselectedLabelStyle: f(base.tabBarTheme.unselectedLabelStyle),
    ),
    popupMenuTheme: base.popupMenuTheme.copyWith(textStyle: f(base.popupMenuTheme.textStyle)),
    dialogTheme: base.dialogTheme.copyWith(
      titleTextStyle: f(base.dialogTheme.titleTextStyle),
      contentTextStyle: f(base.dialogTheme.contentTextStyle),
    ),
    snackBarTheme:
        base.snackBarTheme.copyWith(contentTextStyle: f(base.snackBarTheme.contentTextStyle)),
    tooltipTheme: base.tooltipTheme.copyWith(textStyle: f(base.tooltipTheme.textStyle)),
    inputDecorationTheme: base.inputDecorationTheme.copyWith(
      hintStyle: f(base.inputDecorationTheme.hintStyle),
      labelStyle: f(base.inputDecorationTheme.labelStyle),
      helperStyle: f(base.inputDecorationTheme.helperStyle),
      errorStyle: f(base.inputDecorationTheme.errorStyle),
      prefixStyle: f(base.inputDecorationTheme.prefixStyle),
      suffixStyle: f(base.inputDecorationTheme.suffixStyle),
    ),
    listTileTheme: base.listTileTheme.copyWith(
      titleTextStyle: f(base.listTileTheme.titleTextStyle),
      subtitleTextStyle: f(base.listTileTheme.subtitleTextStyle),
      leadingAndTrailingTextStyle: f(base.listTileTheme.leadingAndTrailingTextStyle),
    ),
    navigationBarTheme: base.navigationBarTheme.copyWith(
      labelTextStyle: fs(base.navigationBarTheme.labelTextStyle),
    ),
    navigationRailTheme: base.navigationRailTheme.copyWith(
      selectedLabelTextStyle: f(base.navigationRailTheme.selectedLabelTextStyle),
      unselectedLabelTextStyle: f(base.navigationRailTheme.unselectedLabelTextStyle),
    ),
    bottomSheetTheme: base.bottomSheetTheme,
    appBarTheme: base.appBarTheme.copyWith(
      titleTextStyle: f(base.appBarTheme.titleTextStyle),
      toolbarTextStyle: f(base.appBarTheme.toolbarTextStyle),
    ),
  );
}

/// 未加载的字体族检查（T17-1 断言）：返回树里指定了"非已加载族"的字体集合。
///
/// 这类文字一定会渲染成豆腐块/实心块，所以必须为空。
Set<String> _unloadedFontFamilies(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text, skipOffstage: false))
    .map((text) => text.style?.fontFamily)
    .whereType<String>()
    .where((family) => family != _shotFontFamily && family != 'MaterialIcons' && family != 'monospace')
    .toSet();

/// 文字"墨迹率"（T17-1 断言）：实心块（Ahem 兜底）会接近满格，真实字形明显更低。
Future<double> _inkRatio(WidgetTester tester, String text) async {
  final key = GlobalKey();
  await tester.pumpWidget(
    MaterialApp(
      theme: _shotTheme(true),
      home: RepaintBoundary(
        key: key,
        child: ColoredBox(
          color: const Color(0xFF000000),
          child: SizedBox(
            width: 420,
            height: 56,
            child: Center(
              child: Text('  $text  ', style: const TextStyle(fontSize: 18)),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final pixels = await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1.0);
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    return data?.buffer.asUint8List();
  });
  if (pixels == null || pixels.isEmpty) return 0;
  var ink = 0;
  for (var i = 0; i + 3 < pixels.length; i += 4) {
    if (pixels[i] > 64 || pixels[i + 1] > 64 || pixels[i + 2] > 64) ink++;
  }
  return ink / (pixels.length / 4);
}

/// 当前截图树上的 RepaintBoundary（保活同一棵树时复用，R2-1）。
GlobalKey? _boundaryKey;

Future<void> _pumpTree(
  WidgetTester tester,
  Widget Function() pageBuilder, {
  required Size size,
  bool dark = true,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final key = GlobalKey();
  _boundaryKey = key;
  // 截图必须同时切换全局 palette，否则 dark 主题下 pal.* 仍是浅色，
  // 生成“浅色卡片 + 浅色文字”的假截图。
  LoopTheme.palette = dark ? LoopPalette.dark : LoopPalette.light;
  await tester.pumpWidget(
    RepaintBoundary(
      key: key,
      child: MaterialApp(
        theme: _shotTheme(dark),
        home: Scaffold(body: Builder(builder: (_) => pageBuilder())),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 在**当前**树上截图（不重建 widget —— R2-1：同一 SubjectScreen 实例保活）。
Future<void> _capture(WidgetTester tester, String name, {bool dark = true}) async {
  final key = _boundaryKey;
  if (key == null) throw StateError('先 _pumpTree 再 _capture（$name）');
  final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final bytes = await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1.0);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data?.buffer.asUint8List();
  });
  final file = File('$_screenDir/$name');
  file.parent.createSync(recursive: true);
  file.writeAsBytesSync(bytes ?? Uint8List(0));
  // 溢出等渲染异常记为证据（不直接失败；AC-07 断言 1 用报告检查）。
  final exception = tester.takeException();
  if (exception != null) {
    _overflows.add('$name: ${exception.toString().split('\n').first}');
  }
  expect(file.existsSync() && file.lengthSync() > 1000, isTrue, reason: '$name 未生成');
}

Future<void> _shot(
  WidgetTester tester,
  Widget page, {
  required String name,
  required Size size,
  bool dark = true,
  Future<void> Function()? before,
}) async {
  await _pumpTree(tester, () => page, size: size, dark: dark);
  if (before != null) {
    await before();
    await tester.pumpAndSettle();
  }
  await _capture(tester, name, dark: dark);
}

/// 渲染一个小部件并返回 PNG 字节（字形验证用）。
Future<Uint8List> _renderBytes(WidgetTester tester, Widget child) async {
  final key = GlobalKey();
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: RepaintBoundary(
        key: key,
        child: Center(child: ColoredBox(color: const Color(0xFFFFFFFF), child: child)),
      ),
    ),
  );
  await tester.pumpAndSettle();
  final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final bytes = await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1.0);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data?.buffer.asUint8List();
  });
  return bytes ?? Uint8List(0);
}

/// 截图过程中观测到的渲染异常（写入 evidence 报告）。
final List<String> _overflows = <String>[];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await _loadSystemFonts();
  });

  testWidgets('AC-07：生成 12 张截图到 docs/evidence/subject-v0.8.0/screens/', (tester) async {
    final api = _ShotApi();
    final state = AppState(api: api)
      ..settings = await api.settings();
    await state.loadSubjects();
    await state.refreshConversations();

    const wide = Size(1440, 900);
    Widget chat() => ChatScreen(active: true, state: state);
    Widget sidebar({bool compact = false}) =>
        Sidebar(index: 0, onSelect: (_) {}, compact: compact, state: state);
    Widget subjectScreen() => SubjectScreen(active: true, state: state);
    Widget skills() => SkillsPanel(subjectId: 1, subjectKey: 's_lin', state: state);
    Widget materials() => MaterialsScreen(active: true, state: state);
    Widget settings() => SettingsScreen(active: true, state: state);

    // R2-2：先证明"已加载的族"确实被用于中文渲染（与一个不存在的族对比，
// 位图必须不同——否则说明字形来自测试兜底字体/豆腐块）。
    final loaded = await _renderBytes(
      tester,
      const Text('线性代数 特征值', style: TextStyle(fontFamily: _shotFontFamily, fontSize: 24)),
    );
    final missing = await _renderBytes(
      tester,
      const Text('线性代数 特征值', style: TextStyle(fontFamily: 'NoSuchFamily-xyz', fontSize: 24)),
    );
    expect(_fontsLoaded, isTrue, reason: '系统 CJK 字体未加载成功');
    expect(_iconsLoaded, isTrue, reason: 'Material 图标字体未加载（截图会有方框）');
    expect(loaded, isNot(equals(missing)), reason: '字形未来自已加载字体（可能渲染成 □）');

    // T17-1：墨迹率检查（实心块 ≈ 每字满格；真实字形笔画细，低一个数量级）。
    // 参考量级：6 字 18px 在 420×56 画布上，真实字形 ≈0.002–0.02，
    // Ahem 实心块 ≈0.07–0.10，因此下界防"空"，上界防"块"。
    for (final label in ['检查更新（全部）', '数据与迁移', '从 EduHub 添加', '掌握度']) {
      final ratio = await _inkRatio(tester, label);
      expect(ratio, greaterThan(0.0005), reason: '「$label」没画出来（墨迹率 $ratio）');
      expect(ratio, lessThan(0.05),
          reason: '「$label」疑似实心块/豆腐块（墨迹率 $ratio 接近满格）');
    }

    await _shot(tester, chat(), name: '01-chat-light-1440.png', size: wide, dark: false);
    await _shot(tester, chat(), name: '02-chat-dark-1440.png', size: wide);
    await _shot(tester, sidebar(), name: '03-sidebar-subject-switcher-dark.png', size: wide);

    // R2-1：04/05 用**同一棵** SubjectScreen 树（切 tab 不重建 widget）。
    await _pumpTree(tester, subjectScreen, size: wide);
    // T17-1：该树里不得有文字指定了未加载的字体族（一定会渲染成豆腐块）。
    expect(_unloadedFontFamilies(tester), isEmpty, reason: '04 树里有未加载字体族');
    await _capture(tester, '04-subject-overview-dark-1440.png');
    await tester.tap(find.byKey(const Key('subject-tab-1')));
    await tester.pumpAndSettle();
    // 05 必须真的是进度 tab：知识点列表 + 掌握度。
    expect(find.textContaining('特征值与特征向量'), findsWidgets,
        reason: '05 截图必须显示知识点列表（进度 tab）');
    expect(_unloadedFontFamilies(tester), isEmpty, reason: '05 树里有未加载字体族');
    await _capture(tester, '05-subject-progress-dark-1440.png');
    await _shot(tester, skills(), name: '06-subject-skills-installed-dark-1440.png', size: wide);
    await _shot(
      tester,
      skills(),
      name: '07-skill-detail-drawer-dark.png',
      size: const Size(900, 860),
      before: () async {
        await tester.tap(find.byKey(const Key('skill-menu-learn-ai-architect')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('skill-detail-learn-ai-architect')));
        await tester.pumpAndSettle();
        // 07 必须真的是详情抽屉：许可/sha256/签名事实都在画面上。
        expect(find.textContaining('许可'), findsWidgets, reason: '07 必须是技能详情抽屉');
        expect(_unloadedFontFamilies(tester), isEmpty, reason: '07 树里有未加载字体族');
      },
    );
    await _shot(tester, materials(), name: '08-narrow-900x600-dark.png', size: const Size(900, 600));
    await _shot(
      tester,
      materials(),
      name: '09-narrow-900x600-light.png',
      size: const Size(900, 600),
      dark: false,
    );
    await _shot(
      tester,
      sidebar(compact: true),
      name: '10-compact-sidebar-76-dark.png',
      size: const Size(900, 600),
    );
    await _shot(
      tester,
      chat(),
      name: '11-floating-360x420-dark.png',
      size: const Size(360, 420),
    );
    // T17-2：12 号图必须真的拍到「数据与迁移」卡片（设置页很长，先滚到底部）。
    await _shot(
      tester,
      settings(),
      name: '12-migration-progress.png',
      size: const Size(1440, 900),
      before: () async {
        final card = find.byKey(const Key('settings-data-migration'));
        expect(card, findsOneWidget, reason: '设置页缺少数据与迁移卡片');
        await tester.scrollUntilVisible(
          card,
          240,
          scrollable: find.byType(Scrollable).first,
          maxScrolls: 40,
        );
        await tester.pumpAndSettle();
        final box = tester.getRect(card);
        expect(box.top, greaterThanOrEqualTo(0), reason: '卡片应滚入可视区');
        expect(box.bottom, lessThanOrEqualTo(900), reason: '卡片应完整落在画面内');
        expect(find.textContaining('迁移'), findsWidgets, reason: '12 号图必须有迁移文案');
        expect(_unloadedFontFamilies(tester), isEmpty, reason: '12 树里有未加载字体族');
      },
    );

    final dir = Directory(_screenDir);
    // 16 张 PNG = 12 张 AC-07 主图 + 4 张 t8 真机图（real-*），全部要求两两互异。
    final files = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.png'))
        .toList();
    final main = files
        .where((f) => !f.uri.pathSegments.last.startsWith('real-'))
        .toList();
    expect(main.length, 12, reason: 'AC-07 要求 12 张主图');
    expect(files.length, 16, reason: '12 张主图 + 4 张真机图 = 16 张');
    for (final file in files) {
      expect(file.lengthSync(), greaterThan(1000), reason: '${file.path} 内容过小');
    }
    // T17-1/R2-1：16 张截图必须两两不同（sha256 互异，避免"同一张图凑数"）。
    final digests = <String, String>{};
    for (final file in files) {
      final digest = sha256.convert(file.readAsBytesSync()).toString();
      final path = file.uri.pathSegments.last;
      expect(digests.containsKey(digest), isFalse,
          reason: '$path 与 ${digests[digest]} 像素完全相同（sha256 相同）');
      digests[digest] = path;
    }
    expect(digests.length, 16, reason: '16 张 PNG sha256 必须两两互异');
    File('$_screenDir/OVERFLOW.txt').writeAsStringSync(
      _overflows.isEmpty ? 'no rendering overflow\n' : '${_overflows.join('\n')}\n',
    );
    expect(_overflows, isEmpty, reason: 'AC-07 断言 1：截图过程中不得有 overflow');
  });
}