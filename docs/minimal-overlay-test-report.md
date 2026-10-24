# 极简形态与独立回答浮窗 — t15 复验 + v0.6.0 交付报告（PASS；T5-08 保留 EXCEPTION）

- 任务：`t15 [verify]` 复验 T9-01 userMoved 遮挡修复与全量回归；`t6 [integrate]` v0.6.0 集成交付
- attempt：`88e76a17-6c91-4813-845b-61f09545d865`（t15） / `18a51b47-0993-4633-9d9c-ade1acb767c9`（t6）
- 基线：`HEAD ac3f767`（v0.5.0）；验证版本 `0.5.0+14` → 发布版本 `0.6.0+15`
- 复验日期：2026-10-25 00:08–00:16 +08:00
- 证据：`docs/evidence/minimal-overlay-v0.6.0/t15/`；环境：`t15/environment.txt`
- **结论：t15 复验 PASS（无 blocker）。** t14 的 T9-01 修复通过真实路径复核：normal 长回答 → 轻拖标题令 userMoved → floating/minimal 输入条移动后，回答窗与真实 `inputBarPhysical` 零交集、dpr/宽度保持、极简输入框可点击输入并成功提交；无遮挡的 userMoved 回答窗在形态切换时不被错误移动。t12 跨屏修复、F-01 指针焦点、F-02 主题、F-03 150% 创建仍通过。**T5-08 首次可见 1032–1099ms 仍是 EXCEPTION（不标 PASS）**，t13 曾记录 4290ms 冷启动更慢值，均交 t9 决策。

> t15 只做验证，没有修改实现、版本、`app/windows/**`、`release/**` 或 `D:\DSH_Workspace\Loop-Test`。新增仅本报告与 `docs/evidence/minimal-overlay-v0.6.0/t15/**`；t13 报告归档到 `t13/t13-report.md`，t8/t13 证据保留。

---

## 1. 基线命令（`app/` 下执行）

| 命令 | 结果 | 证据 |
|---|---|---|
| `flutter analyze --no-pub` | exit 0，`No issues found!` | `t15/quality/analyze.log` |
| `flutter test --no-pub` | exit 0，**261/261 All tests passed!**（新增 U-AL-33/34） | `t15/quality/flutter-test.log` |
| `flutter build windows --release` | exit 0，`√ Built ...\loop.exe` | `t15/quality/build-release.log` |
| 版本 / Loop-Test | `0.5.0+14` 未变；Loop-Test 近 2h 修改 0 | `t15/environment.txt` |

构建 hash：`loop.exe` `110BE3EA…`，`data/app.so` `9579140F…`，plugin `D2707CF5…`。

---

## 2. T9-01 userMoved 输入条遮挡复验（真实路径）

`t15/t9/t9-results.jsonl`（全部 PASS，14 项）：

| 阶段 | 回答窗 rect | 真实输入条 rect（host 日志） | 结果 |
|---|---|---|---|
| normal 长回答（auto 在输入条上方） | (1283,188,896,950)@120 | normal 输入条（下方） | 基准 |
| 轻拖标题（userMoved） | (1323,188,896,950)@120 | — | userMoved=true |
| 进入 floating（输入条移动） | (1050,188,896,950)@120（host nudge #1/#2） | (2064,964,1018,133) / (1956,961,573,133) | **overlap=0，gap 10，dpr/宽保持** |
| 进入 minimal | (1050,188,896,950)@120，无需再移动 | (1956,961,573,133) | **overlap=0，dpr/宽保持** |
| 极简输入条点击 + “测试好” + Enter | 回答窗替换并缩回 **896×225**（minH） | 极简条仍在 | **输入可用；DB messages 含“测试好”** |
| 另一端：无遮挡 userMoved（拖到 783,0）进 floating/minimal | 保持 (783,0) 不变 | 不重叠 | **不被错误移动** |

- host 日志：`answer userMoved nudged for input bar` **2 次**（rect 1158×… / 1050×…，含 gap 8），`overlaps input bar=0`、`stillOverlap=0`；极简 submit 后仍最小化（575×65），回答窗替换为新回答（950→225），`messages` 含“测试好”。
- 说明：探针分阶段读取“最新 input 行”在极端时序下可能读到后一形态；但 host 自身 nudge/overlap 日志为 2/0/0，且无遮挡路径位置逐像素保持不变，t14 原始证据（NUDGE=2、overlap=0）一致。
- 证据：`t15/t9/t9.log`、`t9-results.jsonl`、`app-out.log`；t14 原始证据见 `t15/t14-reference/`。

---

## 3. 跨屏、F-01/F-02/F-03 与 T5 项回归

### 3.1 跨屏 auto-follow（t12 修复保持）

