# 极简形态与独立回答浮窗 — t4/t5 修复后 t8 复验报告

- 任务：`t8 [verify]` 复验 F-01/02/03 修复与全量回归
- attempt：`cc0e0915-2926-41ef-8b33-f661cd6e773a`
- 基线：`HEAD ac3f767`（v0.5.0）；`app/pubspec.yaml` 仍为 `0.5.0+14`（未提升，v0.6.0 留给 t6）
- 复验日期：2026-10-24 23:09–23:30 +08:00
- 证据根目录：`docs/evidence/minimal-overlay-v0.6.0/t8/`
- 环境快照：`docs/evidence/minimal-overlay-v0.6.0/t8/environment.txt`
- **结论：t8 复验 FAIL（NOT PASS）**。t7/t10/t11 对 F-01（点击/拖动/滚轮抢焦点）、F-02（主题不联动）、F-03（150% 副屏创建高度/gap）的修复已通过专项复核；但 **主窗在 125%↔150% 显示器之间真实拖动时，回答窗自动跟随后的物理尺寸错误**（125→150 得到 1290×1344@144，期望 1075×1120；150→125 得到 747×792@120，期望 747×950），属于 T5-03/T5-05 跨屏验收的剩余 major；另有 T5-08 首次可见 1058–1182ms 的明确 EXCEPTION（非 PASS）、创建补偿偶发 108/287ms outlier。t8 不应作为 v0.6.0 的放行结论，需修复后复跑。

> t8 只做验证，没有修改实现代码、版本、`app/windows/**`、`release/**` 或 `D:\DSH_Workspace\Loop-Test`。新增仅本报告与 `docs/evidence/minimal-overlay-v0.6.0/t8/**`。

---

## 1. 基线命令（全部在 `app/` 下执行）

| 命令 | 结果 | 证据 |
|---|---|---|
| `.tools\flutter\bin\flutter.bat analyze --no-pub` | exit 0，`No issues found!` | `t8/quality/analyze.log` |
| `.tools\flutter\bin\flutter.bat test --no-pub` | exit 0，`254/254 All tests passed!` | `t8/quality/flutter-test.log` |
| `.tools\flutter\bin\flutter.bat build windows --release` | exit 0，`√ Built ...\loop.exe` | `t8/quality/build-release.log` |
| `pubspec` | 仍 `0.5.0+14`（未提升） | `t8/environment.txt` |
| Loop-Test | 近 2h 修改 0；t8 未写入 | `t8/environment.txt` |

构建产物 SHA256：`110BE3EA…E00C95`；vendored `desktop_multi_window_plugin.dll` SHA256：`98DFB071…8D975`（t7 构建，path dependency，原生补丁生效）。

---

## 2. t4/t5 失败项复核

### 2.1 F-01 焦点/IME — 点击/拖动/滚轮已修复（PASS），IME 组合仍为人工限制

- t8 专项 click probe（系统级 SendInput；`t8/click/`）：
  - 回答正文点击 **5/5 次**：`GetForegroundWindow` 均为主窗，文本焦点 hwnd 始终为 `32704194`（同一次运行内），无一次切到回答窗。
  - 拖动回答标题、拖动滚动条、滚轮：前台/文本焦点均保持主窗；这些交互后继续输入“好”并按 Enter，数据库 `messages` 中出现完整“测试好”（中文文本通路未中断）。
  - `F-01-episodes`：**0 次回答窗前台事件**（focus 阶段）。
- run3（`t8/run3/`）：点击回答正文后 `fg=14944990`（主窗）不变、`focus=16450710` 不变；`F-03-01` episodes=3、max=32ms（均为创建补偿）。
- 因此 **t7 的 F-01 修复通过**（点击正文/标题/滚动条/滚轮不再抢前台）。真实中文 IME 组合仍无法自动化（Microsoft Pinyin 已安装，`ImmGetContext=0`；环境限制，t7 以“文本焦点不变 + 连续中文输入/提交成功”为等价证据；建议 t9/人工 IME 手测补一条）。
- **残余观察（非点击路径）**：run1 全流程聚合到两次创建/恢复期回答窗前台 108ms、287ms（`t8/run1/foreground.tsv`），而 run3/probe 创建补偿多为 16–32ms。该 outlier 未在专项点击测试复现，可能由自动化/窗口恢复时机导致；但严格按 spec §2.8 “补偿 ≤100ms” 仍应记录，建议 t9 决定是否接受/加监控。

