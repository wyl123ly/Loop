import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'db.dart';

class LlmException implements Exception {
  LlmException(this.message, {this.status = 0});
  final String message;
  final int status;

  @override
  String toString() => message;
}

/// 思考/推理参数的供应商形态。
enum ThinkingStyle { none, deepseek, zhipu, openaiEffort, custom }

/// 鉴权方式：默认 Bearer；部分兼容端点使用自定义头（如 api-key）。
enum AuthStyle { bearer, apiKeyHeader }

class ProviderCapabilities {
  const ProviderCapabilities({
    this.vision = false,
    this.tools = false,
    this.streamUsage = false,
    this.reasoning = false,
  });

  final bool vision;
  final bool tools;
  final bool streamUsage;
  final bool reasoning;

  ProviderCapabilities overrideWith(ProviderCapabilities? other) {
    if (other == null) return this;
    return ProviderCapabilities(
      vision: other.vision || vision,
      tools: other.tools || tools,
      streamUsage: other.streamUsage || streamUsage,
      reasoning: other.reasoning || reasoning,
    );
  }

  Map<String, Object?> toJson() => {
        'vision': vision,
        'tools': tools,
        'stream_usage': streamUsage,
        'reasoning': reasoning,
      };

  factory ProviderCapabilities.fromJson(
    Object? json, {
    ProviderCapabilities fallback = const ProviderCapabilities(),
  }) {
    if (json is! Map) return fallback;
    return ProviderCapabilities(
      vision: json['vision'] == true,
      tools: json['tools'] == true,
      streamUsage: json['stream_usage'] == true,
      reasoning: json['reasoning'] == true,
    );
  }
}

/// 单个模型的能力/价格覆盖；null 表示继承供应商级能力。
class ModelInfo {
  const ModelInfo({
    required this.id,
    this.label = '',
    this.vision,
    this.tools,
    this.reasoning,
    this.priceIn,
    this.priceOut,
  });

  final String id;
  final String label;
  final bool? vision;
  final bool? tools;
  final bool? reasoning;
  final double? priceIn;
  final double? priceOut;

  Map<String, Object?> toJson() => {
        'id': id,
        if (label.isNotEmpty) 'label': label,
        if (vision != null) 'vision': vision,
        if (tools != null) 'tools': tools,
        if (reasoning != null) 'reasoning': reasoning,
        if (priceIn != null) 'price_in': priceIn,
        if (priceOut != null) 'price_out': priceOut,
      };

  factory ModelInfo.fromJson(Map json) => ModelInfo(
        id: (json['id'] ?? '').toString(),
        label: (json['label'] ?? '').toString(),
        vision: json['vision'] is bool ? json['vision'] as bool : null,
        tools: json['tools'] is bool ? json['tools'] as bool : null,
        reasoning: json['reasoning'] is bool ? json['reasoning'] as bool : null,
        priceIn: (json['price_in'] as num?)?.toDouble(),
        priceOut: (json['price_out'] as num?)?.toDouble(),
      );
}

class ProviderProfile {
  const ProviderProfile({
    required this.id,
    required this.name,
    required this.baseUrl,
    this.apiKey = '',
    this.chatPath = '/chat/completions',
    required this.defaultModel,
    this.reasonModel = '',
    this.capabilities = const ProviderCapabilities(),
    this.thinkingStyle = ThinkingStyle.none,
    this.authStyle = AuthStyle.bearer,
    this.authHeaderName = 'Authorization',
    this.extraHeaders = const {},
    this.extraBody = const {},
    this.models = const [],
    this.builtIn = false,
    this.sendTemperature = true,
  });

  final String id;
  final String name;
  final String baseUrl;
  final String apiKey;
  final String chatPath;
  final String defaultModel;
  final String reasonModel;
  final ProviderCapabilities capabilities;
  final ThinkingStyle thinkingStyle;
  final AuthStyle authStyle;
  final String authHeaderName;
  final Map<String, String> extraHeaders;
  final Map<String, Object?> extraBody;
  final List<ModelInfo> models;
  final bool builtIn;
  final bool sendTemperature;

  bool get ready => apiKey.isNotEmpty;

