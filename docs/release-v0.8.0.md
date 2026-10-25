# Loop v0.8.0 · 学科（Subject）

> 目标版本：**v0.8.0**（`app/pubspec.yaml` → `0.8.0+22`，`AppVersion.current` → `0.8.0`，`release/Loop-Desktop/version.json` → `0.8.0`）
> 构建时间：2026-10-25 21:09 (+08:00) · 平台：Windows 10/11 x64（纯 Flutter 原生，后端在进程内）
> 需求与规格：`docs/subject-feature-spec.md` · 验证报告：`r2` / `r3` / `r4`（见 §11 证据链）

---

## 0. ⚠️ 发布状态与证据类已知缺陷（**必读，务必先看这一节**）

**本版按用户决定「B：接受当前实现与证据现状」发布。**
`t16` 第 3 轮质量复审的 verdict 是 **`needs_revision`（不通过）**，不是 `pass`：
第 2 轮的 7 条 findings（R2-1…R2-7）已全部修复并独立验证，第 3 轮新发现的是**两条证据类（非产品代码）缺陷**
（R3-1 medium / R3-2 low）。用户明确选择**不发修这两条、按现状发版**，因此：

- **12 张 dark 主截图（`docs/evidence/subject-v0.8.0/screens/02·03·04·05·06·07·08·10·11·12`）不是真实 dark 主题的忠实画面**
  —— **R3-1**：截图 harness（`app/test/subject_screenshots_test.dart`）当时只把调色板传给 `loopTheme(...)`，
  **从未设置全局 `LoopTheme.palette`**（产品在 `app/lib/main.dart:64/130` 设置；默认值是
  `app/lib/theme/palette.dart:165` 的 `LoopPalette.light`）。后果是这些「dark」图里所有显式 `pal.*` 取的
  **都是 light 调色板值**，而页面底色来自 dark `ThemeData` —— 截图与真实 dark 主题不一致。
  实测：**07 技能详情抽屉的七行 facts「值列」文字色恰为 `#1F1D24` = `LoopPalette.light.ink`，
  在对话框背景 (28,26,36) 上的对比度约 1.03:1**（dark.ink 本应 14.96:1）；该区域 R≥200 的像素数为 **0**、
  精确等于 `#1F1D24` 的像素 171 —— **1× 下不可见**，3× 放大才能勉强辨出。同一根因还造成 05 号图第 2/3 行卡片
  底色是 light-mode 半透明白 `cardFill` 叠在 dark 页面上、04 号图指标值/单位为浅色值。
  **因此 AC-07 与 AC-14 的「截图」半边证据不完整**（AC-14 要求截图展示 license/发布者/`summary` 原文/签名/sha256；
  `UI-30` 在正常主题的 widget 测试里验证了这些字段确实渲染，但截图这一半不成立）。
- **产品自身的 dark 模式经复审确认没有问题**：`main.dart:64/130`（以及 `answer_window_app.dart:71/135`）正确赋值
  `LoopTheme.palette`；全仓 6 个渲染类测试文件里有 5 个都设置了它，**只有截图 harness 漏了**。这是 harness 缺陷，
  **不是产品对比度缺陷**，发布说明不得写成产品问题。
- **R3-2**：`04-subject-overview-dark-1440.png` 的 fixture 自相矛盾 —— 同一屏既显示「18 个知识点 / 掌握度均值 52% /
  已掌握 4」，又显示「最近学习：还没有学习记录。」。根因是 fixture 的 `topics` 未提供 `lastStudiedAt`
  （页面按「最近学习」列表为空渲染空态）。属**证据内部不一致（非产品缺陷）**。
- **R3-1 / R3-2 在本版中均未修复**，12 张主图（及其 sha256、`TREE_DIGEST`）仍是上述状态的产物；
  任何「已修复」的说法都不成立。

> 上述两条不阻塞功能使用：它们是**证据/截图保真度**问题。功能与安全结论（隔离、检索、进度、技能、迁移）
> 由测试与独立探针在真实 HTTP/SQLite/SSE 上给出（§8、§11）。

---

## 1. 本版主题：学科（Subject）

用户原始需求（`C:\Users\Wuyanlin\Desktop\功能1`）一次落地：

