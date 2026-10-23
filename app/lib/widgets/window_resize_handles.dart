import 'package:flutter/material.dart';

import '../desktop/window_controls.dart';
import '../desktop/window_resize_edge.dart';

/// 自绘无边框窗口的拖拽缩放热区。
class WindowResizeHandles extends StatelessWidget {
  const WindowResizeHandles({super.key});

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        _handle(left: 12, right: 12, top: 0, height: 6,
            cursor: SystemMouseCursors.resizeUpDown, edge: LoopResizeEdge.top),
        _handle(left: 12, right: 12, bottom: 0, height: 6,
            cursor: SystemMouseCursors.resizeUpDown, edge: LoopResizeEdge.bottom),
        _handle(top: 12, bottom: 12, left: 0, width: 6,
            cursor: SystemMouseCursors.resizeLeftRight, edge: LoopResizeEdge.left),
        _handle(top: 12, bottom: 12, right: 0, width: 6,
            cursor: SystemMouseCursors.resizeLeftRight, edge: LoopResizeEdge.right),
        _handle(left: 0, top: 0, width: 12, height: 12,
            cursor: SystemMouseCursors.resizeUpLeftDownRight, edge: LoopResizeEdge.topLeft),
        _handle(right: 0, top: 0, width: 12, height: 12,
            cursor: SystemMouseCursors.resizeUpRightDownLeft, edge: LoopResizeEdge.topRight),
        _handle(left: 0, bottom: 0, width: 12, height: 12,
            cursor: SystemMouseCursors.resizeUpRightDownLeft, edge: LoopResizeEdge.bottomLeft),
        _handle(right: 0, bottom: 0, width: 12, height: 12,
            cursor: SystemMouseCursors.resizeUpLeftDownRight, edge: LoopResizeEdge.bottomRight),
      ],
    );
  }

  Widget _handle({
    double? left,
    double? top,
    double? right,
    double? bottom,
    double? width,
    double? height,
    required MouseCursor cursor,
    required LoopResizeEdge edge,
  }) {
    return Positioned(
      left: left,
      top: top,
      right: right,
      bottom: bottom,
      width: width,
      height: height,
      child: MouseRegion(
        cursor: cursor,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (_) => WindowController.instance.startResizing(edge),
        ),
      ),
    );
  }
}
