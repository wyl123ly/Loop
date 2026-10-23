// 桌面端在进程内启动 Dart 后端；Web 端为空实现（Web 构建不使用本地后端）。
export 'start_stub.dart' if (dart.library.io) 'start_io.dart';