  ProviderCapabilities capabilitiesFor(String model) {
    for (final info in models) {
      if (info.id == model) {
        return ProviderCapabilities(
          vision: info.vision ?? capabilities.vision,
          tools: info.tools ?? capabilities.tools,
          streamUsage: capabilities.streamUsage,
          reasoning: info.reasoning ?? capabilities.reasoning,
        );
      }
    }
    return capabilities;
  }

  ProviderProfile copyWith({
    String? name,
    String? baseUrl,
    String? apiKey,
    String? chatPath,
    String? defaultModel,
    String? reasonModel,
    ProviderCapabilities? capabilities,
    ThinkingStyle? thinkingStyle,
    AuthStyle? authStyle,
    String? authHeaderName,
    Map<String, String>? extraHeaders,
    Map<String, Object?>? extraBody,
    List<ModelInfo>? models,
    bool? builtIn,
    bool? sendTemperature,
  }) =>
      ProviderProfile(
        id: id,
        name: name ?? this.name,
        baseUrl: baseUrl ?? this.baseUrl,
        apiKey: apiKey ?? this.apiKey,
        chatPath: chatPath ?? this.chatPath,
        defaultModel: defaultModel ?? this.defaultModel,
        reasonModel: reasonModel ?? this.reasonModel,
        capabilities: capabilities ?? this.capabilities,
        thinkingStyle: thinkingStyle ?? this.thinkingStyle,
        authStyle: authStyle ?? this.authStyle,
        authHeaderName: authHeaderName ?? this.authHeaderName,
        extraHeaders: extraHeaders ?? this.extraHeaders,
        extraBody: extraBody ?? this.extraBody,
        models: models ?? this.models,
        builtIn: builtIn ?? this.builtIn,
        sendTemperature: sendTemperature ?? this.sendTemperature,
      );

  Map<String, Object?> toJson({bool maskKey = false}) => {
        'id': id,
        'name': name,
        'base_url': baseUrl,
        'api_key': maskKey ? maskedKey : apiKey,
        'chat_path': chatPath,
        'default_model': defaultModel,
        'reason_model': reasonModel,
        'capabilities': capabilities.toJson(),
        'thinking_style': thinkingStyle.name,
        'auth_style': authStyle.name,
        'auth_header_name': authHeaderName,
        if (extraHeaders.isNotEmpty) 'extra_headers': extraHeaders,
        if (extraBody.isNotEmpty) 'extra_body': extraBody,
        'models': [for (final item in models) item.toJson()],
        'built_in': builtIn,
        'send_temperature': sendTemperature,
      };

  String get maskedKey {
    final key = apiKey;
    if (key.isEmpty) return '';
    if (key.length <= 8) return '已配置';
    return 'sk-${'•' * 8}${key.substring(key.length - 4)}';
  }

  static ThinkingStyle _thinkingStyle(Object? raw) {
    for (final value in ThinkingStyle.values) {
      if (value.name == raw) return value;
    }
    return ThinkingStyle.none;
  }

  static AuthStyle _authStyle(Object? raw) {
    for (final value in AuthStyle.values) {
      if (value.name == raw) return value;
    }
    return AuthStyle.bearer;
  }

