import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:loop/backend/llm.dart';

/// M1 请求层契约测试：不同供应商只发送自己支持的字段。
class _Captured {
  Map<String, Object?> body = const {};
  Map<String, String> headers = const {};
  Uri uri = Uri();
}

Future<_Captured> _capture(
  LlmConfig Function(Uri serverBase) build, {
  List<Map<String, dynamic>>? tools,
  String thinking = 'medium',
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final captured = _Captured();
  final done = Completer<void>();
  server.listen((request) async {
    captured.uri = request.uri;
    final headers = <String, String>{};
    request.headers.forEach((name, values) {
      headers[name.toLowerCase()] = values.join(',');
    });
    captured.headers = headers;
    final raw = await utf8.decoder.bind(request).join();
    captured.body = (jsonDecode(raw) as Map).cast<String, Object?>();
    request.response.headers.contentType = ContentType('text', 'event-stream');
    request.response.write('data: {"choices":[{"delta":{"content":"ok"}}]}\n\n');
    request.response.write('data: [DONE]\n\n');
    await request.response.close();
    if (!done.isCompleted) done.complete();
  });

  final config = build(Uri.parse('http://127.0.0.1:${server.port}'));
  await streamChat(
    config: config,
    messages: [
      {'role': 'user', 'content': 'hi'},
    ],
    tools: tools,
    thinking: thinking,
  ).drain<void>();
  await done.future.timeout(const Duration(seconds: 5));
  await server.close(force: true);
  return captured;
}

void main() {
  test('R1 DeepSeek 默认：保留 stream_options + thinking/reasoning_effort + tools', () async {
    final captured = await _capture(
      (base) => LlmConfig(
        apiKey: 'sk-test',
        baseUrl: base.toString(),
        model: 'deepseek-flash',
      ),
      thinking: 'high',
      tools: [
        {
          'type': 'function',
          'function': {'name': 'search', 'parameters': <String, Object?>{}},
        },
      ],
    );

    expect(captured.uri.path, '/chat/completions');
    expect(captured.headers['authorization'], 'Bearer sk-test');
    expect(captured.body['model'], 'deepseek-flash');
    expect(captured.body['stream'], isTrue);
    expect(captured.body['stream_options'], {'include_usage': true});
    expect(captured.body['thinking'], {'type': 'enabled'});
    expect(captured.body['reasoning_effort'], 'high');
    expect(captured.body['tools'], isA<List<Object?>>());
  });

  test('R2 Kimi：不发 stream_options，也不发 DeepSeek 专有 thinking 字段', () async {
    final captured = await _capture(
      (base) => LlmConfig(
        apiKey: 'sk-kimi',
        baseUrl: '${base.toString()}/v1',
        model: 'kimi-k2-0905-preview',
        providerId: 'kimi',
        providerName: 'Moonshot / Kimi',
        capabilities: const ProviderCapabilities(tools: true),
        thinkingStyle: ThinkingStyle.none,
      ),
      thinking: 'high',
      tools: [
        {
          'type': 'function',
          'function': {'name': 'search', 'parameters': <String, Object?>{}},
        },
      ],
    );

    expect(captured.uri.path, '/v1/chat/completions');
    expect(captured.body.containsKey('stream_options'), isFalse);
    expect(captured.body.containsKey('thinking'), isFalse);
    expect(captured.body.containsKey('reasoning_effort'), isFalse);
    expect(captured.body['tools'], isA<List<Object?>>());
  });

  test('R3 GLM：thinking 使用智谱形态，不带 reasoning_effort', () async {
    final captured = await _capture(
      (base) => LlmConfig(
        apiKey: 'sk-glm',
        baseUrl: '${base.toString()}/api/paas/v4',
        model: 'glm-4.5',
        providerId: 'glm',
        providerName: '智谱 GLM',
        capabilities: const ProviderCapabilities(tools: true, reasoning: true),
        thinkingStyle: ThinkingStyle.zhipu,
      ),
      thinking: 'high',
    );

    expect(captured.uri.path, '/api/paas/v4/chat/completions');
    expect(captured.body['thinking'], {'type': 'enabled'});
    expect(captured.body.containsKey('reasoning_effort'), isFalse);
    expect(captured.body.containsKey('stream_options'), isFalse);
  });

  test('R4 自定义端点：自定义鉴权头/额外头/extra body 生效且不覆盖核心字段', () async {
    final captured = await _capture(
      (base) => LlmConfig(
        apiKey: 'custom-key',
        baseUrl: base.toString(),
        model: 'my-model',
        providerId: 'custom',
        providerName: '自定义',
        authStyle: AuthStyle.apiKeyHeader,
        authHeaderName: 'x-api-key',
        extraHeaders: const {'X-Trace': 'loop'},
        extraBody: const {'top_p': 0.5, 'model': 'should-not-win'},
        capabilities: const ProviderCapabilities(tools: true, streamUsage: true),
      ),
    );

    expect(captured.headers['x-api-key'], 'custom-key');
    expect(captured.headers.containsKey('authorization'), isFalse);
    expect(captured.headers['x-trace'], 'loop');
    expect(captured.body['top_p'], 0.5);
    expect(captured.body['model'], 'my-model');
    expect(captured.body['stream_options'], {'include_usage': true});
  });

  test('R5 模型不支持工具时不发送 tools；不支持流式用量时不发 stream_options', () async {
    final captured = await _capture(
      (base) => LlmConfig(
        apiKey: 'sk-test',
        baseUrl: base.toString(),
        model: 'plain-model',
        capabilities: const ProviderCapabilities(),
      ),
      tools: [
        {
          'type': 'function',
          'function': {'name': 'search', 'parameters': <String, Object?>{}},
        },
      ],
    );

    expect(captured.body.containsKey('tools'), isFalse);
    expect(captured.body.containsKey('tool_choice'), isFalse);
    expect(captured.body.containsKey('stream_options'), isFalse);
  });

  test('R7 sendTemperature=false 时不发送 temperature，但保留 reasoning_effort', () async {
    final captured = await _capture(
      (base) => LlmConfig(
        apiKey: 'sk-kimi',
        baseUrl: '${base.toString()}/v1',
        model: 'kimi-k3.1-pro',
        providerId: 'kimi',
        providerName: 'Moonshot / Kimi',
        capabilities: const ProviderCapabilities(tools: true, reasoning: true),
        thinkingStyle: ThinkingStyle.openaiEffort,
        sendTemperature: false,
      ),
      thinking: 'high',
    );

    expect(captured.body.containsKey('temperature'), isFalse);
    expect(captured.body['reasoning_effort'], 'high');
  });

  test('R8 fetchModels 拉取 /v1/models 并去重、带 Bearer 鉴权', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    String? auth;
    String? path;
    final done = Completer<void>();
    server.listen((request) async {
      auth = request.headers.value('authorization');
      path = request.uri.path;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'data': [
          {'id': 'm1'},
          {'id': 'm2'},
          {'id': 'm1'},
          'm3',
        ],
      }));
      await request.response.close();
      if (!done.isCompleted) done.complete();
    });

    final models = await fetchModels(LlmConfig(
      apiKey: 'sk-test',
      baseUrl: 'http://127.0.0.1:${server.port}/v1',
      model: 'any',
    ));
    await done.future.timeout(const Duration(seconds: 5));
    await server.close(force: true);

    expect(path, '/v1/models');
    expect(auth, 'Bearer sk-test');
    expect(models.map((item) => item.id).toList(), ['m1', 'm2', 'm3']);
  });

  test('R9 fetchModels 401 抛出 LlmException，带供应商名', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final done = Completer<void>();
    server.listen((request) async {
      request.response.statusCode = 401;
      request.response.write('{"error":"bad key"}');
      await request.response.close();
      if (!done.isCompleted) done.complete();
    });

    await expectLater(
      fetchModels(LlmConfig(
        apiKey: 'sk-bad',
        baseUrl: 'http://127.0.0.1:${server.port}/v1',
        model: 'any',
        providerName: 'Moonshot / Kimi',
      )),
      throwsA(isA<LlmException>()
          .having((error) => error.status, 'status', 401)
          .having((error) => error.message, 'message', contains('Moonshot'))),
    );
    await done.future.timeout(const Duration(seconds: 5));
    await server.close(force: true);
  });

  test('R6 complete() 非流式请求不带 stream_options', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    Map<String, Object?> body = const {};
    final done = Completer<void>();
    server.listen((request) async {
      body = (jsonDecode(await utf8.decoder.bind(request).join()) as Map)
          .cast<String, Object?>();
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'choices': [
          {
            'message': {'content': '可用'},
          },
        ],
        'usage': {'prompt_tokens': 1, 'completion_tokens': 1},
      }));
      await request.response.close();
      if (!done.isCompleted) done.complete();
    });

    final (text, usage) = await complete(
      config: LlmConfig(
        apiKey: 'sk-test',
        baseUrl: 'http://127.0.0.1:${server.port}',
        model: 'deepseek-flash',
      ),
      messages: [
        {'role': 'user', 'content': 'test'},
      ],
      maxTokens: 8,
    );
    await done.future.timeout(const Duration(seconds: 5));
    await server.close(force: true);

    expect(text, '可用');
    expect(usage['prompt_tokens'], 1);
    expect(body['stream'], isFalse);
    expect(body['max_tokens'], 8);
    expect(body.containsKey('stream_options'), isFalse);
  });
}