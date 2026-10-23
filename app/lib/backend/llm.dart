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

class LlmConfig {
  LlmConfig({required this.apiKey, required this.baseUrl, required this.model});

  factory LlmConfig.fromDb({String? modelOverride}) => LlmConfig(
        apiKey: Db.setting('api_key'),
        baseUrl: Db.setting('base_url', 'https://api.deepseek.com'),
        model: modelOverride ?? Db.setting('model', 'deepseek-flash'),
      );

  final String apiKey;
  final String baseUrl;
  final String model;

  bool get ready => apiKey.isNotEmpty;
}

const _prices = {
  'deepseek-flash': (0.15, 0.60),
  'deepseek-v4-pro': (0.66, 1.98),
};

double estimateCost(String model, int tokensIn, int tokensOut) {
  final (priceIn, priceOut) = _prices[model] ?? _prices['deepseek-flash']!;
  final hour = DateTime.now().toUtc().hour;
  final peak = (hour >= 1 && hour < 4) || (hour >= 6 && hour < 10);
  final multiplier = peak ? 2.0 : 1.0;
  final cost = (tokensIn * priceIn + tokensOut * priceOut) / 1000000 * multiplier;
  return double.parse(cost.toStringAsFixed(6));
}

String _explain(int status, String detail) {
  if (status == 401) return 'API Key 无效或已过期，请到设置里检查。';
  if (status == 402) return 'DeepSeek 账户余额不足，请充值后再试。';
  if (status == 429) return '请求太频繁（限流），稍等几秒再试。';
  if (status >= 500) return 'DeepSeek 服务暂时不可用（$status），稍后重试。';
  final short = detail.length > 200 ? detail.substring(0, 200) : detail;
  return '请求失败（$status）：$short';
}

Uri _uri(LlmConfig config) => Uri.parse('${config.baseUrl}/chat/completions');

Map<String, String> _headers(LlmConfig config) => {
      'Authorization': 'Bearer ${config.apiKey}',
      'Content-Type': 'application/json',
      'Accept': 'text/event-stream',
    };

Stream<Map<String, dynamic>> streamChat({
  required LlmConfig config,
  required List<Map<String, dynamic>> messages,
  List<Map<String, dynamic>>? tools,
  double temperature = 0.7,
  String thinking = 'medium',
}) async* {
  if (!config.ready) {
    throw LlmException('还没有配置 DeepSeek API Key，点左下角「设置」填入。', status: 401);
  }
  final body = <String, dynamic>{
    'model': config.model,
    'messages': messages,
    'stream': true,
    'temperature': temperature,
    'stream_options': {'include_usage': true},
    if (thinking == 'high') 'thinking': {'type': 'enabled'},
    if (thinking == 'high') 'reasoning_effort': 'high',
  };
  if (tools != null && tools.isNotEmpty) {
    body['tools'] = tools;
    body['tool_choice'] = 'auto';
  }

  final client = http.Client();
  try {
    final request = http.Request('POST', _uri(config));
    request.headers.addAll(_headers(config));
    request.body = jsonEncode(body);
    final response = await client.send(request).timeout(const Duration(seconds: 180));
    if (response.statusCode != 200) {
      final raw = await response.stream.bytesToString();
      throw LlmException(_explain(response.statusCode, raw), status: response.statusCode);
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
    throw LlmException('还没有配置 DeepSeek API Key。', status: 401);
  }
  final body = <String, dynamic>{
    'model': config.model,
    'messages': messages,
    'stream': false,
    'temperature': temperature,
    'max_tokens': ?maxTokens,
  };
  final response = await http
      .post(
        _uri(config),
        headers: {..._headers(config), 'Accept': 'application/json'},
        body: jsonEncode(body),
      )
      .timeout(const Duration(seconds: 180));
  if (response.statusCode != 200) {
    throw LlmException(_explain(response.statusCode, response.body), status: response.statusCode);
  }
  final data = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
  final choices = data['choices'] as List? ?? [];
  final message = choices.isNotEmpty
      ? ((choices.first as Map)['message'] as Map? ?? {})
      : <String, dynamic>{};
  final content = (message['content'] ?? '').toString().trim();
  return (content, (data['usage'] as Map?)?.cast<String, dynamic>() ?? {});
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