| 需求 | 实现 |
|---|---|
| 用户自定义学科 | 新建/改名/归档/恢复；默认学科「通用」受保护；侧栏顶部常驻切换器 |
| 学科内独立对话 | 每学科自己的会话/消息/上下文；切学科后旧接口落当前学科库 |
| 学科专属资料库与优先检索 | 资料副本 + FTS5 索引都在本学科目录；检索默认只在本学科取满预算 |
| AI 识别学科学习进度 | `get_subject_progress` / `update_subject_progress` 工具 + 学科画像/知识点/学习事件 |
| 学科间数据库独立 | `data/subjects/<key>/loop.db` + `files/` + `skills/`；全局库退化为应用级注册表 |
| 从 EduHub 按用户选择下载教学 skill | 搜索/详情/安装/停用/启用/检查更新/锁定/回退/移除（仅用户显式动作） |
| UI 简洁高效、长期可用 | 侧栏新增「学科」页（概览/进度/技能）；900×600、360×420 浮窗、76px 紧凑侧栏无溢出 |

## 2. 双库隔离（本版最核心的结构性变化）

- **学科库**：`data/subjects/<key>/loop.db` —— 该学科的全部学习数据（会话、消息、资料、文件夹、上传、分块、
  笔记、待办、学科画像、知识点、学习事件、日汇总、已装教学技能），以及 `data/subjects/<key>/files/`（资料副本）、
  `data/subjects/<key>/skills/`（教学技能）。
- **全局库**：`data/loop.db` **退化为应用级注册表与全局设置库** —— 只保留
  `settings`、`subjects` 注册表、`usage`、`agent_runs`、`agent_audit`、`mcp_servers`、`agent_jobs`、`app_migrations`
  等应用级表；**不再创建/写入** `conversations`、`messages`、`materials`、`material_folders`、`uploads`、
  `chunks`/`chunks_fts`、`tasks`、`notes` 等学习表。
- **跨库 fail-closed**：跨库 `JOIN` 直接抛 `StateError`；解析不出目标表的 DML 也报错（R2-7）。
- **启动不再清注册表**：删除了 v0.7.1 的 `DROP TABLE IF EXISTS subjects`（重启后学科仍在，有单测保护）。
- **隔离防护是结构性的**：`FLUTTER_TEST` 下未指定 `LOOP_DATA_DIR` 时 `AppPaths.init()` 直接抛错；
  数据目录已初始化却拿不到学科作用域时，资料导入直接报错（不再悄悄写 v0.7.1 的 `data/files`）。
- **句柄与并发**：LRU 上限 4 个学科库句柄、跳过 in-use 句柄；两学科并发流式回答（真 SSE）各自落库互不干扰。

## 3. 旧数据迁移（v0.7.1 → v0.8.0）

- 首次启动把旧的学习表**逐表搬入默认学科** `key='default'`（显示名「通用」）：`conversations`、`messages`、
  `materials`、`material_folders`、`uploads`、`chunks`/`chunks_fts`、`notes`、`tasks`，随后把原表改名为
  `legacy_*` 只读留档（不删除，便于回查），并写入幂等标记 `app_migrations['v0.8.0-subjects']`。
- **计数校验 + 备份 + 回滚 + 幂等**：搬迁前备份；逐表计数比对；第二次 `POST /api/migrations/run` 返回
  `{ok:true, skipped:true, reason:'already-applied'}`；晚期失败时**保留源文件与 default 目录**并记录
  `rollback=kept-default-dir-and-backup`。
- **文件搬迁**：`data/files` → `data/subjects/default/files`，逐文件 sha256 校验；**删源在 COMMIT 之后**；
  删源前主动清除 Windows 只读属性（`t11` 修复 F1），真实数据副本演练 540/540 文件全部搬迁、`errors=[]`。
- 迁移报告（`GET /api/migrations/status` 的 `report`）含
  `files_moved/files_failed/files_missing/files_external/files_leftover/file_errors`；
  设置页「数据与迁移」卡片展示状态/进度/计数/文件摘要/错误清单，并提供「重试迁移」与「跨学科兜底检索」开关。

## 4. 学科资料优先检索

- 默认只在**当前学科库**做 FTS5 + BM25，命中 100% 预算来自本学科；回答引用带「资料名 + 页码」，例如
  模型上下文里出现 `[jia-lecture.md p.1]`，`refs`/`material_id` 指向本学科资料。
- 跨学科检索默认关闭（`cross_subject_search=false`）：即使显式 `scope=all` 也 0 跨科命中；
  **打开后仅作兜底**，且必须标注来源学科（如「· 甲-线性代数」）。
