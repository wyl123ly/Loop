# 学科功能 v0.8.0 — 证据清单（AC-07 / AC-09 / AC-12 / AC-13）

> 本目录由 t12 修复轮补齐（F-17）。所有命令都可在仓库根目录复现；
> 测试全部隔离数据目录、不访问公网（registry/模型端点用 loopback 替身）。

## 1. 复现命令

```powershell
$env:PATH='D:\DSH_Workspace\Prog2_app\.tools\flutter\bin;'+$env:PATH
Set-Location 'D:\DSH_Workspace\Prog2_app\app'

flutter analyze                                             # 0 issues
flutter test                                                # 全量（含新增回归）
flutter test test/subject_repair_regression_test.dart       # F-1/F-2/F-3/F-4/F-5/F-6/F-7/F-8/F-9/F-10/F-12/F-13/F-14/F-16/F-18（31 条）
flutter test test/subject_migration_readonly_test.dart      # F1 迁移只读回归（R-DRILL 默认 skip，7 passed / 1 skipped）
flutter test test/subject_ui_test.dart                      # 学科 UI（34 条：F-5/F-11/F-15 + 布局 + R2-4 八类断言）
flutter test test/subject_screenshots_test.dart             # AC-07 12 张主图（写入本目录；含 16 张 sha256 互异 + 豆腐块断言）
```

### 1.1 TREE_DIGEST 的可复现算法（T17-3）

`TREE_DIGEST` 是对「app/lib + app/test 的全部 `.dart`」+「`docs/evidence/subject-v0.8.0/`
下全部文件」做一次确定性摘要：按**仓库相对路径升序**排列，每行写成
`相对路径<两空格>文件 sha256（大写十六进制）\n`，整串按 UTF-8 编码后再做一次 SHA-256。

```powershell
Set-Location 'D:\DSH_Workspace\Prog2_app'
$files  = Get-ChildItem 'app\lib','app\test' -Recurse -File -Include *.dart
$files += Get-ChildItem 'docs\evidence\subject-v0.8.0' -Recurse -File |
            Where-Object { $_.Name -ne 'TREE_DIGEST.txt' }   # 排除自身，避免自指
$files  = $files | Sort-Object FullName
$sb = New-Object System.Text.StringBuilder
foreach ($f in $files) {
  [void]$sb.Append($f.FullName.Replace((Get-Location).Path + '\',''))
  [void]$sb.Append('  '); [void]$sb.Append((Get-FileHash $f.FullName -Algorithm SHA256).Hash)
  [void]$sb.Append("`n")
}
$sha = [System.Security.Cryptography.SHA256]::Create()
(($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($sb.ToString())) |
  ForEach-Object { $_.ToString('x2') }) -join '')
