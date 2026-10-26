import 'dart:convert';
import 'dart:typed_data';

import 'llm.dart';

/// 一个可用于扫描件转写的视觉模型。
class VisionModelOption {
  const VisionModelOption({
    required this.providerId,
    required this.providerName,
    required this.model,
    required this.label,
  });

  final String providerId;
  final String providerName;
  final String model;
  final String label;

  String get id => '$providerId/$model';

  Map<String, Object?> toJson() => {
    'id': id,
    'provider': providerId,
    'provider_name': providerName,
    'model': model,
    'label': label,
  };
}

/// 列出所有已配置供应商里声明了 vision 能力的模型。
///
/// 没有 models 列表的供应商，如果 capabilities.vision 为 true，则把默认模型
/// 作为候选，避免用户自定义供应商无法选择。
List<VisionModelOption> visionModelOptions() {
  final options = <VisionModelOption>[];
  final seen = <String>{};
  for (final profile in ProviderRegistry.all()) {
    if (profile.apiKey.trim().isEmpty) continue;
    final models = profile.models.isEmpty
        ? [
            ModelInfo(
              id: profile.defaultModel,
              label: profile.defaultModel,
              vision: profile.capabilities.vision,
            ),
          ]
        : profile.models;
    for (final model in models) {
      final capability = profile.capabilitiesFor(model.id);
      if (!capability.vision) continue;
      final id = '${profile.id}/${model.id}';
      if (!seen.add(id)) continue;
      options.add(
        VisionModelOption(
          providerId: profile.id,
          providerName: profile.name,
          model: model.id,
          label:
              '${profile.name} · ${model.label.isEmpty ? model.id : model.label}',
        ),
      );
    }
  }
  return options;
}

/// 校验并构造 OCR 调用配置。
LlmConfig ocrConfig(String providerId, String model) {
  final profile = ProviderRegistry.byId(providerId);
  if (profile == null) {
    throw LlmException('找不到供应商：$providerId', status: 400);
  }
  final config = ProviderRegistry.config(
    providerId: profile.id,
    modelOverride: model,
  );
  if (!config.capabilities.vision) {
    throw LlmException(
      '${config.providerName} / ${config.model} 不支持图片输入，不能用于扫描件转写。',
      status: 400,
    );
  }
  if (!config.ready) {
    throw LlmException(
      '还没有配置 ${config.providerName} API Key，请先到设置里填写。',
      status: 401,
    );
  }
  return config;
}

const _ocrPrompt = '''
你是文档转写器。逐字转写这一页的内容，不要总结、不要解释、不要补充。
保留标题、段落、列表、表格结构；表格用 Markdown 表格。
公式用 LaTeX；无法辨认的字用 [?] 标记。
只输出本页正文，不要输出“第几页”或前后说明。
如果本页为空白，只输出 [空白页]。
''';

/// 把一页扫描图交给视觉模型转写。
Future<String> transcribePage({
  required LlmConfig config,
  required Uint8List png,
  required int page,
}) async {
  final (content, _) = await complete(
    config: config,
    temperature: 0,
    maxTokens: 4096,
    messages: [
      const {'role': 'system', 'content': _ocrPrompt},
      {
        'role': 'user',
        'content': [
          {'type': 'text', 'text': '这是 PDF 第 $page 页的扫描图，请转写。'},
          {
            'type': 'image_url',
            'image_url': {'url': 'data:image/png;base64,${base64Encode(png)}'},
          },
        ],
      },
    ],
  );
  return sanitizeOcrText(content);
}

/// 去掉模型偶尔加的 Markdown 围栏/客套前言，并识别空白页。
String sanitizeOcrText(String raw) {
  var text = raw.trim();
  if (text.isEmpty) return '';
  if (text == '[空白页]' || text == '【空白页】') return '';
  text = text.replaceFirst(RegExp(r'^```(?:markdown|text|md)?\s*'), '');
  text = text.replaceFirst(RegExp(r'\s*```$'), '');
  text = text.replaceFirst(RegExp(r'^(好的|当然|可以)[，,。\s]*'), '');
  text = text.replaceFirst(RegExp(r'^(以下是|这是)(本页|该页)?(的)?(内容|转写)[：:]\s*'), '');
  text = text.replaceFirst(RegExp(r'^第\s*\d+\s*页[：:]\s*'), '');
  return text.replaceAll('\u0000', '').trim();
}
