# 极简形态与独立回答浮窗 — t12 修复后 t13 复验报告（PASS；T5-08 保留 EXCEPTION）

- 任务：`t13 [verify]` 复验跨屏 auto-follow 修复与全量回归
- attempt：`bd2dbdf2-734f-4516-b7ed-56919c569c21`
- 基线：`HEAD ac3f767`（v0.5.0）；`app/pubspec.yaml` 仍为 `0.5.0+14`（未提升，v0.6.0 留给 t6）
- 复验日期：2026-10-24 23:46–23:55 +08:00
- 证据：`docs/evidence/minimal-overlay-v0.6.0/t13/`；环境：`t13/environment.txt`
- **结论：t13 复验 PASS（无 blocker）。** t8 的两个 MAJOR 跨屏问题（真实拖动 1290×1344/747×792、程序化跨屏留旧屏）已由 t12 修复并复测通过；F-01 指针焦点、F-02 主题、F-03 150% 创建均通过。**T5-08 首次可见 1030–1125ms 仍是 EXCEPTION，不标 PASS**，由 t9 决定是否接受；无其他 blocker。

> t13 只做验证，没有修改实现、版本、`app/windows/**`、`release/**` 或 `D:\DSH_Workspace\Loop-Test`。新增仅本报告与 `docs/evidence/minimal-overlay-v0.6.0/t13/**`；t8 报告已归档到 `t8/t8-report.md`，t8 全流程证据仍保留。

---

## 1. 基线命令（`app/` 下执行）

| 命令 | 结果 | 证据 |
|---|---|---|
| `flutter analyze --no-pub` | exit 0，`No issues found!` | `t13/quality/analyze.log` |
| `flutter test --no-pub` | exit 0，**259/259 All tests passed!** | `t13/quality/flutter-test.log` |
| `flutter build windows --release` | exit 0，`√ Built ...\loop.exe` | `t13/quality/build-release.log` |
| 版本 / Loop-Test | `0.5.0+14` 未变；Loop-Test 近 2h 修改 0 | `t13/environment.txt` |

构建 hash：`loop.exe` `110BE3EA…`，`data/app.so` `8466AC01…`，`desktop_multi_window_plugin.dll` `D2707CF5…`（t12 vendored 补丁）。

---

## 2. 跨屏 auto-follow 复验（t8 的两个 MAJOR 已消除）

| 场景 | t13 实测 | 期望 | 结果 |
|---|---|---|---|
| A0 主屏 125% 创建长回答 | 896×950 @120 | 716.8×760 逻辑@120 | PASS |
| A1 真实拖动主窗 **125→150** | **1075×1120 @144** | 1075×1120 @144 | PASS（旧 1290×1344 未复现） |
| A2 真实拖回 **150→125** | **896×950 @120** | 896×950 @120 | PASS |
| B0 副屏 150% 创建（宽 597.3 逻辑） | 896×1120 @144，gap 11 | 896×1120 @144，gap≈12 | PASS（1px 检测误差） |
| B1 真实拖回 **150→125** | **747×950 @120** | 747×950 @120 | PASS（旧 747×792 未复现） |
| C1 程序化主屏→副屏 | **896×1120 @144** | 896×1120 @144 | PASS |
| C2 程序化副屏→主屏 | **747×950 @120** | 747×950 @120 | PASS |
| D0 用户拖回答窗到副屏（-1800,422,896,1120@144） | 位置/dpr 保持 | userMoved | PASS |
| D1 主窗移到副屏 | 仍 (-1800,422,896,1120)@144 | 不回主屏/不改 dpr | PASS |
| D2 主窗移回主屏 | 仍 (-1800,422,896,1120)@144 | 不回主屏/不改 dpr | PASS |

- 证据：`t13/anchor/anchor-console.log`（真实拖动 A1/A2、userMoved）、`t13/run2/run2-results.jsonl`（D-03 创建、D-05 程序化、D-06 回副屏、D-07 用户移动）、`t12/t12-crossscreen-evidence.txt`（t12 原始 A0–D2 数据，作为实施证据参考）。
- 真实拖动日志：`auto-follow display DISPLAY1 dpr=1.5 / DISPLAY2 dpr=1.25`；稳定写回 1075×1120 / 896×950 / 747×950；`answer overlaps input bar=0`。t13 run2 28 项：25 PASS / 0 FAIL / 3 INFO，退出干净。
- 100% DPI：本机无 100% 显示器、且未改用户显示设置；由单测 `U-AL-30`（t12 新增 U-AL-28..32）覆盖，列环境限制。