```

- 摘要集合**不含 `TREE_DIGEST.txt` 自身**（避免自指）；当前值、文件数、算法与关键指纹
  都记在 `TREE_DIGEST.txt` 里，可用上面的脚本逐字复算。
- 参考：t15 交付时（未含 t18 的截图/文档改动）为
  `039c23017dedf2298b3b7addd31f214aaa28770da3529742f6b9deafb142411a`（162 个文件）。

真实数据副本演练（证明旧库 540 个文件全部搬迁、errors=0；源数据只读）：

```powershell
$env:LOOP_REAL_MIGRATION_DRILL='1'
flutter test test/subject_migration_readonly_test.dart --plain-name 'R-DRILL'
```

正式库零污染检查：全量测试前后 `data/loop.db` 的 mtime + sha256 必须一致
（t11/t12 各轮均为 `1CB939B4…D645`，size=113467392；`data/files` 仍 540 个文件）。

## 2. AC-07 截图（`screens/`）

### 2.1 渲染方式与数据来源（R2-3：如实标注）

| 项 | 说明 |
|---|---|
| 渲染方式 A（12 张主图，**当前字节**） | widget 级渲染：`app/test/subject_screenshots_test.dart` 用**生产 widget** + 注入假后端（`_ShotApi`）在 `RepaintBoundary` 上截屏。字体用**产品自带资产** `assets/fonts/NotoSansSC-Loop.ttf`（与真机同源，含拉丁+CJK）经 `FontLoader` 注册为 `Roboto`，并额外注册为 flutter_test 的兜底族 `Ahem`（实心块字体）与产品里唯一的显式族 `monospace`；`_shotTheme()` 把该族钉到 textTheme/primaryTextTheme **以及** ButtonStyle.textStyle（filled/elevated/outlined/text）、chip、tabBar、popupMenu、dialog、snackBar、tooltip、inputDecoration、listTile、navigationBar/Rail、appBar 各槽位。Material 图标字体从 Flutter SDK `material_fonts/materialicons-regular.otf` 载入 |
| 渲染方式 B（4 张历史真机图，`real-13..16`） | 真实进程截图：**t8 独立验证期间**用 `ui.ps1` + `LOOP_DATA_DIR` 隔离目录启动真实 exe 后抓屏（1440×900，真实字体/图标/壳层/标题栏）。⚠️ **它们是 t8 当时字节的产物**（早于 t12/t15/t18 的改动），**不能作为当前字节的证据**，仅作"真实进程渲染长什么样"的历史参考 |
| 数据来源 | 假后端 fixture（线性代数：3 知识点、1 个已装技能、3 会话、2 资料、迁移 report），**不含**任何真实用户数据；不做网络访问 |
| 可验证范围 | 布局与信息层级、浅/深色主题、窄窗/紧凑侧栏/浮窗的溢出行为、AC-07 要求的界面元素是否出现（tab、chip、技能卡片、verify 徽标、迁移卡片）、**文字与动作按钮可读（非豆腐块）** |
| **不可**验证范围 | 真实进程的窗口装饰/DPI 缩放、真实数据量下的滚动与性能、个别**图标**字形的完整性（见下） |

豆腐块防护（T17-1 修复）：之前只有 textTheme 被钉住，按钮/tab/菜单/chip 等槽位仍走
flutter_test 的兜底测试字体（Ahem = 实心块），所以动作按钮在截图里是方框/实心块。
现在 (a) 兜底族与 monospace 都被覆盖为 CJK 字体，(b) 上述所有主题槽位都显式指定该族，
(c) 用例新增两类断言：**墨迹率检查**（标签渲染后非背景像素占比必须 >0.0005 且 <0.05；
实心块约 0.07–0.10）与 **未加载字体族检查**（树里任何 `Text.style.fontFamily` 不在
已加载族白名单内即失败，产品里唯一的显式族 `monospace` 已列入白名单）。

已知局限（如实记录）：widget 级截图中**文字与动作按钮**已确认可读（断言 + 人工复核 05/06/12）；
少数**图标**字形仍可能是方框（图标字体的个别码点在测试环境取值不全）。需要真实图标/壳层的
场景请以渲染方式 B 的历史图作参考，但请注意其字节时点。

### 2.2 12 张主图

| 文件 | 页面 | 尺寸/主题 | sha256 前 12 |
|---|---|---|---|
| 01-chat-light-1440.png | 对话页（学科 chip + 模式） | 1440×900 浅色 | 0DA5E66C16B2 |
| 02-chat-dark-1440.png | 对话页 | 1440×900 深色 | 8980BEAD8C4F |
| 03-sidebar-subject-switcher-dark.png | 侧栏 + 学科切换器 | 1440×900 深色 | 515C5F8EB724 |
| 04-subject-overview-dark-1440.png | 学科页 · 概览 | 1440×900 深色 | DB31A2B0154F |
| 05-subject-progress-dark-1440.png | 学科页 · 进度（知识点 + 掌握度条） | 1440×900 深色 | 98A392354B53 |
| 06-subject-skills-installed-dark-1440.png | 学科页 · 技能（已安装） | 1440×900 深色 | 2A89FFBC35DB |
| 07-skill-detail-drawer-dark.png | 技能详情（license/发布者/sha256 前 12/verify 原文/unsigned） | 900×860 深色 | 0F9BF3FE3A8F |
| 08-narrow-900x600-dark.png | 资料页 | 900×600 深色 | 59A20C4172ED |
| 09-narrow-900x600-light.png | 资料页 | 900×600 浅色 | A6087BC2F545 |
| 10-compact-sidebar-76-dark.png | 紧凑侧栏（76px 徽标） | 900×600 深色 | 9ADD12D25CAC |
| 11-floating-360x420-dark.png | 浮窗对话页 | 360×420 深色 | 8EA19968256C |
| 12-migration-progress.png | 设置页 · 数据与迁移（**已滚到卡片**） | 1440×900 深色 | 4E7FBBC77F00 |

（以上 sha256 为 **v0.8.0 发版字节**产物：t23 按授权回滚掉 t20 半途落下的 R3-1/R3-2 delta 后重放，
**15/16 张与 T17-1/T17-2 修复后的 pre-fix 产物逐字节一致**；**仅 12 号图因版本号文本
`0.7.1 → 0.8.0`（右上「v0.8.0」、「版本 Loop 0.8.0 · Dart 后端」）而重放**，
`F1E3113D1AA6 → 4E7FBBC77F00`，画面其余部分逐像素相同。用例断言 16 张 PNG 两两互异。）

**R2-1 修复**：04/05 之前各自重建 widget，导致 05 其实是概览页的同一张图。现改为
`_pumpTree` + `_capture`：先拍 04，然后在**同一棵** SubjectScreen 树上切到进度 tab 再拍 05；
用例断言 12 张主图的 **sha256 两两互异**，并断言 05 的树里确实有知识点名（否则失败）。

**T17-2 修复**：12 号图之前拍的是设置页顶部，看不到「数据与迁移」卡片。现在截图前
`scrollUntilVisible(settings-data-migration)` 并断言卡片矩形完整落在 900px 画面内、
页面含迁移文案；我已 `read_image` 复核 12 号图确实是「数据与迁移」（结构版本/迁入记录/
文件 540 搬迁成功/一次性提示/重试迁移/跨学科兜底检索/教学技能来源只读）。

**内容与文件名一致性**：04=概览、05=进度 tab（人工复核）、06=技能、07=技能详情抽屉（断言含「许可」）、
12=数据与迁移（人工复核）；其余页面由 `_pumpTree` 的 pageBuilder 直接指定。

**真机图（渲染方式 B，历史参考，非当前字节证据）**：`real-13-chat-1440-dark.png`（77ED7524C0C8）、
`real-14-subject-overview-1440-dark.png`（F434EC8DF7EB）、
`real-15-subject-a-1440-dark.png`（51AB05FD07CF）、
`real-16-materials-1440-dark.png`（F1FCE35592DB）。
这些文件是 **t8 验证期间**（早于 t12/t15/t18 的改动）在隔离数据目录下抓的真实进程图；
复现方式（t8）：`flutter build windows --debug` → 启动隔离实例（`LOOP_DATA_DIR`）→
`capture_ui.ps1` 抓屏，脚本与日志见 t8 工件目录 `%TEMP%\t8-verify\`。
**t18 未重拍当前字节的真机图**（需要完整 build + 真实进程，属本任务范围外），
因此它们**只能证明"真实进程下该页面长什么样"**，**不能作为当前字节的渲染证据**。

- `screens/OVERFLOW.txt`：截图期间渲染异常的记录（当前为 `no rendering overflow`）。
  AC-07 断言 1（日志无 `RenderFlex overflowed`）由截图用例断言，并由
  `subject_ui_test.dart` 的 UI-18/19/20/21 覆盖 460×600、900×600、紧凑侧栏。
- t12 修复：360×420 浮窗对话页头曾溢出 38px（模式徽标 + 模型名徽标挤占），
  已改为窄宽（<520px）省略模型名徽标，`SubjectChip` 同步退化为色点。

### 2.3 覆盖转移说明（R2-4）

t12 因一次本地编码事故重写了 `app/test/subject_ui_test.dart`，当时的断言口径偏 Key/状态。
本轮（t15）已把丢失的等价断言补回，`subject_ui_test.dart` 由 30 条增至 **32 条**：

| 原先丢失的断言 | 现在的用例 |
|---|---|
| `uploadScopes` / `deleteScopes` 落当前学科 | UI-07（注入 `pickFile` 真上传 + 行内删除二次确认） |
| recreate 后重取进度 | UI-08（`subject-recompute` → `subject-recompute-confirm` → `progressScopes` 增加） |
| 页索引映射（AC-11：学科=4、代理=5、设置=6） | UI-18（`subjectPageIndex==4`、`settingsPageIndex==6`、`kInitialTabMax==6`）+ UI-18b |
| 改名 / 归档只读横幅 / 恢复 | UI-10（非默认学科；改名→页头、归档→`学科已归档（只读）`、恢复→横幅消失） |
| 详情抽屉含 license / summary 原文 / unsigned / sha256 前 12 | UI-30 |
| 回退上一版成功 | UI-31（`rollbackCalls==1` + 提示版本） |
| 技能措辞与 verdict 三态 / 含脚本徽标 / 菜单文案 / 移除二次确认 | UI-32（`registry 未命中规则（非安全保证）`、`registry 未认可`、`未验证`、`含脚本(未执行)`；`查看 SKILL.md / 详情`、`检查更新（手动）`、`更新（先检查更新）`、`锁定版本（不提示更新）`、`回退（没有上一版）`、`移除` + 确认框） |
| 「我了解风险」风险门 | UI-13（未勾选时强装按钮 disabled，勾选后才 `allowSuspicious`） |
| 进度 PATCH / 软删 / 待复习→草稿 / integrity 横幅 / 学科色 token | UI-33（编辑→PATCH 载荷含 mastery；软删→`subject-topic-delete-confirm`→`deleteTopic` 调用；`subject-due-2`→`chatDraftSignal.text` 含知识点名；`找不到这个学科的数据文件` 横幅；`subject-chip` 子树含带色容器） |

因此 t6 报告里的「26 条覆盖 10 条验收」结论在本轮更新为「**34 条**覆盖同样 10 条验收，
且恢复/补齐了 t14 §3 列出的 8 类字符串与文案级断言（技能三态措辞与含脚本徽标、风险门、
菜单项文案与移除二次确认、详情事实、进度 PATCH/软删/重算确认、待复习→草稿、
SubjectChip 与色 token、归档与 integrity 横幅），多为真实点击 + 后端调用计数断言」。

### 2.4 t23 发版字节说明（R3-1/R3-2 状态与回滚）

- **R3-1 在本版仍未修复**：截图 harness 不设置全局 `LoopTheme.palette`，12 张 dark 主图里所有显式 `pal.*`
  取 light 调色板值（07 详情抽屉值列文字为 `light.ink #1F1D24`、在 dark 背景 (28,26,36) 上对比度约 **1.03:1**、
  1× 下不可见；05 第 2/3 行卡片底色为 light `cardFill` 叠在 dark 页面上）。**R3-2 同样未修复**：
  04 概览 fixture 仍会出现「18 个知识点 / 52% / 已掌握 4」与「最近学习：还没有学习记录」同屏矛盾。
  用户决定 **B：接受现状发版**，t20 的修复被取消。**产品 dark 模式本身无缺陷**（`main.dart:64/130` 正确赋值）。