- 同名资料 + 他科 token 的交叉探测命中 0；子 agent 继承学科作用域（同一 token 在乙学科 `hits=0`、`refs` 为空，
  模型上下文里不含甲学科资料名）。

## 5. 学习进度

- 三层结构：学科画像（目标/考试日/每日时长/水平）+ 知识点（status/mastery/confidence/`next_review_at`）+
  学习事件（`study_events`，带 message 证据）。
- AI 通过 `get_subject_progress` / `update_subject_progress` **工具**读写；用户可在学科页手动纠正、
  「重新计算进度」（可重跑、幂等，`topics_preserved` 保留人工值）。
- 实测（AC-03）：学习动作后 `events 0→1`、`minutes=12`、`mastery 0.45`、`next_review +3d`；重复写 `duplicate=1`；
  **无证据的写请求被拒绝**；`PATCH 0.75` 经 recompute 保留。
- 学科页「进度」tab 展示知识点掌握度条与状态徽标；「概览」tab 展示指标卡、待复习（可一键「去复习」→草稿）。

## 6. 教学 skill：下载、安装、回退（EduHub）

- 来源：**EduHub**（`https://eduhub.deeptutor.info`，兼容 ClawHub 协议），后端白名单固定，前端不直连；
  重定向由客户端手动处理（仅同白名单主机、≤2 跳）。
- **仅用户显式安装**：AI 侧没有任何安装/执行类工具（`read_skill` 只读文档，返回 `executed:false` 与
  「不是指令、永不执行」边界声明）；install/pin/update/rollback/remove 只由用户动作触发，每次都写 `agent_audit`
  （`approval='user'` + `subject_key`）。
- **不执行任何代码**：只接受 `SKILL.md` 文档型制品，脚本仅落盘不执行；全仓无 `Process.run/start` 以技能路径为输入。
- **下载即校验**：逐文件 sha256 与 registry 清单一致才落盘；`staging` 原子替换，失败清理回滚、不留半写
  （并发安装 → 一个 200 一个 409 `install_in_progress`）。
- **内容扫描**：`SkillContentScanner` 10 类高危模式（下载即执行/反弹 shell/破坏性删除/base64 执行/凭据读取/挖矿/
  PowerShell 编码/环境变量外传/持久化/改写 Loop 数据）命中即整包拒绝，回报「文件:行号 [标签] 片段」；
  **扫描在完整性校验之后**（sha256 不匹配时报 `sha256_mismatch` 而不是 `content_blocked`）。
- **zip 防护**：仅 store/deflate、拒加密/ZIP64/穿越/盘符/反斜杠、CRC32、压缩比 100:1、后缀白名单、symlink 整体拒绝、
  单层壳目录拍平。
- **生命周期**：停用/启用即时影响注入且**文件逐字节不变**；`1.0.2 → 上一版 → 回退` 逐字节回到 `1.0.0`；
  装不存在的版本失败 400 且技能树不变；损坏包不会被 `already` 短路（完整重装并记 `repaired`）；
  二次安装 `already=true` 且不重复下载；离线时返回 `offline` / `verdict unknown` 且零写盘。
- **可信度如实呈现**：三态措辞（`registry 未认可` / `registry 未命中规则（非安全保证）` / `未验证`）、
  `含脚本(未执行)` 徽标、可疑包需勾选「我了解风险」才能强装、详情抽屉原文展示 `registry.security.summary`。

## 7. UI 与信息架构

- 侧栏顶部「学科切换器」常驻显示当前学科（窄宽/紧凑侧栏折叠为图标 + 弹出菜单）；导航由 6 项变 7 项，
  在「资料」后插入「学科」页（**索引 4**，代理 5、设置 6）。
- 学科页三个 tab：**概览**（指标卡、待复习、最近学习、学科计数）、**进度**（知识点 + 掌握度 + 重新计算）、
  **技能**（安全横幅、已装卡片、检查更新（全部）、从 EduHub 添加、锁定/解锁、更新、回退、移除二次确认）。
- 对话/资料/今日/笔记页按当前学科取数并在页头显示学科；`LOOP_SUBJECT` 可指定启动学科（合法且未归档才生效），
  草稿与附件按学科暂存/恢复。
- 窄窗与浮窗：900×600、360×420 浮窗、76px 紧凑侧栏均无 `RenderFlex overflow`
  （`docs/evidence/subject-v0.8.0/screens/OVERFLOW.txt` = `no rendering overflow`）。