  factory ProviderProfile.fromJson(
    Map json, {
    ProviderProfile? fallback,
  }) {
    final base = fallback;
    final modelsRaw = json['models'];
    final models = <ModelInfo>[
      if (modelsRaw is List)
        for (final item in modelsRaw)
          if (item is Map) ModelInfo.fromJson(item),
    ];
    final headersRaw = json['extra_headers'];
    final extraHeaders = <String, String>{
      if (headersRaw is Map)
        for (final entry in headersRaw.entries)
          entry.key.toString(): entry.value.toString(),
    };
    final bodyRaw = json['extra_body'];
    final extraBody = bodyRaw is Map
        ? bodyRaw.map((key, value) => MapEntry(key.toString(), value))
        : <String, Object?>{};
    return ProviderProfile(
      id: (json['id'] ?? base?.id ?? '').toString(),
      name: (json['name'] ?? base?.name ?? '自定义供应商').toString(),
      baseUrl: (json['base_url'] ?? base?.baseUrl ?? '').toString(),
      apiKey: (json['api_key'] ?? base?.apiKey ?? '').toString(),
      chatPath: (json['chat_path'] ?? base?.chatPath ?? '/chat/completions').toString(),
      defaultModel: (json['default_model'] ?? base?.defaultModel ?? '').toString(),
      reasonModel: (json['reason_model'] ?? base?.reasonModel ?? '').toString(),
      capabilities: ProviderCapabilities.fromJson(
        json['capabilities'],
        fallback: base?.capabilities ?? const ProviderCapabilities(),
      ),
      thinkingStyle: _thinkingStyle(json['thinking_style'] ?? base?.thinkingStyle.name),
      authStyle: _authStyle(json['auth_style'] ?? base?.authStyle.name),
      authHeaderName:
          (json['auth_header_name'] ?? base?.authHeaderName ?? 'Authorization').toString(),
      extraHeaders: extraHeaders.isEmpty ? (base?.extraHeaders ?? const {}) : extraHeaders,
      extraBody: extraBody.isEmpty ? (base?.extraBody ?? const {}) : extraBody,
      models: models.isEmpty ? (base?.models ?? const []) : models,
      builtIn: json['built_in'] is bool ? json['built_in'] as bool : (base?.builtIn ?? false),
      sendTemperature: json['send_temperature'] is bool
          ? json['send_temperature'] as bool
          : (base?.sendTemperature ?? true),
    );
  }
}

/// 供应商注册表：预置 + 用户在 settings.providers_v1 的覆盖。
class ProviderRegistry {
  static const String settingsKey = 'providers_v1';
  static const String activeKey = 'active_provider';
  static const String defaultProviderId = 'deepseek';

  static List<ProviderProfile> builtIns() => const [
        ProviderProfile(
          id: 'deepseek',
          name: 'DeepSeek',
          baseUrl: 'https://api.deepseek.com',
          defaultModel: 'deepseek-flash',
          reasonModel: 'deepseek-v4-pro',
          capabilities: ProviderCapabilities(
            vision: true,
            tools: true,
            streamUsage: true,
            reasoning: true,
          ),
          thinkingStyle: ThinkingStyle.deepseek,
          builtIn: true,
          models: [
            ModelInfo(id: 'deepseek-flash', label: '快、便宜、支持图片'),
            ModelInfo(id: 'deepseek-v4-pro', label: '强推理，不支持图片', vision: false),
          ],
        ),
        ProviderProfile(
          id: 'kimi',
          name: 'Moonshot / Kimi',
          baseUrl: 'https://api.moonshot.cn/v1',
          defaultModel: 'kimi-k3.1-pro',
          reasonModel: 'kimi-k3.1-pro',
          capabilities: ProviderCapabilities(tools: true, reasoning: true),
          thinkingStyle: ThinkingStyle.openaiEffort,
          sendTemperature: false,
          builtIn: true,
          models: [
            ModelInfo(
              id: 'kimi-k3.1-pro',
              label: 'K3.1 Pro 旗舰（视觉/思考）',
              vision: true,
              reasoning: true,
            ),
            ModelInfo(
              id: 'kimi-k3.1-pro-highspeed',
              label: 'K3.1 Pro 高速版',
              vision: true,
              reasoning: true,
            ),
            ModelInfo(id: 'kimi-k2.6', label: 'K2.6 通用'),
            ModelInfo(id: 'kimi-k2.7-code', label: 'K2.7 Code'),
            ModelInfo(id: 'moonshot-v1-128k', label: '128k 长文本'),
            ModelInfo(id: 'moonshot-v1-32k', label: '32k 长文本'),
            ModelInfo(id: 'moonshot-v1-8k', label: '8k 通用'),
            ModelInfo(
              id: 'moonshot-v1-8k-vision-preview',
              label: '8k 视觉',
              vision: true,
            ),
          ],
        ),
        ProviderProfile(
          id: 'glm',
          name: '智谱 GLM',
          baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
          defaultModel: 'glm-5.3',
          reasonModel: 'glm-5.3',
          capabilities: ProviderCapabilities(tools: true, reasoning: true),
          thinkingStyle: ThinkingStyle.zhipu,
          builtIn: true,
          models: [
            ModelInfo(id: 'glm-5.3', label: 'GLM-5.3 旗舰（思考）', reasoning: true),
            ModelInfo(
              id: 'glm-5.3-flash',
              label: 'GLM-5.3 Flash（视觉）',
              vision: true,
              reasoning: true,
            ),
            ModelInfo(id: 'glm-5.2', label: 'GLM-5.2'),
            ModelInfo(id: 'glm-4.5', label: 'GLM-4.5 推理'),
            ModelInfo(id: 'glm-4.5-air', label: 'GLM-4.5 Air 轻量'),
            ModelInfo(id: 'glm-4.5-flash', label: 'GLM-4.5 Flash'),
            ModelInfo(id: 'glm-4v-plus', label: 'GLM-4V 视觉', vision: true, reasoning: false),
            ModelInfo(id: 'glm-4.5v', label: 'GLM-4.5V 视觉推理', vision: true),
          ],
        ),
      ];

