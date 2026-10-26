import 'package:flutter_test/flutter_test.dart';
import 'package:loop/backend/ocr_vision.dart' hide VisionModelOption;
import 'package:loop/models.dart';

void main() {
  group('OCR 文本清洗', () {
    test('去掉 Markdown 围栏和客套前言', () {
      expect(
        sanitizeOcrText('```markdown\n以下是本页内容：\n# 标题\n\n正文\n```'),
        contains('# 标题'),
      );
      expect(sanitizeOcrText('好的，以下是本页内容：\n正文'), '正文');
    });

    test('空白页返回空串', () {
      expect(sanitizeOcrText('[空白页]'), '');
      expect(sanitizeOcrText('【空白页】'), '');
      expect(sanitizeOcrText('   '), '');
    });

    test('页码前缀被去掉', () {
      expect(sanitizeOcrText('第 3 页：矩阵的秩'), '矩阵的秩');
    });
  });

  test('MaterialItem 解析 OCR 失败页 JSON 字符串', () {
    final item = MaterialItem.fromJson({
      'id': 1,
      'name': 'scan.pdf',
      'kind': 'pdf',
      'status': 'ocr_partial',
      'pages': 10,
      'chars': 100,
      'ocr': 1,
      'ocr_status': 'partial',
      'ocr_model': 'kimi/kimi-vision',
      'ocr_failed_pages': '[3, 7]',
    });
    expect(item.ocr, isTrue);
    expect(item.ocrStatus, 'partial');
    expect(item.ocrFailedPages, [3, 7]);
  });

  test('VisionModelOption 解析', () {
    final option = VisionModelOption.fromJson({
      'id': 'kimi/kimi-vision',
      'provider': 'kimi',
      'provider_name': 'Moonshot / Kimi',
      'model': 'kimi-vision',
      'label': 'Kimi · 视觉',
    });
    expect(option.provider, 'kimi');
    expect(option.model, 'kimi-vision');
  });
}
