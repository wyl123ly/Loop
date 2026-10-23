// 文档解析：桌面端用 pdfrx / archive 实现；Web 端不支持本地文件解析。
export 'parsing_stub.dart' if (dart.library.io) 'parsing_io.dart';
