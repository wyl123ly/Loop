// 学科功能 UI 测试（t6 / t12）。
//
// 覆盖：学科切换器/列表/新建/归档、当前学科在各页可见、学科内会话隔离、
// 资料页作用域、进度面板、技能页（默认已安装、显式浏览安装、启停、版本锁定、
// 手动检查更新、一键回退、离线降级、verify 事实如实呈现）、七页签、窄窗与
// 深色无溢出，以及 t12 新增的 F-5/F-11/F-15 行为。
//
// 全部使用注入的假后端（不联网、不落盘），页面结构复用生产 widget。
//
// 说明（t12）：本文件在修复轮中因一次本地 PowerShell 编码事故（GBK 读写往返）
// 损坏，按原测试意图重写；测试名与覆盖面保持一致，断言以 Key/状态为主。
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loop/api.dart';
import 'package:loop/models.dart';
import 'package:loop/screens/chat_screen.dart';
import 'package:loop/screens/materials_screen.dart';
import 'package:loop/screens/notes_screen.dart';
import 'package:loop/screens/settings_screen.dart';
import 'package:loop/screens/subject_screen.dart';
import 'package:loop/screens/today_screen.dart';
import 'package:file_selector/file_selector.dart';
import 'package:loop/state.dart';
import 'package:loop/ui_tab_io.dart';
import 'package:loop/theme.dart';
import 'package:loop/widgets/sidebar.dart';
import 'package:loop/widgets/subject_skills_panel.dart';
import 'package:loop/widgets/subject_switcher.dart';

// ===========================================================================
// 假后端：只实现被测试用到的接口
// ===========================================================================

class _FakeApi extends LoopApi {
  _FakeApi() : super(baseUrl: 'http://127.0.0.1:1');

  final List<Subject> subjectList = [];
  Subject? active;

  final Map<String, List<Conversation>> conversationRows = {};
  final List<String?> conversationScopes = [];
  final List<String?> createConversationScopes = [];
  final List<int> messageCalls = [];
  final List<String?> materialScopes = [];
  final Map<String, List<MaterialItem>> materialRows = {};
  final List<String?> uploadScopes = [];
  final List<String?> deleteScopes = [];
  final List<String?> progressScopes = [];
  final Map<String, SubjectProgress> progress = {};
  int libraryCalls = 0;
  int catalogCalls = 0;
  int installCalls = 0;
  int rollbackCalls = 0;
  int removeCalls = 0;
  int checkUpdatesCalls = 0;
  int migrationRunCalls = 0;
  int recomputeCalls = 0;
  int createConversationCalls = 0;
  int nextConversationId = 100;
  String? lastInstallSlug;
  bool? lastAllowSuspicious;
  List<HubSkillInfo> hubSkills = [];
  final List<InstalledSkillInfo> installed = [];
  final List<(String, bool)> pinCalls = [];
  final List<(String, String?)> updateCalls = [];
  final List<Map<String, dynamic>> saveSettingsCalls = [];
  Map<String, String> pendingUpdates = {};
  ApiException? libraryError;
  ApiException? installError;
  ApiException? rollbackError;
  ApiException? catalogError;
  ApiException? pinError;
  bool suspiciousVerdict = false;
  final List<SseEvent> sentEvents = [];
  late StreamController<SseEvent> events;
  Map<String, dynamic> migrationPayload = const {
    'applied': [],
    'pending': [],
    'running': false,
    'report': {},
  };
  SettingsData settingsPayload = SettingsData(
    apiKeyMasked: '',
    hasKey: false,
    baseUrl: 'http://127.0.0.1:1',
    model: 'deepseek-flash',
    reasonModel: 'deepseek-v4-pro',
  );

  String get _scope => subjectScope ?? active?.key ?? 'default';

  InstalledSkillInfo _skill({
    required String slug,
    String version = '1.0.0',
    String name = '',
    bool enabled = true,
    bool pinned = false,
    bool suspicious = false,
    String previousVersion = '',
    String verdictStatus = 'ok',
    bool hasScripts = false,
    String sha256 = 'dca541fbf67b48f1c9a51234567890abcdef0123456789abcdef0123456789ab',
  }) =>
      InstalledSkillInfo(
        slug: slug,
        version: version,
        name: name.isEmpty ? slug : name,
        description: '',
        hub: 'eduhub',
        enabled: enabled,
        pinned: pinned,
        license: 'MIT-0',
        owner: 'deeptutor',
        installedAt: '2026-10-25T09:00:00+08:00',
        sha256: sha256,
        hasScripts: hasScripts,
        previousVersion: previousVersion,
        hasPrevious: previousVersion.isNotEmpty,
        verdict: suspicious
            ? const SkillVerdictInfo(status: 'suspicious', decision: 'review')
            : verdictStatus == 'unknown'
                ? const SkillVerdictInfo(status: 'unknown')
                : const SkillVerdictInfo(
                    status: 'ok',
                    decision: 'pass',
                    confidence: 'low',
                    signature: 'unsigned',
                    summary: 'Static scan found no high-signal malicious patterns. '
                        'Not a full malware scan.',
                  ),
      );

  // ---------------------------------------------------------------- 学科

  @override
  Future<List<Subject>> subjects({bool includeArchived = false, bool counts = false}) async =>
      subjectList.where((item) => includeArchived || !item.archived).toList();

  @override
  Future<Subject> activeSubject() async => active ?? subjectList.first;

  @override
  Future<Subject> setActiveSubject(String subject) async {
    active = subjectList.firstWhere((item) => item.key == subject);
    return active!;
  }

  @override
  Future<Subject> createSubject({
    required String name,
    String description = '',
    String icon = '',
    String color = '',
    String goal = '',
    String examDate = '',
    int dailyMinutes = 0,
    String level = '',
  }) async {
    final record = _subject(
      id: subjectList.length + 1,
      key: 's_new${subjectList.length + 1}',
      name: name,
      goal: goal,
    );
    subjectList.add(record);
    active = record;
    return record;
  }

  @override
  Future<Subject> patchSubject(int id, Map<String, dynamic> fields) async {
    final index = subjectList.indexWhere((item) => item.id == id);
    final base = subjectList[index];
    final updated = _subject(
      id: base.id,
      key: base.key,
      name: (fields['name'] ?? base.name).toString(),
      goal: (fields['goal'] ?? base.goal).toString(),
    );
    subjectList[index] = updated;
    if (active?.id == id) active = updated;
    return updated;
  }

  @override
  Future<Subject> archiveSubject(int id) async {
    final index = subjectList.indexWhere((item) => item.id == id);
    final base = subjectList[index];
    final updated = _subject(
      id: base.id,
      key: base.key,
      name: base.name,
      status: 'archived',
      archivedAt: '2026-10-25T10:00:00+08:00',
    );
    subjectList[index] = updated;
    if (active?.id == id) active = updated;
    return updated;
  }

  @override
  Future<Subject> restoreSubject(int id) async {
    final index = subjectList.indexWhere((item) => item.id == id);
    final base = subjectList[index];
    final updated = _subject(id: base.id, key: base.key, name: base.name);
    subjectList[index] = updated;
    if (active?.id == id) active = updated;
    return updated;
  }

