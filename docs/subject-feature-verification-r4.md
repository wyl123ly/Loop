# t19 · t18 修复后截图证据独立验证（AC-07）— verifier 报告

> **结论：7/7 验收项全部通过。** T17-1（豆腐块）、T17-2（12 号图未拍到迁移卡片）、T17-3（来源披露）三条 findings 均确认为**已修**；16 张截图逐张实看无空心方框/实心块，04/05 分别对应概览/进度 tab 且互异，`12-migration-progress.png` 真实拍到设置页「数据与迁移」卡片；README 的 TREE_DIGEST 算法可逐字复现（我复算出与 `TREE_DIGEST.txt` 完全一致的 `3faaa26e…`）；analyze 0 issues、全量 473 passed/1 skipped、截图+UI 35 passed、repair 31/31；正式库零污染。
> 另附 3 条**非阻塞观察**（§5.1/5.2/5.3）：技能抽屉值列对比度偏低、`pubspec.yaml` 版本仍为 `0.7.1+21`、01/02 对话页无侧栏——均不影响本轮验收判定，但建议 t10 发版前确认。

## 0. 冻结字节与 TREE_DIGEST 复现

按 README §1.1 给出的脚本（`app/lib` + `app/test` 全部 `.dart` + `docs/evidence/subject-v0.8.0/**` 排除 `TREE_DIGEST.txt` 自身；**Windows 反斜杠相对路径** + 两空格 + 大写 sha256 + `\n`；整串 UTF-8 再 sha256）：

| 项 | 值 |
|---|---|
| 我复算的 TREE_DIGEST（162 文件） | **`3faaa26e5d0b67232c45c7e977c11600f0beeb8e6a52958bdb24b28bb5b80d44`** |
| `docs/evidence/subject-v0.8.0/TREE_DIGEST.txt` 记录 | `3faaa26e5d0b67232c45c7e977c11600f0beeb8e6a52958bdb24b28bb5b80d44` ✅ **一致** |
| 复算脚本（我自建，独立于 t18） | `%TEMP%\t19-verify\digest_alg2.py` |

- 三种排序（绝对路径序数 / 大小写不敏感 / 相对路径）都得到同一值 → 算法对排序实现不敏感、可复现。
- **纠正 t17 的"无法复现"**：t17 我用 **正斜杠** 相对路径、且把 `TREE_DIGEST.txt` 纳入摘要（163 文件）→ 得 `e65567d8…`（含自身）/`1e722adc…`（正斜杠，162 文件）。按 t18 脚本的口径（反斜杠 + 排除自身）即可复现。**t15 的 `039c2301…` 是 t15 时点文件的同算法结果，t18 改动后为 `3faaa26e…`，两者不矛盾。**
- 采集时刻 20:32:28 与命令跑完后（20:35 左右）摘要均相同，工作树在本轮验证期间**未变化**。

## 1. 逐条验收证据

### 1.1 实看全部 16 张截图 ★ 通过（无豆腐块）
逐张 `read_image`（16/16），另对按钮区做 3× 放大裁剪（`%TEMP%\t19-verify\crop_*.png`）：

