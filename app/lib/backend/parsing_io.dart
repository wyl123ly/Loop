import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:xml/xml.dart';

/// 把文件抽成按页文本。PDF 依赖 pdfrx（PDFium），DOCX/PPTX 用 zip + XML。
Future<List<String>> extractPages(String path, String ext) async {
  final lower = ext.toLowerCase();
  switch (lower) {
    case '.pdf':
      return _pdf(path);
    case '.docx':
      return _docx(path);
    case '.pptx':
      return _pptx(path);
    case '.txt':
    case '.md':
    case '.markdown':
    case '.csv':
      return [_text(path)];
    default:
      throw FormatException('暂不支持的文件类型：$ext');
  }
}

Future<List<String>> _pdf(String path) async {
  final document = await PdfDocument.openFile(path);
  try {
    final pages = <String>[];
    for (final page in document.pages) {
      final text = await page.loadText();
      pages.add(clean(text?.fullText ?? ''));
    }
    return pages;
  } finally {
    await document.dispose();
  }
}

Future<List<String>> _docx(String path) async {
  final archive = ZipDecoder().decodeBytes(await File(path).readAsBytes());
  final entry = archive.findFile('word/document.xml');
  if (entry == null) throw FormatException('不是有效的 docx 文件');
  final xml = XmlDocument.parse(utf8.decode(entry.content, allowMalformed: true));
  final paragraphs = <String>[];
  for (final element in xml.descendants.whereType<XmlElement>()) {
    if (element.name.local != 'p') continue;
    final buffer = StringBuffer();
    for (final node in element.descendants.whereType<XmlElement>()) {
      if (node.name.local == 't') buffer.write(node.innerText);
    }
    final text = buffer.toString().trim();
    if (text.isNotEmpty) paragraphs.add(text);
  }
  return _paginate(paragraphs);
}

Future<List<String>> _pptx(String path) async {
  final archive = ZipDecoder().decodeBytes(await File(path).readAsBytes());
  final pattern = RegExp(r'^ppt/slides/slide(\d+)\.xml$');
  final slides = archive.where((file) => pattern.hasMatch(file.name)).toList();
  slides.sort((a, b) => _slideNumber(a.name, pattern).compareTo(_slideNumber(b.name, pattern)));
  final pages = <String>[];
  for (final slide in slides) {
    final xml = XmlDocument.parse(utf8.decode(slide.content, allowMalformed: true));
    final buffer = StringBuffer();
    for (final node in xml.descendants.whereType<XmlElement>()) {
      if (node.name.local == 't') {
        final text = node.innerText.trim();
        if (text.isNotEmpty) buffer.writeln(text);
      }
    }
    pages.add(clean(buffer.toString()));
  }
  return pages;
}

int _slideNumber(String name, RegExp pattern) {
  final match = pattern.firstMatch(name);
  return int.tryParse(match?.group(1) ?? '0') ?? 0;
}

String _text(String path) {
  final bytes = File(path).readAsBytesSync();
  return clean(utf8.decode(bytes, allowMalformed: true));
}

List<String> _paginate(List<String> paragraphs, {int size = 3000}) {
  final pages = <String>[];
  final buffer = StringBuffer();
  for (final paragraph in paragraphs) {
    if (buffer.isNotEmpty && buffer.length + paragraph.length > size) {
      pages.add(buffer.toString());
      buffer.clear();
    }
    buffer.writeln(paragraph);
  }
  if (buffer.toString().trim().isNotEmpty) pages.add(buffer.toString());
  return pages;
}

String clean(String text) {
  return text
      .replaceAll('\u00a0', ' ')
      .replaceAll('\ufeff', '')
      .replaceAll(RegExp(r'[ \t]+'), ' ')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();
}
