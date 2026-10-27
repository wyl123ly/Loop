# Loop v0.8.11 设计 token 实施记录（复验候选）

> 分支：`design/v0.8.11-token-system`（未合并 `main`）
> 版本：`0.8.11+32`
> 设计基线：v0.8.10 / `0095d77`；首轮 token 提交 `c137ece`
> 目标：只收敛 token，不改极光、玻璃、暖纸色与布局骨架。

## 1. 已完成

### 颜色

- `palette.dart` 新增 `accentInk`、`accentFill`、`dangerInk`、`success`、`warningInk`
- light `muted #7B7884 → #6B6878`、`faint #A9A5B2 → #8A8695`
- dark `faint #6F6B7A → #86828F`、`onAccent → #15131A`
- light `userBubble → #4F5CF0 / #8A5BD6`；用户气泡实际改用 `userBubbleGradient`
- `warm` / `accent2` / `danger` / `faint` 不再承载文字：已迁移到 `warningInk` / `accentInk` / `dangerInk` / `muted`
- 错误 SnackBar 背景改 `dangerInk`，文字统一 `onPrimaryBtn`（两主题 ≥5:1；G6 守卫配对）

### 控件主题

- `colorScheme.primary = accent`；`FilledButton` 仍显式用 `primaryBtn`
- 新增 `progressIndicatorTheme` / `switchTheme` / `checkboxTheme` / `sliderTheme`
- 输入框、按钮、弹窗、菜单字号与圆角收敛

### 排版 / 圆角 / 间距

- 字号：字面量清零，全部走 7 级 `LoopType`；Markdown 标题也改用 token
- 圆角：字面量清零，全部走 5 档 `LoopRadius`；`answerRadius` / 图片预览 / 学科切换器动态半径已收口
- 间距：516 个 `EdgeInsets` 数值全部落在 4px 网格（守卫测试）
- 页头：今日/资料/设置/代理/学科/对话统一 24/w700/−0.5，内容左轴 32
- 对话标题：桌面 18/w700/−0.3，窄窗 13.5/w700/−0.1（360 浮窗从 4–5 字改善到 8 字，仍按宽度省略）

### 可读性

- 今日 hero：主/副行均改 `heroInk`（dark `#15131A`），dark 紫端提亮到 `#A98CF0`
- 4 处硬编码白（上传/检查更新 spinner、极简条发送、浮窗关闭 hover）改 `onPrimaryBtn/onAccent`
- 17 处 palette 外硬编码色清零；`answer_ui`、SnackBar、语义徽标全部迁到 ink token

### 测试与证据

- 新增 `test/design_tokens_test.dart`：D1–D6 覆盖卡片/渐变/hero/错误 SnackBar 对比度
- 新增 `test/design_guard_test.dart`：G1–G6 扫描字号/圆角/色值/间距/白字回退
- 修复 `subject_screenshots_test.dart`：补 `LoopTheme.palette` 切换、关闭 DEBUG banner、支持 `LOOP_SHOT_DIR`、补 Today/Notes
- HEAD 证据：`docs/evidence/design-v0.8.11/screens/` 共 17 张（含 Today/Notes 双主题与 waitingApproval），`OVERFLOW.txt` = `no rendering overflow`

## 2. 验收结果

| 判据 | 结果 |
| --- | --- |
| A1 文字对比度 | PASS（token + 真实用法迁移；D1–D3/D6；answer_ui/SnackBar 已收口） |
| A2 非文本对比度 | PASS（accent/dangerInk ≥3:1） |
| A3 字号档位 | PASS（守卫 G1：无数字字面量；动态值均来源于 token） |
| A4 行高档位 | PASS（4 档 1.2/1.4/1.6/1.75；G7） |
| A5 字重 | PASS（仅 w400/w500/w600/w700） |
| A6 圆角档位 | PASS（守卫 G1：无数字字面量） |
| A7 间距网格 | PASS（EdgeInsets + ≤24 SizedBox + spacing/runSpacing；G7） |
| A8 对齐轴 | PASS（七个页头 32；聊天消息列表 32） |
| A9 越权色 | PASS（palette 外 `Color(0x…)` = 0；`Colors.white` 仅叠加/截图豁免） |
| A10 进度圈 | PASS（2.0/2.4 两档；颜色 accent） |
| A11 截图回归 | PASS（17 张 HEAD 截图；无 overflow；#12 显示 v0.8.11） |

- `flutter analyze`：0 issues
- 全量测试：**512 passed / 1 skipped**；`design_guard_test` G2 已覆盖 `p.` 别名

## 3. 收口后剩余项

1. 行高已收 4 档；进度圈已收 2 档；`EdgeInsets`、≤24 `SizedBox`、`spacing/runSpacing` 已对齐 4px 网格；聊天左轴已 32 —— 四项均已闭合，由 G7 锁定。
2. P2 仍未纳入本版：空态统一组件、图标尺寸全量收敛、玻璃高光羽化、标题栏页名去重、主题切换 120ms、触控目标复查。
3. 截图仍为 widget 渲染，非真机；CJK 字体使用系统替代。
4. 未做 golden/pixel diff；截图只做“生成 + 无 overflow + 唯一哈希”

## 4. 复跑

```powershell
cd D:\DSH_Workspace\Prog2_app\app
$env:PATH="D:\DSH_Workspace\Prog2_app\.tools\flutter\bin;$env:PATH"
flutter analyze
flutter test test/design_tokens_test.dart test/design_guard_test.dart
$env:LOOP_SHOT_DIR='../docs/evidence/design-v0.8.11/screens'
flutter test test/subject_screenshots_test.dart
```

## 5. 变更清单（关键）

- `app/lib/theme/palette.dart`
- `app/lib/theme.dart`
- `app/lib/widgets/glass.dart`
- `app/lib/widgets/sidebar.dart`
- `app/lib/screens/chat_screen.dart`
- `app/lib/screens/today_screen.dart`
- `app/lib/screens/subject_screen.dart`
- `app/lib/screens/materials_screen.dart`
- `app/lib/screens/settings_screen.dart`
- `app/lib/widgets/subject_skills_panel.dart`
- 其余 screens/widgets 的 token 替换
- `app/test/design_tokens_test.dart`、`app/test/design_guard_test.dart`
- `app/test/subject_screenshots_test.dart`