| 图 | 内容（与文件名/README 一致） | 文字 |
|---|---|---|
| 01-chat-light-1440 | 对话页（浅色）：学科 chip「线性代数」、答疑、deepseek-flash、用户气泡、回答正文与公式、复制 Markdown/存笔记/加待办、输入区「问点什么，或者把题目截图、PDF 附上来…」 | ✅ 可读 |
| 02-chat-dark-1440 | 对话页（深色）同上 | ✅ 可读 |
| 03-sidebar-subject-switcher-dark | 侧栏：回路/Loop·学习工作台、新对话、线性代数「当前学科」切换器、七页签（对话/今日/笔记/资料/学科/代理/设置）、最近对话 | ✅ 可读（七页签齐） |
| **04-subject-overview-dark-1440** | 学科页 **概览** tab：6 张度量卡 + 待复习「矩阵相似与对角化」+ 右侧 **「去复习」** 按钮 + 最近学习空态 + 这个学科计数 | ✅ **按钮文字可读** |
| **05-subject-progress-dark-1440** | 学科页 **进度** tab：3 知识点（62%/45%/88%）+ 状态徽标 + ✎/🗑 图标 + 右上 **「重新计算进度」** | ✅ **按钮文字可读**（t17 此处为 6 格方框） |
| **06-subject-skills-installed-dark-1440** | 学科页 技能：安全横幅 + 技能卡（AI 架构学习教练 1.0.0、三态 chip、MIT-0）+ 动作行 **「检查更新（全部）」「从 EduHub 添加」** | ✅ **按钮文字可读**（t17 此处为方框/实心块） |
| **07-skill-detail-drawer-dark** | 技能详情抽屉：标题 + `1.0.0 · eduhub`、七行 facts、`registry.security.summary 原文`、说明段、**「查看 SKILL.md（AI 会读到的内容）」**、**「关闭」** | ✅ 标题/标签/正文/按钮可读（值列见 §5.1 观察） |
| 08-narrow-900x600-dark | 资料页（900×600 深色）：2 份资料卡、导入文件夹/上传资料 | ✅ 可读、无溢出 |
| 09-narrow-900x600-light | 资料页（浅色） | ✅ 可读 |
| 10-compact-sidebar-76-dark | 76px 紧凑侧栏：图标轨（导航图标均为真字形，无方框） | ✅ 图标可读 |
| **11-floating-360x420-dark** | 浮窗 360×420：标题截断、答疑 chip、回答正文、三个动作、输入区 | ✅ 可读、无溢出（t12 的 38px 溢出修复成立） |
| **12-migration-progress** | 设置页 **「数据与迁移」卡片**（见 1.2） | ✅ 可读 |
| real-13..16 | t8 时点真机截图（含窗口装饰/标题栏），文字与图标均可读 | ✅（历史参考，非当前字节证据） |

- **附带独立性证据（截图可复现）**：我运行 `flutter test test/subject_screenshots_test.dart` 会**重写**这 12 张主图（mtime 更新），而运行前后 `TREE_DIGEST` 完全一致（`3faaa26e…`）→ 说明这些 PNG 是**确定性渲染产物**（逐字节可重放），不是手工编辑/修补的图片。
- **无任何空心方框 / 实心块**：16 张全部通过目视；3× 放大复核 04「去复习」、05「重新计算进度」、06「检查更新（全部）/从 EduHub 添加」、07「查看 SKILL.md/关闭」、12「刷新/重试迁移/跨学科兜底检索/教学技能来源」均为真实字形。

### 1.2 `12-migration-progress.png` 拍到「数据与迁移」卡片 ★ 通过
画面顶部即 **数据与迁移** 卡片，可见：`结构版本：已是最新（迁移于 2026-10-25T13:00:00+08:00）`、`迁入记录：conversations=3 · messages=54 · materials=532 · chunks=27457`、`文件 540 搬迁成功`、一次性提示「旧数据已迁入默认学科…**知道了**」、置灰的 **「重试迁移」** 按钮、**「跨学科兜底检索」** 开关、**「教学技能来源: https://eduhub.deeptutor.info/api/v1（只读，由后端白名单固定）」**；下方还有 关于与更新（检查更新/启动时自动检查更新/手动下载 Release 页面）、运行信息（本地服务/数据位置/版本）。与文件名及 README 表格「设置页 · 数据与迁移」**一致**。

### 1.3 16 张 sha256 两两互异；04=概览、05=进度且不同 ★ 通过
脚本断言（`%TEMP%\t19-verify\hashes.py`）：`count=16`、`unique=16`、`duplicates=[]`；`04 != 05 : True`（04=`db31a2b0…`、05=`98a39235…`）；`real-13..16` 的 sha256 仍为 t8 值（`77ed7524…`/`f434ec8d…`/`51ab05fd…`/`f1fce355…`）。

