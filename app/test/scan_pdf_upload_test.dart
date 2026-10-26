import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:loop/api.dart';
import 'package:loop/backend/llm.dart';
import 'package:loop/backend/server.dart';

void main() {
  late Directory dataDir;
  late int port;
  late LoopApi api;

  setUp(() async {
    dataDir = await Directory.systemTemp.createTemp('loop_ocr_test_');
    port = await Backend.startForTests(dataDir);
    api = LoopApi(baseUrl: 'http://127.0.0.1:$port');
  });

  tearDown(() async {
    await Backend.stopForTests();
    try {
      if (dataDir.existsSync()) dataDir.deleteSync(recursive: true);
    } catch (_) {
      // Windows 上 sqlite 句柄可能仍持有目录；测试临时目录允许残留。
    }
  });

  test('扫描 PDF 上传返回 scan_pdf，不删除临时文件', () async {
    final bytes = await File('test/fixtures/blank_scan.pdf').readAsBytes();
    ScanPdfException? scan;
    try {
      await api.upload(bytes, 'blank_scan.pdf');
    } on ScanPdfException catch (error) {
      scan = error;
    }
    expect(scan, isNotNull);
    expect(scan!.code, 'scan_pdf');
    expect(scan.pages, 1);
    expect(scan.token, isNotEmpty);
    expect(scan.visionModels, isEmpty, reason: '测试环境没有配置任何视觉模型 API Key');

    // 隐私确认必须是显式 true。
    await expectLater(
      api.startOcr(
        token: scan.token,
        provider: 'mock',
        model: 'mock-vision',
        consent: false,
      ),
      throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 400)),
    );
  });

  test('无文本 PDF 可用视觉模型逐页转写并进入资料库', () async {
    final mock = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    mock.listen((request) async {
      await utf8.decoder.bind(request).join();
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'choices': [
          {
            'message': {'role': 'assistant', 'content': '# 扫描页\n\n这是测试转写内容，用于验证资料入库。'}
          }
        ],
        'usage': {'prompt_tokens': 10, 'completion_tokens': 20},
      }));
      await request.response.close();
    });
    addTearDown(() => mock.close(force: true));

    ProviderRegistry.saveAll([
      ProviderProfile(
        id: 'mock',
        name: 'Mock Vision',
        apiKey: 'test-key',
        baseUrl: 'http://127.0.0.1:${mock.port}/v1',
        defaultModel: 'mock-vision',
        capabilities: const ProviderCapabilities(vision: true, tools: false),
        thinkingStyle: ThinkingStyle.none,
        models: const [ModelInfo(id: 'mock-vision', label: 'Mock Vision', vision: true)],
      ),
    ]);
    ProviderRegistry.setActive('mock');

    final bytes = await File('test/fixtures/blank_scan.pdf').readAsBytes();
    final scan = await () async {
      try {
        await api.upload(bytes, 'blank_scan.pdf');
      } on ScanPdfException catch (error) {
        return error;
      }
      fail('应当返回 scan_pdf');
    }();
    final started = await api.startOcr(
      token: scan.token,
      provider: 'mock',
      model: 'mock-vision',
    );
    expect(started['token'], scan.token);

    Map<String, dynamic> status = {};
    for (var i = 0; i < 40; i++) {
      status = await api.ocrStatus(scan.token);
      if (status['status'] == 'done' || status['status'] == 'failed') break;
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    expect(status['status'], 'done', reason: status['error']?.toString());
    final result = status['result'] as Map<String, dynamic>;
    expect(result['ocr'], isTrue);
    expect(result['pages'], 1);
    expect(result['chars'], greaterThan(10));

    final materials = await api.materials();
    expect(materials.where((item) => item.ocr), hasLength(1));
    final preview = await api.materialPreview(materials.first.id);
    expect(preview['text'], contains('测试转写内容'));
  });
}
