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
    // 浮窗最小 360×420：预览框按窗口 90% 收敛（240..1100 / 200..820），
    // 再留 12 的紧凑边距，保证小窗不溢出。
    final compact = size.width < 420 || size.height < 520;
    return Dialog(
      key: const Key('image-preview'),
      backgroundColor: Colors.transparent,
      insetPadding: EdgeInsets.all(compact ? 12 : 24),
      child: Container(
        key: const Key('image-preview-box'),
        width: (size.width * 0.9).clamp(240.0, 1100.0),
        height: (size.height * 0.9).clamp(200.0, 820.0),
        decoration: panelDecoration(color: pal.cardSolid, radius: compact ? LoopRadius.control : LoopRadius.card),
        child: Column(
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(compact ? 12 : 16, compact ? 4 : 12, 4, compact ? 4 : 8),
              child: Row(
                children: [
                  Icon(Icons.image_outlined, size: compact ? 14 : 16, color: pal.muted),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      title ?? '图片预览',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: compact ? LoopType.caption : LoopType.secondary, color: pal.ink),
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.pop(context),
                    visualDensity: compact ? VisualDensity.compact : null,
                    icon: Icon(Icons.close_rounded, size: compact ? 16 : 18, color: pal.muted),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.vertical(
                  bottom: Radius.circular(compact ? LoopRadius.control : LoopRadius.card),
                ),
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
                                  style: TextStyle(fontSize: LoopType.secondary, color: pal.muted)),
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
