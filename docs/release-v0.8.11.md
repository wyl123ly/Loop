# Loop v0.8.11（设计 token 收口与可读性修复）

## 目标

只收敛颜色、字号、圆角、间距、行高等 token，保留 v0.8.10 的极光背景、玻璃材质、暖纸色和布局骨架；不引入新功能。

## 颜色与可读性

- 新增 `accentInk / accentFill / dangerInk / success / warningInk` 语义 token。
- 浅色 `muted` 提深到 `#6B6878`、`faint` 提深到 `#8A8695`；深色 `faint` 提深到 `#86828F`。
- 深色 `onAccent` 改为近黑 `#15131A`：浅紫渐变上的对比度从 2.23 提升到 8.26。
- 用户气泡改用 `userBubbleGradient`（浅色白字 5.10/4.62）。
- 今日 hero 主/副行改深色 `heroInk`，深色紫端提亮到 `#A98CF0`。
- 错误 SnackBar 统一 `dangerInk` 底 + `onPrimaryBtn` 前景（浅色 5.65、深色 6.66）。
- `warm / accent2 / danger / faint` 不再承载文字；`answer_ui` 审批条、错误条、状态点全部迁移。
- 4 处硬编码白（上传/检查更新 spinner、极简条发送、浮窗关闭 hover）改为随主题反转。
- palette 外硬编码 `Color(0x…)` 清零。

## 排版与几何

- 字号收敛为 7 级：10 / 11.5 / 12.5 / 13.5 / 15 / 18 / 24，字面量清零。
- 行高收敛为 4 档：1.2 / 1.4 / 1.6 / 1.75。
- 圆角收敛为 5 档：8 / 12 / 16 / 24 / 999。
- 间距收敛到 4px 网格：`EdgeInsets`、≤24 的 `SizedBox`、`spacing/runSpacing` 全部归整。
- 进度圈描边只保留 2.0 / 2.4 两档，颜色统一 accent。
- 七个页头统一 24/w700/−0.5、内容左轴 32；聊天消息列表左轴从 24 调到 32。
- 对话标题桌面 18、窄窗 13.5，改善 360×420 浮窗截断。

## 控件主题

- `colorScheme.primary` 改回品牌 accent，主按钮仍显式使用 `primaryBtn`。
- 新增 `progressIndicatorTheme / switchTheme / checkboxTheme / sliderTheme`，默认控件不再渲染成墨色。
- 输入框、按钮、弹窗、菜单统一圆角与字号。

## 测试与证据

- 新增 `test/design_tokens_test.dart`（D1–D6）与 `test/design_guard_test.dart`（G1–G7）。
- 截图 harness 修复：切换全局 palette、关闭 DEBUG banner、支持 `LOOP_SHOT_DIR`、补 Today/Notes/waitingApproval。
- 17 张双主题截图：`docs/evidence/design-v0.8.11/screens/`，无 overflow。
- `flutter analyze`：0 issues
- 全量测试：**512 passed / 1 skipped**

## 已知限制

- 截图来自 widget 测试渲染，不是真机截图；CJK 字体使用系统替代。
- 无 golden/pixel diff；截图只做生成、无溢出、唯一哈希。
- P2 项未纳入本版：空态统一组件、图标尺寸全量收敛、玻璃高光羽化、标题栏页名去重、主题切换过渡、触控目标复查。

## 升级方式

- 替代 v0.8.10，直接覆盖 `Loop.exe` 与运行库即可；用户数据不受影响。
- 自动更新会按 `version.json` 的 `0.8.11` 识别。