  static List<ProviderProfile> decodeStored(String raw) {
    if (raw.trim().isEmpty) return const [];
    try {
      final data = jsonDecode(raw);
      if (data is! List) return const [];
      final byId = {for (final item in builtIns()) item.id: item};
      final result = <ProviderProfile>[];
      for (final item in data) {
        if (item is! Map) continue;
        final id = (item['id'] ?? '').toString();
        if (id.isEmpty) continue;
        result.add(ProviderProfile.fromJson(item, fallback: byId[id]));
      }
      return result;
    } catch (_) {
      return const [];
    }
  }

  static List<ProviderProfile> all() {
    final stored = decodeStored(Db.setting(settingsKey, '[]'));
    final byId = <String, ProviderProfile>{
      for (final item in builtIns()) item.id: item,
    };
    for (final item in stored) {
      byId[item.id] = item;
    }
    return byId.values.toList();
  }

  static ProviderProfile? byId(String id) {
    for (final item in all()) {
      if (item.id == id) return item;
    }
    return null;
  }

  static ProviderProfile active() {
    ensureMigrated();
    final id = Db.setting(activeKey, defaultProviderId);
    return byId(id) ?? byId(defaultProviderId) ?? builtIns().first;
  }

  /// 合并设置页提交的 providers JSON；Key 为空或掩码时保留旧 Key。
  static List<ProviderProfile> mergeIncoming(
    Object? raw,
    List<ProviderProfile> existing,
  ) {
    if (raw is! String || raw.trim().isEmpty) return const [];
    final byId = {for (final profile in existing) profile.id: profile};
    final result = <ProviderProfile>[];
    try {
      final data = jsonDecode(raw);
      if (data is List) {
        for (final item in data) {
          if (item is! Map) continue;
          final id = (item['id'] ?? '').toString();
          if (id.isEmpty) continue;
          final fallback = byId[id];
          final profile = ProviderProfile.fromJson(item, fallback: fallback);
          final key = profile.apiKey;
          result.add(key.isEmpty || key.contains('•')
              ? profile.copyWith(apiKey: fallback?.apiKey ?? '')
              : profile);
        }
      }
    } catch (_) {}
    return result;
  }

  static void saveAll(List<ProviderProfile> profiles) {
    Db.setSetting(
      settingsKey,
      jsonEncode([for (final item in profiles) item.toJson()]),
    );
  }

  static void setActive(String id) {
    if (byId(id) == null) return;
    Db.setSetting(activeKey, id);
  }

  /// 首次运行 v0.7.0：把旧 DeepSeek 设置迁移成 deepseek profile。
  static void ensureMigrated() {
    final storedRaw = Db.setting(settingsKey, '[]');
    if (decodeStored(storedRaw).isNotEmpty) return;
    final legacyKey = Db.setting('api_key');
    final legacyBase = Db.setting('base_url', 'https://api.deepseek.com');
    final legacyModel = Db.setting('model', 'deepseek-flash');
    final legacyReason = Db.setting('reason_model', 'deepseek-v4-pro');
    final host = Uri.tryParse(legacyBase)?.host ?? '';
    final usesDeepSeek = legacyBase.isEmpty || host.endsWith('deepseek.com');
    final ProviderProfile migrated;
    if (usesDeepSeek) {
      migrated = builtIns()
          .firstWhere((item) => item.id == 'deepseek')
          .copyWith(
            apiKey: legacyKey,
            baseUrl: legacyBase,
            defaultModel: legacyModel,
            reasonModel: legacyReason,
          );
    } else {
      // 旧版允许在 DeepSeek 面板填任意 OpenAI 兼容 Base URL；迁移成自定义
      // 供应商，避免把 DeepSeek 专有 thinking/stream_options 发给第三方端点。
      migrated = ProviderProfile(
        id: 'custom_migrated',
        name: '自定义（迁移）',
        baseUrl: legacyBase,
        apiKey: legacyKey,
        defaultModel: legacyModel,
        reasonModel: legacyReason,
        capabilities: const ProviderCapabilities(vision: true, tools: true),
        thinkingStyle: ThinkingStyle.none,
      );
    }
    saveAll([migrated]);
    if (!usesDeepSeek) {
      Db.setSetting(activeKey, migrated.id);
    } else if (Db.setting(activeKey).isEmpty) {
      Db.setSetting(activeKey, migrated.id);
    }
  }

