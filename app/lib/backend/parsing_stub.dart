import 'dart:typed_data';

Future<List<String>> extractPages(String path, String ext) async {
  throw UnsupportedError('当前平台不支持解析文件');
}

Future<Uint8List> renderPdfPage(
  String path,
  int pageIndex, {
  int maxSize = 1600,
}) async {
  throw UnsupportedError('当前平台不支持 PDF 渲染');
}