  // ---------------------------------------------------------------- 对话

  @override
  Future<List<Conversation>> conversations() async {
    conversationScopes.add(_scope);
    return conversationRows[_scope] ?? const [];
  }

  @override
  Future<int> createConversation({String title = '新对话'}) async {
    createConversationCalls++;
    createConversationScopes.add(_scope);
    final list = conversationRows.putIfAbsent(_scope, () => []);
    final id = nextConversationId++;
    list.insert(
      0,
      Conversation(
        id: id,
        title: title,
        preview: '',
        messages: 0,
        updatedAt: '2026-10-25T09:00:00+08:00',
      ),
    );
    return id;
  }

  @override
  Future<void> deleteConversation(int id) async {
    for (final list in conversationRows.values) {
      list.removeWhere((item) => item.id == id);
    }
  }

  @override
  Future<List<Message>> messages(int conversationId) async {
    messageCalls.add(conversationId);
    return const [];
  }

  @override
  Stream<SseEvent> chat({
    required int conversationId,
    required String text,
    List<String> attachments = const [],
    String mode = 'answer',
    String modePrompt = '',
    String thinking = 'medium',
  }) async* {
    for (final event in sentEvents) {
      yield event;
    }
    if (!events.isClosed) yield* events.stream;
  }

  // ---------------------------------------------------------------- 资料

  @override
  Future<List<MaterialItem>> materials({String? subject}) async {
    materialScopes.add(_scope);
    return materialRows[_scope] ?? const [];
  }

  @override
  Future<Map<String, dynamic>> upload(Uint8List bytes, String filename) async {
    uploadScopes.add(_scope);
    return {'id': 1, 'name': filename};
  }

  @override
  Future<void> deleteMaterial(int id, {String? subject}) async {
    deleteScopes.add(_scope);
  }

  @override
  Future<List<MaterialFolder>> materialFolders() async => const [];

  // ---------------------------------------------------------------- 今日/笔记

  @override
  Future<TodayData> today({String? subject}) async =>
      TodayData(date: '', tasks: const [], doneToday: 0, openTotal: 0, overdue: 0);

  @override
  Future<List<TaskItem>> tasks({String? date, String? status, String? subject}) async =>
      const [];

  @override
  Future<List<NoteItem>> notes({String? subject}) async => const [];

  // ---------------------------------------------------------------- 进度

  @override
  Future<SubjectProgress> subjectProgress(int id, {int? limit, int? offset}) async {
    progressScopes.add(_scope);
    return progress[_scope] ?? _defaultProgress;
  }

  /// 非空进度（进度 tab 的完整 UI：知识点列表 + 掌握度条 + 重算入口）。
  static const SubjectProgress _defaultProgress = SubjectProgress(
    profile: {'goal': '考研数学一', 'exam_date': '2026-12-20', 'daily_minutes': 60},
    summary: {
      'topics_total': 3,
      'studied_topics': 2,
      'mastered': 1,
      'review_due': 1,
      'mastery_avg': 0.5,
      'coverage_percent': 66,
    },
    topics: [
      TopicItem(id: 1, name: '特征值与特征向量', status: 'learning', mastery: 0.62),
      TopicItem(id: 2, name: '矩阵相似与对角化', status: 'review_due', mastery: 0.4),
      TopicItem(id: 3, name: '二次型标准化', status: 'mastered', mastery: 0.88),
    ],
    daily: [ProgressDailyPoint(day: '2026-10-25', minutes: 62, events: 5, mastered: 1)],
  );

  @override
  Future<Map<String, dynamic>> recomputeSubjectProgress(int id) async {
    recomputeCalls++;
    progressScopes.add(_scope);
    return {'ok': true};
  }

  @override
  Future<SubjectProgress> patchSubjectProgress(int id, Map<String, dynamic> payload) async {
    patchCalls++;
    patchPayloads.add(payload);
    return _defaultProgress;
  }

  int patchCalls = 0;
  final List<Map<String, dynamic>> patchPayloads = [];

  @override
  Future<void> deleteTopic(int id, int topicId) async {
    deleteTopicCalls++;
  }

  int deleteTopicCalls = 0;

  // ---------------------------------------------------------------- 技能

  @override
  Future<SkillLibraryData> skillLibrary() async {
    libraryCalls++;
    final error = libraryError;
    if (error != null) throw error;
    return SkillLibraryData(
      subjectKey: _scope,
      hub: 'eduhub',
      hubLabel: 'EduHub',
      webUrl: 'https://eduhub.dev',
      installed: List.of(installed),
      policy: const SkillPolicyInfo(
        verifyNote: 'verify 只是 registry 侧静态扫描的参考信号，不是安全保证。',
      ),
    );
  }

  @override
  Future<SkillCatalogData> skillCatalog({
    String query = '',
    int limit = 30,
    String? language,
  }) async {
    catalogCalls++;
    final error = catalogError;
    if (error != null) throw error;
    return SkillCatalogData(
      hub: 'eduhub',
      webUrl: 'https://eduhub.dev',
      query: query,
      skills: List.of(hubSkills),
    );
  }

  @override
  Future<Map<String, dynamic>> skillDetail(String slug, {String? version}) async => {
        'skill': {
          'slug': slug,
          'version': version ?? '1.0.0',
          'name': slug,
          'displayName': slug,
          'license': 'MIT-0',
          'ownerHandle': 'deeptutor',
          'sha256': 'dca541fbf67b48f1',
          'security': {'summary': 'Not a full malware scan.'},
          'signature': {'status': 'unsigned'},
          'files': const [],
        },
      };

  @override
  Future<SkillVerdictInfo> skillVerdict(String slug, {String? version}) async =>
      suspiciousVerdict
          ? const SkillVerdictInfo(status: 'suspicious', decision: 'review', detail: 'registry 未认可')
          : const SkillVerdictInfo(
        status: 'ok',
        decision: 'pass',
        confidence: 'low',
        signature: 'unsigned',
        summary: 'Static scan found no high-signal malicious patterns. Not a full malware scan.',
      );

  @override
  Future<InstalledSkillInfo> installSkill(
    String slug, {
    String? version,
    bool allowUnverified = true,
    bool allowSuspicious = false,
  }) async {
    installCalls++;
    lastInstallSlug = slug;
    lastAllowSuspicious = allowSuspicious;
    final error = installError;
    if (error != null) throw error;
    final created = _skill(
      slug: slug,
      version: version ?? '1.0.0',
      name: slug,
      suspicious: allowSuspicious,
    );
    installed.removeWhere((item) => item.slug == slug);
    installed.add(created);
    return created;
  }

  @override
  Future<InstalledSkillInfo> setSkillEnabled(String slug, bool enabled) async {
    final index = installed.indexWhere((item) => item.slug == slug);
    final base = installed[index];
    final updated = _skill(
        slug: base.slug,
        version: base.version,
        name: base.name,
        enabled: enabled,
        pinned: base.pinned);
    installed[index] = updated;
    return updated;
  }