  static LlmConfig config({
    String? providerId,
    String? modelOverride,
    bool thinkingHigh = false,
  }) {
    final profile = providerId == null ? active() : (byId(providerId) ?? active());
    final model = modelOverride ??
        (thinkingHigh && profile.reasonModel.isNotEmpty
            ? profile.reasonModel
            : profile.defaultModel);
    return LlmConfig(
      apiKey: profile.apiKey,
      baseUrl: profile.baseUrl,
      model: model,
      providerId: profile.id,
      providerName: profile.name,
      chatPath: profile.chatPath,
      capabilities: profile.capabilitiesFor(model),
      thinkingStyle: profile.thinkingStyle,
      authStyle: profile.authStyle,
      authHeaderName: profile.authHeaderName,
      extraHeaders: profile.extraHeaders,
      extraBody: profile.extraBody,
      sendTemperature: profile.sendTemperature,
    );
  }
}

class LlmConfig {
  LlmConfig({
    required this.apiKey,
    required this.baseUrl,
    required this.model,
    this.providerId = 'deepseek',
    this.providerName = 'DeepSeek',
    this.chatPath = '/chat/completions',
    this.capabilities = const ProviderCapabilities(
      vision: true,
      tools: true,
      streamUsage: true,
      reasoning: true,
    ),
    this.thinkingStyle = ThinkingStyle.deepseek,
    this.authStyle = AuthStyle.bearer,
    this.authHeaderName = 'Authorization',
    this.extraHeaders = const {},
    this.extraBody = const {},
    this.sendTemperature = true,
  });

  /// 兼容旧调用：只读旧 settings 键，行为与 v0.6.x 一致。
  factory LlmConfig.fromDb({String? modelOverride}) => LlmConfig(
        apiKey: Db.setting('api_key'),
        baseUrl: Db.setting('base_url', 'https://api.deepseek.com'),
        model: modelOverride ?? Db.setting('model', 'deepseek-flash'),
      );

  final String apiKey;
  final String baseUrl;
  final String model;
  final String providerId;
  final String providerName;
  final String chatPath;
  final ProviderCapabilities capabilities;
  final ThinkingStyle thinkingStyle;
  final AuthStyle authStyle;
  final String authHeaderName;
  final Map<String, String> extraHeaders;
  final Map<String, Object?> extraBody;
  final bool sendTemperature;

  bool get ready => apiKey.isNotEmpty;
}

const _prices = {
  'deepseek-flash': (0.15, 0.60),
  'deepseek-v4-pro': (0.66, 1.98),
};

double estimateCost(String model, int tokensIn, int tokensOut) {
  final price = _prices[model];
  if (price == null) return 0;
  final (priceIn, priceOut) = price;
  final hour = DateTime.now().toUtc().hour;
  final peak = (hour >= 1 && hour < 4) || (hour >= 6 && hour < 10);
  final multiplier = peak ? 2.0 : 1.0;
  final cost = (tokensIn * priceIn + tokensOut * priceOut) / 1000000 * multiplier;
  return double.parse(cost.toStringAsFixed(6));
}

String _explain(int status, String detail, String providerName) {
  if (status == 401) return '$providerName API Key 无效或已过期，请到设置里检查。';
  if (status == 402) return '$providerName 账户余额不足，请充值后再试。';
  if (status == 403) return '$providerName 拒绝访问（403），请检查模型权限或实名/额度。';
  if (status == 429) return '$providerName 请求太频繁（限流），稍等几秒再试。';
  if (status >= 500) return '$providerName 服务暂时不可用（$status），稍后重试。';
  final short = detail.length > 200 ? detail.substring(0, 200) : detail;
  return '请求失败（$status）：$short';
}

