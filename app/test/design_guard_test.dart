import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// v0.8.11 token 守卫：防止字号、圆角、色值、间距回退。
/// 只扫描产品源码，不依赖渲染。
void main() {
  late List<File> sources;
  late Map<String, String> texts;

  setUpAll(() {
    sources = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'))
        .toList();
    texts = {
      for (final file in sources)
        file.path.replaceAll('\\', '/'): file.readAsStringSync(),
    };
  });

  test('G1 不允许字号/圆角数字字面量', () {
    final fontHits = <String>[];
    final radiusHits = <String>[];
    final font = RegExp(r'fontSize:\s*\d');
    final radius = RegExp(r'(?:BorderRadius|Radius)\.circular\(\s*\d');
    for (final entry in texts.entries) {
      for (final match in font.allMatches(entry.value)) {
        fontHits.add('${entry.key}: ${entry.value.substring(match.start, match.end)}');
      }
      for (final match in radius.allMatches(entry.value)) {
        radiusHits.add('${entry.key}: ${entry.value.substring(match.start, match.end)}');
      }
    }
    expect(fontHits, isEmpty, reason: '字号必须走 LoopType：\n${fontHits.join('\n')}');
    expect(radiusHits, isEmpty, reason: '圆角必须走 LoopRadius：\n${radiusHits.join('\n')}');
  });

  test('G2 palette 外不允许硬编码色，也不允许语义色当文字', () {
    final colorHits = <String>[];
    final semanticHits = <String>[];
    for (final entry in texts.entries) {
      if (entry.key.endsWith('theme/palette.dart')) continue;
      if (entry.value.contains('Color(0x')) colorHits.add(entry.key);
      if (RegExp(r'pal\.(warm|accent2)\b').hasMatch(entry.value)) {
        semanticHits.add(entry.key);
      }
    }
    expect(colorHits, isEmpty, reason: '这些文件仍有 palette 外色值：$colorHits');
    expect(semanticHits, isEmpty,
        reason: 'warm/accent2 只能做装饰，文字请用 warningInk/accentInk：$semanticHits');
  });

  test('G3 EdgeInsets 数值必须在 4px 网格上', () {
    final allowed = <double>{0, 4, 8, 12, 16, 20, 24, 32, 48};
    final bad = <String>[];
    final edge = RegExp(r'EdgeInsets\.(?:all|fromLTRB|symmetric|only)\(([^()]*)\)');
    for (final entry in texts.entries) {
      for (final match in edge.allMatches(entry.value)) {
        for (final raw in RegExp(r'(?<![\w.])(\d+(?:\.\d+)?)(?![\w.])')
            .allMatches(match.group(1)!)) {
          final value = double.parse(raw.group(1)!);
          if (!allowed.contains(value)) {
            bad.add('${entry.key}: $value');
          }
        }
      }
    }
    expect(bad, isEmpty, reason: '离网格 EdgeInsets：\n${bad.join('\n')}');
  });

  test('G4 用户气泡、语义 token 必须真实接入', () {
    final chat = texts['lib/screens/chat_screen.dart'] ?? '';
    expect(chat.contains('pal.userBubbleGradient'), isTrue,
        reason: '用户气泡必须使用 userBubbleGradient');
    expect(chat.contains('pal.userBubbleGradient'), isTrue);
    final all = texts.values.join('\n');
    for (final token in ['warningInk', 'accentInk', 'dangerInk', 'success']) {
      expect(all.contains('pal.$token'), isTrue, reason: '$token 没有被产品 UI 使用');
    }
  });

  test('G5 Colors.white 只允许装饰/叠加层', () {
    const allow = {
      'lib/theme/palette.dart',
      'lib/screens/screenshot_overlay.dart',
      'lib/widgets/image_preview.dart',
    };
    final hits = <String>[];
    for (final entry in texts.entries) {
      if (allow.contains(entry.key)) continue;
      if (entry.value.contains('Colors.white')) hits.add(entry.key);
    }
    expect(hits, isEmpty, reason: '这些文件在浅底上仍有 Colors.white：$hits');
  });
}