### 1.4 README 来源披露 + TREE_DIGEST 方法可复现且一致 ★ 通过
- README §2.1 渲染方式 B 行明确写：**4 张 `real-13..16` 是「t8 独立验证期间」产物，「它们是 t8 当时字节的产物（早于 t12/t15/t18 的改动），不能作为当前字节的证据」** —— 与我 t17 的发现一致，如实披露 ✅。
- README §1.1 给出逐字可复现脚本（含「排除自身，避免自指」），我按其口径复算出**完全一致**的 `3faaa26e…`（162 文件，§0）✅；`TREE_DIGEST.txt` 同时保留 t15 历史值 `039c2301…` 供对比 ✅。

### 1.5 硬指标 ★ 全绿
| 命令 | 结果 |
|---|---|
| `flutter analyze` | **No issues found!**（EXIT=0） |
| `flutter test` | **473 passed / 1 skipped**（EXIT=0；≥ 基线 473/1，0 失败） |
| `flutter test test/subject_screenshots_test.dart test/subject_ui_test.dart` | **35 passed**（EXIT=0） |
| `flutter test test/subject_repair_regression_test.dart`（附加） | **31/31**（EXIT=0） |
日志：`%TEMP%\t19-verify\{fulltest,shot_ui,repair}.log`。

### 1.6 正式库保护 ★ 通过
`data/loop.db`：mtime `2026-10-25T08:13:14.1340180Z`、size `113467392`、sha256 `1CB939B44BEBE7EF53709A09BE48705F9E0BD017B0270BBEB1241F69B600D645`，验证前后一致；`data/files` 恒 540 文件。全部测试运行在隔离数据目录（`Directory.systemTemp`）+ `FLUTTER_TEST` 守卫下。

## 2. 复现命令

```powershell
$env:PATH='D:\DSH_Workspace\Prog2_app\.tools\flutter\bin;'+$env:PATH
Set-Location 'D:\DSH_Workspace\Prog2_app\app'
flutter analyze
flutter test
flutter test test/subject_screenshots_test.dart test/subject_ui_test.dart
# TREE_DIGEST 复算（独立于 t18 的实现）
python %TEMP%\t19-verify\digest_alg2.py        # → 3faaa26e5d0b67232c45c7e977c11600f0beeb8e6a52958bdb24b28bb5b80d44
# 截图互异断言
python %TEMP%\t19-verify\hashes.py
```
截图复核：逐张 `read_image`；3× 放大裁剪（System.Drawing）产物见 `%TEMP%\t19-verify\crop_*.png`。

## 3. 与 t17 findings 的对照

| finding | 状态 | 证据 |
|---|---|---|
| T17-1（high）按钮豆腐块 | **已修** | 05/06/04/07/12 的按钮文字与图标均为真字形（目视 + 3× 放大）；harness 现把字体钉到 textTheme/primaryTextTheme + 各 ButtonStyle.textStyle + chip/tabBar/… 槽位，并注册产品自带 `assets/fonts/NotoSansSC-Loop.ttf` 为 Roboto/Ahem/monospace |
| T17-2（medium）12 号图未拍到迁移卡片 | **已修** | 12 号图第一屏即「数据与迁移」卡片，含状态/计数/重试/开关/来源字段（§1.2） |
| T17-3（low）来源披露 | **已修** | README 明确 real-13..16 为 t8 产物、不能作为当前字节证据；新增可复现 TREE_DIGEST 算法 + 值（§1.4） |

## 4. 不在本报告范围（上游已锁定，未重做）

F-1..F-18、R2-5/R2-6/R2-7 等接口/安全/隔离结论由 t14 与 t17 的独立探针在各自字节上给出；本轮只验证 t18 的截图与证据文档改动，未改动任何产品代码，`app/lib` 的 sha256 与 t15 交付一致（由 t18 报告并已被 TREE_DIGEST 间接覆盖）。