### 2.2 F-02 主题即时同步 — 修复通过（PASS）

- run3（`t8/run3/`）：light 主窗 brightness 238.6、回答窗 240.1；主窗设置切深色后，已打开的回答窗 brightness 变为 **40.5**（t4 为 245，说明 `answers.setTheme` 接线生效）；关闭后重建的回答窗首帧 27.6；T-02-* 全部 PASS。
- 单测 `U-AL-19/F-02` 覆盖去重/未打开记录/重建首帧。

### 2.3 F-03 150% 副屏创建 — 修复通过（PASS）

- run2（`t8/run2/`）：主窗 2160×1350@144 位于副屏；创建回答窗 **896×1120 phys @144**（widthLogical 597.3、heightLogical 746.7=maxH），gap=11 phys（期望 12，检测边缘 1px 误差可接受）。t4 的 950/9 旧值未复现。
- 单测 `U-AL-20/U-AL-21`；真实创建路径与 t10 真机一致。

### 2.4 **剩余 MAJOR：主窗真实跨屏拖动时回答窗自动跟随尺寸错误**

这是 t8 新发现，未被 t7/t10 覆盖，直接影响“100/125/150% 跨屏”验收：

| 场景（真实标题栏拖动主窗） | 实测回答窗 | 期望 |
|---|---|---|
| 主屏 125% → 副屏 150%（答案自动跟随） | **1290×1344 @144** | 1075×1120 @144（宽度固定逻辑 716.8；maxH 746.7） |
| 副屏 150% → 主屏 125%（答案自动跟随） | **747×792 @120** | 747×950 @120（宽度固定逻辑 597.3；maxH 760） |
| 回答窗已被用户拖到副屏后，主窗移动（T5-06） | 896×950 @120，位置不变、不回主屏 | T5-06 行为正确 |
| 程序化 `SetWindowPos` 把主窗从副屏移回主屏（未用真实拖动） | 回答窗留在副屏、dpr 仍 144（run2 D-05-03/04/05） | auto 模式应跟随；T5-05 的 500ms anchor sync 未重定向显示器 |

- 证据：`t8/anchor/anchor-console.log`、`t8/anchor/answer-secondary.png`、`answer-back-primary.png`、`answer-user-moved-secondary.png`；`t8/run2/run2-results.jsonl` D-05-03/04/05。
- 观测比例：125→150 的实际尺寸正好是期望的 **1.2×**（1075×1.2=1290、1120×1.2=1344，1.2=150/125），说明 host 在 DPI 切换前已按新 DPI 写入 bounds，随后 Windows `WM_DPICHANGED` 又按新旧 DPI 比例缩放一次，host 未在 DPI 稳定后重写最终 physical rect；150→125 则只把宽度修正、高度为 792（非 950）。根因线索：vendored `win32_window.cpp` 的 `WM_DPICHANGED` 处理与主引擎 `updateAnchors/_applyHeight` 的时序竞争/后续未重应用。修复应在 DPI 切换稳定后按目标显示器/当前 dpr 再 `setBounds` 一次（或延迟到拖动结束+500ms 同步后强制重算），并加跨屏 E2E。
- 程序化移动 auto 模式未跟显示器（run2 D-05）是同一类 gap；若自动恢复/显示设置变更走 `SetWindowPos`，也会出现回答窗留在旧屏；T5-05 的 anchor 轮询只更新输入条/主窗矩形，没有重新选 target display。建议 t10 补 `ensureOnScreen`/`onMainWindowMoved` 的显示器重定向，或让 Shell 500ms sync 在显示器变化时也调用 `answers.ensureOnScreen()`。

### 2.5 其余 t5 修复项

