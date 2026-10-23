# 回路 Loop · UI 设计说明（v0.4）

## 视觉方向
极简 ins 风 + 柔光玻璃：
- 暖米色底 + 蜜桃/淡紫/暖黄光晕（AuroraBackground）
- 半透明面板、白色高光描边、22–30px 大圆角
- 主色 `#6C7BFF → #C08CFF`，正文近黑 `#1F1D24`
- 深色：`#121119 → #171326`，正文 `#F2EFE8`，玻璃 fill 8% 白

## 主题
`lib/theme/palette.dart` 的 `LoopPalette` 统一管理颜色与渐变，`pal` 为全局当前调色板。
设置里的「外观」可切换 跟随系统 / 浅色 / 深色，并持久化到 SQLite（settings.theme）。

## 无边框窗口
`window_manager 0.5.2` + 自绘 `TitleBar`：
- 隐藏系统标题栏，窗口 1440×900（逻辑像素），位置 (24,24)
- 左侧拖拽 / 双击最大化；右侧最小化/最大化/关闭
- 最大化状态由 WindowListener 同步，标题栏按钮 hover 变色

## 已知限制
- 无边框窗口在部分缩放比例下窗口边缘会有 1–2px 透出（截图裁掉了底部 46px）