---

## 3. F-01/F-02/F-03 与 T5 项

### 3.1 F-01 指针焦点（PASS）与 IME 限制

- `t13/click/click-results.jsonl`：5/5 次点击回答正文、拖标题、拖滚动条、滚轮后 `GetForegroundWindow` 均主窗，文本焦点 hwnd 始终不变；`F-01-episodes focus 阶段=0`；随后继续输入“好”并提交，DB messages 含“测试好”。
- `t13/probe/probe-results.jsonl`：F-01 click/drag/scrollbar/wheel 全 PASS，F-01 episodes=6 max=94ms（无 >100ms）；`t13/run3/`：点击回答窗后 fg/focus 不变，F-03-01 max=32ms。
- t8 曾记录的创建/恢复 108/287ms outlier 在 t13 专项复核中未复现（t13 click 0 事件、probe max94、run3 32）；历史数据保留在 `t8/run1/foreground.tsv`，由 t9 决定是否需长期监控。
- 真实中文 IME 组合仍无法自动化（Microsoft Pinyin 已安装，`ImmGetContext=0`；t13/run3 IME-01-00）。以“文本焦点 hwnd 不变 + 连续中文输入/提交成功”为等价证据；建议 t9/人工 IME 手测补一条。

### 3.2 F-02 主题（PASS）

`t13/run3`：light 主 brightness 238.6 / 回答窗 240.1；切深色后已打开回答窗 **40.6**，关闭重建首帧 27.6；T-02-* 全 PASS。

### 3.3 F-03 150% 创建（PASS）

`t13/run2` D-03：副屏创建 **896×1120@144**，gap 11（1px 检测误差）；旧 950/9 未复现。U-AL-20/21。

### 3.4 T5 项

| 项 | 结果 | 证据 |
|---|---|---|
| T5-04 seq/无全量风暴 | PASS：`resync_requested=0` | run2/click/probe |
| T5-05 形态切换重报 anchor | PASS：modes 4/4；minimal 回答窗可见且零交集；返回自动关闭；overlaps=0 | `t13/modes/modes-results.jsonl` |
| T5-06 用户拖到副屏不被主窗拉回 | PASS：run2 D-07-03/04 固定 (-2438,-58,896,1120)@144；anchor userMoved 留主屏@120 | run2/anchor |
| T5-07 创建期 preventClose/无孤儿 | PASS：提交后 30ms tray 退出 exited=True 1137ms，windowsLeft=0/portLeft=0 | probe |
| T5-08 首次可见 | **EXCEPTION（非 PASS）**：三次 **1125/1030/1051ms**（Enter→可见）>400ms；host ready/visible 约 1.0–1.2s；等待态截图 `probe/t5-08-thinking-1.png` 显示“正在思考…”，无空窗；t9 决策（第二引擎冷启动，spec 禁预热） | probe |
| T5-09 非替换 snapshot 保留滚动 | PASS：A-IPC-08/09、A-UI-06；259 测试 | quality |
| T5-10 显示器移除 clamp | PASS（单测 U-AL-26）；物理拔显示器不可自动化，列限制 | quality |
| T5-11 滚轮路由 | PASS：run1 t8 wheel 0.237/scrollbar 0.537；t13 click 滚轮后前台/焦点不变 | click + t8 |
| T5-13 resetPosition | PASS（代码审计）：全仓无 `onResetPosition/reset_position`；A-UI-05。click probe raw T5-13 FAIL 是 before rect 用了拖动前旧值（moved 延迟应用；after 仅 +20 与拖动一致），非双击问题 | `t13/click`、`verification-notes` |
| T5-14 极简 3 次/拖到最小/关闭重开 | PASS：按钮 3 次进入/展开 + 真实拖到最小 450×65 自动极简 + 3 次关闭重开 | probe |

### 3.5 历史原始失败的说明（不改变 t13 结论）