| 项 | 结果 | 证据 |
|---|---|---|
| T5-04 resize_ack seq | PASS：app stdout `resync_requested=0`（长回答/改高/形态切换后无全量风暴）；单测 U-AL-22 | run1/probe/click |
| T5-05 主窗 resize/形态切换重报 anchor | PASS：独立 modes probe 4/4（normal→floating→minimal→back；minimal 回答窗可见且与条零交集；返回自动关闭回答窗）；日志 `overlaps=0`、`anchors updated` 多次 | `t8/modes/modes-results.jsonl` |
| T5-06 用户拖到副屏的回答窗不被主窗移动拉回 | PASS：run2 D-07-03/04 位置不变/dpr144；anchor probe 用户移动后主窗跨屏，回答窗留在主屏@120 | run2/anchor |
| T5-07 创建期 preventClose/无孤儿 | PASS：提交后 30ms tray 退出，exited=True 1191ms，windowsLeft=0/portLeft=0 | probe |
| T5-08 首次可见 | **EXCEPTION（非 PASS）**：三次 1058/1182/1100ms（Enter→可见），host 日志 ready/visible 约 974–1193ms；未达 spec 400ms 目标。等待期截图 `t5-08-thinking-1..3.png` 显示主聊天有“正在思考/生成”反馈、无空窗；需 t9 决定是否接受（第二引擎冷启动，spec 禁止启动预热） | probe/probe-results.jsonl |
| T5-09 非替换 snapshot 保留滚动 | PASS（单测 A-IPC-08/09、A-UI-06；代码 use scrollResetToken 仅替换递增） | flutter-test.log |
| T5-10 显示器移除 clamp | 单测 U-AL-26 PASS；物理拔显示器不可自动化，列环境限制 | flutter-test.log |
| T5-11 滚轮路由 | PASS：run1 真实滚轮像素差 0.237 + 滚动条 0.537；click probe 滚轮后前台/焦点不变；单测 A-UI-08/09 | run1/click |
| T5-13 resetPosition | 采用“移除双击回调”方案：全仓无 `onResetPosition/reset_position`；单测 A-UI-05 双击不抛异常/不改布局。E2E 双击矩形比较被前一步 moved 延迟应用干扰，不作为产品失败证据 | grep/test |
| T5-14 极简 3 次/拖到最小 | PASS：按钮 3 次进入极简/双击展开；一次真实拖到最小自动进入极简 450×65 phys（360×52 逻辑）；3 次关闭/重开 | probe |

### 2.6 run1 原始断言说明（避免误读）

- `run1` 80 checks：74 PASS / 2 FAIL / 4 INFO。两个 FAIL：
  - `A-02-02`“替换后重新增长到 maxH”：检查只等待 1.8s，下一项 `A-02-03` 实测该窗口 896×950（已到 maxH）；属断言等待过短，非功能失败。
  - `F-01-01` 聚合：点击/拖拽专项已 PASS（见 §2.1）；聚合内 108ms/287ms outlier 是创建/恢复路径，见 §2.1 残余观察。
- run2 的 D-05 FAIL 是程序化 `SetWindowPos` 自动跟随问题（见 §2.4 最后一行）；D-03 创建、D-07 用户移动通过。
- run3 17 checks：全 PASS（主题/点击焦点/关闭）。
- T5-08 例外按 captain 要求写 EXCEPTION，不写 PASS。

---

## 3. 全量回归（t8 复验）