- **回滚说明**：t20 在被取消之前已把一半 delta 写进 `app/test/subject_screenshots_test.dart`
  （`_setPalette` + 平均亮度断言 + fixture 的 `summary['coverage']`/`topics.lastStudiedAt`/`evidenceCount`），
  这会让 `flutter analyze` 报 1 条 `unused_element`，并让 12 张 dark 图改用 dark 调色板（即"看起来已修"）。
  t23 已按授权**回滚该 delta**：`flutter analyze` 回到 **0 issues**，**15/16 张图逐字节回到 pre-fix 产物**
  （R3-1/R3-2 恢复为"未修复"状态；仅 12 号图因版本文本变化重放，见 §2.2）。
- 复现：`flutter test test/subject_screenshots_test.dart`（重写 12 张主图，逐字节可重放）+ `flutter analyze`。

## 3. AC-09 安全（技能）

| 断言 | 证据 |
|---|---|
| 无执行路径 | 全仓无 `Process.run/start` 以 skill 路径为输入；导入器只读 ZIP，脚本仅落盘不执行；`read_skill` 返回 `executed:false` |
| 仅用户显式安装 | 工具清单无安装/执行类工具（F-4c）；install/pin/update/remove 只由用户动作触发，逐条写 `agent_audit`（F-3，`approval='user'` + `subject_key`） |
| hub 白名单 | 后端固定 eduhub（F-18：PUT `/api/settings` 传其它 hub → 400；`GET /api/settings` 恒返回白名单值）；前端不直连 registry |
| 禁重定向 | `SkillRegistry` 手动处理重定向（仅同白名单主机，≤2 跳） |
| zip 防护 | store/deflate、拒加密/ZIP64、拒穿越/盘符/反斜杠、CRC32、压缩比 100:1、后缀白名单（含图片/PDF）、symlink 整体拒绝、单层壳目录拍平 |
| 内容扫描 | `SkillContentScanner` 10 类高危模式（下载即执行/反弹 shell/破坏性删除/base64 执行/凭据读取/挖矿/PowerShell 编码/环境变量外传/持久化/改写 Loop 数据），命中整包拒绝并回报文件+行+片段 |