- t8 的 run1 原始 A-02-02 FAIL 是等待 1.8s 过短（下一项 A-02-03 实测已 950）；t13 未重复该断言，保留 t8 归档。
- click probe T5-13 raw FAIL 为旧 rect 对比 artifact；t13 以源码无 resetPosition + 单测 A-UI-05 判定 PASS。
- t8 的 108/287ms 创建/恢复 outlier 在 t13 未复现；t9 可决定是否接受历史记录。

---

## 4. 全量回归

| 项 | 结果 | 证据 |
|---|---|---|
| 第二窗创建/关闭/重开/单实例/外部关闭 | PASS：t8 全流程 A-02-01/A-06-*；t13 run3 重建 | t8/t13 |
| tray 退出无孤儿 | PASS：t13 run2 D-06、probe T5-07 1137ms 无残留 | t13 |
| 主窗唯一数据源/只读 IPC | PASS：answer_ui 不 import state/api/backend；替换/停止/错误/stream off 走主窗快照 | t8 + t13 |
| 极简 460×52/三要素/无留白/3 次循环 | PASS：t13 probe T5-14 | t13 |
| 回答窗 35%/minH/maxH/节流/内部滚动/收起/替换/停止/错误/stream off | PASS：t8 全流程 + t13 run2/click/probe | t8/t13 |
| 截图上传→提问→回答闭环 | PASS：t8 S-01-*、uploads=1（t12 diff 仅跨屏/plugin，不触及截图状态机） | `t8/run1` |
| v0.5.0 900×600/最大化恢复/截图/置顶/托盘 | PASS：t8 回归证据保留；t13 re-ran affected window/answer/theme/modes | `t8/run1` + t13 |
| 数据隔离/不碰 Loop-Test/不 push/不改版本 | PASS | `t13/environment.txt` |

---

## 5. 限制与结论

**限制（非 blocker）**

1. 真实中文 IME 组合不可自动化（`ImmGetContext=0`）；已用焦点 hwnd 不变 + 连续中文输入/提交等价验证。
2. 100% DPI 无物理显示器；单测 `U-AL-30` 覆盖，未改用户显示设置。
3. 任务栏自动隐藏（两屏 rcWork=rcMonitor）；可见任务栏场景未测。
4. 物理拔显示器不可自动化；单测 U-AL-26。
5. **T5-08 首次可见 1125/1030/1051ms >400ms，按 EXCEPTION 记录，不标 PASS**；等待态有明确“正在思考…”反馈、无空窗；由 t9 决定是否接受或另立优化（第二引擎冷启动，spec 当前禁止启动预热）。

**结论**

- t8 的两个 MAJOR 跨屏问题已修复且 t13 双向复核通过（真实 125↔150、程序化、userMoved、无双重缩放）。
- F-01 指针焦点、F-02 主题、F-03 150% 创建均通过；T5-04/05/06/07/09/10/11/13/14 回归通过。
- **无 blocker**，t13 复验 PASS，唯一保留项为 T5-08 EXCEPTION（非 PASS），交 t9 决策。可以进入 t9 评审；版本提升、正式 release、push/tag 仍留给 t6，且不得自动创建 GitHub Release。

---

## 6. 证据索引（`docs/evidence/minimal-overlay-v0.6.0/t13/`）

| 路径 | 内容 |
|---|---|
| `environment.txt` | 版本/hash/显示器/隔离/限制 |
| `quality/` | analyze 0、259/259、release build |
| `anchor/` | 真实 125→150→125 与 userMoved（1075×1120@144 / 896×950@120） |
| `run2/` | 副屏创建 896×1120@144、程序化跨屏、userMoved、tray 退出（全 PASS） |
| `run3/` | light/dark 主题（40.6/27.6）、点击回答窗焦点、F-03 max32ms |
| `click/` | 5 次点击正文/拖标题/滚动条/滚轮，0 回答窗前台、focus 不变、messages 含“测试好” |
| `modes/` | T5-05 形态切换 4/4 |
| `probe/` | T5-08 三次 1125/1030/1051ms + thinking 截图；T5-14 三循环/拖到最小；T5-07 创建期退出 1137ms |
| `scripts/` | t13 自动化脚本快照 |
| `t12-reference/` | t12 原始跨屏证据/摘要（实施参考） |

> 旧 t8 全流程证据在 `docs/evidence/minimal-overlay-v0.6.0/t8/`，t8 报告归档为 `t8/t8-report.md`；t13 未修改其内容。