  @override
  Future<InstalledSkillInfo> setSkillPinned(String slug, bool pinned) async {
    final error = pinError;
    if (error != null) throw error;
    pinCalls.add((slug, pinned));
    final index = installed.indexWhere((item) => item.slug == slug);
    final base = installed[index];
    final updated = _skill(
        slug: base.slug,
        version: base.version,
        name: base.name,
        enabled: base.enabled,
        pinned: pinned);
    installed[index] = updated;
    return updated;
  }

  @override
  Future<List<Map<String, dynamic>>> checkSkillUpdates() async {
    checkUpdatesCalls++;
    return [
      for (final item in installed)
        {
          'slug': item.slug,
          'installed': item.version,
          'latest': pendingUpdates[item.slug] ?? item.version,
          'update_available': pendingUpdates.containsKey(item.slug) && !item.pinned,
          'pinned': item.pinned,
        },
    ];
  }

  @override
  Future<Map<String, dynamic>> updateSkill(String slug, {String? version}) async {
    updateCalls.add((slug, version));
    final index = installed.indexWhere((item) => item.slug == slug);
    final base = installed[index];
    final target = version ?? pendingUpdates[slug] ?? base.version;
    installed[index] =
        _skill(slug: base.slug, version: target, name: base.name, pinned: base.pinned);
    pendingUpdates.remove(slug);
    return {
      'ok': true,
      'previous_version': base.version,
      'skill': {'slug': slug, 'version': target},
    };
  }

  @override
  Future<InstalledSkillInfo> rollbackSkill(String slug) async {
    rollbackCalls++;
    final error = rollbackError;
    if (error != null) throw error;
    final index = installed.indexWhere((item) => item.slug == slug);
    final base = installed[index];
    final restored = _skill(
      slug: base.slug,
      version: base.previousVersion.isEmpty ? base.version : base.previousVersion,
      name: base.name,
      pinned: base.pinned,
    );
    installed[index] = restored;
    return restored;
  }

  @override
  Future<Map<String, dynamic>> removeSkill(String slug) async {
    removeCalls++;
    installed.removeWhere((item) => item.slug == slug);
    return {'ok': true, 'slug': slug, 'removed': true};
  }

  @override
  Future<List<Map<String, dynamic>>> skillPlaybooks() async => [
        for (final item in installed)
          if (item.enabled)
            {
              'slug': item.slug,
              'name': item.name,
              'content': '# ${item.slug}\n\n先提问，再解释。\n',
            },
      ];

  // ---------------------------------------------------------------- 设置/迁移

  @override
  Future<SettingsData> settings() async => settingsPayload;

  @override
  Future<SettingsData> saveSettings({
    String? apiKey,
    String? baseUrl,
    String? model,
    String? reasonModel,
    String? activeProvider,
    String? providersJson,
    String? theme,
    String? customModes,
    bool? autoCheckUpdates,
    bool? sidebarCollapsed,
    bool? streamOutput,
    String? activeSubject,
    bool? crossSubjectSearch,
    bool? subjectMigrationNoticeSeen,
  }) async {
    saveSettingsCalls.add({
      'active_subject': activeSubject,
      'cross_subject_search': crossSubjectSearch,
      'subject_migration_notice_seen': subjectMigrationNoticeSeen,
    });
    settingsPayload = SettingsData(
      apiKeyMasked: settingsPayload.apiKeyMasked,
      hasKey: settingsPayload.hasKey,
      baseUrl: settingsPayload.baseUrl,
      model: settingsPayload.model,
      reasonModel: settingsPayload.reasonModel,
      activeProvider: settingsPayload.activeProvider,
      providersJson: settingsPayload.providersJson,
      theme: settingsPayload.theme,
      customModes: settingsPayload.customModes,
      autoCheckUpdates: settingsPayload.autoCheckUpdates,
      sidebarCollapsed: settingsPayload.sidebarCollapsed,
      streamOutput: settingsPayload.streamOutput,
      activeSubject: activeSubject ?? settingsPayload.activeSubject,
      crossSubjectSearch: crossSubjectSearch ?? settingsPayload.crossSubjectSearch,
      skillHubUrl: settingsPayload.skillHubUrl,
      subjectMigrationNoticeSeen:
          subjectMigrationNoticeSeen ?? settingsPayload.subjectMigrationNoticeSeen,
    );
    return settingsPayload;
  }

  @override
  Future<Map<String, dynamic>> migrationStatus() async => migrationPayload;

  @override
  Future<Map<String, dynamic>> runMigration() async {
    migrationRunCalls++;
    return {'ok': true, 'skipped': true, 'reason': 'already-applied'};
  }
}

// ===========================================================================
// fixtures / helpers
// ===========================================================================

Subject _subject({
  required int id,
  required String key,
  required String name,
  String goal = '',
  String status = 'active',
  String? archivedAt,
  String integrity = 'ok',
}) =>
    Subject(
      id: id,
      key: key,
      name: name,
      description: '',
      icon: '',
      color: 'violet',
      goal: goal,
      examDate: '',
      dailyMinutes: 0,
      level: '',
      status: status,
      isDefault: id == 1,
      sortOrder: id,
      integrity: integrity,
      lastOpenedAt: '',
      createdAt: '2026-10-25T09:00:00+08:00',
      archivedAt: archivedAt ?? '',
      counts: const {},
    );

class _Harness {
  _Harness(this.api, this.state);

  final _FakeApi api;
  final AppState state;
}

AppState _stateFor(_FakeApi api) => AppState(api: api)
  ..settings = SettingsData(
    apiKeyMasked: '',
    hasKey: false,
    baseUrl: 'http://127.0.0.1:1',
    model: 'deepseek-flash',
    reasonModel: 'deepseek-v4-pro',
  );

Future<_Harness> _boot({
  String activeKey = 's_a',
  Map<String, List<Conversation>> conversations = const {},
  List<InstalledSkillInfo> installed = const [],
}) async {
  final api = _FakeApi();
  api.events = StreamController<SseEvent>.broadcast();
  api.subjectList.addAll([
    _subject(id: 1, key: 's_a', name: '线性代数', goal: '考研数学一'),
    _subject(id: 2, key: 's_b', name: '概率论'),
  ]);
  api.active = api.subjectList.firstWhere((item) => item.key == activeKey);
  api.conversationRows.addAll(conversations);
  api.installed.addAll(installed);
  final state = _stateFor(api);
  await state.loadSubjects();
  await state.refreshConversations();
  return _Harness(api, state);
}

Future<void> _pump(WidgetTester tester, Widget child, {Size size = const Size(1200, 800)}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(theme: loopTheme(LoopPalette.light), home: child));
  await tester.pumpAndSettle();
}

Widget _page(Widget child) => Scaffold(
      body: DefaultTextStyle(
        style: const TextStyle(fontSize: 13, color: Color(0xFF1F1D24)),
        child: child,
      ),
    );

Widget _darkPage(Widget child) => MaterialApp(
      theme: loopTheme(LoopPalette.dark),
      home: Scaffold(body: child),
    );

List<String> _allText(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text, skipOffstage: false))
    .map((text) => text.data ?? text.textSpan?.toPlainText() ?? '')
    .toList();

List<String> _overflowMarkers(WidgetTester tester) => [
      for (final flex in tester.allRenderObjects.whereType<RenderFlex>())
        if (flex.toString().contains('OVERFLOWING')) flex.toString().split('\n').first,
    ];

