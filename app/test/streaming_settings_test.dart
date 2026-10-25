import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loop/api.dart';
import 'package:loop/models.dart';
import 'package:loop/screens/settings_screen.dart';
import 'package:loop/state.dart';

SettingsData _settings({
  bool streamOutput = true,
  bool sidebarCollapsed = false,
  bool autoCheckUpdates = true,
}) {
  return SettingsData(
    apiKeyMasked: 'sk-••••abcd',
    hasKey: true,
    baseUrl: 'https://api.deepseek.com',
    model: 'deepseek-flash',
    reasonModel: 'deepseek-v4-pro',
    theme: 'system',
    customModes: '[]',
    autoCheckUpdates: autoCheckUpdates,
    sidebarCollapsed: sidebarCollapsed,
    streamOutput: streamOutput,
  );
}

/// 不访问网络：记录 saveSettings 的 payload，可配置为抛错。
class _FakeLoopApi extends LoopApi {
  _FakeLoopApi() : super(baseUrl: 'http://127.0.0.1:1');

  final List<Map<String, dynamic>> saved = [];
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
  }) async {
    if (failSaves) throw ApiException('连不上本地服务');
    final payload = <String, dynamic>{};
    if (apiKey != null) payload['api_key'] = apiKey;
    if (baseUrl != null) payload['base_url'] = baseUrl;
    if (model != null) payload['model'] = model;
    if (reasonModel != null) payload['reason_model'] = reasonModel;
    if (activeProvider != null) payload['active_provider'] = activeProvider;
    if (providersJson != null) payload['providers'] = providersJson;
    if (theme != null) payload['theme'] = theme;
    if (customModes != null) payload['custom_modes'] = customModes;
    if (autoCheckUpdates != null) payload['auto_check_updates'] = autoCheckUpdates;
    if (sidebarCollapsed != null) payload['sidebar_collapsed'] = sidebarCollapsed;
    if (streamOutput != null) payload['stream_output'] = streamOutput;
    saved.add(payload);
    return _settings(
      streamOutput: streamOutput ?? true,
      sidebarCollapsed: sidebarCollapsed ?? false,
      autoCheckUpdates: autoCheckUpdates ?? true,
    );
  }
}

void main() {
  test('F1 SettingsData 解析 streamOutput：缺字段默认 true，支持 false', () {
    expect(SettingsData.fromJson({}).streamOutput, isTrue);
    expect(SettingsData.fromJson({'stream_output': true}).streamOutput, isTrue);
    expect(SettingsData.fromJson({'stream_output': false}).streamOutput, isFalse);
    expect(SettingsData.fromJson({'stream_output': null}).streamOutput, isTrue);
  });

  test('F2 LoopApi 读写 stream_output 为布尔字段', () async {
    // widget 测试套件默认把 HttpClient 替换成始终返回 400 的 mock；
    // 这里临时恢复真实网络，用于本地 HttpServer 契约验证。
    final previousOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = previousOverrides);

    final payloads = <Map<String, dynamic>>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      final body = await utf8.decoder.bind(request).join();
      if (request.method == 'PUT' && body.isNotEmpty) {
        payloads.add(jsonDecode(body) as Map<String, dynamic>);
      }
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'api_key': '',
        'has_key': false,
        'base_url': 'https://api.deepseek.com',
        'model': 'deepseek-flash',
        'reason_model': 'deepseek-v4-pro',
        'theme': 'system',
        'custom_modes': '[]',
        'auto_check_updates': true,
        'sidebar_collapsed': false,
        'stream_output': false,
      }));
      await request.response.close();
    });

    final api = LoopApi(baseUrl: 'http://127.0.0.1:${server.port}');
    final loaded = await api.settings();
    expect(loaded.streamOutput, isFalse);

    await api.saveSettings(streamOutput: false);
    expect(payloads, hasLength(1));
    expect(payloads.single['stream_output'], isFalse);
    expect(payloads.single['stream_output'], isA<bool>());
  });

  test('F3 AppState 乐观更新、保存成功与失败回滚', () async {
    final fake = _FakeLoopApi();
    final state = AppState(api: fake);
    // 设置还没加载时按默认 true。
    expect(state.streamOutput, isTrue);
    expect(await state.setStreamOutput(false), isFalse);
    expect(fake.saved, isEmpty);

    state.settings = _settings(streamOutput: true);
    final ok = await state.setStreamOutput(false);
    expect(ok, isTrue);
    expect(state.settings!.streamOutput, isFalse);
    expect(state.streamOutput, isFalse);
    expect(fake.saved.single['stream_output'], isFalse);

    // 相同值不重复请求。
    expect(await state.setStreamOutput(false), isTrue);
    expect(fake.saved, hasLength(1));

    fake.failSaves = true;
    final failed = await state.setStreamOutput(true);
    expect(failed, isFalse);
    expect(state.settings!.streamOutput, isFalse);
    expect(state.streamOutput, isFalse);
  });

  test('F4 侧栏折叠/自动更新开关不会重置 streamOutput', () async {
    final fake = _FakeLoopApi();
    final state = AppState(api: fake)..settings = _settings(streamOutput: false);

    await state.setSidebarCollapsed(true);
    expect(state.settings!.sidebarCollapsed, isTrue);
    expect(state.settings!.streamOutput, isFalse);

    await state.setAutoCheckUpdates(false);
    expect(state.settings!.autoCheckUpdates, isFalse);
    expect(state.settings!.sidebarCollapsed, isTrue);
    expect(state.settings!.streamOutput, isFalse);

    expect(fake.saved[0]['sidebar_collapsed'], isTrue);
    expect(fake.saved[0]['stream_output'], isNull);
    expect(fake.saved[1]['auto_check_updates'], isFalse);
    expect(fake.saved[1]['stream_output'], isNull);
  });

  testWidgets('F5 设置页渲染流式开关与固定说明，失败回滚并提示', (tester) async {
    final fake = _FakeLoopApi();
    final state = AppState(api: fake)..settings = _settings(streamOutput: true);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: SettingsScreen(active: true, state: state)),
    ));
    await tester.pump();

    expect(find.text('对话与模型'), findsOneWidget);
    expect(find.text('流式输出'), findsOneWidget);
    expect(find.text('开启后逐字显示；关闭后等待完整回复；对下一条消息生效。'), findsOneWidget);
    final streamSwitch = find.byType(Switch).first;
    expect(tester.widget<Switch>(streamSwitch).value, isTrue);

    // 成功切换：立即持久化并更新开关。
    await tester.tap(streamSwitch);
    await tester.pumpAndSettle();
    expect(fake.saved.single['stream_output'], isFalse);
    expect(state.streamOutput, isFalse);
    expect(tester.widget<Switch>(streamSwitch).value, isFalse);

    // 失败：开关回滚，提示“已恢复原状态”。
    fake.failSaves = true;
    await tester.tap(streamSwitch);
    await tester.pumpAndSettle();
    expect(state.streamOutput, isFalse);
    expect(tester.widget<Switch>(streamSwitch).value, isFalse);
    expect(find.text('流式设置保存失败，已恢复原状态'), findsOneWidget);

    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
  });
}
