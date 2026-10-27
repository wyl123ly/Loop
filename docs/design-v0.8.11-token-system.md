# Loop v0.8.11 设计 token 实施记录（验收候选）

> 分支：`design/v0.8.11-token-system`（未合并 `main`）
> 基线：v0.8.10 / `c137ece` 开始，当前 `0.8.11+32`
> 目标：只收敛 token，不改极光、玻璃、暖纸色与布局骨架。

## 1. 已完成

### 颜色（P0）

- `palette.dart` 新增：`accentInk`、`accentFill`、`dangerInk`、`success`、`warningInk`
- light `muted #7B7884 → #6B6878`；light `faint #A9A5B2 → #8A8695`
- dark `faint #6F6B7A → #86828F`；dark `onAccent → #15131A`
- light `userBubble → #4F5CF0 / #8A5BD6`
- `GradientButton` 改用 `accentFillGradient`；侧栏「新对话」同步

### 控件主题（P0）

- `colorScheme.primary` 从 `primaryBtn` 改为 `accent`，`FilledButton` 仍显式用 `primaryBtn`
- 新增 `progressIndicatorTheme`、`switchTheme`、`checkboxTheme`、`sliderTheme`，默认控件统一 accent
- 输入框/按钮/弹窗/菜单圆角与字号按 token 收敛

### 排版 / 圆角 / 间距（P1）

- 字号：全部字面量映射到 7 级 `LoopType`；剩余动态值为 `fontSize: size`、`size * 0.46`
- 圆角：全部 `BorderRadius/Radius.circular` 映射到 5 档 `LoopRadius`
- 间距：516 个 `EdgeInsets` 数值全部落在 `{0,4,8,12,16,20,24,32,48}`（审计 0 离网格）
- 页头：今日/资料/设置/代理/学科/对话统一为 24/w700/−0.5，内容左轴统一 32

### 可读性（P0）

- 今日 hero 卡白字改为深色 `heroInk`（light `ink` / dark `onPrimaryBtn`）
- 用户气泡与发送按钮文字使用 `onAccent`，深色为近黑
- 17 处 palette 外硬编码色清零；`screenshot_overlay` 仅保留截图上可读性豁免

### 截图 harness 修复

- 原 `subject_screenshots_test.dart` 只切 `MaterialApp.theme`，未切全局 `LoopTheme.palette`，导致 dark 截图是「浅卡片 + 浅文字」的假图。已补 `LoopTheme.palette = ...`。

## 2. 实测结果

| 判据 | 结果 |
| --- | --- |
| A1 文字对比度 | `design_tokens_test` D1/D2/D3 全绿 |
| A2 非文本对比度 | accent/onAccent、dangerInk 均 ≥3:1 |
| A3 字号档位 | 字面量只剩 7 个 `LoopType`；动态值 2 处 |
| A4 行高档位 | 仍有多档，未完全收口（见 gap） |
| A5 字重 | 仅 w400/w500/w600/w700 |
| A6 圆角档位 | 5 档；无数字字面量 |
| A7 间距网格 | 516 个值，0 离网格 |
| A8 对齐轴 | 七个页面内容左轴 32 |
| A9 越权色 | palette 外 `Color(0x…)` = 0 |
| A10 进度圈 | 主题统一 accent；局部 `strokeWidth` 未全部收口 |
| A11 截图回归 | 12 张截图生成无 overflow；见 evidence |

- `flutter analyze`：0 issues
- 全量测试：**504 passed / 1 skipped**
- 截图：`docs/evidence/design-v0.8.11/screens/`（chat light/dark、sidebar、subject、skills、materials、settings、narrow、compact、floating）

## 3. 已知 gap（验收时请重点看）

1. **行高仍有多档**：`height:` 未做全量 7 档收敛。
2. **A10 进度圈**：`strokeWidth` 仍有 1.8/2.2 等值；颜色已由主题兜底。
3. **P2 未做**：空态统一组件、图标尺寸 4 档、玻璃高光羽化、标题栏页名去重、主题切换 120ms 过渡、触控目标复查。
4. **今日/笔记页未在现有截图 harness 内**：现有 harness 只覆盖 chat/materials/settings/sidebar/subject/skills；今日 hero 的修改已由 token 测试与代码评审覆盖，但没有新截图证据。
5. **未做真机截图对比**：所有截图为 widget 测试渲染，字体使用系统 CJK 替代；最终观感需真机复核。

## 4. 验证入口

```powershell
cd D:\DSH_Workspace\Prog2_app\app
$env:PATH="D:\DSH_Workspace\Prog2_app\.tools\flutter\bin;$env:PATH"
flutter analyze
flutter test test/design_tokens_test.dart
flutter test test/subject_screenshots_test.dart
```

截图输出：`D:\DSH_Workspace\Prog2_app\docs\evidence\design-v0.8.11\screens\`