## 5. 非阻塞观察与未验证/不确定项

### 5.1 观察（low）：技能抽屉的值列对比度偏低
`07` 抽屉七行 facts 的**标签**清晰，但**值**（发布者/许可/内容 sha256/文件数/安装时间/registry 裁决/包签名）以很小的字号 + 低亮度颜色渲染：我在该区域测得像素亮度 `文本≈116–122 / 背景≈27`（色值约 3.8:1，低于 WCAG AA 正文 4.5:1）；3× 放大后可辨（应为 `deeptutor`/`MIT-0`/sha256 前 12 位/`unsigned` 等），1× 下近乎不可见。这不属于「豆腐块」（是真实字形），不影响本轮验收，但建议：值列改用更高对比度颜色（或单列换行展示），否则 AC-09/AC-14 要求的「如实展示 verify 事实」在视觉上打了折扣。
### 5.2 观察（low）：`pubspec.yaml` 版本仍为 `0.7.1+21`
`12` 号图页面显示「关于与更新 v0.7.1」「版本 Loop 0.7.1 · Dart 后端」，与 `app/pubspec.yaml: version: 0.7.1+21` 一致（t8 曾记 F2-info：`/api/health` 亦为 0.7.1）。团队目标版本是 v0.8.0，**发版前请确认是否需要 bump 版本号**（属 t10 决定范围，本轮不作判定）。
### 5.3 观察（info）：01/02 对话页画面中无侧栏
01/02 是「对话页」整幅截图，画面为整宽对话区 + 顶部 chips，侧栏未出现在画面内（03 单独展示了侧栏）。与 README 表格描述（对话页）不冲突，但若要表达「对话页与学科 chip/侧栏」同框，可考虑补一张含侧栏的对话页图。
### 5.4 未验证/不确定项
1. **当前字节的真机界面未重拍**：`real-13..16` 是 t8 时点产物；本轮**没有**用当前构建启动真实 exe 抓屏（需完整 build + 真实进程，t18 亦未做）。因此"当前字节在真实进程中的渲染"仍未验证；12 张主图是 widget 级渲染（生产 widget + 假后端）。
2. **字体路径可移植性**：harness 现用产品自带 `assets/fonts/NotoSansSC-Loop.ttf`（较 t17 的 `C:\Windows\Fonts\*` 更可移植），但 `MaterialIcons` 仍从 **Flutter SDK 缓存路径**加载（README 已列为不可验证范围之一）；换机器/换 SDK 是否仍无豆腐块未验证。
3. **AC-12 绝对值基线 / AC-13 真实断网**：仍未建立/未验证（与 t8/t14/t17 一致，无新增证据）。
4. **R-DRILL**：opt-in 真实 540 文件迁移演练本轮未运行（默认 skip）。
5. **07 值列对比度未在真机复核**：5.1 的测量基于截图（widget 级渲染，使用生产主题）；真实进程中是否同样偏暗未验证。
6. **未逐像素扫描"方框"**：本轮为人工目视 16 张 + 5 处 3× 放大裁剪；t18 另有墨迹率断言（>0.0005 且 <0.05）作为自动化兜底，我没有独立复现该断言（未读其实现细节并重新推导阈值）。

## 6. 证据路径（仓库外）

```
%TEMP%\t19-verify\
  digest_alg2.py             # 独立实现 README §1.1 的 TREE_DIGEST 算法（→ 3faaa26e…）
  hashes.py                  # 16 张互异 + 04≠05 + real-* 指纹断言
  crop_07_rows.png crop_07_button.png crop_06_buttons.png crop_05_button.png crop_04_button.png  # 3× 放大
  fulltest.log shot_ui.log repair.log
仓库内仅新增本报告（docs/subject-feature-verification-r4.md）；未产生其他验证产物。
```