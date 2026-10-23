import 'dart:io';

import 'package:pdfrx/pdfrx.dart';

import 'server.dart';

/// Flutter 桌面端启动时调用：初始化 PDFium，并在当前进程内起 HTTP 服务。
Future<void> startBackend() async {
  try {
    pdfrxFlutterInitialize();
  } catch (error) {
    stderr.writeln('pdfrx init failed: $error');
  }
  try {
    await Backend.start();
  } catch (error, stack) {
    stderr.writeln('backend start failed: $error\n$stack');
  }
}