Uri _uri(LlmConfig config) {
  final base = config.baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
  if (base.endsWith('/chat/completions')) return Uri.parse(base);
  final path = config.chatPath.trim();
  final suffix = path.isEmpty
      ? '/chat/completions'
      : (path.startsWith('/') ? path : '/$path');
  return Uri.parse('$base$suffix');
}

Map<String, String> _headers(LlmConfig config, {bool stream = true}) {
  final headers = <String, String>{
    'Content-Type': 'application/json',
    'Accept': stream ? 'text/event-stream' : 'application/json',
  };
  if (config.authStyle == AuthStyle.apiKeyHeader) {
    headers[config.authHeaderName] = config.apiKey;
  } else {
    headers['Authorization'] = 'Bearer ${config.apiKey}';
  }
  headers.addAll(config.extraHeaders);
  return headers;
}

const _protectedBodyKeys = {
  'model',
  'messages',
  'stream',
  'temperature',
  'max_tokens',
  'stream_options',
  'tools',
  'tool_choice',
};

void _applyThinking(
  Map<String, dynamic> body,
  LlmConfig config,
  String thinking,
) {
  if (thinking != 'high' || !config.capabilities.reasoning) return;
  switch (config.thinkingStyle) {
    case ThinkingStyle.deepseek:
      body['thinking'] = {'type': 'enabled'};
      body['reasoning_effort'] = 'high';
    case ThinkingStyle.zhipu:
      body['thinking'] = {'type': 'enabled'};
    case ThinkingStyle.openaiEffort:
      body['reasoning_effort'] = 'high';
    case ThinkingStyle.none:
    case ThinkingStyle.custom:
      break;
  }
}

Map<String, dynamic> _buildBody({
  required LlmConfig config,
  required List<Map<String, dynamic>> messages,
  List<Map<String, dynamic>>? tools,
  required double temperature,
  required String thinking,
  required bool stream,
  int? maxTokens,
}) {
  final body = <String, dynamic>{
    'model': config.model,
    'messages': messages,
    'stream': stream,
    if (config.sendTemperature) 'temperature': temperature,
    if (stream && config.capabilities.streamUsage)
      'stream_options': {'include_usage': true},
    'max_tokens': ?maxTokens,
  };
  if (tools != null && tools.isNotEmpty && config.capabilities.tools) {
    body['tools'] = tools;
    body['tool_choice'] = 'auto';
  }
  _applyThinking(body, config, thinking);
  for (final entry in config.extraBody.entries) {
    if (_protectedBodyKeys.contains(entry.key)) continue;
    body[entry.key] = entry.value;
  }
  return body;
}

Stream<Map<String, dynamic>> streamChat({
  required LlmConfig config,
  required List<Map<String, dynamic>> messages,
  List<Map<String, dynamic>>? tools,
  double temperature = 0.7,
  String thinking = 'medium',
}) async* {
  if (!config.ready) {
    throw LlmException(
      '还没有配置 ${config.providerName} API Key，点左下角「设置」填入。',
      status: 401,
    );
  }
  final body = _buildBody(
    config: config,
    messages: messages,
    tools: tools,
    temperature: temperature,
    thinking: thinking,
    stream: true,
  );

  final client = http.Client();
  try {
    final request = http.Request('POST', _uri(config));
    request.headers.addAll(_headers(config));
    request.body = jsonEncode(body);
    final response = await client.send(request).timeout(const Duration(seconds: 180));
    if (response.statusCode != 200) {
      final raw = await response.stream.bytesToString();
      throw LlmException(
        _explain(response.statusCode, raw, config.providerName),
        status: response.statusCode,
      );
    }
    await for (final line in response.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())) {
      if (!line.startsWith('data:')) continue;
      final data = line.substring(5).trim();
      if (data == '[DONE]') break;
      try {
        final decoded = jsonDecode(data);
        if (decoded is Map<String, dynamic>) yield decoded;
      } catch (_) {}
    }
  } finally {
    client.close();
  }
}