## 8. 验收

- 规格 §14 唯一权威清单 **AC-01…AC-14**（`docs/subject-feature-spec.md`）。
  复审结论：**AC-01/02/03/04/05/06/08/09/10/11/12/13 达标**；
  **AC-07（UI 窄窗/深色/浅色截图）与 AC-14（可信度如实呈现）的「截图」半边不达标**（R3-1 详见 §0/§9）。
- 三条独立验证报告：
  - `docs/subject-feature-verification-r2.md`（t14：t9 的 18 条 findings 在 t12 字节上全部确认为已修）
  - `docs/subject-feature-verification-r3.md`（t17：R2-5/R2-6/R2-7 独立复现通过；T17-1/2/3 已修；**不通过项**见该报告 §3）
  - `docs/subject-feature-verification-r4.md`（t19：7/7 通过；T17-1/2/3 确认已修；另记 3 条非阻塞观察）
- 独立探针（真实 HTTP + SQLite + SSE，仅模型端点与 registry 用 loopback 替身）：F-1…F-18、R2-5/R2-6/R2-7
  在各自字节上逐条复现；端到端套件 `app/test/subject_e2e_test.dart` 15 条（含 T1…T14 冻结契约冒烟）。

## 9. 已知限制与未验证项（如实记录）

### 9.1 证据类缺陷（本版按用户决定 B 未修）
1. **R3-1（medium）**：12 张 dark 主截图的调色板保真度问题（harness 未设全局 `LoopTheme.palette`），
   07 值列 **1.03:1、1× 下不可见**；AC-07/AC-14 的截图证据不完整。**产品 dark 模式本身无缺陷**（§0）。
2. **R3-2（low）**：`04` 概览图 fixture「有知识点但无学习记录」同屏矛盾（证据内部不一致，非产品缺陷）。

### 9.2 功能类限制（已确认为设计取舍或未实现）
3. **F1 已由 t11 修复**：只读源文件导致迁移残留的问题（删源前清只读 + 先改 path 再删源）；
   真实数据副本演练 540/540、`errors=[]`（无需再列为风险）。
4. **F3 `skill_hub_url` 设置项无效**：仓库白名单固定 EduHub（`GET /api/settings` 恒返回白名单值 + `readonly` 标志，
   `PUT` 传其它 hub → `400 hub_readonly`），本版不支持切换技能站点。
5. **`pinned`（锁定版本）仅作标记与更新链路提示**：不提供自动更新/自动回退策略，也不改变已安装文件内容。
6. **`Ctrl+Shift+S` 快捷截图未实现**（现有截图入口为 `Alt+A` 与输入框菜单）。
7. **§8.7 迁移期进度回填（可选，P1）未做**：迁移不凭空生成掌握度，也不按旧消息回填 `progress_daily`/`topics`
   （迁移后 `get_subject_progress` 的画像/知识点为空，需从新对话产生证据）。
8. **正式库 mtime 变化无法归因**：`data/loop.db` 的 mtime 为 `2026-10-25T08:13:14Z`，
   该次变化的原因无法归因（内容 size/sha256 全程一致，本版发版验证前后也未再变化）。

### 9.3 未验证项（不得当成已验证）
9. **当前字节的真机界面未重拍**：`real-13..16` 是 t8 时点构建的真实进程截图，**不能作为当前字节的证据**；
   12 张主图是 widget 级渲染（生产 widget + 假后端 fixture），不含真实数据量/窗口装饰/DPI。
10. **AC-12 只有实测值、没有绝对值基线**：20 学科打开/切换总耗时 60ms、P95 3ms、句柄上限 4（`t8`/`repair` 用例打印）；
    未建立机器可比的绝对阈值。
11. **AC-13 只验证了替身离线**：`offline` 码与零写盘用 loopback 替身验证，**真实断网**未验证。
12. **R-DRILL（真实 540 文件迁移演练）默认 skip、本版未运行**（t11 曾在授权下单独跑通一次）。
13. **字体/图标路径可移植性**：widget 级截图 harness 依赖产品自带 `assets/fonts/NotoSansSC-Loop.ttf` 与
    Flutter SDK 缓存里的 `MaterialIcons`，换机器/换 SDK 是否仍无豆腐块未验证；个别图标码点仍可能是方框。

## 10. 产物、校验与升级

