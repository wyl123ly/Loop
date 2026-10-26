import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loop/api.dart';
import 'package:loop/main.dart';
import 'package:loop/models.dart';
import 'package:loop/state.dart';
import 'package:loop/theme.dart';

/// 主题切换性能回归（真实 LoopApp 接线）：
/// - 会话通知不重建 MaterialApp；
/// - 主题变化只重建一次，且复用缓存的 ThemeData；
/// - 主题动画时长为 0（不做整树 lerp）。
SettingsData _settings() => SettingsData(
      apiKeyMasked: 'sk-••••abcd',
      hasKey: true,
      baseUrl: 'https://api.deepseek.com',
      model: 'deepseek-flash',
      reasonModel: 'deepseek-v4-pro',
      theme: 'system',
      customModes: '[]',
      autoCheckUpdates: false,
      sidebarCollapsed: false,
      streamOutput: true,
    );

class _ShellApi extends LoopApi {
  _ShellApi() : super(baseUrl: 'http://127.0.0.1:1');

  @override
  Future<SettingsData> settings() async => _settings();

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
  }) async =>
      _settings();

  @override
  Future<List<Subject>> subjects({bool includeArchived = false, bool counts = false}) async =>
      [Subject.fromJson(const {'id': 1, 'key': 'default', 'name': '默认'})];

  @override
  Future<Subject> activeSubject() async =>
      Subject.fromJson(const {'id': 1, 'key': 'default', 'name': '默认'});

  @override
  Future<List<Conversation>> conversations() async => [];
}

void main() {
  testWidgets('TM1 会话通知不重建 MaterialApp，主题变化才重建且复用 ThemeData', (tester) async {
    final state = AppState(api: _ShellApi());
    await tester.pumpWidget(LoopApp(
      state: state,
      home: const SizedBox.expand(),
    ));
    // 等 bootstrap 完成。
    for (var i = 0; i < 10 && !state.ready; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(state.ready, isTrue);
    // 冲掉 bootstrap 结束时排队的 bootRevision 重建帧。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 30));

    final appBefore = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(appBefore.themeAnimationDuration, Duration.zero);
    expect(appBefore.themeMode, ThemeMode.system);

    // 高频通知：MaterialApp 不应重建。
    state.setCurrentConversation(9);
    await tester.pump();
    final appAfterNotify = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(identical(appBefore, appAfterNotify), isTrue,
        reason: '会话通知不应重建 MaterialApp');

    // 主题变化：重建一次，主题切换生效，且两份 ThemeData 复用同一实例。
    await state.setTheme(ThemeMode.dark);
    await tester.pump();
    final appThemed = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(identical(appBefore, appThemed), isFalse, reason: '主题变化需要重建');
    expect(appThemed.themeMode, ThemeMode.dark);
    expect(identical(appBefore.theme, appThemed.theme), isTrue,
        reason: 'ThemeData 应缓存复用，不应每次重建');
    expect(identical(appBefore.darkTheme, appThemed.darkTheme), isTrue);
  });

  testWidgets('TM2 系统亮度变化只影响跟随系统模式', (tester) async {
    final state = AppState(api: _ShellApi());
    await tester.pumpWidget(LoopApp(state: state, home: const SizedBox.expand()));
    for (var i = 0; i < 10 && !state.ready; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }

    state.themeMode = ThemeMode.dark;
    var appearance = 0;
    state.appearanceRevision.addListener(() => appearance++);
    state.notifySystemBrightnessChanged();
    expect(appearance, 0);

    state.themeMode = ThemeMode.system;
    state.notifySystemBrightnessChanged();
    await tester.pump();
    expect(appearance, 1);
    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
      ThemeMode.system,
    );
  });

  tearDown(() {
    LoopTheme.palette = LoopPalette.light;
  });
}