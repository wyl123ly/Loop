# 桌面答疑悬浮窗 v0.5.0 — t4 功能验证与端到端测试报告

- 任务：t4 `[verify] 浮窗功能、截图问答与回归端到端验证`
- 执行者：floating-verifier；attempt 1，attempt_id `97e2688f-9027-4610-b615-c0f568c0a1c5`
- 仓库：正式版 `D:\DSH_Workspace\Prog2_app`（HEAD `4850848` + t2/t3 未提交改动）
- 日期：2026-10-24（Asia/Shanghai）
- 结论：**验证通过（最终 142/142；t4 发现的 F1/F2/F3 已由 t7/t8 修复，t7/t8 经 t9 复评 pass，t6 集成复核）**。静态检查 0 issue；全量 `flutter test` **142/142**；真实 Backend + SQLite + mock LLM live E2E **27/27**、重启持久化 **4/4**；真实 Windows 窗口（含双显示器/125%+150% DPI）验证了浮窗进入/置顶/缩放/返回/最大化恢复、最大化截图恢复、360×420 真实六页无溢出、截图框选→上传→`img_` 附件→提问→流式/非流式→停止→审批全链路；正式版打包链路构建成功并交付 v0.5.0。用户正在使用的 `release\`、`data\` 与 `Loop-Test` 未被污染。

> **最终口径（t6，2026-10-24）**
> - 测试最终为 **142/142**（含 t7 的 5 条最大化恢复测试、t8 的 4 条窄布局/过渡测试；此前 t4 阶段的 133/133 为历史数字，见 §13）。
> - 原 t4 发现 **F1（隐藏页 360 窄宽溢出）、F2（过渡帧页头溢出）、F3（最大化→浮窗→还原位置丢失）均已修复**，由 t7/t8 实现、t9 独立复评 pass；对应 T5-01/02/03/06（最大化恢复/截图恢复/回滚清理）与 T5-04/05（窄布局/过渡帧）已关闭。
> - 已知限制按期保留：本机全局快捷键被占用（1409）时降级为按钮；物理任务栏/拔插显示器矩阵未全部真机复跑；非聊天页跨形态会 remount（`ChatScreen` 保持）；输入注入/真实鼠标热区受测试机全屏程序限制。详见 §7 与 `docs/release-v0.5.0.md`。


---

## 1. 验证环境与隔离策略

| 项 | 值 |
|---|---|
| OS | Windows 11 家用中文版 10.0.26200 |
| Flutter / Dart | Flutter 3.47.7 stable（`abaf9c5237`）/ Dart 3.13.5 |
| 原生工具链 | VS 2022 BuildTools（MSVC 19.44） |
| 显示器 | **双屏实测**：主屏 2560×1440 物理 @125%（工作区 2560×1440）；副屏 2560×1600 物理 @150%，位于主屏左侧，原点 (-2560,-58) |
| 正式数据/产物 | `D:\DSH_Workspace\Prog2_app\data`、`release\`：只读；哈希与 mtime 验证前后一致（见 §9） |
| 隔离数据 | `%TEMP%\loop-floating-t4\data`（`LOOP_DATA_DIR`，空 `loop.db` 初始化） |
| 隔离源码/构建 | `%TEMP%\loop-floating-t4\`：正式源码副本，仅改测试隔离参数：后端端口 `8765→8767`（`backend/server.dart`、`api.dart`）、窗口标题 `回路 Loop T4`；其余与正式仓库一致；`.tools\flutter` 用 junction 复用 SDK |
| Mock LLM | `docs/floating-evidence/tools/mock_llm_floating.py`，`127.0.0.1:9999`（stdlib，SSE；slow/long/empty/error500/tool/plan/image 分支，并把请求写入 `mock_requests.jsonl` 供断言） |
| 真实窗口驱动 | `docs/floating-evidence/tools/floating_ui.ps1`（DPI-aware Win32 探针/PrintWindow/SetWindowPos）+ `docs/floating-evidence/tools/vm/*.dart`（VM Service 指针注入，不占用 OS 输入） |
| 用户实例/前台 | 未启动/未停止用户 Loop 实例（验证期间无 Loop 进程，8765 空闲）；桌面前台是用户的全屏游戏，所有 UI 注入均通过 VM Service 完成，未向游戏发送任何真实输入 |

**隔离说明**：live E2E 与真实窗口验证都在上述临时副本/临时数据中运行；从未写入或替换正式 `release\`、`data\`、`server\`、`plugins\` 与 `Loop-Test`。

---

## 2. 自动化验证

### 2.1 静态检查与全量测试（正式仓库）

```powershell
cd D:\DSH_Workspace\Prog2_app\app
..\.tools\flutter\bin\flutter.bat analyze --no-pub
..\.tools\flutter\bin\flutter.bat test --no-pub
```

| 命令 | 结果 | 证据 |
|---|---|---|
| `flutter analyze --no-pub`（t4 阶段） | No issues found!（0 issues，7.3s） | `docs/floating-evidence/logs/flutter-analyze.log` |
| `flutter test --no-pub`（t4 阶段） | All tests passed! 133/133 | `docs/floating-evidence/logs/flutter-test.log` |
| `flutter analyze --no-pub`（**t6 最终**） | **No issues found!**（0 issues，9.8s） | `docs/floating-evidence/logs/flutter-analyze-t6.log` |
| `flutter test --no-pub`（**t6 最终**） | **All tests passed! 142/142** | `docs/floating-evidence/logs/flutter-test-t6.log` |

最终 142 条 = 37 条 v0.4.0 基线 + 浮窗/窗口/几何/截图/布局新增测试（含 t7 的 U-WM-13~17 最大化恢复/截图恢复/回滚清理，t8 的 4 条窄布局与逐帧过渡测试）。t4 阶段的 133/133 是 t7/t8 修复前的历史结果，不作为最终口径。

### 2.2 禁止项与结构静态检查

| 检查 | 结果 |
|---|---|
| `setFullScreen`（lib/test/runner） | 仅静态检查测试源引用该字符串用于断言“不得调用”；产品代码 0 处 |
| `runApp(` | 1 处（`app/lib/main.dart:48`），无第二入口 |
| `FlutterEngine` | 0 处，无第二引擎 |
| `lib/desktop` 中 `Timer.periodic` / `WH_KEYBOARD_LL` | 0 处 |
| 用户 `Loop-Test` 修改 | 无（mtime 检查为空，见 §9） |

### 2.3 `assets/screenshot.ps1` v2 独立验证（不依赖 UI）

| 用例 | 结果 |
|---|---|
| 显式物理矩形 `-X 0 -Y 0 -W 800 -H 600` | exit 0，PNG **800×600** |
| 缺省/非法 W/H 回退主屏 | exit 0，PNG **2560×1440**（主屏物理，DPI-aware） |
| 小矩形 `10×10` | 正常输出 10×10（用于错误路径构造） |

---

## 3. Live Backend + SQLite + mock LLM 端到端

隔离实例（8767）真实运行 `agent.dart`/`server.dart`/SQLite；mock LLM 在 9999。驱动脚本：`docs/floating-evidence/tools/e2e_floating.py`；原始断言与事件序列：`docs/floating-evidence/logs/e2e-floating-full.json`。

### 3.1 结果：27/27 通过

| # | 用例 | 关键断言 | 结果 |
|---|---|---|---|
| E1 | 健康/版本/隔离端口 | `/api/health` ok、version `0.4.0`（t4 未做版本提升，预期值） | ✅ |
| E1b | 初始流式默认 | `stream_output=true`、theme=dark | ✅ |
| E1c | mock/工作区隔离 | base_url=9999、workspace=%TEMP% 隔离目录 | ✅ |
| E2a–E2f | **截图 PNG → `img_` 附件 → 随问题发送** | 上传 `kind=image,id=img_N`；SSE run→14×delta→done；mock 收到 `images=1, image_data_len>100`；落库 `attachments=[{id:img_N,is_image:true}]`；正文逐字一致 | ✅ |
| E3a–E3c | stream on/off | true 多 delta；false **单 delta**；两种模式正文一致 | ✅ |
| E4a–E4b | 运行中切换 stream_output | 当前 run 仍 28 delta；下一条按 false 单 delta（请求级快照） | ✅ |
| E5a–E5c | 停止 | 慢速生成中 cancel → `cancelled`、无 `done`；部分正文落库；下一条恢复可用 | ✅ |
| E6a–E6c | 审批 allow | `approval(fs_write)` 实时；allow → 文件写入 + audit `approval=approved`；回答完成 | ✅ |
| E7 | 审批 reject | reject → audit `approval=rejected`、工具不执行、回答收尾 | ✅ |
| E8 | 空回复 | 0 delta、done 一次、**不产生空助手消息** | ✅ |
| E9/E9b | 上游 500 | run→error（无 done），消息可读；下一条正常 | ✅ |
| E10 | 无 API Key | error 文案“还没有配置 DeepSeek API Key…”；恢复 Key 后可用 | ✅ |
| E11 | 长回复 | 140 delta 拼接 11191 字 == 落库；含 ```dart、`$r(A)$`、表格 | ✅ |
| E12 | 计划/工具 | plan/step 实时、终态 done、plan 落库 | ✅ |

### 3.2 重启与持久化：4/4

| # | 断言 | 结果 |
|---|---|---|
| R1 | 重启后健康 | ✅ |
| R2 | `stream_output=true` 持久化 | ✅ |
| R3 | mock base_url / has_key 保留 | ✅ |
| R4 | 截图问答会话历史仍在（user+assistant） | ✅ |

证据：`docs/floating-evidence/logs/e2e-floating-restart.json`。

### 3.3 隔离数据写盘校验

- 上传文件写入 `%TEMP%\loop-floating-t4\data\files\`，主屏真实截图 PNG **1125×750**（框选 900×600 逻辑 ×1.25，误差 0）；副屏真实截图 PNG **600×450**（框选 400×300 逻辑 ×1.5，误差 0）。
- 所有会话/消息/审计均在隔离 `loop.db`；正式 `data\loop.db` 的 SHA-256 验证前后一致（§9）。

---

## 4. 真实 Windows 窗口验证（隔离实例，debug）

驱动方式：`floating_ui.ps1` 读取真实 HWND/Win32 状态与 `PrintWindow(PW_RENDERFULLCONTENT)` 离屏截图；UI 点击/滚动/框选通过 **VM Service 注入 `GestureBinding.handlePointerEvent`**（微任务调度，不抢占焦点），绝不使用真实鼠标/键盘（桌面被用户全屏游戏占据）。窗口尺寸/位置变更使用 Win32 `SetWindowPos`/`MoveWindow`（等价于用户拖动结束后的几何，用于尺寸矩阵与多屏校验）。

### 4.1 窗口形态矩阵（真实探针）

| 场景 | 物理 rect（探针） | 逻辑换算 | topmost | maximized | minTrack（物理=逻辑×DPI） | 证据 |
|---|---|---|---|---|---|---|
| 普通窗口启动 | (380,157) 1800×1125 | 1440×900 @1.25 | false | false | 1125×750 = 900×600 | `logs/baseline-artifacts.json`、截图 t04-07 |
| 点标题栏“浮窗答疑” | (1955,345) **575×750** | **460×600** | **true** | false | **450×525 = 360×420** | t04-03、t04-08 |
| 浮窗缩放到 500×620 | (1900,300) 625×775 | 500×620 | true | false | 450×525 | 探针 |
| 浮窗缩到最小 | (1900,300) 450×525 | **360×420（compact）** | true | false | 450×525 | t04-05 |
| 浮窗取消置顶 | 575×750 | — | **false** | false | 450×525 | 探针（VM `pinned=false`） |
| 再次置顶 | 575×750 | — | **true** | false | 450×525 | 探针 |
| 最大化（原生） | (-9,-9) 2578×1458（client 2560×1440） | 2048×1152 | false | **true** | 1125×750 | 探针 |
| 最大化→浮窗 | (1955,345) 575×750 | 460×600 | true | **false** | 450×525 | 探针 |
| 返回→恢复最大化 | (-9,-9) 2578×1458 | — | false | **true** | 1125×750 | 探针 |
| 浮窗返回主窗口 | (380,157) 1800×1125（逐项还原） | 1440×900 | false | false | 1125×750 | t04-11 |
| 副屏（左，150%）普通窗口 | (-1800,-58) 2160×1350 | 1440×900 @1.5 | false | false | 1350×900 = 900×600 | 探针 |
| 副屏进入浮窗 | (-576,427) **540×630**（右缩 24 逻辑、垂直居中） | **360×420** @1.5 | true | false | 540×630 | t04-33 |
| 副屏截图后恢复 | (-576,427) 540×630 | — | true | false | 540×630 | t04-34 |

结论：
- 默认浮窗尺寸/最小尺寸/置顶/非最大化/位置（右缘内缩 24、垂直居中）与规格一致；DPI 125%/150% 下物理↔逻辑换算正确。
- 返回主窗口时 bounds/maximized/minSize/topmost 均按快照恢复（误差 0px）；连续进入/返回期间 ChatScreen State 与消息不变。
- 无原生标题栏：PrintWindow 截图中只有自绘 `FloatingBar`；`setFullScreen` 未被调用。

### 4.2 浮窗 UI 与真实交互（screens/）

| 证据 | 内容 | 结论 |
|---|---|---|
| `t04-03-floating-460x600-dark.png` | 暗色 460×600 浮窗：拖动栏（Loop/浮窗标签/会话标题）+ 截图/置顶/返回/关闭 + 空态 + 输入区；无侧栏/页头 | ✅ |
| `t04-05-floating-360x420-dark.png` | 360×420 compact：标题隐藏、四个按钮仍可见、空态不溢出 | ✅ |
| `t04-30-floating-360x420-light-empty.png` | 亮色 360×420 空态 | ✅ |
| `t04-08-floating-conversation-460x600-dark.png` | 浮窗内同一会话（图片预览、Markdown、token 行、输入区） | ✅ |
| `t04-06-floating-screenshot-attachment-dark.png` | 截图完成后浮窗自动恢复（460×600、置顶）且附件 chip 出现在输入区（缩略图已打码） | ✅ |
| `t04-09-floating-approval-dark.png` | 浮窗审批卡（fs_write 参数、允许/拒绝）；允许后回复完成（audit/落库见 §3） | ✅ |
| `t04-32-floating-360-light-error-snack.png` | 浮窗内 500 错误：气泡保留用户消息 + SnackBar「DeepSeek 服务暂时不可用（500），稍后重试。」 | ✅ |
| `t04-35/36-floating-stream-off-*.png` | stream=false：等待期「正在思考…」+停止按钮；完成后一次性整段正文（50 in/10 out） | ✅ |
| `keepalive-02/03/04.png` | 流式中：浮窗部分正文 → 切回主窗口继续增量 → 再回浮窗，最终正文完整且无重复 | ✅ |
| `t04-27/28-floating-360-light-long*.png` | 360×420 长 Markdown：表格、公式、代码块、列表；横向滚动；上滚出现「回到底部」胶囊并可跳回 | ✅（渲染正确） |
| `t04-22/23` | 设置页暗/亮（模型 deepseek-flash；流式开关为开） | ✅ |
| `t04-16/19/22/23` | 六页回归代表截图：今日/代理/设置（暗）与设置（亮）；六页均已实机切换 | ✅ |
| `t04-25-normal-900x600-light-long.png`、`t04-15` | 900×600 主窗口（侧栏自动 compact） | ✅ |

### 4.3 截图闭环（真实窗口，非 mock 服务）

1. 浮窗点截图（默认 hideLoop=true）：窗口隐藏 → `assets/screenshot.ps1` 抓当前显示器物理工作区 → 浮窗放大为截图覆盖层（主屏 2560×1440@1.25；副屏 2560×1600@1.5）→ VM 指针拖选框选（主屏 900×600 逻辑；副屏 400×300 逻辑）→「完成」→ 上传 → `img_` 附件 chip。
2. 全程 `captureInProgress=true` 时按钮禁用；完成后窗口恢复 **原形态/尺寸/位置/置顶/minSize**（主屏 575×750@(1955,345)；副屏 540×630@(-576,427)），无临时 `loop_shot_*` 目录残留（验证后检查 `%TEMP%` 为空）。
3. 重截上限、取消/Esc、上传失败路径：取消 live 通过（点击「取消」→ 无新上传、附件不变、窗口恢复）；重截与上传失败由 `W-SHOT-04/05/06` widget 测试覆盖（未 live 重跑）。
4. 附件随问题发送：live UI 在浮窗发送了文字 + `img_1` 附件；后端落库 `attachments=[{id:img_1,is_image:true}]`，mock 请求记录 `images=1, image_data_len=1302222`（即 image_url data URI），助手回答正常流式返回。

### 4.4 会话保活（切换不中断）真实观测

- 慢速回答生成中：浮窗（`isSending=true`，部分正文）→ 点返回 → 主窗口 1800×1125（**同一 `ChatScreenState` 对象 id/identityHashCode 不变**，`conversationId=1`、`messageCount=4`、`isSending=true`）→ 再进浮窗（State 仍不变）→ 完成后同会话正文 109 字完整、无重复。
- 证据：`logs/keepalive-flow.log` + `logs/keepalive-window-probes.log`（窗口尺寸序列 575×750 → 1800×1125 → 575×750，topmost 随形态变化）+ `keepalive-02/03/04.png`。
- `ChatScreenState` 在普通↔浮窗、置顶切换、审批、截图前后 identityHashCode 全程不变（VM probe `logs/` 输出见截图/命令记录），未重建、未重新 `_bootstrap`。

### 4.5 停止 / 审批 / 错误 / 空回复（浮窗内）

| 用例 | 结果 |
|---|---|
| 浮窗内停止 | 生成中点击停止 → `isSending=false`；后端落库部分正文 68 字；无重复 done | ✅ |
| 浮窗内审批 allow | 审批卡 → 允许 → `floating-approval.md` 写入、audit `fs_write/approved`、回答「已写入并回读…」 | ✅ |
| 浮窗内 500 | SnackBar 可读错误；UI 稳定；无助手消息落库 | ✅ |
| 浮窗内空回复 | 无 delta、无助手消息、无崩溃 | ✅ |
| 浮窗内 stream=false | 「正在思考…」→ 整段一次到达 | ✅ |

### 4.6 多显示器 / DPI（真实双屏，非模拟）

- 主屏 2560×1440 @125%、副屏 2560×1600 @150%（左置、负 X）。普通窗口拖到副屏后 Flutter DPR **1.5**、逻辑窗口仍 1440×900（物理 2160×1350）。
- 在副屏进入浮窗：位置 (-576,427) = 副屏工作区右缘内缩 24 逻辑、垂直居中；minTrack 540×630（360×420 逻辑）。
- 副屏截图：覆盖层物理 2560×1600，Flutter 逻辑 1706.67×1066.67；框选 400×300 逻辑得到 PNG **600×450**（×1.5，误差 0），结束后回到副屏浮窗；副屏取消路径同样恢复。
- 未做物理拔插/禁用副屏与任务栏方位变更（受环境限制）；`ensureGeometry` 的显示器移除/DPI 变化由 t2 单测/fake 覆盖，规格 D8/D9 记录为“单测覆盖”。

### 4.7 快捷键（Alt+Q / Alt+A）

- 启动日志：`hotkeys: HotkeyRegistration(toggle=false/1409, screenshot=false/1409, unsupported=false)`；VM 读取 `HotkeyService.instance.status.value.name == "bothConflict"` → 本机 `Alt+Q`/`Alt+A` 均被其他程序（全屏游戏/反作弊）占用，**真实按键注册成功路径未测**，符合预期降级。
- 按钮路径：标题栏「浮窗答疑」按钮与浮窗内返回/截图按钮均实测可用；截图按钮默认 hideLoop=true、右键菜单“直接截图”由 W-SHOT-08 覆盖。
- 由于 `HotkeyController._active=false`（两个键都未注册成功），即使向窗口投递合成 `WM_HOTKEY(0x4C51/0x4C52)` 也会按设计忽略；因此**未伪报** Alt+Q/Alt+A 真机按键通过。快捷键映射/去抖/1409 冲突/注销由 5 条 `hotkey_status_test` 覆盖。
- 未能验证真实键盘焦点/记事本场景（M-33/34）与“退出后热键注销”（M-35）的物理按键侧；注册失败降级为按钮可用已实测，注销逻辑由单测覆盖。

---

## 5. 回归矩阵

| 项 | 验证方式 | 结果 |
|---|---|---|
| flutter analyze / test | 正式仓库 | **0 issues / 142 passed（t6 最终）** |
| 900×600 主窗口 | Win32 物理 1125×750 实机截图（暗/亮） | 正常，侧栏自动 compact，无溢出 |
| 360×420 浮窗 | 实机 450×525@1.25 截图（暗/亮、空态/长文/审批/错误/流式） | 布局/按钮/输入正常；**F1 已由 t8 修复（隐藏页按 900×600 布局，逐帧扫描 0 overflow）** |
| 460×600 浮窗 | 默认尺寸实机 | 正常 |
| 亮/暗主题 | 浮窗 + 主窗口 + 设置页实机截图 | 正常、可读 |
| 长文滚动 | 8000+ 字长回答在 360 浮窗；上滚暂停跟随、回到底部 | 正常 |
| Markdown/公式/代码块/表格 | 长回答实机截图；宽内容横向滚动 | 正常（公式/代码/表格渲染正确） |
| 图片/截图附件预览 | 浮窗与主窗口缩略图 + 历史重载；点击大图由 widget 测试覆盖 | 正常（缩略图已打码存档） |
| 流式 on/off | live UI（浮窗）+ API E2E | 正常；请求级快照正确 |
| 停止 | live UI（浮窗）+ API E2E | 正常 |
| 审批 allow/reject | live UI allow + API E2E allow/reject | 正常 |
| 工具/计划步骤 | API E2E E12（plan/step 实时 + 落库） | 正常 |
| 空回复/500/无 Key | API E2E + live UI 500/空回复 | 正常 |
| 历史重载/同会话 | 重启后会话/截图附件/长回答均在；切换形态同会话 | 正常 |
| 六页回归 | 实机切换 今日/笔记/资料/代理/设置/对话 并截图 | 正常（数据库有 E2E 产生的测试数据） |
| 最大化/还原/缩放 | 实机最大化→浮窗→返回；Win32 resize 矩阵 | 主流程正常；**F3 restore-down 缺陷已由 t7 修复**（SetWindowPlacement，t9 复评 pass） |
| 多显示器/DPI | 真实双屏 125%/150%：定位、minSize、截图裁剪 | 正常 |

---

## 6. 发现（Findings）与修复状态

> 以下 F1–F4 为 **t4 阶段**记录；t7/t8 已修复 F1/F2/F3（t9 复评 pass），F4 为 v0.4.0 既有行为、与浮窗无关。

### F1（中，已修复 t8）浮窗 360×420 时隐藏页仍以 360 宽布局，debug 持续 overflow

- **现象**：浮窗处于 360×420 时，`Shell` 的 `IndexedStack` 仍布局其余五页（仅不绘制）。debug 日志出现：
  - `RenderFlex overflowed by 181 / 90 pixels on the right`、`45 / 386 pixels on the bottom`；
  - `Trailing widget consumes the entire tile width (ListTile…)`；
  - 长 Markdown 会话时额外出现 `RenderLine overflowed by 99 / 52 / 64 pixels`（连续多帧）。
- **影响**：用户不可见（只绘制对话页），release 下静默裁剪；但 debug 控制台被错误淹没、每帧多做 5 页窄宽布局，存在性能与可观测性风险；与“稳定 360×420 无溢出”的验收口径存在解释差异（可见页无溢出，隐藏页有）。
- **证据**：`logs/debug-app-run.log`（2026-10-24T18:31–18:33 段，T4ERR 详细记录）；空会话同样触发，排除了“长文内容本身”。
- **建议（已被 t8 采纳）**：floating 时不要把其余五页放进可布局的 `IndexedStack`；用仅含 `ChatScreen` 的稳定槽位（其余页在返回普通窗口时再挂载），或给隐藏页 `SizedBox.shrink()` 占位并保持 index 映射。需保持 ChatScreen 的 GlobalKey/State 不变（现实现已满足）。
- **修复**：t8 在 floating 时对隐藏五页使用 `OverflowBox` 按普通窗口最小尺寸 900×600 布局并由 Stack 裁剪，ChatScreen 保持稳定槽位；新增 `floating_narrow_layout_test.dart` 真实六页 360/460/900 扫描 0 overflow，并做“回退修复→测试失败”的对照。t9 复评 pass。

### F2（低，已修复 t8）normal→floating 过渡帧页头 overflow

- **现象**：点击按钮进入浮窗的 1–2 帧内出现 `A RenderFlex overflowed by 81 pixels on the right`，定位 `app/lib/screens/chat_screen.dart:776`，约束 `w<=150, h=56`，即窗口已缩到 460 逻辑宽而 Shell 仍按 normal 布局（侧栏展开动画中），`content=198`、页头可用 150。
- **影响**：debug 下过渡帧可能闪现黄黑条纹；稳定 460×600/360×420 复测无溢出、无裁切、输入正常。与 captain 提到的 t2 观测一致。
- **证据**：`logs/debug-app-run.log`；`t04-03/08` 稳定态截图无条纹。
- **建议（已被 t8 采纳）**：在 `enterFloating` 设置 bounds 前先把 Shell 置为“过渡中”（隐藏侧栏/页头），或在 `_header` 的固定子项外再包一层 `Flexible/ClipRect`。
- **修复**：t8 在 `FloatingQaScaffold` 增加过渡期最小尺寸守卫（< 900×600 normal / < 360×420 floating 时先按最小尺寸布局再 ClipRect），逐帧测试覆盖 150/460/600 宽等过渡场景；t9 复评 pass。

### F3（中，已修复 t7）最大化 → 浮窗 → 返回（最大化）→ 还原，丢失原普通 bounds

- **复现（真实 UI 按钮，非模拟）**：普通 1440×900@(380,157) → 点最大化（2578×1458, maximized）→ 点“浮窗答疑”（575×750，非最大化）→ 点浮窗返回（恢复最大化）→ 点标题栏“还原”按钮 → 窗口变为 **1125×750 @ (1955,345)**（即 900×600 最小尺寸停在浮窗位置），而不是最大化前的 1440×900@(380,157)。
- **原因分析**：`enterFloating` 在最大化状态下先 `unmaximize()`，随后把窗口设为浮窗 bounds；Windows 将这次浮窗 bounds 记作窗口的 restore-down placement。`exitFloating` 重新 `maximize()` 后，用户再“还原”时 Windows 使用被覆盖的浮窗 placement，并被新的 `minTrack(900×600)` 钳为最小尺寸。
- **影响**：AC-2.2 本身通过（返回后 `isMaximized=true`）；但用户随后点“还原”得到的是错误尺寸/位置（用户可见、可恢复，不崩溃）。属 FR-2“普通窗口快照与恢复”的边缘路径缺陷。
- **证据**：`t04-14-restore-after-max-floating-dark.png` + 探针输出（报告 §4.1）；脚本复现命令见 §8。
- **建议（已被 t7 采纳）**：退出浮窗时若快照为最大化：先 `unmaximize` → `setBounds(snapshot)` → `maximize`；或在重新最大化前用 `SetWindowPlacement` 把正常位置恢复为 `normalSnapshot.physicalBounds`。并补一条 max→floating→max→restore 回归测试。
- **修复**：t7 在 `WindowSnapshot.normalPlacement` 保存 `WINDOWPLACEMENT.rcNormalPosition`，`_restoreMaximized()` 优先 `SetWindowPlacement` 一次写回 placement + 最大化，失败回退并校验；截图覆盖/恢复同样走该逻辑，`applySnapshot` finally 清理 `captureInProgress`。新增 U-WM-13~17；真实窗口验证 max→floating→exit→unmaximize 精确回到原 rect。t9 复评 pass。

### F4（记录，非本迭代回归）设置页对未知 model 不健壮
- E2E 为使用 mock 将 DB `model` 设为 `mock` 后，设置页 `DropdownButtonFormField` 在 debug 抛断言并红屏（`Either zero or 2 or more DropdownMenuItems ... 'mock'`）。v0.4.0 同样存在；正常用户路径的 model 来自固定下拉项，风险低。测试中已改回 `deepseek-flash` 并重拍干净截图。建议后续把“未知模型”降级显示为只读文本或追加自定义项。

---

## 7. 限制与未测项（如实声明）

1. **真实 Alt+Q/Alt+A 按键注册成功路径未测**：`RegisterHotKey` 返回 1409（both conflict，见 §4.7）；降级为按钮可用已实测，快捷键状态机/去抖/注销由单测覆盖。未伪报通过。
2. **真实 OS 鼠标拖动/缩放热区未测**：桌面被用户全屏游戏占用，发送真实鼠标输入会落到游戏窗口；改为 Win32 `SetWindowPos/MoveWindow` 验证几何矩阵与 `WM_GETMINMAXINFO` minTrack，并配合 `W-UI/W-GEO` 单测覆盖拖动栏/缩放热区手势。未验证“真实按住拖动”路径。
3. **截图“重截”与上传失败未 live 重跑**：取消与完成 live 验证；重截≤3、第 4 次上限、上传失败恢复由 `W-SHOT-04/05/06` 覆盖。
4. **图片大图预览的点击缩放/拖动**未 live 点击（缩略图渲染/落库/重载已实测）；由 `image_preview`/W-CHAT-08 测试覆盖。
5. **无 Key 的 UI 表现**未 live（API E2E 覆盖错误文案）；500/空回复已 live。
6. **物理拔插/禁用显示器、任务栏方位（左/上）** 未实测；`chooseDisplay/clamp/ensureGeometry` 由 U-GEO/U-WM 单测覆盖，真实双屏左置负坐标已实测。本机任务栏自动隐藏，**“任务栏可见时的工作区扣除”物理矩阵未逐项复跑**，以单测几何不变量为准。
7. **非聊天页跨形态会 remount**：`ChatScreen` 的 State/SSE 保持（核心保活契约通过），其余五页在浮窗↔普通切换时会重建（返回普通窗口时重新加载），不影响会话与当前回答。
8. **快捷键 1409 降级**：本机 Alt+Q/Alt+A 均被其他程序占用，真机只验证了“冲突状态 + 按钮可用 + tooltip”；注册成功后的真实按键路径由单测覆盖，未伪报真机通过。
9. 截图/全屏覆盖层包含用户桌面内容，仓库中只保留打码后的窗口证据；原始截图 PNG 仅在隔离临时目录，未入库。
10. 证据与验证脚本使用 VM Service 指针注入/合成 Win32 消息，不等于真实键盘/鼠标压测；真实拖动/缩放、真实按键、物理任务栏矩阵为已知边界。

---

## 8. 正式版构建链路（隔离副本）

```powershell
$env:Path = "$env:TEMP\loop-floating-t4\.tools\flutter\bin;$env:Path"
cd "$env:TEMP\loop-floating-t4"
powershell -ExecutionPolicy Bypass -File packaging\build_native.ps1
```

| 项 | 结果 |
|---|---|
| `flutter build windows --release`（隔离副本） | ✅ 成功，87.1s |
| `release\Loop-Desktop\` 组装 | ✅ 存在 `Loop.exe`（`loop.exe` 已重命名）、`version.json`、`使用说明.txt` 与全部依赖 |
| `version.json` | `{"version":"0.4.0"}`（预期值；t4 不提升版本，v0.5.0 由 t6 集成） |
| `Loop.exe` FileVersion | `0.4.0+13`（与 `pubspec.yaml` 一致） |
| 产物大小 / SHA-256 | exe 114,688 B，SHA256 `5C0E2F62…09B16C7`；zip 20,606,996 B，SHA256 `7F5A1145…1BDE8DF` |
| 构建后启动冒烟 | ✅ 隔离 `LOOP_DATA_DIR` 启动：`/api/health` → `{ok:true, version:"0.4.0", has_key:true}`；单一 `Loop.exe`；普通窗口 1800×1125 @(380,157)、minTrack 1125×750、topmost=false；关闭后 8767 释放 |
| 构建日志 | `docs/floating-evidence/logs/build-release.log`；启动截图 `screens/t04-37-release-build-running.png` |


- **t4 阶段**在隔离副本执行 `build_native.ps1` 并保持正式 `release\` 不动（本节证据）；**t6 集成**在确认无用户实例后于正式仓库执行同一脚本，`release\` 三件套按交付预期更新为 v0.5.0（见 §13.3）。
- 版本：t4 阶段隔离副本保持 `0.4.0`（不提升版本）；t6 正式交付提升为 `0.5.0`。

---

## 9. 未污染与清理证据

| 对象 | 验证前（17:53） | 验证后 | 结论 |
|---|---|---|---|
| 用户 Loop 实例 | 无 Loop 进程；8765 空闲 | 无 Loop 进程；8765 空闲 | 未占用/未停止用户实例 |
| `data\loop.db` | 113,467,392 B，mtime 16:32:15，SHA256 `6C259E…A2C7` | 同尺寸/mtime/SHA256 | 未写入 |
| `data\loop.db-wal` | 0 B，SHA256 `E3B0C4…B855` | 同 | 未写入 |
| `release\Loop-Desktop\Loop.exe` | SHA256 `8528C6…324F`（v0.4.0） | t6 更新为 v0.5.0（预期交付，见 §13.3） | 按发布流程替换 |
| `release\Loop-Desktop\version.json` | SHA256 `9CCD6C…F863`（0.4.0） | t6 更新为 `{"version":"0.5.0"}`（预期） | 按发布流程替换 |
| `release\Loop-Desktop-win64.zip` | SHA256 `7D1BF2…09E0`（v0.4.0） | t6 重新构建（预期） | 按发布流程替换 |
| `D:\DSH_Workspace\Loop-Test` | — | 17:40 后无文件修改 | 未触碰 |
| 正式仓库 git 工作树 | HEAD `4850848` + t2/t3 改动 | t6 交付提交：t2/t3/t7/t8 源码与测试、t1 规格、t4 报告与证据、t6 版本/README/release 文档；`.agent-teams/` 不提交 | 符合文件归属 |

- 验证进程/端口清理：t4 阶段 debug 实例、release 冒烟实例与 mock 进程均已停止；t6 最终冒烟实例/构建进程同样在报告前停止，8765/8767/9999 无监听。t4 隔离目录（2.33 GB）已整体删除，所需日志/断言已在 `docs/floating-evidence/` 留存；t6 隔离数据/工具目录同样在交付前删除。
- `loop_shot_*` 临时截图目录：截图流程结束后检查为空。

---

## 10. 证据清单

### 截图（`docs/floating-evidence/screens/`）

> 另将一组精选截图复制到 `docs/screenshots/floating-*.png` 与 `normal-900x600-*.png`，供 README/发布说明引用；内容与下表同源（含打码版本）。

| 文件 | 说明 |
|---|---|
| `t04-03/05` | 浮窗 460×600 / 360×420（暗色空态） |
| `t04-06` | 截图完成→附件 chip（缩略图已打码） |
| `t04-07/08/11` | 主窗口/浮窗同一会话、返回恢复（缩略图已打码） |
| `t04-09` | 浮窗审批卡（fs_write 参数、允许/拒绝） |
| `t04-14` | t4 阶段 F3 还原缺陷现场（t7 已修复，见 §13） |
| `t04-15` | 主窗口 900×600 暗色（缩略图已打码） |
| `t04-16/19/22/23` | 六页代表：今日/代理/设置（暗）/设置（亮） |
| `t04-24/25` | 主窗口 1440×900 / 900×600 亮色长 Markdown |
| `t04-26/27` | 浮窗 460×600 / 360×420 亮色长 Markdown（公式/代码/表格） |
| `t04-28` | 360 长文上滚“回到底部”胶囊 |
| `t04-30` | 360×420 亮色空态 |
| `t04-32` | 浮窗 500 错误 SnackBar（用户消息 + 可读错误） |
| `t04-33/34` | 副屏（150%）浮窗 / 副屏截图后恢复 |
| `t04-35/36` | stream=false「正在思考…」/ 一次性完整正文 |
| `t04-37` | 隔离副本 **release 构建**启动冒烟（健康检查通过后的真实窗口；附件为副屏蓝天壁纸截图，无隐私内容） |
| `keepalive-02..04` | 流式中切换形态：浮窗部分正文→主窗口续流→浮窗完成 |

### 日志/数据（`docs/floating-evidence/logs/`）

| 文件 | 内容 |
|---|---|
| `flutter-analyze.log` / `flutter-test.log` | t4 阶段 analyze 0 issues / 133 tests passed（历史） |
| `flutter-analyze-t6.log` / `flutter-test-t6.log` | **t6 最终** analyze 0 issues / **142 tests passed** |
| `e2e-floating-full.json` / `e2e-full-console.log` | live E2E 27/27 断言、事件序列、时间戳（t6 最终版复跑） |
| `e2e-floating-restart.json` | 重启持久化 4/4（t6 最终版复跑） |
| `e2e-state.json` | E2E 会话 id/工作区（供重启/复现） |
| `debug-app-run.log` | 真实窗口 debug 日志（含 F1/F2 overflow 证据、hotkey 1409、dwm） |
| `keepalive-flow.log` / `keepalive-window-probes.log` | 流式中切换的 VM 状态与窗口 rect 序列 |
| `baseline-artifacts.json` | 验证前正式 release/data/git 基线 |
| `static-checks.txt` | 禁止项静态检查结果 |
| `build-debug.log` / `build-release.log` | 隔离副本 debug/release 构建日志 |

### 可复现工具（`docs/floating-evidence/tools/`）

- `floating_ui.ps1`：DPI-aware Win32 探针/PrintWindow/点击/拖动/移动/最大化/hotkey 注入（ASCII-only，Windows PowerShell 5.1 可运行）。
- `vm/vm_probe.dart`、`vm/vm_ui.dart`：VM Service 状态探针与 Flutter 指针注入驱动（见 `vm/README.md`）。
- `mock_llm_floating.py`：SSE mock（slow/long/empty/error/tool/plan/image，请求日志）。
- `e2e_floating.py`：真实 Backend live E2E（full/restart）。

---

## 11. 复现命令（摘要）

```powershell
# 1) 自动检查 + 全量测试（正式仓库）
cd D:\DSH_Workspace\Prog2_app\app
..\.tools\flutter\bin\flutter.bat analyze --no-pub
..\.tools\flutter\bin\flutter.bat test --no-pub

# 2) 隔离副本 + mock + 真实实例（示例；避免占用用户 8765）
$tmp = "$env:TEMP\loop-floating-t4"
# 复制 app/packaging，junction .tools\flutter，改 server.dart/api.dart 8765→8767
$env:LOOP_DATA_DIR = "$tmp\data"; New-Item -ItemType File "$tmp\data\loop.db" -Force
$env:MOCK_LOG = "$tmp\mock_requests.jsonl"
Start-Process python "D:\DSH_Workspace\Prog2_app\docs\floating-evidence\tools\mock_llm_floating.py"
cd "$tmp\app"; ..\.tools\flutter\bin\flutter.bat run -d windows --debug --no-pub
# 记下输出中的 VM Service ws:// 地址

# 3) live API E2E
cd D:\DSH_Workspace\Prog2_app
python docs\floating-evidence\tools\e2e_floating.py full       # 27/27
python docs\floating-evidence\tools\e2e_floating.py restart    # 4/4

# 4) 真实窗口
$h = "D:\DSH_Workspace\Prog2_app\docs\floating-evidence\tools\floating_ui.ps1"
$pidLoop = (Get-Process loop).Id
powershell -ExecutionPolicy Bypass -File $h -Action probe -ProcessId $pidLoop
powershell -ExecutionPolicy Bypass -File $h -Action shot  -ProcessId $pidLoop -Out "shot.png"
# VM 驱动（需 vm_service；见 tools/vm/README.md）
dart run bin\vm_ui.dart "ws://127.0.0.1:PORT/TOKEN/ws" state
dart run bin\vm_ui.dart "ws://127.0.0.1:PORT/TOKEN/ws" tap-key window-floating-toggle
dart run bin\vm_ui.dart "ws://127.0.0.1:PORT/TOKEN/ws" keepalive-flow
dart run bin\vm_ui.dart "ws://127.0.0.1:PORT/TOKEN/ws" screenshot-flow 1800 "100,100,500,400"

# 5) 正式打包链路（隔离副本，不碰正式 release）
cd "$tmp"; powershell -ExecutionPolicy Bypass -File packaging\build_native.ps1
Get-Content "$tmp\release\Loop-Desktop\version.json"
(Get-FileHash "$tmp\release\Loop-Desktop-win64.zip" -Algorithm SHA256).Hash
```

---

## 12. 与 t4 验收项映射

| 任务验收项 | 结果 | 证据 |
|---|---|---|
| 1) analyze/test 全过；状态机/快捷键/显示器/截图像素/DPI 测试 | ✅ | §2、**142/142（t6 最终）** |
| 2) 真实窗口：按钮进小尺寸置顶浮窗、拖动/缩放、返回恢复 bounds/maximized、Alt+Q/A、无原生标题栏、流式中切换 | ✅（Alt 真实注册与 OS 拖动受限，见 §7.1/7.2；Widget 测试+Win32 几何/热键单测覆盖） | §4 |
| 3) 真实 Backend+SQLite+mock：截图→框选/取消/重截→PNG 上传→img_id 随问题→流式→停止→返回主窗口同会话；stream on/off | ✅（重截 live 未重跑，widget 覆盖） | §3、§4.3–4.5 |
| 4) 亮暗、360/460/900、长文滚动、图片预览、Markdown/公式/代码块、审批、无 Key/失败/空回复 | ✅（无 Key/预览点击由 API/widget 覆盖） | §5 |
| 5) 单显示器无法多屏时用单测覆盖并声明 | ✅ 超出要求：真实双屏 125%/150% 实测 + 单测 | §4.6 |
| 6) 正式版构建链路、报告与截图/日志、不污染 data/release、不做发布 | ✅ | §8、§9、§10 |

---

## 13. t6 集成复核与 v0.5.0 交付（2026-10-24 最终）

### 13.1 版本与文档

- `app/pubspec.yaml`：`0.5.0+14`；`AppVersion.current = '0.5.0'`。
- `README.md`：当前版本 v0.5.0、悬浮窗功能章节、v0.5.0 版本改动、相关文档链接。
- `docs/release-v0.5.0.md`：功能/修复/兼容/验证/限制/构建产物/手动发布说明。
- `docs/floating-qa-spec.md` 追加交付定稿；本报告更新最终口径（142/142、F1/F2/F3 已修复）。

### 13.2 最终自动化与真实闭环

- `flutter analyze --no-pub` → **No issues found**（t6 最终，`logs/flutter-analyze-t6.log`）。
- `flutter test --no-pub` → **142/142 All tests passed**（t6 最终，`logs/flutter-test-t6.log`）。
- t7 真实窗口复核（t9 独立复评 pass）：最大化 → 浮窗 → 返回（最大化）→ 还原精确回到原普通 rect；最大化窗口截图覆盖/恢复后 `maximized`、`rcNormalPosition`、`captureInProgress` 全部正确；异常路径可重试。
- t8 真实六页复核：360×420 floating、460×600、900×600 与逐帧过渡 150/300/460/600/700/1440 宽扫描 0 RenderFlex/RenderLine overflow；`ChatScreen` 保持同一 State。
- **t6 最终真实窗口冒烟（v0.5.0 debug）**：normal 1800×1125@(380,157) → 按钮进入浮窗 575×750@(1955,345)（topmost、minTrack 450×525）→ 缩到 360×420（compact）全程 `run.log` 无新 overflow；最大化 → 浮窗（450×525=上次浮窗尺寸，非最大化）→ 返回最大化 → 点击“还原”精确回到 **1800×1125@(380,157)**（F3 修复生效）；截图 `screens/t06-01-floating-v050.png`、`t06-02-floating-360-v050.png`、`t06-03-final-restore-v050.png`。
- t6 最终版真实隔离后端 live E2E：**27/27** + 重启 **4/4**（脚本与断言同 §3；最终 release 构建启动后复跑，`logs/e2e-floating-full.json`）。
- 用户数据/实例：全程无用户 Loop 进程、8765 空闲；正式 `data\loop.db` 哈希、`release` 三件套哈希前后一致（构建后更新为 v0.5.0 属预期交付动作）；`Loop-Test` 无文件修改。

### 13.3 最终构建产物（正式 `release/`）

| 文件 | 大小 | SHA-256 |
|---|---|---|
| `release/Loop-Desktop/Loop.exe` | 114,688 B | `B626915EAA58E314FFC0BB55F7E6EA241D3165CF60AEBBEF5020AFCD51C036AC` |
| `release/Loop-Desktop/version.json` | 19 B | `1CA74BD4BC478F15FD14BEA176074894A7A169D54ACC3CDE5594969D8FEE8123` |
| `release/Loop-Desktop-win64.zip` | 20,609,950 B | `1F335A94D96F570DFF3E5BE18FEA5D0FE9520105F5E612F46215C54E5176A5BD` |

- `version.json` 必须为 `{"version":"0.5.0"}`；`Loop.exe` FileVersion `0.5.0+14`；zip 为 `Loop-Desktop\*` 压缩包。
- 构建方式：`packaging\build_native.ps1`（正式仓库，确认无用户实例后执行）；构建日志 `logs/build-release-t6.log`；release 启动冒烟截图 `screens/t06-04-release-v050-running.png`。
- release 启动冒烟：`/api/health` → `{ok:true,version:"0.5.0"}`；窗口 1800×1125@(380,157)、minTrack 1125×750；最终版 live E2E 27/27 + 重启 4/4。

### 13.4 提交与发布

- Git：提交 `main`（提交信息 `feat: 桌面答疑悬浮窗 (v0.5.0)`），创建并推送 `v0.5.0` tag；**未自动创建 GitHub Release**。
- 发布 ZIP 需由维护者在 GitHub Releases 手动上传 `release/Loop-Desktop-win64.zip` 并填写 `docs/release-v0.5.0.md` 说明。
- 交付 tag：`v0.5.0`（`main` 上对应交付 commit，hash 见 `git log`/最终任务报告）；未创建 GitHub Release。