| 项 | 值 |
|---|---|
| 目录 | `release/Loop-Desktop/`（`Loop.exe` + DLL + `data/` 界面资源 + `使用说明.txt`） |
| 压缩包 | `release/Loop-Desktop-win64.zip` — **21,143,715 字节** |
| ZIP SHA-256 | `84863F481782C5C472766BF6BE6A68D8C26E7E70B9FA6C8911F7E09F00EC1AD3` |
| `Loop.exe` SHA-256 | `82C58A60CC7FBE93D343F57A21140B3599520C8EB9984CF106392BB32B82A1F7`（114,688 字节） |
| `version.json` | `{"version":"0.8.0"}`（构建脚本按 `app/pubspec.yaml` 自动写入） |
| 构建后 `/api/health` | `{"ok":true,"version":"0.8.0","has_key":false,"active_subject":"default"}`（隔离 `LOOP_DATA_DIR`、真实进程、真实 HTTP，连续两次探活一致） |

- 升级：从 v0.7.1 启动后首次运行会把旧数据迁入默认学科「通用」（见 §3），`legacy_*` 留档；用户 `data` 保留。
  降级到 v0.7.1 看不到新数据，属既定非目标（规格 §16 #9）。
- **本版不自动创建 GitHub Release**：需要人工把 `release/Loop-Desktop-win64.zip` 上传到 Releases。
- 推送结果（如实）：{{PUSH_RESULT}}

## 11. 验收命令与证据链

```powershell
$env:PATH='D:\DSH_Workspace\Prog2_app\.tools\flutter\bin;'+$env:PATH
Set-Location 'D:\DSH_Workspace\Prog2_app\app'
flutter analyze          # No issues found!（0 issues，EXIT=0）
flutter test             # 473 passed / 1 skipped（EXIT=0，All tests passed!）
flutter test test/subject_repair_regression_test.dart        # 31/31
flutter test test/subject_migration_readonly_test.dart       # 7 passed / 1 skipped（R-DRILL opt-in）
flutter test test/subject_ui_test.dart                       # 34/34
flutter test test/subject_screenshots_test.dart              # 1/1（写 12 张主图到证据目录）
Set-Location 'D:\DSH_Workspace\Prog2_app'
powershell -ExecutionPolicy Bypass -File packaging\build_native.ps1   # release 构建 + zip
```

证据链（当前字节）：

- `docs/evidence/subject-v0.8.0/screens/`：**16 张 PNG**（12 张 AC-07 主图 + 4 张 t8 时点真机图）+ `OVERFLOW.txt`
  （`no rendering overflow`）。
- `docs/evidence/subject-v0.8.0/TREE_DIGEST.txt`：`app/lib` + `app/test` 全部 `.dart` +
  本证据目录全部文件的树摘要（算法见证据目录 `README.md` §1.1，可逐字复算）。
  本版发版字节 = **`a4bd71afed1eafb767e7c13f5c23bb1f545cc0b9be54e5801801f74ebc9a40c3`**（162 文件）；
  发版前 pre-fix 值为 `3faaa26e…80d44`（t18/t19）。**差异三处、全部可归因**：① `app_version.dart`
  版本号 0.7.1→0.8.0（发版要求）；② t23 回滚掉 t20 半截 delta 后 harness 源码无法与 t18 原版逐字节相同；
  ③ 12 号图因版本文本变化重放。两条证据类缺陷（R3-1/R3-2）状态未变。
- `docs/evidence/subject-v0.8.0/README.md`：渲染方式 A/B、数据来源、可验证/不可验证范围、逐图 sha256。
- `docs/subject-feature-verification-r2.md` / `-r3.md` / `-r4.md`：独立验证报告。
- 正式库零污染：全量测试与构建前后 `data/loop.db` 的 **mtime + sha256 完全一致**
  （mtime `2026-10-25T08:13:14.1340180Z`、size `113467392`、
  sha256 `1CB939B44BEBE7EF53709A09BE48705F9E0BD017B0270BBEB1241F69B600D645`），
  `data/files` 恒 540 个文件；真实进程探活用的是隔离数据目录 `LOOP_DATA_DIR`（生成
  `subjects/default/{loop.db,files,skills}`，未回退到正式库）。

> 本文件如实描述发布状态：**t16 复审 verdict = `needs_revision`（仅证据类 findings），经用户决定 B 接受现状发版**；
> R3-1 / R3-2 **未修复**，不得对外表述为已修复或 pass。