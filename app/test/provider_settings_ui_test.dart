import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loop/api.dart';
import 'package:loop/models.dart';
import 'package:loop/screens/settings_screen.dart';
import 'package:loop/state.dart';

class _FakeLoopApi extends LoopApi {
  _FakeLoopApi() : super(baseUrl: 'http://127.0.0.1:1');

  String activeProvider = 'deepseek';
  String providersJson = '[]';
  final List<Map<String, dynamic>> saved = [];
  final List<String?> testedProviders = [];
  List<String> fetchedModels = const ['kimi-k3.1-pro', 'new-model-x'];

  SettingsData _settings() => SettingsData(
        apiKeyMasked: 'sk-••••abcd',
        hasKey: true,
        baseUrl: 'https://api.deepseek.com',
        model: 'deepseek-flash',
        reasonModel: 'deepseek-v4-pro',
        activeProvider: activeProvider,
        providersJson: providersJson,
      );

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
  }) async {
    if (activeProvider != null) this.activeProvider = activeProvider;
    if (providersJson != null) this.providersJson = providersJson;
    final payload = <String, dynamic>{
      'active_provider': ?activeProvider,
      'providers': ?providersJson,
    };
    saved.add(payload);
    return _settings();
  }

  @override
  Future<Map<String, dynamic>> fetchModels({String? providerId}) async {
    return {
      'ok': true,
      'models': fetchedModels,
      'message': '拉取到 ${fetchedModels.length} 个模型',
    };
  }

  @override
  Future<Map<String, dynamic>> testSettings({String? providerId, String? model}) async {
    testedProviders.add(providerId);
    return {'ok': true, 'message': '连接正常（$providerId）'};
  }
}

void main() {
  testWidgets('S1 设置页渲染 AI 供应商与能力开关，默认 DeepSeek', (tester) async {
    final fake = _FakeLoopApi();
    final state = AppState(api: fake)..settings = await fake.settings();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: SettingsScreen(active: true, state: state)),
    ));
    await tester.pump();

    expect(find.text('AI 供应商'), findsOneWidget);
    expect(find.text('每个供应商独立保存 Key；Key 只存在本机 SQLite，不会上传。'), findsOneWidget);
    expect(find.text('图片'), findsOneWidget);
    expect(find.text('工具'), findsOneWidget);
    expect(find.text('思考'), findsOneWidget);
    expect(find.text('流式用量'), findsOneWidget);
    expect(find.text('对话模型 ID'), findsOneWidget);
    expect(find.text('推理模型 ID（可留空）'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('S2 切换供应商后 Base URL/模型跟随，可设为当前并保存', (tester) async {
    final fake = _FakeLoopApi();
    final state = AppState(api: fake)..settings = await fake.settings();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: SettingsScreen(active: true, state: state)),
    ));
    await tester.pump();

    final dropdown = find.byType(DropdownButtonFormField<String>).first;
    await tester.ensureVisible(dropdown);
    await tester.tap(dropdown);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Moonshot / Kimi').last);
    await tester.pumpAndSettle();

    final fields = find.byType(TextField);
    expect(tester.widget<TextField>(fields.at(1)).controller!.text,
        'https://api.moonshot.cn/v1');
    expect(tester.widget<TextField>(fields.at(2)).controller!.text,
        'kimi-k3.1-pro');
    expect(find.textContaining('kimi-k3.1-pro'), findsWidgets);

    await tester.ensureVisible(find.text('设为当前'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('设为当前'));
    await tester.pumpAndSettle();
    expect(fake.saved, isNotEmpty);
    expect(fake.saved.last['active_provider'], 'kimi');
    expect(fake.saved.last['providers'], contains('kimi'));
    expect(fake.saved.last['providers'], contains('moonshot.cn'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('S3 测试连接使用当前选中的供应商', (tester) async {
    final fake = _FakeLoopApi();
    final state = AppState(api: fake)..settings = await fake.settings();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: SettingsScreen(active: true, state: state)),
    ));
    await tester.pump();

    await tester.ensureVisible(find.text('测试连接'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('测试连接'));
    await tester.pumpAndSettle();
    expect(fake.testedProviders, ['deepseek']);
    expect(find.textContaining('连接正常'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('S4 刷新模型列表：新模型进入 chips 并保存到 providers', (tester) async {
    final fake = _FakeLoopApi();
    final state = AppState(api: fake)..settings = await fake.settings();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: SettingsScreen(active: true, state: state)),
    ));
    await tester.pump();

    await tester.ensureVisible(find.text('刷新模型列表'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('刷新模型列表'));
    await tester.pumpAndSettle();

    expect(find.text('new-model-x'), findsOneWidget);
    expect(fake.saved, isNotEmpty);
    expect(fake.saved.last['providers'], contains('new-model-x'));
    expect(find.textContaining('新增 2 个'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
