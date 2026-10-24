import 'package:flutter/material.dart';

import '../desktop/window_mode.dart';
import '../theme.dart';
import 'glass.dart';

/// 稳定布局壳：normal 与 floating 两种窗口形态共用同一 widget 类与槽位。
///
/// 关键点：内容区（[content]，生产环境是 `IndexedStack` + `ChatScreen`）在
/// 两种形态下始终保持同一父级槽位，因此 `ChatScreen` 的 `State`（消息、
/// 附件、SSE 迭代）不会因为切换浮窗被销毁重建。浮窗只替换 [chrome]、
/// 把 [sidebar] 换成 `SizedBox.shrink()` 并缩小圆角，不改变树结构。
///
/// normal 模式的视觉（容器、圆角 18、边框、Aurora 背景、Column/Row）与
/// v0.4.0 的 `_ShellState.build` 完全一致，浮窗只把圆角改成 16。
class FloatingQaScaffold extends StatelessWidget {
  const FloatingQaScaffold({
    super.key,
    required this.floating,
    required this.chrome,
    required this.sidebar,
    required this.content,
    this.framed = true,
    this.maximized = false,
    this.minimal = false,
  });

  /// 是否浮窗形态；只影响圆角（结构/槽位保持不变）。
  final bool floating;

  /// 极简形态（规格 §3.5）：圆角 12、无装饰背景、窗口 360×52；
  /// chrome/sidebar 传 shrink，content 仍是同一个 ChatScreen 槽位。
  final bool minimal;

  /// 顶部 chrome：normal = `TitleBar`，floating = `FloatingBar`。
  final Widget chrome;

  /// 侧栏；floating/minimal 时传 `SizedBox.shrink()`。
  final Widget sidebar;

  /// 内容区；生产环境固定为同一个 `IndexedStack`。
  final Widget content;

  /// 是否显示窗口边框/圆角（生产为 `WindowController.ready`）。
  final bool framed;

  /// 最大化时圆角为 0（与 v0.4.0 一致）。
  final bool maximized;

  /// 普通窗口圆角，与 v0.4.0 一致。
  static const double normalRadius = 18;

  /// 浮窗圆角。
  static const double floatingRadius = 16;

  @override
  Widget build(BuildContext context) {
    final p = pal;
    final radius = !framed || maximized
        ? 0.0
        : minimal
            ? minimalRadius
            : (floating ? floatingRadius : normalRadius);
    final borderRadius = BorderRadius.circular(radius);
    return Container(
      key: const Key('floating-qa-scaffold'),
      decoration: BoxDecoration(
        color: p.bgTop,
        borderRadius: borderRadius,
        border: Border.all(
          color: framed ? p.windowBorder : Colors.transparent,
          width: 1,
        ),
      ),
      child: ClipRRect(
        borderRadius: borderRadius,
        child: AuroraBackground(
          // 极简条不显示装饰背景（规格 §3.5 “无装饰背景”）：用不透明底色
          // 覆盖 Aurora 渐变/光晕，但保留同一 widget 结构以保住 ChatScreen State。
          child: ColoredBox(
            color: minimal ? p.bgTop : Colors.transparent,
            child: _minSizeGuard(
              Column(
                children: [
                  chrome,
                  Expanded(
                    child: Row(
                      children: [
                        sidebar,
                        Expanded(child: content),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 过渡期保护（t5 T5-05）：
  ///
  /// Windows 上“缩小窗口”和“把 mode 置为 floating”不在同一帧完成——窗口先被
  /// 缩到 460/360 逻辑宽，Shell 仍按旧形态渲染 1–2 帧，页头/工具栏会在远小于
  /// 设计宽度的约束下 overflow。这里在小于当前形态最小尺寸的帧里，先按
  /// `normalMinSize`/`floatingMinSize`/`minimalMinSize` 完成布局，再由
  /// [ClipRect] 裁剪到真实窗口大小：过渡帧不会产生 RenderFlex overflow，
  /// 稳定尺寸下该守卫是 no-op。
  ///
  /// 注意：外层 [Container] 的 1px 边框会让内容比窗口少 2px，因此阈值按
  /// `minSize - 2` 比较，保证稳定 900×600 / 460×600 / 360×420 / 360×52 时守卫不生效。
  Widget _minSizeGuard(Widget child) {
    final min = minimal
        ? minimalMinSize
        : (floating ? floatingMinSize : normalMinSize);
    const borderInset = 2.0;
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= min.width - borderInset &&
            constraints.maxHeight >= min.height - borderInset) {
          return child;
        }
        return ClipRect(
          child: OverflowBox(
            alignment: Alignment.topLeft,
            minWidth: min.width,
            maxWidth: min.width,
            minHeight: min.height,
            maxHeight: min.height,
            child: SizedBox(
              width: min.width,
              height: min.height,
              child: child,
            ),
          ),
        );
      },
    );
  }
}
