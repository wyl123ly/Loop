import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';

/// 截图覆盖层的结果。
///
/// - `done(bytes)`：用户完成框选，返回裁切后的 PNG；
/// - `retake()`：用户要求重新取景（调用方先恢复窗口再重新捕获）；
/// - `null`（`Navigator.pop` 不携带结果）：取消/Esc，不上传。
class ScreenshotOverlayResult {
  const ScreenshotOverlayResult.done(Uint8List this.bytes) : retake = false;
  const ScreenshotOverlayResult.retake()
      : bytes = null,
        retake = true;

  final Uint8List? bytes;
  final bool retake;
}

/// 全屏截图选框：显示刚截的桌面图，拖拽选择区域，裁切后返回 PNG。
///
/// 浮窗与主窗口共用；`allowRetake=false` 时（重截次数用尽）隐藏重截按钮。
class ScreenshotOverlay extends StatefulWidget {
  const ScreenshotOverlay({
    super.key,
    required this.imageBytes,
    this.allowRetake = true,
  });

  final Uint8List imageBytes;

  /// 是否显示“重截”按钮（ChatScreen 限制最多 3 次）。
  final bool allowRetake;

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

  /// 截图宽高比与窗口视口偏差超过 1% 时判为失败，防止裁错图。
  bool _ratioMismatch(Size viewport) {
    final image = _image;
    if (image == null || viewport.isEmpty) return false;
    final viewportRatio = viewport.width / viewport.height;
    final imageRatio = image.width / image.height;
    return (imageRatio - viewportRatio).abs() / viewportRatio > 0.01;
  }

  Future<void> _confirm() async {
    final image = _image;
    final rect = _selection;
    if (image == null || rect == null || _cropping || _ratioMismatch(_viewport)) {
      return;
    }
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
      if (!mounted || data == null) return;
      Navigator.of(context).pop(ScreenshotOverlayResult.done(data.buffer.asUint8List()));
    } catch (error) {
      if (mounted) {
        setState(() {
          _cropping = false;
          _error = '裁切失败：$error';
        });
      }
    }
  }

  void _cancel() => Navigator.of(context).pop();

  void _retake() => Navigator.of(context).pop(const ScreenshotOverlayResult.retake());

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.escape) {
      _cancel();
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
        key: const Key('screenshot-overlay'),
        backgroundColor: Colors.black,
        body: LayoutBuilder(
          builder: (context, constraints) {
            final viewport = constraints.biggest;
            _viewport = viewport;
            final ratioMismatch = _ratioMismatch(viewport);
            final compact = viewport.width < 420;
            final canDone =
                selection != null && !_cropping && !ratioMismatch;
            final hint = _error ??
                (ratioMismatch
                    ? '截图尺寸与窗口不匹配，请重截'
                    : '拖拽选择截图区域 · Esc 取消');
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
                  top: compact ? 12 : 20,
                  left: 8,
                  right: 8,
                  child: Center(
                    child: Container(
                      padding: EdgeInsets.symmetric(
                        horizontal: compact ? 12 : 16,
                        vertical: compact ? 8 : 8,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.62),
                        borderRadius: BorderRadius.circular(LoopRadius.pill),
                        border: Border.all(color: Colors.white24),
                      ),
                      child: Text(
                        hint,
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: ratioMismatch ? pal.dangerInk : Colors.white,
                          fontSize: compact ? LoopType.caption : LoopType.secondary,
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: compact ? 12 : 24,
                  child: Center(
                    child: Container(
                      padding: EdgeInsets.symmetric(
                        horizontal: compact ? 4 : 8,
                        vertical: compact ? 4 : 8,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.72),
                        borderRadius: BorderRadius.circular(LoopRadius.card),
                        border: Border.all(color: Colors.white24),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          TextButton(
                            key: const Key('screenshot-cancel'),
                            onPressed: _cancel,
                            style: _textStyle(compact),
                            child: const Text('取消', style: TextStyle(color: Colors.white70)),
                          ),
                          TextButton(
                            key: const Key('screenshot-select-all'),
                            onPressed: _selectAll,
                            style: _textStyle(compact),
                            child: const Text('全屏', style: TextStyle(color: Colors.white70)),
                          ),
                          if (widget.allowRetake)
                            TextButton(
                              key: const Key('screenshot-retake'),
                              onPressed: _cropping ? null : _retake,
                              style: _textStyle(compact),
                              child: const Text('重截', style: TextStyle(color: Colors.white70)),
                            ),
                          const SizedBox(width: 4),
                          FilledButton(
                            key: const Key('screenshot-done'),
                            onPressed: canDone ? _confirm : null,
                            style: FilledButton.styleFrom(
                              backgroundColor: pal.accentInk,
                              foregroundColor: Colors.white,
                              padding: EdgeInsets.symmetric(
                                horizontal: compact ? 16 : 20,
                                vertical: compact ? 12 : 16,
                              ),
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
                      child: ColoredBox(color: Colors.black54),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  ButtonStyle _textStyle(bool compact) {
    return TextButton.styleFrom(
      padding: EdgeInsets.symmetric(horizontal: compact ? 8 : 12, vertical: compact ? 8 : 12),
      minimumSize: Size(compact ? 44 : 52, compact ? 34 : 38),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
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
      ..color = pal.accentInk
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawRect(rect, border);

    final corner = Paint()
      ..color = pal.accentInk
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
    canvas.drawLine(rect.bottomRight, rect.bottomRight + const Offset(0, len), corner);

    if (busy) return;
    final label = '${rect.width.round()} × ${rect.height.round()}';
    final painter = TextPainter(
      text: TextSpan(
        text: label,
        style: const TextStyle(color: Colors.white, fontSize: LoopType.caption, fontWeight: FontWeight.w600),
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
      RRect.fromRectAndRadius(labelRect, const Radius.circular(LoopRadius.small)),
      Paint()..color = Colors.black.withValues(alpha: 0.7),
    );
    painter.paint(canvas, labelRect.topLeft + const Offset(6, 3));
  }

  @override
  bool shouldRepaint(covariant _SelectionPainter oldDelegate) =>
      oldDelegate.selection != selection || oldDelegate.busy != busy;
}
