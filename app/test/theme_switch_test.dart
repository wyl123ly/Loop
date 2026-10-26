import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loop/api.dart';
import 'package:loop/models.dart';
import 'package:loop/state.dart';

/// 主题切换性能回归：
/// - 外观变化用独立的 appearanceRevision，驱动 MaterialApp 重建；
/// - 会话/学科等高频通知不再让整棵 MaterialApp 重建；
/// - 重复选择同一主题不产生额外工作；系统亮度只在“跟随系统”时刷新。
SettingsData _settings({String theme = 'system'}) => SettingsData(
      apiKeyMasked: 'sk-••••abcd',
      hasKey: true,
      baseUrl: 'https://api.deepseek.com',
      model: 'deepseek-flash',
      reasonModel: 'deepseek-v4-pro',
      theme: theme,
      customModes: '[]',
      autoCheckUpdates: true,
      sidebarCollapsed: false,
      streamOutput: true,
    );

class _ThemeApi extends LoopApi {
  _ThemeApi() : super(baseUrl: 'http://127.0.0.1:1');

  final List<String?> savedThemes = [];
  bool failSaves = false;

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
  }) async {
    savedThemes.add(theme);
    if (failSaves) throw ApiException('离线');
    return _settings(theme: theme ?? 'system');
  }
}

void main() {
  test('TS1 切换主题只触发一次外观刷新并持久化', () async {
    final api = _ThemeApi();
    final state = AppState(api: api);
    var appearance = 0;
    var general = 0;
    state.appearanceRevision.addListener(() => appearance++);
    state.addListener(() => general++);

    await state.setTheme(ThemeMode.dark);
    expect(state.themeMode, ThemeMode.dark);
    expect(appearance, 1);
    expect(general, 1);
    expect(api.savedThemes, ['dark']);

    // 重复点同一个选项：不应再刷新、不再写后端。
    await state.setTheme(ThemeMode.dark);
    expect(appearance, 1);
    expect(api.savedThemes, ['dark']);
  });

  test('TS2 会话/学科类通知不会触发外观刷新', () async {
    final api = _ThemeApi();
    final state = AppState(api: api);
    var appearance = 0;
    state.appearanceRevision.addListener(() => appearance++);

    state.setCurrentConversation(42);
    state.customModes = [];
    await state.refreshSettings();
    expect(appearance, 0, reason: '这些通知不应重建 MaterialApp');

    await state.setTheme(ThemeMode.light);
    expect(appearance, 1);
  });

  test('TS3 系统亮度只在“跟随系统”时刷新外观', () async {
    final api = _ThemeApi();
    final state = AppState(api: api);
    var appearance = 0;
    state.appearanceRevision.addListener(() => appearance++);

    state.themeMode = ThemeMode.dark;
    state.notifySystemBrightnessChanged();
    expect(appearance, 0);

    state.themeMode = ThemeMode.system;
    state.notifySystemBrightnessChanged();
    expect(appearance, 1);
  });

  test('TS4 后端保存失败也不影响界面切换', () async {
    final api = _ThemeApi()..failSaves = true;
    final state = AppState(api: api);
    var appearance = 0;
    state.appearanceRevision.addListener(() => appearance++);

    await state.setTheme(ThemeMode.light);
    expect(state.themeMode, ThemeMode.light);
    expect(appearance, 1);
  });
}