| 回归项 | 结果 | 证据 |
|---|---|---|
| 第二窗创建/关闭/重开/单实例/外部关闭 | PASS：run1 A-02-01/A-06-*、M-03-*；run3 回答窗重建 | run1/run3 |
| tray 退出无孤儿 | PASS：run1 X-02-03..06 answerGoneMs=144/exitMs=144、windowsLeft=0、portLeft=0；probe T5-07 创建期退出 1191ms 无残留 | run1/probe |
| 主窗唯一数据源/只读 IPC | PASS：answer_ui 仍不 import state/api/backend；替换/停止/错误/stream off 全走主窗快照 | 代码审计 + run1 A-02/A-03/A-04/A-05 |
| 极简 460×52/minSize/三要素/无留白 | PASS：run1 M-02-*、M-03-*、probe T5-14 | run1/probe |
| 回答窗 35%/minH180/maxH760/节流/内部滚动 | PASS：run1 896×225/950、min interval 129ms（本轮负载下）、滚轮/滚动条；单测 80ms | run1 |
| 收起/替换/停止/错误/stream off | PASS：run1 A-02-06/07、A-03、A-04、A-05 | run1 |
| 截图上传→提问→回答闭环 | PASS：run1 S-01-*、S-01-07 uploads=1、21-answer-after-screenshot.png | run1 |
| v0.5.0 900×600/最大化恢复/截图/置顶/托盘 | PASS：run1 N-01-02/N-02/M-01/X-01/X-02、S-01/S-02 | run1 |
| 数据隔离/不碰 Loop-Test/不 push/不改版本 | PASS | environment.txt |

---

## 4. 结论与风险

**t8 复验结论：FAIL（NOT PASS），需修复后再次复验。**

- 已确认修复：**F-01 点击/拖动/滚动条/滚轮抢焦点**、**F-02 主题不联动**、**F-03 150% 副屏创建高度/gap**；T5-04/05/06(用户移动)/07/09/10(单测)/11/13/14 也通过。
- **剩余 major（放行阻断）**：真实跨屏拖动主窗时回答窗自动跟随后的尺寸错误（§2.4）：125→150 为 1290×1344@144（应 1075×1120），150→125 为 747×792@120（应 747×950）；程序化跨屏 auto 模式还会留在旧屏/旧 dpr。该问题直接落在 t8 的“100/125/150% 跨屏测试”验收项。
- **明确 EXCEPTION（非 PASS）**：T5-08 首次可见 1058/1182/1100ms >400ms；等待期有清晰“正在思考”反馈；由 t9 决定是否接受该已知限制（第二引擎冷启动，禁止预热）。
- **残余观察**：F-01 创建/恢复补偿偶发 108/287ms（专项点击 0 事件；run3 32ms）；建议 t9 决定是否加验收监控或继续优化。
- 环境限制：100% DPI 无显示器（单测覆盖）、任务栏自动隐藏、物理显示器移除不可自动化、真实中文 IME 组合不可自动化（焦点/文本通路已等价验证）。
- 建议：t7/t10 优先修跨屏 auto-follow resize（DPI 稳定后强制重算/ensureOnScreen + 500ms sync），t9 复评时复跑 anchor probe、run2、run3、click probe；T5-08 若接受则降级为已知限制，否则另行评估预热/启动优化（spec 当前禁止）。

---

## 5. 证据索引（`docs/evidence/minimal-overlay-v0.6.0/t8/`）

| 路径 | 内容 |
|---|---|
| `environment.txt` | 版本/构建 hash/显示器/隔离/限制 |
| `quality/*` | analyze 0、254/254、build success |
| `run1/` | 主屏全流程（含 A-02 断言时序说明、F-01 聚合日志） |
| `run2/` | 150% 副屏创建 896×1120；程序化跨屏 D-05 finding |
| `run3/` | light/dark 主题（40.5/27.6）、点击回答窗焦点（fg 不变）、F-03 max32ms |
| `click/` | 5 次点击正文/拖标题/滚轮 → 0 次回答窗前台、文本焦点不变、messages 含“测试好” |
| `probe/` | T5-08 三次 1058/1182/1100ms + thinking 截图；T5-14 三循环/拖到最小；T5-05、T5-07 |
| `modes/` | T5-05 clean 4/4 PASS |
| `anchor/` | 真实 125↔150 跨屏 auto-follow 尺寸错误证据（1290×1344/747×792） |
| `verification-notes.txt` | T5-13 无 resetPosition 引用、254 测试、click raw FAIL 说明 |
| `scripts/` | 本轮自动化脚本快照（含硬编码本机路径，仅参考） |

> 证据不含桌面全屏截图；`t5-08-thinking-*.png` 仅为主窗截图。旧 t4 证据仍保存在 `docs/evidence/minimal-overlay-v0.6.0/run1..run3`，本报告不覆盖。
