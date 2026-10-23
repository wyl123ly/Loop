import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 全屏截图选框：显示刚截的桌面图，拖拽选择区域，裁切后返回 PNG。
class ScreenshotOverlay extends StatefulWidget {
  const ScreenshotOverlay({super.key, required this.imageBytes});

  final Uint8List imageBytes;

  @override
  State<ScreenshotOverlay> createState() => _ScreenshotOverlayState();
}

class _ScreenshotOverlayState extends State<ScreenshotOverlay> {
  ui.Image? _image;
  Offset? _start;
  Offset? _end;
  Size _viewport = Size.zero;
  bool _cropping = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadImage();
  }

  Future<void> _loadImage() async {
    try {
      final codec = await ui.instantiateImageCodec(widget.imageBytes);
      final frame = await codec.getNextFrame();
      if (!mounted) return;
      setState(() => _image = frame.image);
    } catch (error) {
      if (mounted) setState(() => _error = '截图加载失败：$error');
    }
  }

  Rect? get _selection {
    final start = _start;
    final end = _end;
    if (start == null || end == null) return null;
    final rect = Rect.fromLTRB(
      start.dx < end.dx ? start.dx : end.dx,
      start.dy < end.dy ? start.dy : end.dy,
      start.dx > end.dx ? start.dx : end.dx,
      start.dy > end.dy ? start.dy : end.dy,
    );
    return rect.width >= 4 && rect.height >= 4 ? rect : null;
  }

  void _selectAll() {
    setState(() {
      _start = Offset.zero;
      _end = Offset(_viewport.width, _viewport.height);
    });
  }

  Future<void> _confirm() async {
    final image = _image;
    final rect = _selection;
    if (image == null || rect == null || _cropping) return;
    setState(() => _cropping = true);
    try {
      final scaleX = image.width / _viewport.width;
      final scaleY = image.height / _viewport.height;
      final source = Rect.fromLTWH(
        (rect.left * scaleX).clamp(0.0, image.width.toDouble()),
        (rect.top * scaleY).clamp(0.0, image.height.toDouble()),
        (rect.width * scaleX).clamp(1.0, image.width.toDouble()),
        (rect.height * scaleY).clamp(1.0, image.height.toDouble()),
      );
      final width = source.width.round().clamp(1, image.width);
      final height = source.height.round().clamp(1, image.height);
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      final paint = Paint()..filterQuality = FilterQuality.high;
      canvas.drawImageRect(
        image,
        source,
        Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
        paint,
      );
      final picture = recorder.endRecording();
      final cropped = await picture.toImage(width, height);
      final data = await cropped.toByteData(format: ui.ImageByteFormat.png);
      cropped.dispose();
      if (!mounted) return;
      Navigator.of(context).pop(data?.buffer.asUint8List());
    } catch (error) {
      if (mounted) {
        setState(() {
          _cropping = false;
          _error = '裁切失败：$error';
        });
      }
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.escape) {
      Navigator.of(context).pop();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final selection = _selection;
    return Focus(
      autofocus: true,
      onKeyEvent: _onKey,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: LayoutBuilder(
          builder: (context, constraints) {
            _viewport = constraints.biggest;
            return Stack(
              fit: StackFit.expand,
              children: [
                if (_image != null)
                  RawImage(image: _image, fit: BoxFit.fill, filterQuality: FilterQuality.medium)
                else
                  const Center(child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white)),
                Positioned.fill(
                  child: IgnorePointer(
                    child: CustomPaint(
                      painter: _SelectionPainter(selection, _cropping),
                    ),
                  ),
                ),
                Positioned.fill(
                  child: MouseRegion(
                    cursor: SystemMouseCursors.precise,
                    child: Listener(
                      behavior: HitTestBehavior.opaque,
                      onPointerDown: (event) {
                        setState(() {
                          _start = event.localPosition;
                          _end = event.localPosition;
                        });
                      },
                      onPointerMove: (event) {
                        if (_start == null) return;
                        setState(() => _end = event.localPosition);
                      },
                      onPointerUp: (_) => setState(() {}),
                      child: const ColoredBox(color: Colors.transparent),
                    ),
                  ),
                ),
                Positioned(
                  top: 20,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.62),
                        borderRadius: BorderRadius.circular(99),
                        border: Border.all(color: Colors.white24),
                      ),
                      child: Text(
                        _error ?? '拖拽选择截图区域 · Esc 取消',
                        style: const TextStyle(color: Colors.white, fontSize: 12.5),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 24,
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.72),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: Colors.white24),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          TextButton(
                            onPressed: () => Navigator.of(context).pop(),
                            child: const Text('取消', style: TextStyle(color: Colors.white70)),
                          ),
                          TextButton(
                            onPressed: _selectAll,
                            child: const Text('全屏', style: TextStyle(color: Colors.white70)),
                          ),
                          const SizedBox(width: 4),
                          FilledButton(
                            onPressed: selection == null || _cropping ? null : _confirm,
                            style: FilledButton.styleFrom(
                              backgroundColor: const Color(0xFF8E9BFF),
                              foregroundColor: Colors.white,
                            ),
                            child: Text(_cropping ? '处理中…' : '完成'),
                          ),
                          const SizedBox(width: 4),
                        ],
                      ),
                    ),
                  ),
                ),
                if (_cropping)
                  const Positioned.fill(
                    child: IgnorePointer(
                      child: ColoredBox(color: Color(0x33000000)),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _SelectionPainter extends CustomPainter {
  _SelectionPainter(this.selection, this.busy);

  final Rect? selection;
  final bool busy;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = selection;
    if (rect == null) {
      canvas.drawRect(Offset.zero & size, Paint()..color = Colors.black.withValues(alpha: 0.38));
      return;
    }
    final shade = Paint()..color = Colors.black.withValues(alpha: 0.48);
    canvas.drawRect(Rect.fromLTRB(0, 0, size.width, rect.top), shade);
    canvas.drawRect(Rect.fromLTRB(0, rect.bottom, size.width, size.height), shade);
    canvas.drawRect(Rect.fromLTRB(0, rect.top, rect.left, rect.bottom), shade);
    canvas.drawRect(Rect.fromLTRB(rect.right, rect.top, size.width, rect.bottom), shade);

    final border = Paint()
      ..color = const Color(0xFFB9C1FF)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawRect(rect, border);

    final corner = Paint()
      ..color = const Color(0xFFB9C1FF)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    const len = 12.0;
    canvas.drawLine(rect.topLeft, rect.topLeft + const Offset(len, 0), corner);
    canvas.drawLine(rect.topLeft, rect.topLeft + const Offset(0, len), corner);
    canvas.drawLine(rect.topRight, rect.topRight - const Offset(len, 0), corner);
    canvas.drawLine(rect.topRight, rect.topRight + const Offset(0, len), corner);
    canvas.drawLine(rect.bottomLeft, rect.bottomLeft + const Offset(len, 0), corner);
    canvas.drawLine(rect.bottomLeft, rect.bottomLeft - const Offset(0, len), corner);
    canvas.drawLine(rect.bottomRight, rect.bottomRight - const Offset(len, 0), corner);
    canvas.drawLine(rect.bottomRight, rect.bottomRight - const Offset(0, len), corner);

    if (busy) return;
    final label = '${rect.width.round()} × ${rect.height.round()}';
    final painter = TextPainter(
      text: TextSpan(
        text: label,
        style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final labelRect = Rect.fromLTWH(
      rect.left,
      (rect.top - painter.height - 10).clamp(4.0, size.height),
      painter.width + 12,
      painter.height + 6,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(labelRect, const Radius.circular(4)),
      Paint()..color = Colors.black.withValues(alpha: 0.7),
    );
    painter.paint(canvas, labelRect.topLeft + const Offset(6, 3));
  }

  @override
  bool shouldRepaint(covariant _SelectionPainter oldDelegate) =>
      oldDelegate.selection != selection || oldDelegate.busy != busy;
}