## 4. AC-12 性能与资源（实测，20 学科）

由 `subject_repair_regression_test.dart` 的 F-1c 打印：

```
AC-12 证据：20 学科打开/切换总耗时=60ms，P95=3ms，句柄上限=4，累计打开=35
```

- 单次打开 ≤ 300ms ✓；句柄数 ≤ 4（LRU，跳过 in-use 句柄）✓；启动不打开学科库 ✓。
- 并发：F-1e 两学科真实 SSE 流式 run 并发完成（200 + `event:done`，各落 2 条消息，
  日志无 `already been closed`）。

## 5. AC-13 离线与降级

- `/api/skills/status`（无 probe）不触网，只报缓存探测结果；`probe=true` 才联网。
- catalog/detail 离线 → `offline` 码 + UI 横条，不弹错误框（UI-15）。
- 安装失败区分 offline/sha256_mismatch/zip_slip/zip_bomb/symlink/suffix/…
  （UI-16 断言完整性失败提示，且已装列表不变）。

## 6. 迁移证据

- `GET /api/migrations/status` → `{applied:[{id:'v0.8.0-subjects',applied_at}], pending, running, report}`；
  report 含 `files_moved/files_failed/files_missing/files_external/files_leftover/file_errors`。
- 删源在 COMMIT 之后（F-10）：晚期失败保留源文件 + default 目录 + 备份（`rollback` 字段）。
- 幂等：第二次 `POST /api/migrations/run` → `{ok:true,skipped:true,reason:'already-applied'}`。
- UI：设置页「数据与迁移」展示状态/计数/文件摘要/错误清单，提供「重试迁移」与
  「跨学科兜底检索」开关，迁移完成一次性提示（`subject_migration_notice_seen`）。