| 场景 | 实测 | 期望 | 结果 |
|---|---|---|---|
| 真实 125→150 | 1075×1120@144 | 1075×1120@144 | PASS（旧 1290×1344 未复现） |
| 真实 150→125 | 896×950@120 | 896×950@120 | PASS |
| 副屏创建 | 896×1120@144，gap 11 | 896×1120@144 | PASS |
| 150%→125%（副屏创建后） | 747×950@120 | 747×950@120 | PASS |
| 程序化主→副 / 副→主 | 896×1120@144 / 747×950@120 | 同 | PASS |
| userMoved 回答窗 + 主窗跨屏 | 位置/dpr 保持 | 不拉回/不改 dpr | PASS |

证据：`t15/anchor/anchor-console.log`、`t15/run2/run2-results.jsonl`（t15 run2 25 PASS/0 FAIL/3 INFO）。

### 3.2 F-01/F-02/F-03

- **F-01**：`t15/click` 5/5 点击正文 + 拖标题/滚动条/滚轮后 `GetForegroundWindow` 均主窗、文本焦点 hwnd 不变、focus 阶段 0 次回答窗前台；随后输入“好”提交，DB messages 含“测试好”。`t15/run3` 点击回答窗 fg/focus 不变；F-03-01 max 32ms。t15 probe 聚合到创建/恢复期 7 次回答窗前台、max **126ms**、over100=1（专项点击为 0；属创建/恢复路径残余，记录供 t9，非 blocker）。
- **F-02**：`t15/run3` light 主 238.6 / 回答窗 240.1；切深色后已打开回答窗 **40.6**，重建首帧 27.6；全 PASS。
- **F-03**：`t15/run2` 副屏创建 896×1120@144、gap 11；旧 950/9 未复现。

### 3.3 T5 项

| 项 | 结果 | 证据 |
|---|---|---|
| T5-04 seq/无全量风暴 | PASS：resync=0 | run2/click/probe |
| T5-05 形态切换 | PASS：`t15/modes` 4/4；overlaps=0；极简返回自动关闭回答窗 | modes |
| T5-06 用户移动跨屏保持 | PASS：run2 D-07 rect (-2438,-58,896,1120)@144 | run2 |
| T5-07 创建期 preventClose 无孤儿 | PASS：提交后 30ms tray 退出 exited=True 1186ms，windowsLeft=0/portLeft=0 | probe |
| T5-08 首次可见 | **EXCEPTION（非 PASS）**：三次 **1032/1099/1093ms** >400ms；t13 冷启动记录 4290ms；等待态截图 `probe/t5-08-thinking-1.png` 显示“正在思考…”，无空窗；t9 决策 | probe |
| T5-09 滚动保持 | PASS：A-IPC-08/09、A-UI-06；261 测试 | quality |
| T5-10 显示器移除 clamp | PASS（U-AL-26）；物理拔显示器不可自动化 | quality |
| T5-11 滚轮路由 | PASS：t8 wheel 0.237/scrollbar 0.537；t15 click 滚轮后前台/焦点不变 | click/t8 |
| T5-13 resetPosition | PASS（代码审计）：全仓无 `onResetPosition/reset_position`；A-UI-05。click raw T5-13 FAIL 为 before 旧 rect（moved 延迟 20px），非双击问题 | `t15/click` + notes |
| T5-14 极简 3 次/拖到最小/关闭重开 | PASS：按钮 3 次、双击展开、真实拖到最小 450×65 自动极简、3 次关闭重开 | probe |

### 3.4 全量回归

- 第二窗创建/关闭/重开/单实例/外部关闭、tray 退出无孤儿：t15 run2/probe + t13/t8 证据。
- 极简 460×52/三要素/无留白/返回；回答窗 35%/minH180/maxH760/80ms/内部滚动/收起/替换/停止/错误/stream off：t15 modes/t9/run2 + t13/t8 全流程。
- 截图闭环/v0.5.0 900×600/最大化恢复/置顶/托盘：t8 全流程归档（`t8/run1`）仍有效；t12/t14 diff 仅回答窗跨屏/遮挡逻辑，未改截图/minSize/标题栏；t15 已复跑第二窗/回答窗/极简/主题/焦点/形态切换。
- 版本/发布边界/Loop-Test：未提升、未 push/tag/Release、Loop-Test 修改 0。

---

## 4. 限制与结论

**限制（非 blocker）**

1. 真实中文 IME 组合不可自动化（`ImmGetContext=0`）；已用焦点 hwnd 不变 + 连续中文输入/提交等价验证。
2. 100% DPI 无物理显示器；t12 U-AL-28..32 单测覆盖，未改用户显示设置。
3. 任务栏自动隐藏（两屏 rcWork=rcMonitor）；可见任务栏场景未测。
4. 物理拔显示器不可自动化；U-AL-26。
5. **T5-08 首次可见 1032/1099/1093ms >400ms，EXCEPTION（非 PASS）**；t13 冷启动 4290ms 单独记录；等待态有明确“正在思考…”反馈、无空窗；t9 决定接受或另立优化（第二引擎冷启动，spec 禁止启动预热）。
6. F-01 创建/恢复期 126ms 一次 outlier（专项点击 0 事件；run3 max32ms），记录供 t9，不作为 blocker。

