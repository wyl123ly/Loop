import 'dart:typed_data';

import 'package:flutter/material.dart';

/// 截图完成后恢复窗口所需的状态。
class ScreenshotSession {
  const ScreenshotSession({
    required this.bytes,
    required this.bounds,
    required this.maximized,
    required this.fullScreen,
  });

  final Uint8List bytes;
  final Rect bounds;
  final bool maximized;
  final bool fullScreen;
}
