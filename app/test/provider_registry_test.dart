import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:loop/backend/db.dart';
import 'package:loop/backend/llm.dart';

/// M1 多供应商骨架测试：预置、迁移、能力合并、模型解析。
void main() {
  setUp(() {
    Db.initInMemoryForTests();
    for (final key in ['api_key', 'base_url', 'model', 'reason_model']) {
      Db.setSetting(key, '');
    }
    Db.setSetting('providers_v1', '[]');
    Db.setSetting('active_provider', 'deepseek');
  });

  test('P1 预置包含 DeepSeek/Kimi/GLM，且能力差异正确', () {
    final ids = ProviderRegistry.builtIns().map((item) => item.id).toList();
    expect(ids, containsAll(<String>['deepseek', 'kimi', 'glm']));

    final deepseek = ProviderRegistry.builtIns().firstWhere((p) => p.id == 'deepseek');
    expect(deepseek.capabilitiesFor('deepseek-flash').vision, isTrue);
    expect(deepseek.capabilitiesFor('deepseek-v4-pro').vision, isFalse);
    expect(deepseek.capabilitiesFor('deepseek-v4-pro').tools, isTrue);
    expect(deepseek.capabilitiesFor('deepseek-flash').streamUsage, isTrue);

    final kimi = ProviderRegistry.builtIns().firstWhere((p) => p.id == 'kimi');
    expect(kimi.defaultModel, 'kimi-k3.1-pro');
    expect(kimi.capabilitiesFor('kimi-k3.1-pro').tools, isTrue);
    expect(kimi.capabilitiesFor('kimi-k3.1-pro').streamUsage, isFalse);
    expect(kimi.capabilitiesFor('kimi-k3.1-pro').vision, isTrue);
    expect(kimi.capabilitiesFor('kimi-k3.1-pro').reasoning, isTrue);
    expect(kimi.capabilitiesFor('moonshot-v1-8k-vision-preview').vision, isTrue);
    expect(kimi.thinkingStyle, ThinkingStyle.openaiEffort);
    expect(kimi.sendTemperature, isFalse);

    final glm = ProviderRegistry.builtIns().firstWhere((p) => p.id == 'glm');
    expect(glm.defaultModel, 'glm-5.3');
    expect(glm.thinkingStyle, ThinkingStyle.zhipu);
    expect(glm.capabilitiesFor('glm-5.3').reasoning, isTrue);
    expect(glm.capabilitiesFor('glm-5.3-flash').vision, isTrue);
    expect(glm.capabilitiesFor('glm-5.3').vision, isFalse);
    expect(glm.capabilitiesFor('glm-4v-plus').vision, isTrue);
    expect(glm.capabilitiesFor('glm-4.5').tools, isTrue);
  });

  test('P2 旧 DeepSeek 配置迁移成 deepseek profile，且不丢 Key', () {
    Db.setSetting('api_key', 'sk-legacy-1234567890');
    Db.setSetting('base_url', 'https://api.deepseek.com');
    Db.setSetting('model', 'deepseek-flash');
    Db.setSetting('reason_model', 'deepseek-v4-pro');

    ProviderRegistry.ensureMigrated();

    final active = ProviderRegistry.active();
    expect(active.id, 'deepseek');
    expect(active.apiKey, 'sk-legacy-1234567890');
    expect(active.defaultModel, 'deepseek-flash');
    expect(active.reasonModel, 'deepseek-v4-pro');

    // 再次调用不覆盖用户后续写入 providers_v1 的修改。
    ProviderRegistry.saveAll([
      ProviderRegistry.active().copyWith(apiKey: 'sk-changed'),
    ]);
    ProviderRegistry.ensureMigrated();
    expect(ProviderRegistry.active().apiKey, 'sk-changed');
  });

  test('P8 mergeFetchedModels 保留已有能力/标签，只追加新模型', () {
    const existing = [
      ModelInfo(id: 'glm-5.3', label: '旗舰', reasoning: true),
      ModelInfo(id: 'glm-4v-plus', label: '视觉', vision: true),
    ];
    final merged = mergeFetchedModels(existing, const [
      ModelInfo(id: 'glm-5.3'),
      ModelInfo(id: 'glm-new'),
      ModelInfo(id: 'glm-4v-plus'),
    ]);
    expect(merged.map((item) => item.id).toList(),
        ['glm-5.3', 'glm-4v-plus', 'glm-new']);
    expect(merged.first.reasoning, isTrue);
    expect(merged.first.label, '旗舰');
    expect(merged[1].vision, isTrue);
  });

  test('P7 旧自定义 Base URL 迁移成自定义供应商，不误发 DeepSeek 专有字段', () {
    Db.setSetting('api_key', 'sk-proxy');
    Db.setSetting('base_url', 'https://my-proxy.local/v1');
    Db.setSetting('model', 'my-model');
    Db.setSetting('reason_model', '');

    ProviderRegistry.ensureMigrated();
    final active = ProviderRegistry.active();
    expect(active.id, 'custom_migrated');
    expect(active.baseUrl, 'https://my-proxy.local/v1');
    expect(active.apiKey, 'sk-proxy');
    expect(active.thinkingStyle, ThinkingStyle.none);
    expect(active.capabilities.streamUsage, isFalse);
  });

  test('P3 config() 按供应商/思考模式解析模型与能力', () {
    Db.setSetting('api_key', 'sk-kimi');
    final kimi = ProviderRegistry.builtIns().firstWhere((p) => p.id == 'kimi');
    ProviderRegistry.saveAll([kimi.copyWith(apiKey: 'sk-kimi')]);
    ProviderRegistry.setActive('kimi');

    final normal = ProviderRegistry.config();
    expect(normal.providerId, 'kimi');
    expect(normal.model, 'kimi-k3.1-pro');
    expect(normal.thinkingStyle, ThinkingStyle.openaiEffort);
    expect(normal.capabilities.streamUsage, isFalse);
    expect(normal.sendTemperature, isFalse);

    final thinking = ProviderRegistry.config(thinkingHigh: true);
    expect(thinking.model, 'kimi-k3.1-pro');
  });

  test('P4 profile JSON 往返保留能力/模型/Key 掩码', () {
    final glm = ProviderRegistry.builtIns().firstWhere((p) => p.id == 'glm');
    final json = glm.toJson();
    final decoded = ProviderProfile.fromJson(json, fallback: glm);
    expect(decoded.id, 'glm');
    expect(decoded.thinkingStyle, ThinkingStyle.zhipu);
    expect(decoded.capabilitiesFor('glm-4v-plus').vision, isTrue);
    expect(decoded.models.length, glm.models.length);

    final withKey = glm.copyWith(apiKey: 'sk-abcdefghijklmnop');
    expect(withKey.toJson(maskKey: true)['api_key'], isNot(contains('abcdefghij')));
    expect(withKey.maskedKey, contains('mnop'));
  });

  test('P6 providers JSON 合并：掩码/空 Key 保留旧 Key，新 Key 覆盖', () {
    final existing = [
      ProviderRegistry.builtIns().firstWhere((p) => p.id == 'glm').copyWith(
            apiKey: 'sk-old-glm',
          ),
    ];
    final masked = jsonEncode([
      {
        'id': 'glm',
        'name': '智谱 GLM',
        'base_url': 'https://open.bigmodel.cn/api/paas/v4',
        'api_key': 'sk-••••••••1234',
        'default_model': 'glm-4.5',
      },
    ]);
    final kept = ProviderRegistry.mergeIncoming(masked, existing).single;
    expect(kept.apiKey, 'sk-old-glm');

    final blank = jsonEncode([
      {
        'id': 'glm',
        'name': '智谱 GLM',
        'base_url': 'https://open.bigmodel.cn/api/paas/v4',
        'api_key': '',
        'default_model': 'glm-4.5',
      },
    ]);
    expect(ProviderRegistry.mergeIncoming(blank, existing).single.apiKey, 'sk-old-glm');

    final replaced = jsonEncode([
      {
        'id': 'glm',
        'name': '智谱 GLM',
        'base_url': 'https://open.bigmodel.cn/api/paas/v4',
        'api_key': 'sk-new-glm',
        'default_model': 'glm-4.5',
      },
    ]);
    final updated = ProviderRegistry.mergeIncoming(replaced, existing).single;
    expect(updated.apiKey, 'sk-new-glm');
    expect(updated.capabilitiesFor('glm-4v-plus').vision, isTrue,
        reason: '合并时保留预置模型能力');
  });

  test('P5 供应商级 vision=false + 模型级 true 可覆盖', () {
    const profile = ProviderProfile(
      id: 'custom',
      name: 'Custom',
      baseUrl: 'https://example.com/v1',
      defaultModel: 'a',
      capabilities: ProviderCapabilities(tools: true),
      models: [
        ModelInfo(id: 'a'),
        ModelInfo(id: 'b', vision: true),
      ],
    );
    expect(profile.capabilitiesFor('a').vision, isFalse);
    expect(profile.capabilitiesFor('b').vision, isTrue);
    expect(profile.capabilitiesFor('b').tools, isTrue);
  });
}