Future<(String, Map<String, dynamic>)> complete({
  required LlmConfig config,
  required List<Map<String, dynamic>> messages,
  double temperature = 0.4,
  int? maxTokens,
}) async {
  if (!config.ready) {
    throw LlmException('还没有配置 ${config.providerName} API Key。', status: 401);
  }
  final body = _buildBody(
    config: config,
    messages: messages,
    temperature: temperature,
    thinking: 'medium',
    stream: false,
    maxTokens: maxTokens,
  );
  final response = await http
      .post(
        _uri(config),
        headers: _headers(config, stream: false),
        body: jsonEncode(body),
      )
      .timeout(const Duration(seconds: 180));
  if (response.statusCode != 200) {
    throw LlmException(
      _explain(response.statusCode, response.body, config.providerName),
      status: response.statusCode,
    );
  }
  final data = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
  final choices = data['choices'] as List? ?? [];
  final message = choices.isNotEmpty
      ? ((choices.first as Map)['message'] as Map? ?? {})
      : <String, dynamic>{};
  final content = (message['content'] ?? '').toString().trim();
  return (content, (data['usage'] as Map?)?.cast<String, dynamic>() ?? {});
}

/// 供设置页/测试连接复用的请求头（默认 JSON，不含 SSE）。
Map<String, String> providerHeaders(LlmConfig config) =>
    _headers(config, stream: false);

Uri _modelsUri(LlmConfig config) {
  final base = config.baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
  const chatSuffix = '/chat/completions';
  if (base.endsWith(chatSuffix)) {
    return Uri.parse('${base.substring(0, base.length - chatSuffix.length)}/models');
  }
  if (base.endsWith('/models')) return Uri.parse(base);
  return Uri.parse('$base/models');
}

/// 拉取供应商 `/models` 列表。解析 OpenAI 风格 `{data:[{id}]}`，也兼容
/// `{models:[...]}` 和纯字符串数组。
Future<List<ModelInfo>> fetchModels(LlmConfig config) async {
  if (!config.ready) {
    throw LlmException(
      '还没有配置 ${config.providerName} API Key，点左下角「设置」填入。',
      status: 401,
    );
  }
  final response = await http
      .get(_modelsUri(config), headers: providerHeaders(config))
      .timeout(const Duration(seconds: 20));
  if (response.statusCode != 200) {
    throw LlmException(
      _explain(response.statusCode, response.body, config.providerName),
      status: response.statusCode,
    );
  }
  final decoded = jsonDecode(utf8.decode(response.bodyBytes));
  final raw = decoded is Map
      ? (decoded['data'] ?? decoded['models'] ?? const [])
      : (decoded is List ? decoded : const []);
  final models = <ModelInfo>[];
  final seen = <String>{};
  if (raw is List) {
    for (final item in raw) {
      final id = switch (item) {
        String value => value.trim(),
        Map value => (value['id'] ?? value['name'] ?? '').toString().trim(),
        _ => '',
      };
      if (id.isEmpty || !seen.add(id)) continue;
      models.add(ModelInfo(id: id));
    }
  }
  return models;
}

/// 把远端拉取的模型合并到现有列表：保留已有模型的能力/标签和顺序，
/// 只追加远端新增的模型 ID。
List<ModelInfo> mergeFetchedModels(
  List<ModelInfo> existing,
  List<ModelInfo> fetched,
) {
  final byId = {for (final item in existing) item.id: item};
  final merged = <ModelInfo>[...existing];
  for (final item in fetched) {
    if (byId.containsKey(item.id)) continue;
    byId[item.id] = item;
    merged.add(item);
  }
  return merged;
}

Object? extractJson(String text) {
  var source = text.trim();
  if (source.startsWith('```')) {
    final first = source.indexOf('\n');
    final last = source.lastIndexOf('```');
    if (first >= 0 && last > first) {
      source = source.substring(first + 1, last).trim();
    }
  }
  for (final pair in [
    ('[', ']'),
    ('{', '}'),
  ]) {
    final start = source.indexOf(pair.$1);
    final end = source.lastIndexOf(pair.$2);
    if (start >= 0 && end > start) {
      try {
        return jsonDecode(source.substring(start, end + 1));
      } catch (_) {}
    }
  }
  return null;
}