**结论**

- T9-01 修复通过：userMoved 回答窗在 normal→floating→minimal 的输入条位置变化后重新检查真实 inputBarPhysical，零交集、dpr/宽度保持、输入可用、回答窗替换成功；无遮挡 userMoved 不被错误移动。
- 跨屏、F-01 指针、F-02 主题、F-03 创建、T5-04/05/06/07/09/10/11/13/14 及全量回归通过。
- **无 blocker**，t15 复验 PASS；唯一保留项 T5-08 EXCEPTION（非 PASS）交 t9 决策。可进入 t9 评审；版本提升、正式 release、push/tag 仍留给 t6，且不得自动创建 GitHub Release。

---

## 5. 证据索引（`docs/evidence/minimal-overlay-v0.6.0/t15/`）

| 路径 | 内容 |
|---|---|
| `environment.txt` | 版本/hash/显示器/隔离/限制 |
| `quality/` | analyze 0、261/261、release build |
| `t9/` | T9-01 14 项（真实路径 nudge/overlap/input/DB + 无遮挡保持） |
| `t14-reference/` | t14 原始 NUDGE=2/overlap=0 证据/N0/F1/M1/M2 截图 |
| `anchor/` | 真实 125↔150 跨屏（1075×1120@144 / 896×950@120） |
| `run2/` | 副屏创建、程序化跨屏、userMoved、tray 退出（25 PASS/3 INFO） |
| `run3/` | light/dark 主题、点击回答窗焦点、F-03 max32ms |
| `click/` | 5 次点击正文/拖标题/滚轮、0 回答窗前台、messages 含“测试好” |
| `modes/` | T5-05 4/4 |
| `probe/` | T5-08 三次 1032/1099/1093ms + thinking 截图；T5-14 三循环/拖到最小；T5-07 1186ms |
| `scripts/` | t15 自动化脚本快照 |

> t13 报告归档在 `t13/t13-report.md`，t8 报告在 `t8/t8-report.md`；旧证据未覆盖。

---

## 6. v0.6.0 正式交付（t6）

- 版本：`app/pubspec.yaml` → `0.6.0+15`；`AppVersion.current = 0.6.0`；`Loop.exe` FileVersion/ProductVersion = `0.6.0+15`；`version.json = {"version":"0.6.0"}`。
- 文档：`README.md`（当前功能 + v0.6.0 changelog）、`docs/release-v0.6.0.md`、`packaging/native-readme.txt`（使用说明）。
- 构建：`flutter analyze --no-pub` 0；`flutter test --no-pub` **261/261**；`packaging/build_native.ps1` 成功。
- 正式产物（`release/` 被 gitignore，ZIP 保留手动上传）：
  - `release/Loop-Desktop/Loop.exe`：114,688 B，SHA256 `4CC23EDDA929D27BEADDA81B6B9257E680DD839B0F7137E2310B49B9EE7A6416`
  - `release/Loop-Desktop/version.json`：19 B，SHA256 `9F2A0F085AF1D8D75C044CB7D0B9B45DB4E975A2FA9354CFDF62731A791A0899`
  - `release/Loop-Desktop-win64.zip`：**20,773,594 B（19.81 MiB）**，SHA256 `F63F539BEDACC0297C30A82A0B685AFF3DC486F2CD52EA10FB62E33097A1D7C9`
- ZIP 校验：含 `Loop.exe`、`version.json`、`使用说明.txt`、`desktop_multi_window_plugin.dll`、`flutter_windows.dll`、`data/app.so` 等；不含用户 `loop.db`。
- 正式产物冒烟（隔离 `LOOP_DATA_DIR`，官方 `release/Loop-Desktop/Loop.exe` + mock LLM）：`/api/health` `ok=true/version=0.6.0`；T9-01 14/14 PASS（第二窗/极简/输入提交/替换/零遮挡，host nudge=2/overlapWarn=0）；退出无残留进程/端口。
- 用户数据：默认 `data/loop.db` 未触碰（mtime 2026-10-24 16:32，早于本轮 00:2x 验证）；所有测试使用 `%TEMP%` 隔离数据目录。
- Loop-Test：近 2h 修改 0；未 push GitHub Release。
- 证据：`docs/evidence/minimal-overlay-v0.6.0/t6-release/`（analyze/test/build、release-check、官方冒烟 t9 log/results、environment）。