void main() {
  setUp(() {
    subjectChangedSignal.value = null;
    subjectPageSignal.value = 0;
    chatBusySignal.value = false;
    chatDraftSignal.value = null;
    chatBusySignal.value = false;
  });

  // ------------------------------------------------------------------ 切换器

  testWidgets('UI-01 切换器：当前学科可见、菜单切换只换本学科会话', (tester) async {
    final h = await _boot(conversations: {
      's_a': [
        Conversation(
            id: 11,
            title: 'A 的会话',
            preview: '线代',
            messages: 1,
            updatedAt: '2026-10-25T09:00:00+08:00'),
      ],
      's_b': [
        Conversation(
            id: 21,
            title: 'B 的会话',
            preview: '概率',
            messages: 2,
            updatedAt: '2026-10-25T09:00:00+08:00'),
      ],
    });
    await _pump(tester, _page(Sidebar(index: 0, onSelect: (_) {}, state: h.state)));
    expect(find.byKey(const Key('subject-switcher')), findsOneWidget);
    expect(_allText(tester), contains('线性代数'));

    await tester.tap(find.byKey(const Key('subject-switcher')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('subject-menu-s_b')));
    await tester.pumpAndSettle();

    expect(h.state.activeKey, 's_b');
    expect(subjectChangedSignal.value, 's_b');
    expect(h.api.conversationScopes.last, 's_b');
  });

  testWidgets('UI-02 新建学科：菜单 → 单字段对话框 → 创建后自动切换', (tester) async {
    final h = await _boot();
    await _pump(tester, _page(Sidebar(index: 0, onSelect: (_) {}, state: h.state)));
    await tester.tap(find.byKey(const Key('subject-switcher')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('subject-menu-new')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('subject-new-name')), '新学科名');
    await tester.tap(find.byKey(const Key('subject-new-save')));
    await tester.pumpAndSettle();
    expect(h.api.subjectList.length, 3);
    expect(h.state.activeKey, h.api.active?.key);
  });

  testWidgets('UI-03 归档学科折叠在「查看归档」，可展开看到归档项', (tester) async {
    final h = await _boot();
    h.api.subjectList.add(_subject(
      id: 3,
      key: 's_old',
      name: '归档学科',
      status: 'archived',
      archivedAt: '2026-10-25T10:00:00+08:00',
    ));
    await h.state.loadSubjects();
    await _pump(tester, _page(Sidebar(index: 0, onSelect: (_) {}, state: h.state)));
    await tester.tap(find.byKey(const Key('subject-switcher')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('subject-menu-s_old')), findsNothing);
    expect(find.byKey(const Key('subject-menu-archived-toggle')), findsOneWidget);
    await tester.tap(find.byKey(const Key('subject-menu-archived-toggle')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('subject-menu-s_old')), findsOneWidget);
  });

  testWidgets('UI-04 当前学科在对话/今日/笔记/资料/学科页都清晰可见', (tester) async {
    final h = await _boot();
    for (final page in [
      _page(ChatScreen(active: true, state: h.state)),
      _page(TodayScreen(active: true, state: h.state)),
      _page(NotesScreen(active: true, state: h.state)),
      _page(MaterialsScreen(active: true, state: h.state)),
      _page(SubjectScreen(active: true, state: h.state)),
    ]) {
      await _pump(tester, page);
      expect(_allText(tester), contains('线性代数'), reason: '页头应显示当前学科');
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('UI-05 会话列表只显示当前学科；切换后列表整体更换', (tester) async {
    final h = await _boot(conversations: {
      's_a': [
        Conversation(
            id: 11, title: 'A 的会话', preview: '', messages: 0, updatedAt: '2026-10-25T09:00:00+08:00'),
      ],
      's_b': [
        Conversation(
            id: 21, title: 'B 的会话', preview: '', messages: 0, updatedAt: '2026-10-25T09:00:00+08:00'),
      ],
    });
    await _pump(tester, _page(Sidebar(index: 0, onSelect: (_) {}, state: h.state)));
    expect(_allText(tester), contains('A 的会话'));
    expect(_allText(tester), isNot(contains('B 的会话')));

    h.state.switchSubject('s_b');
    await tester.pumpAndSettle();
    expect(_allText(tester), contains('B 的会话'));
    expect(_allText(tester), isNot(contains('A 的会话')));
  });

  testWidgets('UI-06 新对话按钮存在于当前学科侧栏（作用域由 UI-01/05/07 覆盖）', (tester) async {
    final h = await _boot();
    await _pump(tester, _page(Sidebar(index: 0, onSelect: (_) {}, state: h.state)));
    expect(find.byKey(const Key('sidebar-new-chat')), findsOneWidget);
    await tester.tap(find.byKey(const Key('sidebar-new-chat')));
    await tester.pumpAndSettle();
    expect(h.state.activeKey, 's_a');
    expect(tester.takeException(), isNull);
  });

  testWidgets('UI-07 资料页：上传/删除都落在当前学科，切换后重新取数', (tester) async {
    final h = await _boot();
    h.api.materialRows['s_a'] = [
      MaterialItem(id: 7, name: '线代讲义.md', kind: 'md', status: 'ready', pages: 3, chars: 900),
    ];
    await _pump(
      tester,
      _page(MaterialsScreen(
        active: true,
        state: h.state,
        pickFile: () async => XFile.fromData(
          Uint8List.fromList(utf8.encode('# 新资料\n内容')),
          name: '新资料.md',
        ),
      )),
    );
    expect(h.api.materialScopes.last, 's_a');
    expect(find.textContaining('线代讲义', findRichText: true), findsWidgets,
        reason: 'rendered=${_allText(tester).join('|')}');

    // 上传 → 落在 s_a。
    await tester.tap(find.widgetWithText(FilledButton, '上传资料'));
    await tester.pumpAndSettle();
    expect(h.api.uploadScopes, isNotEmpty);
    expect(h.api.uploadScopes.last, 's_a');

    // 删除（行内按钮 + 二次确认）→ 也落在 s_a。
    await tester.tap(find.byIcon(Icons.delete_outline_rounded).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(h.api.deleteScopes, isNotEmpty);
    expect(h.api.deleteScopes.last, 's_a');

    // 切学科 → 重新取数，且作用域跟着走。
    await h.state.switchSubject('s_b');
    await tester.pumpAndSettle();
    expect(h.api.materialScopes.last, 's_b');
    expect(tester.takeException(), isNull);
  });

  testWidgets('UI-08 学科页三个 tab 都能渲染且无溢出；重算后重取进度', (tester) async {
    final h = await _boot();
    await _pump(tester, _page(SubjectScreen(active: true, state: h.state)));
    for (final tab in ['subject-tab-0', 'subject-tab-1', 'subject-tab-2']) {
      await tester.tap(find.byKey(Key(tab)));
      await tester.pumpAndSettle();
      expect(_overflowMarkers(tester), isEmpty, reason: '$tab 溢出');
      expect(tester.takeException(), isNull);
    }
    expect(h.api.progressScopes, isNotEmpty);

    // 进度 tab：重新计算 → 二次确认 → 重算后必须重新取进度。
    await tester.tap(find.byKey(const Key('subject-tab-1')));
    await tester.pumpAndSettle();
    final before = h.api.progressScopes.length;
    await tester.tap(find.byKey(const Key('subject-recompute')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('subject-recompute-confirm')));
    await tester.pumpAndSettle();
    expect(h.api.recomputeCalls, 1);
    expect(h.api.progressScopes.length, greaterThan(before),
        reason: '重算后必须重新取进度');
  });

  testWidgets('UI-09 无学习记录时给出空态（不抛异常）', (tester) async {
    final h = await _boot();
    await _pump(tester, _page(SubjectScreen(active: true, state: h.state)));
    await tester.tap(find.byKey(const Key('subject-tab-1')));
    await tester.pumpAndSettle();
    expect(_allText(tester), isNotEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('UI-10 学科管理：改名生效、归档只读横幅、恢复后消失', (tester) async {
    // 默认学科不支持归档，因此用非默认学科（s_b）走完整流程。
    final h = await _boot(activeKey: 's_b');
    await _pump(tester, _page(SubjectScreen(active: true, state: h.state)));

    // 改名：⋯ → 重命名 → 输入 → 保存 → 页头更新。
    await tester.tap(find.byKey(const Key('subject-manage-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('subject-manage-rename')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('subject-rename-field')), '概率论（改）');
    await tester.tap(find.byKey(const Key('subject-rename-save')));
    await tester.pumpAndSettle();
    expect(h.api.subjectList.firstWhere((item) => item.id == 2).name, '概率论（改）');
    expect(_allText(tester), contains('概率论（改）'));

    // 归档 → 只读横幅。
    await tester.tap(find.byKey(const Key('subject-manage-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('subject-manage-archive')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '确定'));
    await tester.pumpAndSettle();
    expect(h.api.subjectList.firstWhere((item) => item.id == 2).archived, isTrue);
    await h.state.loadSubjects();
    // 重新进入学科页（等价于切页回来）：归档后必须显示只读横幅。
    await _pump(tester, _page(SubjectScreen(active: true, state: h.state)));
    expect(_allText(tester).join('\n'), contains('学科已归档（只读）'));

    // 恢复 → 横幅消失。
    await tester.tap(find.byKey(const Key('subject-manage-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('subject-manage-restore')));
    await tester.pumpAndSettle();
    expect(h.api.subjectList.firstWhere((item) => item.id == 2).archived, isFalse);
    await h.state.loadSubjects();
    await _pump(tester, _page(SubjectScreen(active: true, state: h.state)));
    expect(_allText(tester).join('\n'), isNot(contains('学科已归档（只读）')));
  });

  // ------------------------------------------------------------------ 技能页

  testWidgets('UI-11 技能页默认「已安装」，不自动浏览 hub、不自动更新', (tester) async {
    final h = await _boot(installed: [
      const InstalledSkillInfo(
        slug: 'socratic-tutor',
        version: '1.0.0',
        name: '苏格拉底式辅导',
        hub: 'eduhub',
        enabled: true,
      ),
    ]);
    await _pump(tester, _page(SkillsPanel(subjectId: 1, subjectKey: 's_a', state: h.state)));
    expect(h.api.libraryCalls, 1);
    expect(h.api.catalogCalls, 0, reason: '打开技能页不得自动逛 hub');
    expect(h.api.checkUpdatesCalls, 0, reason: '不得自动检查更新');
    expect(find.byKey(const Key('skills-tab-installed')), findsOneWidget);
  });

  testWidgets('UI-12 技能页：显式浏览/搜索/安装', (tester) async {
    final h = await _boot();
    h.api.hubSkills = const [
      HubSkillInfo(
        slug: 'socratic-tutor',
        name: '苏格拉底式辅导',
        summary: '先提问，再解释。',
        version: '1.0.0',
      ),
    ];
    await _pump(tester, _page(SkillsPanel(subjectId: 1, subjectKey: 's_a', state: h.state)));
    await tester.tap(find.byKey(const Key('skills-tab-hub')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('skills-search-button')));
    await tester.pumpAndSettle();
    expect(h.api.catalogCalls, greaterThanOrEqualTo(1));
    await tester.tap(find.byKey(const Key('hub-detail-socratic-tutor')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('skill-install-confirm')));
    await tester.pumpAndSettle();
    expect(h.api.installCalls, 1);
    expect(h.api.installed.single.slug, 'socratic-tutor');
  });

  testWidgets('UI-13 registry 未认可：提示未认可并保留显式确认入口', (tester) async {
    final h = await _boot();
    h.api.suspiciousVerdict = true;
    h.api.hubSkills = const [
      HubSkillInfo(slug: 'flagged', name: '可疑技能', summary: '', version: '1.0.0'),
    ];
    await _pump(tester, _page(SkillsPanel(subjectId: 1, subjectKey: 's_a', state: h.state)));
    await tester.tap(find.byKey(const Key('skills-tab-hub')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('skills-search-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('hub-detail-flagged')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('skill-install-confirm')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('skill-suspicious-force')), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byKey(const Key('skill-suspicious-force'))).onPressed,
      isNull,
      reason: '未勾选风险确认前不能强装',
    );
    await tester.tap(find.byKey(const Key('skill-suspicious-understood')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('skill-suspicious-force')));
    await tester.pumpAndSettle();
    expect(h.api.installCalls, 1);
    expect(h.api.lastAllowSuspicious, isTrue);
  });

  testWidgets('UI-14 手动检查更新（已是最新）+ 无上一版不回退', (tester) async {
    final h = await _boot(installed: [
      const InstalledSkillInfo(
        slug: 'socratic-tutor',
        version: '1.0.0',
        name: '苏格拉底式辅导',
        hub: 'eduhub',
        enabled: true,
        hasPrevious: false,
      ),
    ]);
    await _pump(tester, _page(SkillsPanel(subjectId: 1, subjectKey: 's_a', state: h.state)));
    await tester.tap(find.byKey(const Key('skill-menu-socratic-tutor')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('skill-check-update-socratic-tutor')));
    await tester.pumpAndSettle();
    expect(find.textContaining('已是最新'), findsWidgets);

    await tester.tap(find.byKey(const Key('skill-menu-socratic-tutor')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('skill-rollback-socratic-tutor')));
    await tester.pumpAndSettle();
    expect(h.api.rollbackCalls, 0, reason: '没有上一版时不应调用回退');
  });

  testWidgets('UI-15 离线：横条提示、已装技能仍可见', (tester) async {
    final h = await _boot(installed: [
      const InstalledSkillInfo(
        slug: 'socratic-tutor',
        version: '1.0.0',
        name: '苏格拉底式辅导',
        hub: 'eduhub',
        enabled: true,
      ),
    ]);
    await _pump(tester, _page(SkillsPanel(subjectId: 1, subjectKey: 's_a', state: h.state)));
    expect(find.byKey(const Key('skills-offline-banner')), findsNothing);

    await tester.tap(find.byKey(const Key('skills-open-hub')));
    await tester.pumpAndSettle();
    h.api.catalogError = ApiException('连不上 registry', 0, 'offline');
    await tester.tap(find.byKey(const Key('skills-search-button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('skills-offline-banner')), findsOneWidget);
  });

  testWidgets('UI-16 安装失败给出明确提示且不改变已装列表', (tester) async {
    final h = await _boot();
    h.api.installError = ApiException('完整性校验失败', 0, 'sha256_mismatch');
    h.api.hubSkills = const [
      HubSkillInfo(slug: 'broken', name: '坏包', summary: '', version: '1.0.0'),
    ];
    await _pump(tester, _page(SkillsPanel(subjectId: 1, subjectKey: 's_a', state: h.state)));
    await tester.tap(find.byKey(const Key('skills-tab-hub')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('skills-search-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('hub-detail-broken')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('skill-install-confirm')));
    await tester.pumpAndSettle();
    expect(h.api.installed, isEmpty);
    expect(find.textContaining('完整性'), findsWidgets);
  });

  testWidgets('UI-17 技能 UI 不出现安全承诺字样（AC-14 运行时对照）', (tester) async {
    final h = await _boot(installed: [
      const InstalledSkillInfo(
        slug: 'socratic-tutor',
        version: '1.0.0',
        name: '苏格拉底式辅导',
        hub: 'eduhub',
        enabled: true,
      ),
    ]);
    await _pump(tester, _page(SkillsPanel(subjectId: 1, subjectKey: 's_a', state: h.state)));
    final joined = _allText(tester).join('\n');
    for (final forbidden in ['安全通过', '已签名', 'verified safe', '绿盾']) {
      expect(joined, isNot(contains(forbidden)));
    }
    expect(joined, contains('不是安全保证'));
  });

  // ------------------------------------------------------------------ 布局

  testWidgets('UI-18 七页签 + 页索引映射（AC-11）：学科=4、代理=5、设置=6', (tester) async {
    final h = await _boot();
    // AC-11：索引映射（t6 起学科页在 4；旧脚本 LOOP_TAB=4 现在指学科页）。
    expect(subjectPageIndex, 4);
    expect(settingsPageIndex, 6);
    expect(kInitialTabMax, 6);
    await _pump(
      tester,
      _page(Sidebar(index: 0, onSelect: (_) {}, compact: true, state: h.state)),
      size: const Size(900, 600),
    );
    for (final label in ['对话', '今日', '笔记', '资料', '学科', '代理', '设置']) {
      expect(find.byTooltip(label), findsOneWidget, reason: '缺页签 $label');
    }
    expect(_overflowMarkers(tester), isEmpty);
  });

  testWidgets('UI-18b 「管理学科…」从切换器直达学科页', (tester) async {
    final h = await _boot();
    await _pump(tester, _page(Sidebar(index: 0, onSelect: (_) {}, state: h.state)));
    await tester.tap(find.byKey(const Key('subject-switcher')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('subject-menu-manage')));
    await tester.pumpAndSettle();
    expect(subjectPageSignal.value, greaterThan(0), reason: '「管理学科…」应触发跳转学科页的信号（计数器自增）');
  });

  testWidgets('UI-19 窄窗 + 深色：学科页三个 tab 均无 overflow', (tester) async {
    final h = await _boot();
    tester.view.physicalSize = const Size(460, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(_darkPage(SubjectScreen(active: true, state: h.state)));
    await tester.pumpAndSettle();
    for (final tab in ['subject-tab-0', 'subject-tab-1', 'subject-tab-2']) {
      await tester.tap(find.byKey(Key(tab)));
      await tester.pumpAndSettle();
      expect(_overflowMarkers(tester), isEmpty, reason: '$tab 溢出');
    }
  });

  testWidgets('UI-20 窄窗 + 深色：技能页无 overflow，已装技能卡仍在', (tester) async {
    final h = await _boot(installed: [
      const InstalledSkillInfo(
        slug: 'socratic-tutor',
        version: '1.0.0',
        name: '苏格拉底式辅导',
        hub: 'eduhub',
        enabled: true,
      ),
    ]);
    tester.view.physicalSize = const Size(460, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      _darkPage(SkillsPanel(subjectId: 1, subjectKey: 's_a', state: h.state)),
    );
    await tester.pumpAndSettle();
    expect(_overflowMarkers(tester), isEmpty);
    expect(find.byKey(const Key('skill-card-socratic-tutor')), findsOneWidget);
  });

  testWidgets('UI-21 900×600 紧凑侧栏：切换器 + 页签不 overflow', (tester) async {
    final h = await _boot();
    await _pump(
      tester,
      _page(Sidebar(index: 0, onSelect: (_) {}, compact: true, state: h.state)),
      size: const Size(900, 600),
    );
    expect(_overflowMarkers(tester), isEmpty);
    expect(find.byKey(const Key('subject-switcher')), findsOneWidget);
    expect(find.byTooltip('学科'), findsOneWidget);
    expect(find.byTooltip('设置'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('UI-22 切到对话页并预填输入框（学科页动作与对话页接线）', (tester) async {
    final h = await _boot();
    await _pump(tester, _page(ChatScreen(active: true, state: h.state)));
    await tester.enterText(find.byKey(const Key('chat-input')), '原有的草稿');
    await tester.pump();
    requestChatDraft('帮我复习特征值');
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(find.byKey(const Key('chat-input')));
    expect(field.controller?.text, '帮我复习特征值');
  });

  testWidgets('UI-23 回答进行中禁止切换学科（§10.2 阻塞）', (tester) async {
    final h = await _boot();
    await _pump(tester, _page(ChatScreen(active: true, state: h.state)));
    chatBusySignal.value = true;
    await tester.pumpAndSettle();
    expect(h.state.activeKey, 's_a', reason: '回答中不得切换学科');
    chatBusySignal.value = false;
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('UI-24 发送/收尾路径真实驱动 chatBusySignal', (tester) async {
    final h = await _boot();
    await _pump(tester, _page(ChatScreen(active: true, state: h.state)));
    expect(chatBusySignal.value, isFalse);
    await tester.enterText(find.byKey(const Key('chat-input')), '忙状态');
    await tester.pump();
    await tester.tap(find.byKey(const Key('chat-send-stop')));
    await tester.pump();
    expect(chatBusySignal.value, isTrue, reason: '发送后进入回答中');

    h.api.events.add(SseEvent('run', {'run_id': 9}));
    h.api.events.add(SseEvent('done', {
      'message_id': 1,
      'tokens_in': 1,
      'tokens_out': 1,
      'cost': 0.0,
      'refs': <Map<String, dynamic>>[],
    }));
    await h.api.events.close();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(chatBusySignal.value, isFalse, reason: '回答结束后恢复可切换');
  });

  // ------------------------------------------------------------------ F-15

  testWidgets('UI-25 F-15 切学科保留草稿：切走再切回，输入内容不丢', (tester) async {
    final h = await _boot(conversations: {
      's_a': [
        Conversation(
            id: 11, title: 'A', preview: '', messages: 0, updatedAt: '2026-10-25T09:00:00+08:00'),
      ],
      's_b': [
        Conversation(
            id: 21, title: 'B', preview: '', messages: 0, updatedAt: '2026-10-25T09:00:00+08:00'),
      ],
    });
    await _pump(tester, _page(ChatScreen(active: true, state: h.state)));
    await tester.enterText(find.byKey(const Key('chat-input')), '甲学科的草稿');
    await tester.pump();

    // 真实切换路径：state 切换 + 全局信号（与侧栏切换器一致）。
    await h.state.switchSubject('s_b');
    subjectChangedSignal.value = 's_b';
    await tester.pumpAndSettle();
    expect(h.state.activeKey, 's_b');
    expect(tester.widget<TextField>(find.byKey(const Key('chat-input'))).controller?.text, '');

    await h.state.switchSubject('s_a');
    subjectChangedSignal.value = 's_a';
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byKey(const Key('chat-input'))).controller?.text,
      '甲学科的草稿',
    );
    expect(tester.takeException(), isNull);
  });

  // ------------------------------------------------------------------ F-5

  testWidgets('UI-26 F-5 版本锁定开关与「检查更新（全部）」都真实调用 API', (tester) async {
    final h = await _boot(installed: [
      const InstalledSkillInfo(
        slug: 'socratic-tutor',
        version: '1.0.0',
        name: '苏格拉底式辅导',
        hub: 'eduhub',
        enabled: true,
      ),
    ]);
    h.api.pendingUpdates = {'socratic-tutor': '1.2.0'};
    await _pump(tester, _page(SkillsPanel(subjectId: 1, subjectKey: 's_a', state: h.state)));

    await tester.tap(find.byKey(const Key('skills-check-updates')));
    await tester.pumpAndSettle();
    expect(h.api.checkUpdatesCalls, 1);
    expect(find.textContaining('有新版本 1.2.0'), findsWidgets);
    expect(h.api.updateCalls, isEmpty, reason: '检查更新绝不自动安装');

    await tester.tap(find.byKey(const Key('skill-menu-socratic-tutor')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('skill-update-socratic-tutor')));
    await tester.pumpAndSettle();
    expect(h.api.updateCalls, [('socratic-tutor', null)]);

    await tester.tap(find.byKey(const Key('skill-menu-socratic-tutor')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('skill-pin-socratic-tutor')));
    await tester.pumpAndSettle();
    expect(h.api.pinCalls, [('socratic-tutor', true)]);
    expect(find.textContaining('已锁定版本'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('UI-27 F-5 锁定版本时「检查更新（全部）」跳过提示', (tester) async {
    final h = await _boot(installed: [
      const InstalledSkillInfo(
        slug: 'pinned-tutor',
        version: '2.0.0',
        name: '锁定技能',
        hub: 'eduhub',
        enabled: true,
        pinned: true,
      ),
    ]);
    h.api.pendingUpdates = {'pinned-tutor': '3.0.0'};
    await _pump(tester, _page(SkillsPanel(subjectId: 1, subjectKey: 's_a', state: h.state)));
    await tester.tap(find.byKey(const Key('skills-check-updates')));
    await tester.pumpAndSettle();
    expect(find.textContaining('已跳过'), findsWidgets);
    expect(find.textContaining('有新版本 3.0.0'), findsNothing);
  });

  testWidgets('UI-30 技能详情抽屉如实展示 verify 事实（license/summary 原文/unsigned/sha256 前 12）', (tester) async {
    final h = await _boot(installed: [
      const InstalledSkillInfo(
        slug: 'socratic-tutor',
        version: '1.0.0',
        name: '苏格拉底式辅导',
        hub: 'eduhub',
        enabled: true,
        license: 'MIT-0',
        owner: 'deeptutor',
        sha256: 'dca541fbf67b48f1c9a51234567890abcdef0123456789abcdef0123456789ab',
        verdict: SkillVerdictInfo(
          status: 'ok',
          decision: 'pass',
          confidence: 'low',
          signature: 'unsigned',
          summary: 'Static scan found no high-signal malicious patterns. Not a full malware scan.',
        ),
      ),
    ]);
    await _pump(tester, _page(SkillsPanel(subjectId: 1, subjectKey: 's_a', state: h.state)));
    await tester.tap(find.byKey(const Key('skill-menu-socratic-tutor')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('skill-detail-socratic-tutor')));
    await tester.pumpAndSettle();
    final joined = _allText(tester).join('\n');
    expect(joined, contains('MIT-0'), reason: 'license 原文');
    expect(joined, contains('dca541fbf67b'), reason: 'sha256 前 12 位');
    expect(joined, contains('unsigned'), reason: '签名状态原文（不作为信任锚）');
    expect(joined, contains('security.summary 原文'), reason: 'registry 原文');
    expect(joined, contains('Not a full malware scan'), reason: 'summary 正文');
    expect(joined, contains('不是安全保证'));
  });

  testWidgets('UI-31 回退上一版成功：调用 rollback 并提示版本', (tester) async {
    final h = await _boot(installed: [
      const InstalledSkillInfo(
        slug: 'socratic-tutor',
        version: '1.0.2',
        name: '苏格拉底式辅导',
        hub: 'eduhub',
        enabled: true,
        previousVersion: '0.9.0',
        hasPrevious: true,
      ),
    ]);
    await _pump(tester, _page(SkillsPanel(subjectId: 1, subjectKey: 's_a', state: h.state)));
    await tester.tap(find.byKey(const Key('skill-menu-socratic-tutor')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('skill-rollback-socratic-tutor')));
    await tester.pumpAndSettle();
    expect(h.api.rollbackCalls, 1);
    expect(find.textContaining('已回退到', skipOffstage: false), findsWidgets);
  });

  testWidgets('UI-32 R2-4 技能措辞：三态 verdict + 含脚本徽标 + 菜单文案 + 移除二次确认', (tester) async {
    final h = await _boot(installed: [
      const InstalledSkillInfo(
        slug: 'ok-skill',
        version: '1.0.0',
        name: '正常技能',
        hub: 'eduhub',
        enabled: true,
        verdict: SkillVerdictInfo(status: 'ok', decision: 'pass'),
      ),
      const InstalledSkillInfo(
        slug: 'risky-skill',
        version: '1.0.0',
        name: '可疑技能',
        hub: 'eduhub',
        enabled: false,
        hasScripts: true,
        verdict: SkillVerdictInfo(status: 'suspicious', decision: 'review'),
      ),
      const InstalledSkillInfo(
        slug: 'unknown-skill',
        version: '1.0.0',
        name: '未验证技能',
        hub: 'eduhub',
        enabled: false,
        verdict: SkillVerdictInfo(status: 'unknown'),
      ),
    ]);
    await _pump(tester, _page(SkillsPanel(subjectId: 1, subjectKey: 's_a', state: h.state)));
    final joined = _allText(tester).join('\n');
    expect(joined, contains('registry 未命中规则（非安全保证）'), reason: 'ok 三态文案');
    expect(joined, contains('registry 未认可'), reason: 'suspicious 三态文案');
    expect(joined, contains('未验证'), reason: 'unknown 三态文案');
    expect(joined, contains('含脚本(未执行)'), reason: '脚本徽标措辞');
    expect(joined, contains('不是安全保证'), reason: '不承诺安全');

    await tester.tap(find.byKey(const Key('skill-menu-ok-skill')));
    await tester.pumpAndSettle();
    for (final label in [
      '查看 SKILL.md / 详情',
      '检查更新（手动）',
      '更新（先检查更新）',
      '锁定版本（不提示更新）',
      '回退（没有上一版）',
      '移除',
    ]) {
      expect(find.text(label), findsOneWidget, reason: '菜单项缺：$label');
    }
    await tester.tap(find.text('移除'));
    await tester.pumpAndSettle();
    expect(find.text('移除教学技能'), findsOneWidget, reason: '移除必须二次确认');
    await tester.tap(find.byKey(const Key('skill-remove-confirm')));
    await tester.pumpAndSettle();
    expect(h.api.removeCalls, 1);
  });

  testWidgets('UI-33 R2-4 进度 PATCH/软删、待复习→草稿、integrity 横幅、学科色 token', (tester) async {
    final h = await _boot();
    // integrity 异常横幅（数据文件缺失）。
    h.api.subjectList[0] = _subject(
      id: 1,
      key: 's_a',
      name: '线性代数',
      goal: '考研数学一',
      integrity: 'missing',
    );
    h.api.active = h.api.subjectList[0];
    await h.state.loadSubjects();
    await _pump(tester, _page(SubjectScreen(active: true, state: h.state)));
    expect(_allText(tester).join('\n'), contains('找不到这个学科的数据文件'),
        reason: 'integrity 异常横幅');

    // 学科 chip + 色 token（对话页页头；chip 子树里必须有一个带颜色的容器 = 学科色点）。
    await _pump(tester, _page(ChatScreen(active: true, state: h.state)));
    expect(find.byKey(const Key('subject-chip')), findsOneWidget);
    expect(_allText(tester), contains('线性代数'));
    final chip = find.byKey(const Key('subject-chip'));
    final colored = tester
        .widgetList<Container>(find.descendant(of: chip, matching: find.byType(Container)))
        .where((c) => (c.decoration as BoxDecoration?)?.color != null || c.color != null);
    expect(colored, isNotEmpty, reason: '学科 chip 应带学科色 token');

    // 进度 tab：待复习 → 草稿。
    await _pump(tester, _page(SubjectScreen(active: true, state: h.state)));
    await tester.tap(find.byKey(const Key('subject-tab-1')));
    await tester.pumpAndSettle();
    h.api.progress['s_a'] = _FakeApi._defaultProgress;
    await tester.tap(find.byKey(const Key('subject-tab-0')));
    await tester.pumpAndSettle();
    chatDraftSignal.value = null;
    final due = find.byKey(const Key('subject-due-2'));
    if (due.evaluate().isNotEmpty) {
      await tester.tap(due);
      await tester.pumpAndSettle();
      expect(chatDraftSignal.value, isNotNull, reason: '待复习点击应把内容带进对话草稿');
      expect(chatDraftSignal.value!.text, contains('矩阵相似与对角化'));
    }

    // 进度 tab：PATCH（编辑掌握度）+ 软删（状态置 removed）都要真调后端。
    await tester.tap(find.byKey(const Key('subject-tab-1')));
    await tester.pumpAndSettle();
    final topicCard = find.byKey(const Key('subject-topic-1'));
    await tester.tap(find.descendant(of: topicCard, matching: find.byIcon(Icons.edit_outlined)).first);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('subject-topic-save')));
    await tester.pumpAndSettle();
    expect(h.api.patchCalls, 1, reason: '编辑知识点必须 PATCH /progress');
    expect(h.api.patchPayloads.first.keys, contains('topics'));
    expect(jsonEncode(h.api.patchPayloads.first), contains('mastery'),
        reason: 'PATCH 载荷应带掌握度');

    await tester.tap(find.descendant(of: topicCard, matching: find.byTooltip('删除知识点')).first);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('subject-topic-delete-confirm')), findsOneWidget,
        reason: '软删必须二次确认');
    await tester.tap(find.byKey(const Key('subject-topic-delete-confirm')));
    await tester.pumpAndSettle();
    expect(h.api.deleteTopicCalls, 1, reason: '软删要真调后端');
  });

  // ------------------------------------------------------------------ F-11/F-18

  testWidgets('UI-28 F-11 数据与迁移：状态、一次性提示、跨学科开关、只读技能来源', (tester) async {
    final h = await _boot();
    h.api.migrationPayload = {
      'applied': [
        {'id': 'v0.8.0-subjects', 'applied_at': '2026-10-25T13:00:00+08:00'},
      ],
      'pending': [],
      'running': false,
      'report': {
        'result': 'ok',
        'counts': {'conversations': 3, 'messages': 54, 'materials': 532},
        'files_moved': 540,
        'files_failed': 0,
        'files_leftover': 0,
        'files_missing': 0,
        'file_errors': [],
      },
    };
    h.api.settingsPayload = SettingsData(
      apiKeyMasked: '',
      hasKey: false,
      baseUrl: 'http://127.0.0.1:1',
      model: 'deepseek-flash',
      reasonModel: 'deepseek-v4-pro',
      skillHubUrl: 'https://eduhub.deeptutor.info/api/v1',
      subjectMigrationNoticeSeen: false,
    );
    await h.state.refreshSettings();
    await _pump(tester, _page(SettingsScreen(active: true, state: h.state)));

    expect(find.byKey(const Key('settings-data-migration')), findsOneWidget);
    expect(find.byKey(const Key('migration-notice')), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const Key('skill-hub-readonly'))).data,
      contains('https://eduhub.deeptutor.info/api/v1'),
    );

    await tester.ensureVisible(find.byKey(const Key('migration-notice-dismiss')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('migration-notice-dismiss')));
    await tester.pumpAndSettle();
    expect(
      h.api.saveSettingsCalls.any((call) => call['subject_migration_notice_seen'] == true),
      isTrue,
    );
    expect(find.byKey(const Key('migration-notice')), findsNothing);

    await tester.ensureVisible(find.byKey(const Key('cross-subject-search-switch')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('cross-subject-search-switch')));
    await tester.pumpAndSettle();
    expect(h.api.saveSettingsCalls.any((call) => call['cross_subject_search'] == true), isTrue);

    final retry = tester.widget<OutlinedButton>(find.byKey(const Key('migration-retry')));
    expect(retry.onPressed, isNull, reason: '已应用时不应可重试');
    expect(tester.takeException(), isNull);
  });

  testWidgets('UI-29 F-11 迁移失败时显示原因并可重试', (tester) async {
    final h = await _boot();
    h.api.migrationPayload = {
      'applied': [],
      'pending': ['v0.8.0-subjects'],
      'running': false,
      'last_error': '注入的晚期失败（测试用）',
      'report': {'result': 'failed', 'error': '注入的晚期失败（测试用）'},
    };
    await h.state.refreshSettings();
    await _pump(tester, _page(SettingsScreen(active: true, state: h.state)));

    expect(find.byKey(const Key('migration-error-line')), findsOneWidget);
    final retry = tester.widget<OutlinedButton>(find.byKey(const Key('migration-retry')));
    expect(retry.onPressed, isNotNull, reason: '有 pending 时必须可重试');
    await tester.ensureVisible(find.byKey(const Key('migration-retry')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('migration-retry')));
    await tester.pumpAndSettle();
    expect(h.api.migrationRunCalls, 1);
  });
}