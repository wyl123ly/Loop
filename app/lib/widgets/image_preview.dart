import 'package:flutter/material.dart';

import '../theme.dart';

/// 图片全屏预览：支持缩放、拖动、Esc/遮罩关闭。
class ImagePreview extends StatelessWidget {
  const ImagePreview({super.key, required this.url, this.title});

  final String url;
  final String? title;

  static Future<void> show(BuildContext context, String url, {String? title}) {
    return showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.82),
      builder: (_) => ImagePreview(url: url, title: title),
    );
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(24),
      child: Container(
        width: (size.width * 0.82).clamp(420.0, 1100.0),
        height: (size.height * 0.82).clamp(320.0, 820.0),
        decoration: panelDecoration(color: pal.cardSolid, radius: 18),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 8, 8),
              child: Row(
                children: [
                  Icon(Icons.image_outlined, size: 16, color: pal.muted),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      title ?? '图片预览',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12.5, color: pal.ink),
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.pop(context),
                    icon: Icon(Icons.close_rounded, size: 18, color: pal.muted),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ClipRRect(
                borderRadius: const BorderRadius.vertical(bottom: Radius.circular(18)),
                child: Container(
                  color: Colors.black,
                  child: InteractiveViewer(
                    minScale: 0.5,
                    maxScale: 6,
                    child: Center(
                      child: Image.network(
                        url,
                        fit: BoxFit.contain,
                        loadingBuilder: (context, child, progress) {
                          if (progress == null) return child;
                          return const Center(
                            child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white),
                          );
                        },
                        errorBuilder: (context, error, stack) => Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.broken_image_outlined, size: 36, color: Colors.white54),
                              const SizedBox(height: 8),
                              Text('图片加载失败',
                                  style: TextStyle(fontSize: 12, color: pal.muted)),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
