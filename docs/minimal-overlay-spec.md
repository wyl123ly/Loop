# 极简形态与独立回答浮窗（Minimal Bar & Answer Popup）规格与验收契约 — v0.6.0

- 任务：`t1 [spec]` 极简形态、第二窗口可行性与验收契约（attempt 1，attempt_id `aea8cb82-9075-4a96-9f74-aad70a1b1523`）
- 审计对象：正式版 `D:\DSH_Workspace\Prog2_app`，基线 `HEAD ac3f767`（v0.5.0，含文档提交）
- 审计方式：只读阅读 `app/lib`、`app/test`、`app/pubspec.yaml`、`app/windows/**`、`docs/**`；另在 `%TEMP%` 建隔离探针工程实测 `desktop_multi_window`（不进入仓库、不修改正式版、不修改 Loop-Test）
- 目标版本：**v0.6.0**（`app/pubspec.yaml` → `0.6.0+15`）
- 本任务唯一新增文件：本文件
- 下游：`t2 minimal-windows`（桌面/第二窗口/IPC/几何）、`t3 minimal-ui`（极简条/回答窗 UI/入口分流）、`t4 minimal-verifier`（验证与正式版构建）、`t5 minimal-reviewer`（只读评审）、`t6`/captain（版本、发布、推送 tag）
- 硬约束：不修改 `D:\DSH_Workspace\Loop-Test`；不自动创建 GitHub Release；**不得静默降级为同窗内嵌回答面板**

---

## 0. 结论速览（TL;DR）

1. **第二顶层窗口可行，无阻塞。** `desktop_multi_window 0.3.1` 可在本机 Flutter 3.47.7 / Dart 3.13.5 / Windows runner 上构建并运行；已实测创建第二引擎、第二窗口、双向 IPC、跨进程 Win32 改样式/移动/关闭、关闭后重开。证据见 §2.3。
2. **架构**：主窗口（主 FlutterEngine）仍是**唯一数据源**：`ChatScreen`/`AppState`/`LoopApi`/SSE/会话/附件/审批全部只在主窗口；第二引擎只做**只读渲染**。第二窗口**不得**调用后端 8765、不得写 SQLite、不得创建会话。
3. **入口**：同一份 Dart `main(List<String> args)` 分流——主窗口 `args` 为空；第二窗口由插件以 `["multi_window", windowId, payload]` 启动，进入 `AnswerWindowApp`。主窗口入口在分流前**不得**执行 `loadBootTheme()/WindowController.init()/initTray()/startBackend()`。
4. **IPC**：使用 `desktop_multi_window` 的 `WindowMethodChannel`（native-mediated 本地 IPC，无监听端口，等价于 loopback WebSocket）作为首选；协议 v1、带 `seq`、快照+增量、80ms 合批。自定义第二引擎回退方案才使用 `127.0.0.1` 随机端口 WebSocket + token（§2.10）。
5. **窗口控制**：第二窗口的框架/位置/尺寸/置顶/显示/关闭由**主引擎**通过现有 `Win32Display` FFI（追加少量函数）统一执行；第二引擎内**禁止注册/使用 `window_manager`**——实测在子引擎调用 `setAsFrameless`/`setSkipTaskbar` 会让 `window_manager_plugin.dll` 崩溃（`0xC0000005`，见 §2.3）。回答窗拖动由第二引擎 Dart 侧 FFI `GetCursorPos + GetWindowRect + SetWindowPos` 手动实现（`WS_EX_NOACTIVATE` 下仍可收到鼠标事件）。
6. **焦点**：插件 `createWindow` 的创建路径会把前台切到新窗口（探针实测：即使 `hiddenAtLaunch:true`、`IsWindowVisible=false`，`createWindow` 返回后 `GetForegroundWindow` 仍变为第二窗口）。实现必须在 `createWindow` 返回后立刻：设置 `WS_EX_NOACTIVATE` → `SetForegroundWindow(主窗口)` → 恢复主窗口输入焦点；显示/移动/改高一律 `SWP_NOACTIVATE`/`SW_SHOWNOACTIVATE`。t2 必须用真实主窗口+输入法复测；若无法通过焦点闸门，改为打补丁的 fork（§2.4 R1-B）或自定义引擎（§2.10），不允许静默接受抢焦点。
7. **极简形态**：仍是**同一个主窗口**（不新建窗口/引擎），在 `floating` 内新增 `minimal` 子状态：窗口缩成 **`宽度 × 52`** 的紧凑条，只有**输入框（含内嵌发送/停止）+ 截图 + 返回**三要素，无消息区/页头/侧栏/留白；置顶、可拖动；`minSize` 动态为 `360×52`、禁用用户缩放；触发方式=浮窗拖动到最小（360×420，释放后 250ms）或浮窗拖动栏新增的最小化按钮。
8. **回答浮窗**：只有**用户提交非空问题（`text.trim().isNotEmpty`）**后才创建；附件-only 提交沿用 v0.5.0，不弹窗。固定宽度 = 目标显示器工作区宽度的 **35%**（钳制 420–900 逻辑 px，约 30%–40%）；高度按正文自适应，`minH=180`、`maxH=min(工作区高×70%, 760)`，达 maxH 内部滚动；流式 IPC/测高/窗口改高统一 **80ms** 节流（允许 60–100ms）。默认就近放在输入条上方/侧方，**任何时刻与输入条矩形交集为 0**；可拖动、可收起为 36px 标题条、可关闭；关闭/收起/替换都不影响主窗口会话与 SSE。
9. **不遮挡/不抢焦点/不孤儿**：回答窗 `WS_EX_TOPMOST|WS_EX_TOOLWINDOW|WS_EX_NOACTIVATE`（无任务栏、不激活）；主窗口重新激活时用无激活 `SetWindowPos` 把回答窗重新抬到最上层；关闭主窗口/退出应用时**先关回答窗**再关主窗口（实测主窗口先关会留下孤儿进程，见 §2.3）。
10. **回归**：v0.5.0 的截图（含隐藏 Loop/按显示器/重截/上传）、置顶、窗口恢复（normal/maximized/浮窗 minSize）、`stream_output` 开关、亮暗主题、900×600、460×600/360×420、Alt+Q/Alt+A 降级、会话保活全部保持；本版本不改变 v0.5.0 的单窗口形态语义。
11. **验收**：`flutter analyze` 0 issue；全量测试（v0.5.0 的 142 条全部通过 + 新增用例）；真实 Windows 双窗口手工矩阵（焦点/拖动/多显示器/DPI/截图/关闭/重开/无孤儿）；隔离数据 + mock LLM 的流式 E2E；正式构建 v0.6.0；推送代码 + `v0.6.0` tag；不创建 GitHub Release；Loop-Test 未改。
12. **默认产品决策**（可在评审时改，但实现必须按一个明确值）：回答窗默认始终置顶；收起=折叠为标题条（不隐藏到托盘）；关闭=销毁第二窗口、会话留在主窗口；从浮窗/极简条返回主窗口时自动关闭回答窗；主窗口最小化/隐藏到托盘时回答窗一并隐藏、恢复时无激活显示；新问题替换旧回答（复用同一窗口）。

### 0.1 Definition of Done（t5/t6 判定用）

- [ ] 第二顶层窗口在正式版中真实出现、渲染、IPC 双向、关闭/重开稳定；无崩溃、无孤儿进程、无 8765 端口/数据目录副作用。
- [ ] 创建/显示/改高/收起回答窗不抢主窗口输入焦点与 IME 组合；主窗口最小化/托盘/恢复不丢形态。
- [ ] 极简条：`360×52` 稳定无留白/无溢出，只有输入、截图、返回三要素；两个触发入口、返回/展开、置顶、拖动、截图、焦点、`minSize` 恢复全部通过。
- [ ] 回答窗：非空提交才创建；宽度 35%（钳制）且固定；高度自适应/钳制/内部滚动；80ms 节流；输入条与回答窗零交集；收起/关闭/替换语义正确；会话只在主窗口。
- [ ] 多显示器/DPI/任务栏/自动隐藏任务栏/屏幕移除/最大化主窗口/附件-only/空回答/错误/停止/超长回答/流式开关全矩阵有结果。
- [ ] v0.5.0 回归矩阵全绿；`flutter analyze` 0 issue；全量测试通过。
- [ ] 正式版 v0.6.0 构建、隔离冒烟、SHA、推送 main + tag；不创建 GitHub Release；Loop-Test 未改。

### 0.2 阻塞判定（必须遵守）

以下任一条件成立时，t2 必须**停止实现并报告 captain/用户**，不得静默改成同窗内嵌面板：

1. 真实正式版中第二窗口无法稳定出现/渲染/IPC/关闭重开（不是探针工程的问题，而是与 Loop 的 runner/资产/插件组合不兼容）。
2. 焦点闸门无法通过（见 §2.4/§2.8）：创建/显示/改高会持续抢走主窗口输入焦点或打断 IME，且补偿/补丁/自定义引擎方案均无法在 v0.6.0 预算内解决。
3. 原生补丁或自定义引擎需要改动 v0.5.0 已验收的窗口/截图/热键语义，且无法通过回归矩阵。

> 运行时**单次**创建失败允许显式降级：主窗口聊天继续显示回答 + 一次性错误提示（“回答浮窗创建失败，回答显示在主窗口”），并允许用户重试。该错误路径是用户可见的失败处理，不是设计上的“同窗内嵌”。

---

## 1. 基线审计（HEAD ac3f767 / v0.5.0）

### 1.1 文件与职责（现状）

| 文件 | 现状职责 | 与 v0.6.0 的关系 |
|---|---|---|
| `app/lib/main.dart` | `main()` 初始化主题/`WindowController`/托盘/后端；`LoopApp`；`Shell` 的 normal/floating 双形态、`IndexedStack` 六页、`FloatingQaScaffold` | 入口需分流第二引擎；`Shell` 增加 minimal 布局；不改变 normal/floating 现有语义 |
| `app/lib/desktop/window_mode.dart` | `LoopWindowMode{normal,floating}`、常量、`DisplayInfo/CaptureDisplay/WindowSnapshot`、`FloatingModeHost`、`WindowPlatform`、`FloatingWindowPlanner` | 追加 `minimal` 子状态/候选接口与几何 planner；旧成员语义不变 |
| `app/lib/desktop/floating_window.dart` | `FloatingWindowController`：进入/退出浮窗事务、快照/恢复、置顶、显示器校正、截图覆盖/恢复 | 增加 minimal 进入/退出、动态 minSize、快照 `minimal` 字段；回答窗与截图互斥/隐藏 |
| `app/lib/desktop/window_controls_io.dart` | 单例 `WindowController`：frameless、初始尺寸、拖动/缩放/最小化/最大化/关闭、托盘、DPI/屏幕监听、`_DesktopWindowPlatform` | 增加回答窗生命周期清理、minimal 下的 resizable/minSize、回答窗 Win32 操作入口 |
| `app/lib/desktop/window_controls_stub.dart` | Web/非桌面空实现 | 保持 API 对等；回答窗/极简条 stub 为 no-op |
| `app/lib/desktop/win32_display.dart` | Win32 FFI：显示器/工作区/DPI、`GetWindowRect`、`SetWindowPlacement`、`setWindowPos`（含 `SWP_NOACTIVATE`）、`showNoActivate/restoreNoActivate`、`isAlwaysOnTop` | 追加：`SetWindowLongPtr`、`ShowWindow`、`PostMessage(WM_CLOSE)`、`SetWindowTextW`、`SetForegroundWindow`、`GetCursorPos`/`EnumWindows` 等回答窗所需函数 |
| `app/lib/desktop/screenshot_capture_io.dart` | 快照→隐藏→PowerShell 按显示器工作区截图→覆盖层→恢复；`captureHideDelay=280ms` | 截图时隐藏/恢复回答窗；minimal 快照恢复回极简条 |
| `app/lib/desktop/screenshot_types.dart` / `screenshot_overlay.dart` | 截图会话/全屏框选（取消/全屏/重截/完成） | 复用；不改变键位与交互 |
| `app/lib/desktop/floating_bar.dart` | 浮窗拖动栏：截图/置顶/返回/关闭 | 新增“最小化到极简条”按钮与 key |
| `app/lib/widgets/floating_qa_scaffold.dart` | 两种形态共用同一树与槽位，保证 `ChatScreen` State 不重建 | minimal 时只保留 chrome/slot 中的紧凑条，内容区不销毁 |
| `app/lib/widgets/title_bar.dart` | 主窗口标题栏（浮窗答疑/最小化/最大化/关闭） | 不改；normal 行为回归 |
| `app/lib/screens/chat_screen.dart` | 会话/消息/附件/SSE/截图/审批/停止/输入/Markdown | 提交钩子：非空问题→通知回答窗 Host；输入条 key/矩形可上报；minimal 下进入单行输入模式 |
| `app/lib/api.dart` / `backend/server.dart` | `LoopApi.chat()` SSE（127.0.0.1:8765）、上传、会话 | 不改；第二引擎不得使用 |
| `app/windows/runner/**` | 标准 runner；`FlutterWindow` 原生热键 `loop/hotkeys`；唯一主窗口 | 选定路线**不需要改 runner**；仅当走补丁/自定义引擎回退时才改 |
| `app/pubspec.yaml` | `0.5.0+14`；`window_manager 0.5.2`、`screen_retriever 0.2.2`、`ffi 2.2.0`、`web_socket_channel 3.0.3` 等 | 新增 `desktop_multi_window: 0.3.1`（或 path fork）；版本由 t6 提升 |
| `app/test/**` | 142 条测试（v0.5.0） | 全部保持通过；新增 minimal/answer 测试 |

### 1.2 窗口生命周期关键行号（v0.5.0）

- `main.dart:33-49` `main()`：`WidgetsFlutterBinding` → `loadBootTheme` → `WindowController.init` → `initTray` → `startBackend` → `runApp`。
- `main.dart:228-475` `_ShellState`：`_host = WindowController.instance.floating`；`_chatKey = GlobalKey<ChatScreenState>`；`_buildScreens` 保持六页常驻；floating 时隐藏页按 900×600 `OverflowBox` 布局（`main.dart:366-409`）；`FloatingQaScaffold(chrome, sidebar, content)`（`main.dart:453-465`）。
- `floating_window.dart:15` `FloatingWindowController`；`:82-173` `enterFloating`（快照→unmaximize→minSize 360×420→置顶→物理 bounds→show/focus→校验）；`:175-219` `exitFloating`；`:227-234` `setPinned`；`:244-308` `ensureGeometry`；`:313-335` `beginCaptureOverlay`；`:341-374` `applySnapshot`（**不修改 mode**）；`:376-381` `dispose`。
- `window_mode.dart:7` 枚举；`:14/17/20/23/32/35` 常量；`:134` `WindowSnapshot`；`:220` `FloatingModeHost`；`:259` `WindowPlatform`；`:312` `FloatingWindowPlanner`。
- `window_controls_io.dart:25-101` `WindowController.init()`（frameless/minSize 900×600/初始 1440×900 居中/置顶监听/DWM 圆角）；`:121-132` `show({focus})/focusOnce`；`:135-151` `quit()`；`:153-181` DPI/屏幕/拖动/关闭/最大化监听；`:215-234` `minimize/toggleMaximize/close`；`:294-505` `_DesktopWindowPlatform`。
- `floating_qa_scaffold.dart:52-126`：同一 `Column(chrome, Expanded(Row(sidebar, content)))`；`_minSizeGuard` 在过渡帧按当前形态最小尺寸布局并裁剪。
- `title_bar.dart:36-51/120-139`：浮窗按钮、最小化/最大化/关闭；`floating_bar.dart:83-211`：截图/置顶/返回/关闭，拖动区 `onPanStart → startDragging`。

### 1.3 会话与 SSE

- `chat_screen.dart:63-84` `ChatScreenState` 持有消息/附件/输入/滚动/焦点/会话 id/发送/上传/截图/审批/runId；`:124-160` 注册全局信号；`:392-498` `_send()` 内 `await for (api.chat(...))` 处理 `delta/run/plan/approval/cancelled/step/done/error`；`:500-520` 审批与停止；`:1367-1516` 输入区（附件、截图菜单、Enter 发送、发送/停止、hint）。
- `api.dart:26-100` `LoopApi`（baseUrl `127.0.0.1:8765`）；`:275-348` `chat()` SSE 解析与 `imageUrl`；`:351-373` `upload()`。
- `server.dart:25` 端口 8765；`:301-405` `_chat`：请求级 `stream_output` 快照（`:305`）、空文本+空附件 400（`:310-312`）、SSE headers（`:368-373`）、`run` 首事件（`:376`）、后续 `event/data`（`:392-397`）。
- 结论：回答窗只需要**主窗口镜像**；第二引擎若直接开 SSE 会产生第二数据源、重复落库/工具副作用，禁止。

### 1.4 截图与焦点

- `screenshot_capture_io.dart:30-67` `start()`：snapshot → plan（按窗口中心显示器工作区）→ 可选 `windowManager.hide()` + 280ms → PowerShell → 覆盖窗口 → 返回 `ScreenshotSession`；`:72-76` `restore()`；`:151-181` 临时目录/超时/尺寸校验。
- `screenshot_overlay.dart:24-310` 全屏框选；keys：`screenshot-overlay/cancel/select-all/retake/done`。
- 焦点：v0.5.0 规格 §8.4 明确“拖动/缩放/流式/刷新不得 focus”；`WindowController.show()` 已拆 `focusOnce`；`Win32Display.showNoActivate/restoreNoActivate` 已存在，可直接复用。
- 回答窗的焦点策略必须复用同一原则：只有用户动作可聚焦，且回答窗本身永不主动聚焦（`WS_EX_NOACTIVATE`）。

### 1.5 技术栈与构建（实测）

- Flutter `3.47.7` stable（`.tools/flutter`），Dart `3.13.5`，Windows runner 模板；VS2022 BuildTools。
- `pubspec.lock`/`.flutter-plugins-dependencies`：`window_manager 0.5.2`、`screen_retriever 0.2.2`、`ffi 2.2.0`、`tray_manager 0.5.3`、`local_notifier 0.1.6`、`pdfrx 2.9.0`、`sqlite3 3.7.1`、`web_socket_channel 3.0.3` 等；无多窗口插件。
- 构建命令：`powershell -ExecutionPolicy Bypass -File packaging\build_native.ps1`（内部 `flutter build windows --release` → `release/Loop-Desktop` → zip）。
- v0.5.0 质量基线：`flutter analyze` 0 issue；142/142 测试；真实窗口/双屏/mock LLM E2E 通过（见 `docs/release-v0.5.0.md`、`docs/floating-qa-test-report.md`）。
- 本任务只读审计复跑（2026-10-24，HEAD ac3f767）：`flutter analyze --no-pub` → **No issues found**；`flutter test --no-pub` → **142/142 All tests passed**（exit 0）。证明本规格未改变 v0.5.0 基线。

### 1.6 缺口清单（实现必须逐条消除）

| 编号 | 缺口 | 证据 | 影响 |
|---|---|---|---|
| G1 | 无独立顶层回答窗；仅有同窗口浮窗 | `floating_window.dart` 全篇、`main.dart:453-465` | FR-A |
| G2 | 无第二 FlutterEngine/入口分流；`main()` 无 `args` | `main.dart:33` | FR-A |
| G3 | 无跨窗口 IPC/只读镜像协议 | 全仓无 | FR-A |
| G4 | 无 second-window 生命周期（创建/等待/关闭/重开/主窗关闭清理） | 无 | FR-A |
| G5 | 浮窗最小只能到 360×420，无法变成 52px 紧凑条；无最小化按钮 | `window_mode.dart:20`、`floating_bar.dart:171-211` | FR-M |
| G6 | `WindowSnapshot` 无 minimal 标记，minSize 固定 360×420 | `window_mode.dart:134-216` | FR-M |
| G7 | `Shell` 无 minimal 布局；内容区/隐藏页处理按浮窗假设 | `main.dart:366-475` | FR-M |
| G8 | `ChatScreen._send` 无“非空问题→回答窗”钩子；无输入条屏幕矩形上报 | `chat_screen.dart:392-498` | FR-A/M |
| G9 | 截图不隐藏/恢复第二窗口；minimal 快照/恢复未覆盖 | `screenshot_capture_io.dart:30-76` | FR-M/A |
| G10 | 主窗口关闭不清理第二窗口（探针实测会留下孤儿进程） | 探针 §2.3 | FR-A |
| G11 | 无回答窗几何 planner（宽度比、min/maxH、输入条排除区、多 DPI） | 无 | FR-A |
| G12 | 无流式合批/测高/改高 60–100ms 节流 | 无 | FR-A |
| G13 | 无回答窗主题/字体同步（第二引擎不读 DB） | 无 | FR-A |
| G14 | 无回答窗焦点/任务栏/置顶/收起/替换语义 | 无 | FR-A |

---

## 2. 第二顶层窗口可行性与技术路线（核心，先验证）

### 2.1 结论

**可行，无阻塞。** 选定 `desktop_multi_window 0.3.1` + 主引擎 Win32 FFI + 第二引擎只读渲染 + 本地 MethodChannel IPC。理由：

- 获取/兼容：pub.dev 最新 `0.3.1`（2026-08-26 发布），`environment: sdk >=3.5.0 <4.0.0, flutter >=3.0.0`，支持 Windows/macOS/Linux；本机 Flutter 3.47.7/Dart 3.13.5 满足。`flutter build windows --release` 实测成功（§2.3）。
- 能力匹配：每窗口独立 FlutterEngine + `FlutterViewController`，回调/重开/关闭可用；跨引擎 MethodChannel 满足“主窗口唯一数据源、第二窗口只读渲染”。
- 缺陷可控：插件只提供 `arguments/hiddenAtLaunch` 与 `window_show/window_hide`，无 HWND/几何/无激活；因此用主引擎 Win32 FFI 补齐。插件创建时抢焦点、主窗关闭孤儿等风险有明确缓解与验收闸门（§2.4/§2.8）。

### 2.2 `desktop_multi_window 0.3.1` 评估

| 项目 | 结论 |
|---|---|
| 获取 | pub.dev 可获取；`flutter pub add desktop_multi_window:0.3.1`；无额外平台依赖（仅 Flutter SDK） |
| 兼容 | Windows/macOS/Linux；Windows 用 `FlutterViewController` 新引擎；本机构建/运行实测通过 |
| Dart API | `WindowController.create(WindowConfiguration(arguments, hiddenAtLaunch))`、`fromCurrentEngine()`、`getAll()`、`onWindowsChanged`、`WindowMethodChannel(name, mode)` |
| 原生 API | `createWindow/getWindowDefinition/getAllWindows`、`window_show/window_hide`；**无** HWND/位置/尺寸/样式/置顶/无激活 |
| 第二窗口入口 | 同一 Dart `main`，入口参数 `["multi_window", windowId, arguments]`；第二引擎单独 isolate，无共享内存 |
| 插件注册 | 主引擎由 generated registrant 自动注册；第二引擎只自动注册 desktop_multi_window 自身；其他插件需 runner callback（本方案不需要） |
| 引擎生命周期 | 关闭窗口销毁引擎；`onWindowsChanged` 通知；最后窗口关闭时 `PostQuitMessage` |
| 已知缺陷 | ① 创建阶段会把前台切到新窗口（即使 `hiddenAtLaunch:true`，实测 `IsWindowVisible=false` 时前台已变）；② 主窗先关、第二窗仍在时进程不退出（孤儿）；③ 无 HWND/几何 API；④ 第二引擎注册 `window_manager` 后调用部分方法崩溃（见 2.3） |
| 版本风险 | 0.3.1 为当前最新；插件版本锁定，升级需重新跑本规格 §2.3/§7 闸门 |

### 2.3 实测证据（隔离探针，2026-10-24，%TEMP%，不入库）

探针工程：`flutter create --platforms=windows` + `desktop_multi_window 0.3.1`；Flutter 3.47.7/Dart 3.13.5；`flutter build windows --release` 成功（`dmw_probe.exe`）。

| # | 验证项 | 结果 | 证据/说明 |
|---|---|---|---|
| P1 | 构建 | PASS | `√ Built build\windows\x64\runner\Release\dmw_probe.exe` |
| P2 | 创建第二窗口 | PASS | `WindowController.create(...) -> windowId=...`；主进程窗口数 1→2 |
| P3 | 第二入口/隔离 | PASS | 第二引擎 `main` 收到 `['multi_window', id, payload]`；`fromCurrentEngine()` 返回 id/arguments |
| P4 | 双向 IPC | PASS | 第二窗 `answer_ready` → 主窗收到；主窗 `delta` → 第二窗收到并回 `ack`；关闭重开后再次成功 |
| P5 | HWND 发现 | PASS | `EnumWindows`+`GetWindowThreadProcessId`+`GetClassNameW` 找到 `FLUTTER_MULTI_WINDOW_WIN32_WINDOW`；也可由第二窗上报（见路线） |
| P6 | 跨进程样式/位置 | PASS | 主进程 `SetWindowLongPtr` 去掉 `WS_CAPTION` + `SetWindowPos(HWND_TOPMOST, 460×320)` 生效；截图确认无原生标题栏、内容正常渲染 |
| P7 | 跨进程关闭/通知 | PASS | `PostMessage(hwnd, WM_CLOSE)` → 窗口销毁 → `onWindowsChanged` → windows=1；随后重开新 HWND + IPC 成功 |
| P8 | 主窗先关 | **FAIL（风险）** | 主窗 `WM_CLOSE` 后进程仍存活、回答窗仍在（无主窗口孤儿）→ 必须“先关回答窗再关主窗” |
| P9 | 创建焦点 | **FAIL（风险）** | `createWindow` 返回后前台变为第二窗口（即使 `hiddenAtLaunch:true` 且 `IsWindowVisible=false`）→ 必须无激活创建/补偿 |
| P10 | `WS_EX_NOACTIVATE` + 显示 | PASS（初步） | 创建后立即设置 `WS_EX_NOACTIVATE`、`SetForegroundWindow(主窗)`、`SW_SHOWNOACTIVATE` 显示；探针观测 1.2s 内前台保持主窗（探针前台锁有噪声，正式版必须复测输入/IME） |
| P11 | 第二引擎 `window_manager` | **FAIL（崩溃）** | 子引擎 `ensureInitialized/getId/setSize/setAlwaysOnTop` 可用；`setAsFrameless`/`setSkipTaskbar` 触发 `window_manager_plugin.dll` `0xC0000005`（offset `0xa015`），WER 记录 2026-10-24 20:59/21:00 → **禁止**在第二引擎使用 window_manager |
| P12 | 主题/字体/资产 | 未测（风险） | 第二引擎使用同一 `data/` 资产；必须用真实 Loop 资源验证 `NotoSC`/KaTeX/代码块渲染 |
| P13 | 内存/启动耗时 | 未测（预算） | 需在 t2/t4 记录：第二引擎常驻内存、首次可见延迟（目标 ≤400ms）、关闭后内存回落 |
| P14 | 回答窗拖动 | 未测（方案） | 计划用第二引擎 Dart FFI `GetCursorPos/GetWindowRect/SetWindowPos(SWP_NOACTIVATE)` 手动拖动；由 W5 真实鼠标验收；失败→fork/native helper |

> 探针代码与截图只存在于 `%TEMP%`，不提交；t2/t4 需在正式版复跑 P2–P11 并留下证据。

### 2.4 选定路线与回退路线

**R1（选定）：`desktop_multi_window 0.3.1` 原版 + 主引擎 Win32 FFI + 第二引擎 Dart FFI 拖动。**

- **不改 Windows runner**（`app/windows/**` 保持 v0.5.0）；唯一新增依赖 `desktop_multi_window: 0.3.1`（t2 加依赖，t6 随版本提交 `pubspec.lock`）。
- 不注册桌面插件到子引擎、不引入 `window_manager` 子引擎用法。
- 主引擎持有：`AnswerWindowHost`（状态机/IPC host/几何/创建关闭/焦点补偿）。
- 第二引擎：`AnswerWindowApp`（只读 UI、`WindowMethodChannel` client、测高、拖动 FFI、收起/关闭请求）。
- 焦点：创建后立即 `WS_EX_NOACTIVATE` + `SetForegroundWindow(mainHwnd)` + 主窗口输入 `requestFocus` 一次；所有后续展示/移动/改高 `SWP_NOACTIVATE`/`SW_SHOWNOACTIVATE`。
- 拖动：第二引擎在指针手势中 `GetCursorPos` + `GetWindowRect` + `SetWindowPos(SWP_NOSIZE|SWP_NOZORDER|SWP_NOACTIVATE)`；结束上报 `moved{rect}`，主引擎钳制回工作区并记忆位置。`WS_EX_NOACTIVATE` 不影响鼠标事件。
- 关闭：主引擎 `PostMessage(WM_CLOSE)`；收起：主引擎 `ShowWindow(SW_HIDE)` / 无激活显示。

**R1-B（焦点闸门失败时）：最小 fork 补丁。** 将插件 0.3.1 以 path 依赖 vendored 到 `app/third_party/desktop_multi_window/`，只改 Windows 原生：

- `win32_window.cpp`：`CreateWindowEx(WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW, ...)`；`Show()` 改 `SW_SHOWNOACTIVATE`；
- `multi_window_manager.cc`：创建后显示/隐藏统一无激活；可选 `window_getHandle`；
- Dart API 不变；`dependency_overrides` 指向本地路径。
- 成本：+0.5–1 人日；风险：fork 维护、插件升级需重放补丁；收益：彻底消除创建/首帧激活。

**R2（R1/R1-B 均失败时）：自定义第二 `FlutterViewController`/引擎（§2.10）。** 成本 +2–4 人日；仅在 blocker 评审通过后启动。

> **禁止**：把回答内容改成主窗口内嵌面板/第二个聊天页来“实现”需求；禁止第二引擎直接连 8765。

### 2.5 数据所有权与只读约束

- 主窗口唯一写者：`AppState`、`ChatScreenState`、`LoopApi`、SQLite、附件上传、审批/停止、会话切换。
- 第二窗口只读：只接收 `snapshot/delta/status/theme` 并渲染；不得 import `state.dart`/`api.dart`/`backend/**`；不得写文件/DB/网络。
- 第二窗口的用户动作只有：拖动、滚动、收起、展开、关闭（均不改变会话内容）。
- 关闭/收起/替换后，回答完整保留在主窗口聊天中（v0.5.0 行为）；回答窗不是数据权威。

### 2.6 IPC 协议（v1）

**传输**：`WindowMethodChannel`（`desktop_multi_window`，native-mediated 本地 IPC；无监听端口/无 token；可靠有序）。通道名带 windowId 后缀，避免重开时旧 channel 注册冲突：

- 主→第二：`loop/answer.stream.v1.<windowId>`（unidirectional；第二窗注册 handler）
- 第二→主：`loop/answer.control.v1.<windowId>`（unidirectional；主窗注册 handler）

**编码**：`Map<String, Object?>`（`StandardMethodCodec` 支持的类型）；禁止闭包/二进制大对象；Markdown 为 UTF-8 String。

**消息（主→第二）**

| method | 参数 | 语义 |
|---|---|---|
| `hello` | `{protocol:1, windowId, hwnd, widthLogical, minH, maxH, themeMode, brightness, fontFamily}` | 显示前发送；第二窗据此初始化主题/尺寸 |
| `snapshot` | `{seq, conversationId, runId, question, answerMarkdown, status, plan, refs, error, elapsedMs}` | 全量状态；创建/重开/替换/重同步 |
| `delta` | `{seq, text}` | 增量正文；`seq` 单调递增 |
| `status` | `{seq, state, label, approvalRequired, runId}` | `thinking/streaming/tool/waiting_approval/done/stopped/error` |
| `presentation` | `{collapsed: bool}` | 主窗确认收起（36px 标题条）/展开；第二窗切换 UI |
| `theme` | `{themeMode, brightness}` | 主题切换 |
| `resize_ack` | `{seq, heightLogical}` | 主窗已应用高度（可观测） |

**消息（第二→主）**

| method | 参数 | 语义 |
|---|---|---|
| `ready` | `{protocol:1, windowId, dpr, workAreaLogical, contentHeightLogical, buildMode}` | 第二窗 UI 就绪；主窗随后定位/显示 |
| `content_height` | `{seq, heightLogical}` | 测高结果（80ms 节流，±2px 去抖） |
| `moved` | `{physicalRect}` | 拖动结束后的位置（主窗钳制/记忆） |
| `collapse_requested` | `{}` | 用户点收起 |
| `expand_requested` | `{}` | 用户点展开 |
| `close_requested` | `{}` | 用户点关闭 |
| `activated` | `{}` | 可选：用户点击回答窗（无激活策略下一般不会触发） |
| `render_error` | `{code, message}` | 第二窗内部错误（显示占位 + 主窗记录） |

**规则**

- `seq`：主窗每次 `snapshot/delta/status` 自增；第二窗记录 `lastSeq`；收到 `snapshot` 重置；`delta.seq != lastSeq+1` → 请求重同步（`resync_requested`，主窗回 `snapshot`；该消息允许在 control 通道追加）。
- 合批：主窗累积 SSE delta，**80ms** 窗口合并发送（允许 60–100ms）；首条 delta/状态立即发送（≤100ms）。
- 注册顺序：主窗必须在 `createWindow` 前/同时注册 control handler；第二窗必须先注册 stream handler，再发 `ready`；`ready` 若遇 `NO_HANDLER`/`CHANNEL_NOT_FOUND` 以 100ms 退避重试（≤1s），仍失败则通过 `render_error`/日志显式失败。
- 安全：只接受当前 `windowId` 的 `ready/...`；未知 method 返回 `MissingPluginException` 并由主窗记录；不打印正文到日志。
- 超时：`ready` ≤4000ms；超时→关闭窗口、标记失败、显式提示；允许用户重试一次。
- 重开：旧窗口销毁且 `onWindowsChanged` 确认后再创建新窗口；新通道名（新 windowId），无旧 handler 冲突。
- 兼容：`protocol` 不匹配时主窗拒绝并显示错误；v1 内可加字段（向前兼容）。
- 第二窗入口：`WindowController.fromCurrentEngine()` 若因插件注册时序失败，100ms 退避重试（≤2s）；仍失败则写一次日志并退出第二引擎（不得静默空白窗口）。

### 2.7 回答窗生命周期

```text
absent --(非空提交)--> creating --(ready+定位+显示)--> visible
visible --(收起)--> collapsed --(展开/新提交)--> visible
visible/collapsed --(关闭/外部销毁/主窗退出)--> closing --(窗口销毁+onWindowsChanged)--> absent
creating --(超时/失败/主窗退出)--> closing/absent
```

| 事件 | 行为 |
|---|---|
| 应用启动 | **不创建**回答窗；不预热第二引擎（除非评审批准；即使预热也不得显示/抢焦点） |
| 首次非空提交 | 创建（hidden，`arguments` 内带首帧 `themeMode/brightness`）→ 等待 ready → 主引擎设 frameless/toolwindow/noactivate/尺寸/位置 → 无激活显示 → 发送 hello/snapshot |
| 后续非空提交（未关闭） | 复用窗口；发送新 `snapshot`（替换语义）；高度重算；若 collapsed 则先展开 |
| 空文本/附件-only | 不创建/不更新回答窗；v0.5.0 主聊天行为 |
| 用户关闭 | 主窗 `PostMessage WM_CLOSE`；状态 closing→absent；回答留主聊天；下一个非空提交重建 |
| 用户收起 | 主窗把窗口高度改为 36（保持可见、`SWP_NOACTIVATE`）；发 `presentation{collapsed:true}`；第二窗切标题条 UI；主聊天/SSE 继续；展开/新提交→恢复原高度/位置 + 全量 snapshot |
| 主窗口最小化/隐藏到托盘 | 回答窗隐藏（记录 visible/collapsed；挂接 `WindowListener.onWindowMinimize`/托盘 hide）；主窗恢复（`onWindowRestore`/托盘 show）时无激活显示（原状态） |
| 主窗口关闭（托盘激活时） | v0.5.0 `onWindowClose` 在托盘激活时是**隐藏**而不是退出：回答窗随主窗隐藏（不销毁）；托盘“显示回路”时无激活恢复 |
| 主窗口关闭/退出（无托盘/托盘“退出”） | **先**关回答窗（≤1s），确认 `onWindowsChanged` 后再关闭/退出主窗；超时则 `PostMessage WM_CLOSE` + 500ms 后继续，保证无孤儿 |
| 主窗口在浮窗/极简条 | 回答窗可显示；返回 normal 时关闭回答窗（§0-12） |
| 显示器移除/DPI 变化 | 主窗钳制回答窗到最近工作区；无法容纳则收起并提示；不抢焦点 |
| 第二窗崩溃/外部 Kill | `onWindowsChanged` 检测 absent；主聊天不受影响；下一次提交重建；记录一次日志（不含正文） |
| 主题变化 | 发送 `theme`；第二窗重建 palette；不改变尺寸（字体行高一致） |

### 2.8 焦点契约（回答窗 + 极简条）

- **创建/显示/改高/收起/展开/重定位/流式更新**：回答窗不得获得键盘焦点，不得改变主窗（或极简条）输入焦点与 IME 组合；只允许一次性的创建补偿（`SetForegroundWindow(main)` + 输入 `requestFocus`，≤100ms，且不可见闪烁）。
- 用户点击回答窗：`WS_EX_NOACTIVATE` 使其不激活；滚动/点击收起/关闭仍工作；不把焦点从主输入抢走。
- 用户点击收起/关闭：动作完成后，若主输入此前有焦点，恢复焦点一次；否则不主动聚焦。
- 主窗口获得焦点/激活：主窗用无激活 `SetWindowPos` 把回答窗重新抬到最上层（`HWND_TOPMOST`，`SWP_NOMOVE|SWP_NOSIZE|SWP_NOACTIVATE`），不改变焦点。挂接点：`WindowListener.onWindowFocus`（主窗）、`onWindowMoved/onWindowResized`（auto 模式重定位），全部 80ms 去抖、无 focus。
- 极简条：进入/退出、截图恢复各允许 1 次聚焦（用户动作）；拖动/缩放/流式/定时器 0 次。
- 测试：`focusCount`、`GetForegroundWindow`、`FocusManager.instance.primaryFocus` 断言；真实输入法中文组合 + 流式时切换形态手工验证。

### 2.9 主窗口关闭/退出的清理顺序（必须）

```text
用户 close / 托盘“退出” / 无托盘 Alt+F4
  → AnswerWindowHost.shutdown():
       if state != absent:
          state=closing; send 'bye'（可选）
          Win32 PostMessage(answerHwnd, WM_CLOSE)
          等待 onWindowsChanged / getAllWindows 移除（≤1s）
          若仍存在：再次 WM_CLOSE，500ms；记录错误但继续
  → WindowController 原有 close()/quit()（注销热键、托盘、windowManager.close）
  → 进程退出；断言无 dmw/第二引擎残留（任务管理器/窗口枚举）

托盘“关闭到托盘”路径（onWindowClose 且 trayActive）：
  → 回答窗 ShowWindow(SW_HIDE)（保留引擎/状态），主窗 windowManager.hide()
  → 托盘“显示回路”：主窗无激活显示；回答窗按原状态无激活显示
```

> 探针 P8 已证明“主窗先关”会孤儿；实现顺序不可颠倒。**回答窗存在期间主窗必须 `windowManager.setPreventClose(true)`**（v0.5.0 只在托盘激活时设置），并在 `onWindowClose` 里执行上述 shutdown；否则原生 `WM_CLOSE` 会先销毁主窗，Dart 来不及清理。回答窗关闭后恢复 v0.5.0 的 `preventClose` 语义（托盘激活时保持 true）。

### 2.10 回退：自定义第二 FlutterViewController/引擎（仅 R1/R1-B 失败时）

- **做法**：`app/windows/runner/` 新增 `answer_window.{h,cpp}`（约 350–600 行 C++）：
  - `Win32Window` 子类（frameless、`WS_EX_NOACTIVATE|WS_EX_TOOLWINDOW|WS_EX_TOPMOST`、无任务栏）；
  - `flutter::DartProject(L"data")` + `set_dart_entrypoint_arguments({"answer"})`；`FlutterViewController` 新引擎；
  - 自带 `loop/answer-window` MethodChannel：`create/show/hide/place/close`、内容/状态消息，或改为本地 loopback WebSocket（`127.0.0.1` 随机端口 + 一次性 token + 仅本进程 parent 校验）；
  - `WM_NCHITTEST` 返回 `HTCAPTION`（顶部 36px）实现原生拖动；`WM_CLOSE` 通知主窗；DPI/圆角/阴影自绘。
- **成本**：+2–4 人日；**风险**：引擎生命周期/线程、AOT 入口、插件注册、资源路径、关闭竞态、与 v0.5.0 runner 热键/无边框窗口回归冲突。
- **收益**：完全控制焦点/拖动/任务栏/尺寸，不依赖第三方插件缺陷。
- **前置**：必须先向 captain 提交 blocker 说明与用户决策，不得私自启动。

---

## 3. 极简形态（Minimal Bar）规格

### 3.1 定义与状态

- 极简形态是 `floating` 的**子状态**：`mode=floating`，`minimal=true`；不是第三种窗口/引擎。
- 进入后窗口尺寸 = `width × 52`（逻辑 px），内容只有三要素；`ChatScreen` State/SSE/附件/会话**不销毁**（与 v0.5.0 浮窗保活一致）。
- 退出后回到进入前的浮窗 bounds（记忆的 expanded bounds）或最近一次浮窗尺寸；主窗口 normal 不受影响。

### 3.2 常量

| 名称 | 值（逻辑 px/时长） | 说明 |
|---|---|---|
| `minimalHeight` | `52` | 紧凑条总高；含 1px 边框，内容填满，无上下留白 |
| `minimalMinWidth` | `360` | 与浮窗最小宽一致 |
| `minimalMaxWidth` | `560` | 紧凑条最大宽；超出则钳制 |
| `minimalRadius` | `12` | 圆角；最大化不适用 |
| `minimalEnterTolerance` | `2` | 判定“拖到最小”的 bounds 容差 |
| `minimalEnterDelay` | `250ms` | resize 结束后去抖，避免拖动中误触发 |
| `minimalButtonSize` | `32×32`（紧凑 30） | 截图/返回热区 |
| `minimalInputHeight` | `38` | 输入容器（含内嵌发送/停止） |
| `floatingMinSize` | `360×420` | 保持 v0.5.0；极简动态 minSize 见 §3.4 |

### 3.3 触发与退出

| 入口 | 条件 | 行为 |
|---|---|---|
| 浮窗拖动栏「最小化」按钮（新增 `floating-minimize`） | `mode=floating && !minimal && !transitioning && !captureInProgress` | 事务式进入 minimal（§3.4） |
| 拖到最小 | 用户缩放浮窗，resize 结束（`onWindowResized`）后 250ms 去抖；`physicalRect` 宽/高均 ≈ `360×420`（±2px） | 事务式进入 minimal |
| 双击拖动区/Logo | minimal 状态下 | 退出 minimal，恢复 expanded bounds |
| 返回按钮 | minimal 状态下 | 退出浮窗 → normal（v0.5.0「返回主窗口」语义），并关闭回答窗（§0-12） |
| `Alt+Q` | minimal 可见 | 退出浮窗 → normal（同返回按钮）；不切到“浮窗展开” |
| `Alt+A` | minimal 可见且空闲 | 截图（hideLoop=true）；结束后回 minimal |
| 主窗口最小化/托盘隐藏 | minimal 状态 | 保持 minimal；显示时恢复 bar |

**禁止**：拖动过程中实时切换；过渡中再次触发；截图覆盖/发送中触发。所有入口幂等。

### 3.4 进入/退出事务

进入（`enterMinimal`）：

1. 校验 `mode=floating && !minimal && !transitioning && !captureInProgress`。
2. `expandedSnapshot = snapshot()`（bounds/physical/dpr/alwaysOnTop/minSize/pinned）。
3. `transitioning=true`；`setResizable(false)`；`setMinimumSize(Size(360,52))`；`_minSize=(360,52)`。
4. 计算 bar 逻辑矩形：宽度 = `clamp(expanded.bounds.width, 360, 560)`；高度 52；**保持右下角锚定**（`right/bottom` 不变，clamp 到工作区）；物理 = 逻辑×dpr。
5. `setAlwaysOnTop(true)`（minimal 恒置顶）；`setBoundsPhysical`（失败回退 logical）；`show()`；用户动作 focus 恰 1 次；请求输入焦点 1 次（post-frame）。
6. 读回校验（容差 4px 物理）；失败重试一次；仍失败→回滚 expanded snapshot + 提示一次。
7. `minimal=true`；`transitioning=false`；`notifyListeners`；`lastExpandedSnapshot` 保留。

退出（`exitMinimal`）：

1. 非 minimal → true；过渡中/截图 → false。
2. `transitioning=true`；恢复 `setResizable(true)`；`setMinimumSize(expanded.minSize)`；`setAlwaysOnTop(expanded.alwaysOnTop)`；恢复 expanded bounds（物理优先，容差 4px；失败重试一次）。
3. `show()`；用户动作 focus 1 次；`minimal=false`；`transitioning=false`；输入焦点按“进入前是否有焦点”恢复一次。
4. 失败→默认 460×600 浮窗 + 提示，不得停在半 bar/半 fullscreen。

### 3.5 布局（三要素，无留白）

```text
┌──────────────────────────────────────────────────────────┐ 52
│ [Loop Logo/拖动 24] [输入框 ................................ ▲] [截图 32] [返回 32] │
└──────────────────────────────────────────────────────────┘
   ↑ 1px border；容器圆角 12；内部无上下留白；无消息区/页头/侧栏/滚动条
```

| 元素 | 规格 |
|---|---|
| 拖动区/Logo | 宽 24；`Key('minimal-drag-handle')`；`onPanStart → WindowController.startDragging()`；双击退出 minimal；tooltip“拖动；双击展开浮窗”；不显示“回路”文字以节省宽度 |
| 输入框 | 占据剩余宽度；单行 `TextField`，`Key('minimal-input')`；Enter 发送；Shift+Enter 无操作（不换行）；粘贴中的换行归一为空格；`hint`：“问点什么…” |
| 发送/停止 | 输入容器右侧内嵌 `IconButton`（`Key('minimal-send-stop')`，30×30）：`_sending` 时停止，否则发送；属于输入要素，不单列第四要素 |
| 附件 badge | 有附件时在输入框左侧显示 20px 缩略图/`×N` 计数（`Key('minimal-attachment-badge')`），属于输入要素；点击不打开（展开后可管理） |
| 截图 | `Key('minimal-screenshot')`，32×32；左键=隐藏 Loop 后截图（`requestScreenshot(hideLoop:true)`）；禁用条件 `_sending||_uploading||_screenshotting||captureInProgress`；tooltip 含 Alt+A |
| 返回 | `Key('minimal-back')`，32×32；点击=退出浮窗到主窗口；tooltip“返回主窗口 (Alt+Q)” |
| 流式状态 | 输入框边框/左侧 2px 进度条表示 streaming/thinking；不新增文字/按钮 |
| 置顶 | 恒 `alwaysOnTop=true`；无单独按钮；退出 minimal 恢复进入前 `pinned` |
| 焦点 | 进入后输入框获焦一次；流式/拖动/截图恢复不抢焦；点击返回后主窗口输入获焦一次 |
| 无留白 | 窗口高度=52；`Scaffold`/容器 `padding` 为 0；只有 1px border/圆角；不得出现空消息区/底部空白；DPI 150% 下物理 78px 仍填满 |

**Widget keys（冻结）**：`minimal-bar`、`minimal-drag-handle`、`minimal-input`、`minimal-send-stop`、`minimal-screenshot`、`minimal-back`、`minimal-attachment-badge`、`floating-minimize`。

### 3.6 `minSize`/缩放/窗口行为

- minimal：`setResizable(false)`；`setMinimumSize(Size(360,52))`；不用 `setMaximumSize`（避免 `WM_GETMINMAXINFO` 阻止截图覆盖的 `SetWindowPos`）。
- 普通浮窗：`360×420`；normal：`900×600`；截图覆盖期间允许程序化全工作区，恢复后回快照 minSize/resizable。
- 拖动/缩放监听：minimal 下忽略用户 resize（OS 已禁用）；主窗口 `onWindowResized` 仍可用于 DPI 校正。
- 显示器/DPI 变化：`ensureGeometry` 把 bar clamp 到最近工作区；宽度 clamp 360–560；不 focus、不改 minimal。
- 任务栏：主窗口仍显示任务栏按钮；自动隐藏任务栏时使用工作区。
- 最大化：minimal 不可最大化；`toggleMaximize` no-op。
- 关闭：minimal 下关闭主窗口=正常退出/tray 逻辑；先关回答窗（§2.9）。

### 3.7 截图与极简条

- `ScreenshotCapture.start` 的快照必须含 `minimal=true` 与 `minSize=360×52`；隐藏 Loop 前同时隐藏回答窗；`beginCaptureOverlay` 暂时 `setResizable(true)`/清除用户缩放限制并把主窗铺满工作区；覆盖层完成后 `applySnapshot` 恢复 bar bounds/minSize/置顶/resizable/minimal 标记。
- 取消/重截/失败：均恢复 bar（不是展开浮窗）；不上传；焦点仅在原输入有焦点时恢复一次。
- 完成后附件：输入容器显示 badge；可继续输入/发送；不自动展开浮窗。

### 3.8 极简条边界

| 场景 | 期望 |
|---|---|
| 360 宽 + 150% DPI | 无 RenderFlex/RenderLine 溢出；按钮 32、输入 ≥200 宽 |
| 输入超长文本 | 单行水平滚动/省略；窗口不增高 |
| 中文 IME 组合中 Enter | 不误发送（沿用现有 `Focus.onKeyEvent` + IME 手测） |
| 附件很多 | badge 显示 `×N`；不增高 |
| 流式中截图 | 禁用并提示“等这条回答结束再截图” |
| 无网络/无 Key | 输入可编辑；发送失败提示一次；bar 不崩 |
| 托盘隐藏/恢复 | 保持 minimal；无激活显示恢复 |
| 显示器移除 | clamp 到主屏工作区；保持 52 高；可交互 |
| 快速重复最小化/展开 | 幂等；最终状态一致；无中间态卡死 |

---

## 4. 回答浮窗（Answer Popup）规格

### 4.1 创建触发（严格）

- **仅**当主窗口/极简条提交的消息满足 `text.trim().isNotEmpty` 时创建/更新回答窗。
- 附件-only（`text.trim().isEmpty && attachments.isNotEmpty`）**不创建/不更新**；回答照 v0.5.0 显示在主窗口聊天。
- 空提交（无文本无附件）不发送、不创建。
- 用户按下发送即创建（显示“思考中”），不等首个 delta；若请求立即失败（无 Key/400），显示错误状态但窗口保留（下次提交替换）。
- 发送前已存在回答窗：复用、替换内容；不新建第二个窗口。
- 发送时回答窗已关闭：先创建，再随主窗数据更新。
- 第二窗口不可用/创建失败：**显式**提示 + 主聊天继续显示回答（§0.2），不得静默改成同窗面板。

### 4.2 宽度（固定舒适宽）

```text
workWidth = 输入条所在显示器工作区宽度（逻辑 px，Win32 rcWork ÷ dpr）
width = clamp(workWidth × 0.35, 420, 900)   // 35%，约 30%–40%
```

- 创建时计算；同一会话内固定（用户不可拖宽/不可缩放边框）；显示器/DPI 变化不重算宽度（避免跳动）；关闭重开按新显示器重算。
- 示例：1280→448；1440→504；1920→672；2560→896；1024→420（钳制，记录限制）；3440→900（钳制）。
- 测试断言：1280/1920/2560 下宽度比例 ∈ [30%, 40%]；极端宽度按钳制。

### 4.3 高度（自适应 + 钳制 + 内部滚动）

```text
minH = 180
maxH = min(workHeight × 0.70, 760)
desired = header(36) + question(≤1 行, 18) + statusChip(22) + bodyContent + padding(16)
height = clamp(desired, minH, maxH)
```

- 测高：第二窗用 `GlobalKey` + `RenderBox.size.height` 测量**正文内容子树**（放在 `SingleChildScrollView` 内、宽度固定、高度无约束），`desired = 内容高 + header/question/status/padding`；**不要**用 `maxScrollExtent + viewportDimension`（内容短时无法回缩）。**80ms** 节流、±2px 去抖；主窗收到后钳制并 `SetWindowPos` 无激活改高。
- 高度增长时：auto 模式保持**底边**（= 输入条上边 - gap）不动，向上生长；user-moved 模式保持**顶边**不动，向下生长；到工作区/输入条排除区边界则停止增长，内容内部滚动。
- 达 `maxH`：header 固定、正文 `SingleChildScrollView` 内部滚动；滚动条 6px；流式时若用户在底部则跟随，用户上滚则暂停跟随并显示“回到底部”胶囊（`answer-scroll-bottom`）。
- 内容缩短（错误/停止/替换）：高度缩短到 minH/desired，不闪烁；动画禁止（直接 SetWindowPos）。
- 空回答/无内容：显示“（无内容）”占位，高度 minH；错误显示错误 banner；停止显示“已停止”并保留已生成正文。
- 超长单行/宽表格/公式/代码块：正文内部横向滚动（代码块）或换行；窗口宽度不变；不得撑破窗口。

### 4.4 节流与性能

- 主窗 SSE delta → 累积；**80ms**（允许 60–100ms）合批发送 `delta`；首条立即；`status/plan/approval` 立即（≤100ms）。
- 第二窗渲染后测高；测高/上报/主窗改高同一 80ms 节流；高度变化 <2px 不调用 Win32。
- 拖动中暂停自动改高（`drag_started`/`drag_ended`），结束后应用最新高度一次。
- 目标：1000 条 delta 下第二窗帧耗时 ≤16ms（常规文本）；主窗 UI 不因第二窗阻塞；窗口改高 ≤12.5 次/秒。
- 不使用动画/逐帧 `IntrinsicHeight`；`RepaintBoundary` 可选。

### 4.5 默认位置（就近 + 不遮挡输入条）

- 输入条矩形 `inputBarPhysical` 由主窗 `GlobalKey` + `RenderBox.localToGlobal` + 窗口物理原点/dpr 计算；无法获取时退化为窗口底部 120 逻辑 px 带。
- 候选顺序（逻辑坐标，gap=8）：
  1. **输入条上方**：`right` 对齐输入条右边，`bottom = inputBar.top - gap`；水平 clamp 到工作区；垂直可用高度 ≥ minH 才采用；
  2. **输入条下方**（输入条接近工作区顶部时）：`top = inputBar.bottom + gap`；
  3. **主窗/极简条右侧**：`left = window.right + gap`，`top` 对齐输入条顶；
  4. **左侧**：`right = window.left - gap`；
  5. 兜底：放在工作区内不覆盖输入条的最大可用矩形（高度可小于 minH 时仍保证不遮挡，内部滚动）。
- 放置后断言：`answerRect ∩ inputBarRect = ∅`（可再加 8px 安全间距）；回答窗完全位于目标工作区（允许 1px 舍入）。
- 回答窗与主窗口其他区域重叠是允许的（例如悬浮在聊天区上方），但**绝不覆盖输入条**。
- 主窗移动/缩放/形态切换/极简条拖动时：auto 模式重新计算并跟随（无激活、80ms 节流）；user-moved 模式仅在会覆盖输入条时轻推（最小位移）或压缩高度。
- 主窗最大化：仍用“输入条上方”候选（回答窗覆盖聊天区，不覆盖输入条）；主窗激活时无激活抬升回答窗到最上层。

### 4.6 外观/交互

- 无原生标题栏/边框；圆角 14（DWM 可用时圆角，失败可方形）；1px `windowBorder`；`WS_EX_TOOLWINDOW|WS_EX_TOPMOST|WS_EX_NOACTIVATE`；不出现在任务栏/Alt+Tab。
- Header 36px：左侧“回答”标签 + 状态点/文字；右侧**收起**（`answer-collapse`）与**关闭**（`answer-close`）各 28×28；中间空白为拖动区（`answer-drag`）。
- 收起：窗口高→36（`answerCollapsedHeight`），只留 header；位置 clamp 到工作区；点击 header 或展开按钮恢复原高度/位置；收起状态不改变内容/滚动位置。
- 关闭：发 `close_requested`，主窗销毁窗口；主聊天保留回答；不改变会话。
- 双击 header：恢复 auto 放置（重新按输入条定位）。
- 只读：正文/问题/计划/引用/状态；无输入框、无发送/停止/审批按钮；审批提示“需要审批，请回主窗口处理”。
- 文本选择：可选（`SelectableText` 或 Markdown 渲染保持只读）；不要求复制按钮。
- 主题：亮/暗与主窗一致；发送 `palette` 所需 mode/brightness；字体 `NotoSC` 与主窗一致；Markdown/KaTeX/代码块复用 `MarkdownText`（只依赖 `theme.dart`/palette，可在第二 isolate 使用）。
- 空态/错误/停止/审批：见 §4.3；错误消息截断 ≤200 字符。

### 4.7 替换语义

- 新非空提交（上一条已 done/stopped/error）：同一窗口，`snapshot` 替换问题+正文+状态；滚动到顶部；高度重置为 minH→增长；位置/宽度保持不变；若 collapsed 先展开；若 user-moved 保留位置（除非覆盖输入条）。
- 上一条仍在流式：v0.5.0 `_send` 已阻止发送；不实现并发替换。
- 替换不创建新会话/不清空主聊天历史；主窗口仍可看到全部问答。

### 4.8 回答窗与主窗口会话

- 回答窗不持有 conversationId 的写权限；只显示当前 run 的快照。
- 用户切换会话/新建对话/删除会话时：若回答窗可见，关闭它（主窗已切换，旧回答窗内容失效）；主聊天照常。
- 用户在主窗口继续提问：回答窗替换为新问答（若可见）。
- 关闭回答窗不取消 SSE、不删除消息、不停止工具；回答继续在主聊天更新。
- 停止/审批只在主窗口输入区/审批卡操作；回答窗只显示状态。

---

## 5. 窗口 / 几何 / DPI / 多显示器契约

### 5.1 `WindowSnapshot`（v0.6.0 加法扩展）

```dart
class WindowSnapshot {
  // v0.5.0 字段保持不变：mode/bounds/physicalBounds/dpr/maximized/
  // alwaysOnTop/minSize/pinned/displayId/normalPlacement
  final bool minimal; // 新增：floating 的极简子状态；normal/maximized 时为 false
}
```

- `copyWith` 增加 `minimal`；`toString` 包含 `minimal`。
- `applySnapshot` 恢复 `minimal`（截图后回极简条）；`enter/exitFloating` 不改变该字段语义。
- `FloatingModeHost` 加法扩展（旧成员语义不变）：
  - `bool get minimal;`
  - `Future<bool> enterMinimal({bool focus = true});`
  - `Future<bool> exitMinimal({bool focus = true});`
  - `Future<bool> toggleMinimal({bool focus = true});`
  - `WindowSnapshot? get lastExpandedSnapshot;`
- 所有实现（io/stub/fake）同步；测试 fake 增加 `minimal` 状态与计数。

### 5.2 回答窗几何 planner（纯 Dart，可单测）

```dart
class AnswerWindowPlanner {
  static double widthLogical(Rect workLogical) =>
      (workLogical.width * 0.35).clamp(420.0, 900.0).toDouble();

  static double maxHeightLogical(Rect workLogical) =>
      math.min(workLogical.height * 0.70, 760.0);

  static Rect place({
    required Rect workPhysical,
    required Rect inputBarPhysical,
    required Rect mainWindowPhysical,
    required double dpr,
    required double widthLogical,
    required double heightLogical,
    required bool userMoved,
    Rect? userRect,
    double gap = 8,
  });
}
```

规则：

- 所有输入/输出物理像素；内部用 `dpr` 换算逻辑；DPR 归一化失败→1.0（沿用 `FloatingWindowPlanner.normalizedDpr`）。
- 输出必须 `isInsideWorkArea`（±2px）且与 `inputBarPhysical` 无交集（含 gap）。
- `userMoved`：尊重用户位置，仅在覆盖输入条/越界时最小位移/压缩；`auto`：按 §4.5 候选。
- 高度变化时：auto 底边固定；user 顶边固定；均重新 clamp。
- 多显示器：`workPhysical` 取输入条中心所在显示器（`chooseDisplay` 复用）；回答窗拖到另一屏后，其 `moved` 位置以新屏工作区为准；宽度逻辑值**优先不变**；若新工作区放不下（`width > workWidth - 2×gap`），一次性钳制到可用宽（≥420），之后本会话固定，并记录一次限制。
- DPI：物理 = 逻辑 × **目标显示器 dpr**；混屏时由主窗查询 `DisplayInfo.scaleFactor`/`GetDpiForWindow`；第二窗 `ready.dpr` 用于校正一次。
- 屏幕移除：`ensureGeometry` 将回答窗 clamp 到最近工作区；无法容纳→收起并提示；不 focus。
- 任务栏：工作区已排除任务栏；自动隐藏任务栏按全屏工作区；回答窗不覆盖任务栏区域。

### 5.3 不变量

- **I-1** 主窗口唯一数据源；第二窗口只读；第二引擎无网络/DB。
- **I-2** 回答窗最多 1 个；状态机串行；`creating/closing` 中不接受新创建。
- **I-3** `answerRect ∩ inputBarRect = ∅`（所有状态、所有高度、拖动结束、主窗移动/缩放/形态切换）。
- **I-4** 回答窗完全位于目标显示器工作区（容差 2px）。
- **I-5** 回答窗宽度固定（会话内不因内容/高度变化；跨屏放不下时按 §5.2 一次性钳制）；高度 ∈ [minH, maxH]。
- **I-6** 回答窗创建/显示/改高/收起/重定位不改变主窗输入焦点与 IME；仅创建补偿例外（≤100ms）。
- **I-7** minimal 时窗口高=52、minSize=360×52、resizable=false、无内容区/留白。
- **I-8** 所有形态 minSize 与状态匹配：normal 900×600；floating 360×420；minimal 360×52。
- **I-9** 截图不改变 mode/minimal；快照含回答窗隐藏前状态；恢复后一致。
- **I-10** 主窗关闭/退出必须先销毁回答窗；无孤儿进程。
- **I-11** 回答窗关闭/收起/替换不取消 SSE、不删除会话消息。
- **I-12** 所有跨进程操作失败都有显式提示/降级，不静默。

---

## 6. 边界与失败矩阵

| 场景 | 期望行为 | 验收方式 |
|---|---|---|
| 空文本提交 | 不发送、不建窗 | widget test |
| 附件-only 提交 | 不建回答窗；主聊天回答（v0.5.0） | widget test + E2E |
| 非空 + 附件 | 建窗；问题区显示文本；正文流式 | E2E |
| 首次提交时第二窗创建超时 | 显式错误 snack + 主聊天显示回答 + 可重试；无第二窗残留 | 注入 fake transport 超时 |
| 第二窗创建后崩溃/被外部关闭 | 状态 absent；主聊天不受影响；下次提交重建；日志一次 | 手工 kill / 注入 |
| 无 Key/网络错误/500 | 回答窗错误 banner；主聊天 snack（v0.5.0）；高度收缩；不崩 | mock LLM |
| 流式关闭（stream_output=false） | 正文一次性到达；回答窗仍可用；状态 thinking→done | 设置切换 E2E |
| 停止 | 回答窗“已停止”+保留正文；主聊天一致；不自动关窗 | E2E |
| 审批 | 回答窗“需要审批，回主窗口处理”；主窗审批卡可操作；不抢焦点 | E2E |
| 空回答 | 回答窗占位“（无内容）”；minH；不崩 | mock |
| 超长回答 | maxH + 内部滚动 + 跟随/回到底部；宽度不变 | widget + E2E |
| 超宽表格/公式 | 内部横向滚动/换行；不撑破窗口 | widget |
| 快速连续提问（上一条完成后） | 同一窗口替换；无第二窗；高度重置；位置保持 | widget/E2E |
| 提问后立即关闭回答窗 | 关闭成功；SSE 继续；主聊天更新；无错误 | E2E |
| 收起后新提问 | 自动展开并替换 | widget |
| 回答窗拖动到主窗输入条上 | 拖动结束被钳制/轻推，交集 0 | manual + planner test |
| 主窗最大化 + 回答窗 | 输入条上方；不覆盖输入条；主窗激活时回答窗抬升 | manual |
| 主窗最小化/托盘隐藏 | 回答窗隐藏；恢复时无激活显示，状态不变 | manual |
| 主窗关闭/退出 | 先回答窗后主窗；进程退出；无残留窗口 | manual + 任务管理器 |
| 双屏不同 DPI | 宽度按所在屏；位置/高度物理换算正确；跨屏拖动不跳宽 | manual（125%/150%） |
| 拔掉/禁用显示器 | 回答窗/极简条 clamp 回可用工作区；失败提示；不崩 | manual/单测 planner |
| 任务栏在左/上/自动隐藏 | 工作区计算正确；不覆盖任务栏 | manual |
| 主题切换（亮/暗） | 回答窗即时跟随；无尺寸跳变 | manual |
| 字体缩放/高 DPI | 52/36 高度仍容纳控件；无溢出 | manual 125/150 |
| 中文 IME 组合中 | 主输入不丢焦点；Enter 不误发；回答窗只读 | manual |
| 热键被占用 | 按钮仍可用；回答窗/极简条入口不受影响 | manual |
| 关闭回答窗后重启应用 | 无残留；不自动恢复回答窗；会话历史在主窗 | manual |

---

## 7. 回归矩阵（v0.5.0 已验收功能）

| # | v0.5.0 行为 | v0.6.0 要求 | 验证 |
|---|---|---|---|
| R1 | 主窗口 900×600 最小、无边框圆角、标题栏拖动/最小化/最大化/关闭 | 不变 | 现有 `floating_*`/`widget_test` + manual |
| R2 | 浮窗 460×600、最小 360×420、自绘栏（截图/置顶/返回/关闭）、可拖动/缩放/置顶 | 不变；新增最小化按钮不挤压 360 宽布局 | `floating_window_test`/`floating_layout_test` + manual 360×420 |
| R3 | 浮窗进入/退出精确恢复 `bounds/maximized/alwaysOnTop/minSize/normalPlacement`；失败回滚 | 不变；minimal 进出不影响 normal 快照 | `floating_window_test` + manual 最大化往返 |
| R4 | 浮窗复用同一 `ChatScreenState`/会话/SSE；切换不断流 | 不变；minimal 也不销毁 State；回答窗额外只读显示 | `floating_chat_test`（identical/chatCalls==1）+ E2E |
| R5 | 截图：按窗口中心显示器工作区、隐藏 Loop/直接、框选/全屏/取消/重截/完成、`img_*` 上传、恢复浮窗 | 不变；截图期间额外隐藏/恢复回答窗；minimal 快照恢复回 bar | `screenshot_flow_test`/`screenshot_capture_test` + 双屏 manual |
| R6 | `Alt+Q` 切浮窗/主窗、`Alt+A` 截图、冲突 1409 降级、按钮可用 | 不变；minimal 下 Alt+Q 回主窗；回答窗不注册全局热键 | `hotkey_status_test` + manual |
| R7 | `stream_output` 开/关：逐字/整段；工具/计划/审批/停止/token/cost | 不变；回答窗两种模式都能显示 | `streaming_*_test` + mock E2E |
| R8 | 亮/暗主题、暖色玻璃、Markdown/KaTeX/代码块/表格 | 不变；回答窗复用同一 palette/字体/Markdown | `markdown_math_test` + manual 亮暗 |
| R9 | 侧栏收起/自动 compact、六页状态保留 | 不变；minimal 不渲染侧栏但 State 保留 | `floating_shell_test` + manual |
| R10 | 托盘显示/关闭到托盘/开机自启/自动更新/后端 8765/SQLite/上传 | 不变；回答窗不触碰 | 现有 `update_test`/manual + E2E |
| R11 | 窗口恢复、最大化还原位置、最大化截图恢复 | 不变；回答窗隐藏/恢复不改变主窗 placement | v0.5.0 测试 + manual |
| R12 | 900×600 / 460×600 / 360×420 无 RenderFlex/RenderLine 溢出 | 新增 360×52 bar 无溢出；回答窗 420–900 宽无溢出 | `floating_narrow_layout_test` + 新 widget 测试 |

---

## 8. 测试与验收

### 8.1 分层

1. **纯单元（无需窗口）**：minimal/answer 几何 planner、状态机、协议编解码/seq/节流、快照 copyWith。
2. **Widget**：MinimalBar 三要素/无留白/溢出/焦点；AnswerWindow UI 高度/滚动/收起/错误/主题；Shell minimal 保活；ChatScreen 提交钩子。
3. **Fake 集成**：`FakeWindowPlatform` + `FakeAnswerWindowPlatform` + `FakeAnswerTransport` 验证创建/关闭/重开/主窗退出顺序/失败矩阵，不启动真窗口。
4. **真实 Windows（t4）**：双窗口、焦点、拖动、截图、双屏/DPI、任务栏、关闭/重开/无孤儿、性能。
5. **隔离 E2E**：`LOOP_DATA_DIR` 临时目录 + mock LLM（`docs/streaming-evidence/tools/mock_llm.py`）验证流式/停止/审批/空回答/超长/流式开关。

### 8.2 新增/修改测试文件（建议）

| 文件 | 覆盖 |
|---|---|
| `app/test/minimal_window_test.dart` | minimal 常量/状态机/触发/幂等/minSize/resizable/退出恢复/失败回滚 |
| `app/test/minimal_bar_test.dart` | 三要素 keys、52 高无留白、360/420 宽无溢出、附件 badge、发送/停止、焦点、IME Enter |
| `app/test/answer_geometry_test.dart` | 宽度 35% 钳制、min/maxH、放置候选/输入条排除区/多 DPI/多屏/clamp |
| `app/test/answer_protocol_test.dart` | 消息编解码、seq 连续性/resync、80ms 合批、超时/未知消息 |
| `app/test/answer_window_test.dart` | 只读渲染、测高、maxH 滚动、收起、错误/停止/空内容、主题 |
| `app/test/answer_lifecycle_test.dart` | 非空/附件-only/替换/关闭/重开/主窗退出顺序/崩溃恢复 |
| `app/test/chat_answer_trigger_test.dart` | `_send` 钩子只在非空文本触发；chatCalls 不变 |
| `app/test/screenshot_flow_test.dart`（扩展） | 截图隐藏/恢复回答窗；minimal 快照往返 |
| `app/test/support/fake_answer_platform.dart` / `fake_answer_transport.dart` | 创建/显示/隐藏/关闭/几何/失败注入 |
| `app/test/support/fake_window_platform.dart`（扩展） | minimal 状态、resizable/minSize 断言 |

> 现有 142 条必须全部继续通过（可改 fake 接口实现，但不得删除/弱化断言）。

### 8.3 验收闸门（t2/t4 必须提供证据）

- **W1** 真实正式版第二窗口出现且内容正确（截图 + 窗口枚举）。
- **W2** 创建/显示/改高时 `GetForegroundWindow` 保持主窗；主输入连续输入 100 字符不丢字（含 IME 中文）。
- **W3** 关闭/重开 3 次无崩溃/无残留；任务管理器无第二进程。
- **W4** 主窗/回答窗位置尺寸符合 §4.2/§4.3；输入条交集 0（多组窗口位置/尺寸）。
- **W5** 拖动回答窗跟手、结束位置合法；主窗不卡顿（拖拽期间 SSE 继续，主窗帧不冻结）。
- **W6** 主窗关闭/退出无孤儿（窗口枚举 + 进程退出 + 8765 释放）。
- **W7** 360×52 极简条在 100%/125%/150% 下无溢出；三要素可达。
- **W8** 截图（浮窗/极简/主窗）隐藏并恢复回答窗；取消/重截/完成状态正确。
- **W9** 双屏 125%/150%：宽度/位置/高度/截图正确；屏幕移除 clamp。
- **W10** 性能：回答窗首次可见 ≤400ms；80ms 合批；1000 delta 无卡顿/无内存持续增长（可记录任务管理器）。

### 8.4 命令（Windows PowerShell，仓库根目录）

```powershell
# 0) 前置
Get-Process Loop -ErrorAction SilentlyContinue
Get-NetTCPConnection -LocalPort 8765 -ErrorAction SilentlyContinue

# 1) 依赖 + 静态检查 + 全量测试（app）
cd D:\DSH_Workspace\Prog2_app\app
..\.tools\flutter\bin\flutter.bat pub get
..\.tools\flutter\bin\flutter.bat analyze
..\.tools\flutter\bin\flutter.bat test

# 2) 新增用例（示例）
..\.tools\flutter\bin\flutter.bat test test\minimal_window_test.dart test\minimal_bar_test.dart test\answer_geometry_test.dart test\answer_protocol_test.dart test\answer_window_test.dart test\answer_lifecycle_test.dart test\chat_answer_trigger_test.dart

# 3) 构建正式版（t6；产物 release/Loop-Desktop + zip）
cd D:\DSH_Workspace\Prog2_app
powershell -ExecutionPolicy Bypass -File packaging\build_native.ps1
Get-Content release\Loop-Desktop\version.json
(Get-Item release\Loop-Desktop\Loop.exe).VersionInfo.FileVersion
(Get-FileHash release\Loop-Desktop-win64.zip -Algorithm SHA256).Hash

# 4) 隔离冒烟（先建空 loop.db 再启动，避免污染用户数据）
$env:LOOP_DATA_DIR = Join-Path $env:TEMP 'loop-v060-minimal\data'
New-Item -ItemType Directory -Force (Split-Path $env:LOOP_DATA_DIR) | Out-Null
New-Item -ItemType File -Force (Join-Path $env:LOOP_DATA_DIR 'loop.db') | Out-Null
Start-Process -FilePath 'D:\DSH_Workspace\Prog2_app\release\Loop-Desktop\Loop.exe'
$base='http://127.0.0.1:8765'
for ($i=0; $i -lt 60; $i++) { try { Invoke-RestMethod "$base/api/health" -TimeoutSec 2; break } catch { Start-Sleep -Milliseconds 500 } }

# 5) mock LLM（新窗口）
python D:\DSH_Workspace\Prog2_app\docs\streaming-evidence\tools\mock_llm.py
Invoke-RestMethod -Method Put -Uri "$base/api/settings" -ContentType 'application/json' `
  -Body '{"api_key":"test-key","base_url":"http://127.0.0.1:9999","model":"mock"}'
Invoke-RestMethod -Method Put -Uri "$base/api/settings" -ContentType 'application/json' -Body '{"stream_output":true}'

# 6) 双窗口验证（窗口枚举，确认 class/hwnd/rect/visible）
#    可用 PowerShell Add-Type EnumWindows + GetClassNameW；期望 1 个 FLUTTER_RUNNER_WIN32_WINDOW + 0..1 个 FLUTTER_MULTI_WINDOW_WIN32_WINDOW

# 7) 推送（t6；不创建 GitHub Release）
git status --short
git add <t2/t3/t4/t6 允许文件>
git commit -m "feat: 极简形态与独立回答浮窗 (v0.6.0)"
git tag -a v0.6.0 -m "Loop v0.6.0 极简形态与独立回答浮窗"
git push origin main
git push origin v0.6.0

# 8) Loop-Test 未修改
Get-ChildItem D:\DSH_Workspace\Loop-Test -Recurse -File -ErrorAction SilentlyContinue |
  Where-Object { $_.LastWriteTime -gt (Get-Date '2026-10-24T21:00:00') } |
  Select-Object FullName, LastWriteTime
```

### 8.5 证据产物

| 产物 | 归属 | 内容 |
|---|---|---|
| `docs/minimal-overlay-test-report.md` | t4 | 自动/手工/E2E 逐项 PASS/FAIL、命令输出、限制 |
| `docs/minimal-evidence/**` | t4 | 双窗口截图、hwnd/rect、焦点日志、双屏/DPI、性能、清理记录 |
| `docs/screenshots/minimal-*.png` | t4 | 极简条 360×52、回答窗宽/高/收起/亮暗、双屏 |
| `docs/release-v0.6.0.md` | t6 | 功能/兼容/验证/产物 SHA/升级说明 |
| `docs/minimal-evidence/v060-build-evidence.md` | t6 | 构建日志、版本/SHA、隔离冒烟、推送/tag 证据、Release 未创建 |

---

## 9. 文件归属与并行协作

### 9.1 所有权

| 成员 | 允许修改/新增 | 只读依赖 | 禁止 |
|---|---|---|---|
| **t1 minimal-architect** | `docs/minimal-overlay-spec.md`（本文件） | 全仓只读 | 任何实现/测试/团队状态/Loop-Test |
| **t2 minimal-windows** | `app/lib/desktop/window_mode.dart`、`floating_window.dart`、`window_controls_io.dart`、`window_controls_stub.dart`、`win32_display.dart`、`screenshot_capture_io.dart`、`screenshot_types.dart`、新增 `app/lib/desktop/minimal_window.dart`、`app/lib/desktop/answer_host/{answer_window_host,answer_window_platform,answer_protocol,answer_transport_io,answer_transport_stub,win32_answer}.dart`、`app/pubspec.yaml`（依赖）、`app/pubspec.lock`、`app/test/{minimal_window,answer_geometry,answer_protocol,answer_lifecycle}_test.dart`、`app/test/support/fake_answer_platform.dart`、`fake_answer_transport.dart`、`fake_window_platform.dart` | `main.dart`、`chat_screen.dart`、`theme.dart`、`api.dart` | `ChatScreen` 业务/UI、`main.dart` 入口、回答窗 UI、release、Loop-Test |
| **t3 minimal-ui** | `app/lib/main.dart`（入口分流/Shell minimal）、`app/lib/widgets/floating_bar.dart`、`app/lib/widgets/floating_qa_scaffold.dart`、新增 `app/lib/widgets/minimal_bar.dart`、`app/lib/answer_ui/{answer_window_app,answer_client,answer_widgets}.dart`、`app/lib/screens/chat_screen.dart`（提交钩子/输入条矩形/单行模式）、`app/lib/screens/screenshot_overlay.dart`（如需 minimal 适配）、`app/test/{minimal_bar,answer_window,chat_answer_trigger,floating_shell,screenshot_flow}_test.dart` | t2 接口、`theme.dart`、`models.dart`、`api.dart` | `desktop/**`、runner、pubspec、server、Loop-Test |
| **t4 minimal-verifier** | `docs/minimal-overlay-test-report.md`、`docs/minimal-evidence/**`、`docs/screenshots/minimal-*.png` | 全部 | 生产代码/测试源码/release/用户 data |
| **t5 minimal-reviewer** | 无文件（只读评审，结论写任务输出） | 全部 | 代码/测试/文档/Loop-Test |
| **t6 / captain** | `app/pubspec.yaml`（版本）、`app/lib/update/app_version.dart`、`README.md`、`docs/release-v0.6.0.md`、`docs/minimal-evidence/v060-build-evidence.md`、`release/**`（构建产物，gitignore）；提交但不改内容：t1/t4 文档 | 其余只读 | 不创建 GitHub Release；不改他人文档内容 |

### 9.2 冻结接口与变更流程

- 冻结：`WindowSnapshot` 新字段、`FloatingModeHost` 加法成员、`AnswerWindowHost`/`AnswerTransport`/IPC 消息名与字段、`MinimalBar`/回答窗 Widget keys、常量表（§3.2/§4.2/§4.3）。
- t2 先落接口骨架 + fake（建议先于 UI），t3 才能编译；任何签名变更先 `agent_teams_send_message` 通知 t3 + captain，并在提交信息中说明。
- 同一文件同一时间只允许一个 owner；发现冲突先沟通。
- 禁止重复定义 `ScreenshotSession`/`WindowSnapshot`/`FloatingModeHost`；回答窗不得 import `state.dart`/`api.dart`/`backend/**`。

### 9.3 禁止修改清单

- `D:\DSH_Workspace\Loop-Test`（任何文件）。
- `.agent-teams/`（只通过工具）。
- 用户数据 `data/`（验证只用 `LOOP_DATA_DIR` 临时目录）。
- `app/lib/backend/**`、`app/lib/state.dart`、`app/lib/models.dart`、`app/lib/api.dart`（本版本不需要改；回答窗只读镜像）。
- **子引擎不得注册/使用 `window_manager`**（崩溃风险，§2.3 P11）。
- 不提交 `release/`、`data/`、`app/build/`、`.tools/`、`.agent-teams/`、`%TEMP%` 探针。
- 不创建 GitHub Release；不用 `git add -A`。

### 9.4 合并顺序

```text
t1 spec（本文件）
  └─ t2 接口骨架 + 第二窗口/IPC/几何 + fake
       ├─ t3 入口分流 + 极简条 + 回答窗 UI + 提交钩子
       └─ t2 测试/生命周期补齐
            └─ t4 验证（真实双窗口/双屏/焦点/E2E）
                 └─ t5 评审
                      └─ t6 版本/构建/推送 tag
```

---

## 10. 发布契约（v0.6.0）

### 10.1 版本与文案

- `app/pubspec.yaml`：`version: 0.6.0+15`。
- `app/lib/update/app_version.dart`：`current = '0.6.0'`。
- `README.md`：新增极简形态/回答浮窗说明、限制、快捷键、升级说明；版本历史加 v0.6.0。
- `docs/release-v0.6.0.md`：功能、兼容、验证、产物 SHA、升级、已知限制。
- `version.json` 由 `packaging/build_native.ps1` 从 pubspec 生成 `{"version":"0.6.0"}`。

### 10.2 构建与产物

- `packaging/build_native.ps1`（不修改逻辑）→ `release/Loop-Desktop/`（`Loop.exe`、DLL、`data/`、`version.json`）与 `release/Loop-Desktop-win64.zip`。
- 验收：`Loop.exe` FileVersion `0.6.0+15`；`version.json`=0.6.0；zip SHA-256 记录到 release 文档/构建证据；隔离 `LOOP_DATA_DIR` 启动后 `/api/health` 返回 `{ok:true,version:"0.6.0"}`；关闭后 8765 释放。
- **新增依赖**：`desktop_multi_window: 0.3.1`（或 t2 评审通过的 path fork）；`pubspec.lock` 一并提交。
- 不修改 Loop-Test；不自动创建 GitHub Release。

### 10.3 提交与 tag

```powershell
git add <允许文件>
git commit -m "feat: 极简形态与独立回答浮窗 (v0.6.0)"
git tag -a v0.6.0 -m "Loop v0.6.0 极简形态与独立回答浮窗"
git push origin main
git push origin v0.6.0
```

- 提交前 `flutter analyze` 0 issue、全量测试通过、真实双窗口冒烟通过。
- 不创建 GitHub Release（由用户手动上传 zip）。

### 10.4 回滚

- 若第二窗口在正式版出现不可修复问题：回滚到 v0.5.0 tag；或由 captain 决定是否**显式**关闭回答窗功能（仅隐藏入口）并保留极简形态。**不允许**静默保留半成品或同窗内嵌。
- 数据无破坏性变更；升级/回滚保留 `data/loop.db`、`data/files`。

### 10.5 非目标（Out of Scope）

- 不改 `D:\DSH_Workspace\Loop-Test`；不把 Loop-Test 的插件/能力带入正式版。
- 不改后端 `backend/**`、SQLite schema、HTTP API、上传/解析、Agent 工具/审批语义。
- 不改 v0.5.0 的浮窗默认尺寸/最小尺寸/快照恢复/截图显示器选择/热键语义（除新增 minimal 子状态与最小化入口）。
- 不做回答窗内输入/多轮/停止/审批按钮；不把回答窗做成第二个聊天页；不做多回答窗/多会话并行。
- 不做跨平台（macOS/Linux）多窗口；非 Windows 走 no-op/stub（主窗口功能不变）；不做 Web 端第二窗口。
- 不做窗口位置/形态的磁盘持久化（重启回 normal，回答窗不自动恢复）。
- 不做回答窗宽度手动调整、不做内容选择/复制/导出/OCR。
- 不做设置页新增开关（默认行为固定；如需开关另立任务）。
- 不引入 WebSocket server/端口（R1 MethodChannel 已满足；仅 §2.10 自定义引擎回退才考虑 loopback WS）。
- 不自动创建 GitHub Release；不自动上传 Release 资产。
- 不重构 v0.5.0 `FloatingWindowController` 的既有事务/截图/热键实现（只做加法与必要的最小改动）。

---

## 11. 风险与开放问题

### 11.1 风险

| 风险 | 等级 | 缓解 |
|---|---|---|
| 插件创建/首帧抢主窗焦点 | 高 | `WS_EX_NOACTIVATE` + 补偿 + `SW_SHOWNOACTIVATE`；真实 IME 复测；失败→fork/自定义引擎 |
| 子引擎 `window_manager` 崩溃 | 高 | 禁止使用；框架/几何/拖动全部 FFI；§2.3 P11 证据 |
| 主窗先关导致孤儿 | 高 | §2.9 强顺序 + 超时兜底 + 进程/窗口枚举验收 |
| 拖动跟手/卡顿（手动 SetWindowPos） | 中 | 60–120Hz 节流、无动画、拖动中暂停改高；失败→native helper/fork |
| 双引擎内存/启动开销 | 中 | 懒创建、关闭即销毁、无预热；记录内存与 ≤400ms 目标 |
| 混合 DPI/双屏坐标偏差 | 中 | 物理像素权威 + Win32Display + 目标屏 dpr + builder 单测 + 真机双屏 |
| 截图与第二窗口叠加/遮挡 | 中 | 截图前后隐藏/恢复回答窗；覆盖层仍只在主窗 |
| 流式高频 IPC/改高抖动 | 中 | 80ms 合批 + ±2px 去抖 + 拖动暂停 + 无动画 |
| 第二引擎资源/字体差异 | 中 | 同一 `data/` + `NotoSC` + `MarkdownText` 复用；真实资源复测 |
| 插件升级/Flutter 升级破坏 | 中 | 版本锁定 + §2.3 闸门 + 可选 fork 固定 |
| 回答窗始终置顶干扰其他应用 | 低 | 可收起/关闭；仅在有回答时显示；不抢焦点 |
| 5 分钟/长时间流式高度增长 | 低 | maxH 滚动 + 节流 + 无动画 |

### 11.2 开放问题（默认值已给出，评审可改）

1. 回答窗默认始终置顶（同意/改为仅主窗置顶时置顶）？
2. 收起=折叠为 36px 标题条（同意/改为隐藏+主窗入口）？
3. 从极简/浮窗返回主窗口时自动关闭回答窗（同意/保留）？
4. 极简条高度 52 / 输入单行 / Shift+Enter 无操作（同意/改多行）？
5. 回答窗宽度 35%（30%–40%）与 maxH 70%/760（同意/调整）？
6. 首次创建回答窗的一次性焦点补偿是否可接受（若不可接受必须上 fork）？

---

## 12. 附录

### A. 关键常量汇总

| 常量 | 值 |
|---|---|
| `normalMinSize` | 900×600 |
| `floatingDefaultSize` | 460×600 |
| `floatingMinSize` | 360×420 |
| `minimalHeight` | 52 |
| `minimalMinWidth` / `minimalMaxWidth` | 360 / 560 |
| `minimalEnterTolerance` / `minimalEnterDelay` | 2px / 250ms |
| `floatingMargin` / `floatingRadius` | 24 / 16 |
| `answerWidthRatio` / `answerWidthMin` / `answerWidthMax` | 0.35 / 420 / 900 |
| `answerMinHeight` / `answerMaxHeightRatio` / `answerMaxHeightCap` | 180 / 0.70 / 760 |
| `answerHeaderHeight` / `answerCollapsedHeight` | 36 / 36 |
| `answerGap` / `answerRadius` | 8 / 14 |
| `answerCreateTimeout` | 4000ms |
| `answerStreamThrottle` | 80ms（允许 60–100） |
| `answerHeightEpsilon` | 2px |
| `captureHideDelay` / `transitionDebounce` | 280ms / 300ms |

### B. Widget Keys（冻结）

`floating-minimize`、`minimal-bar`、`minimal-drag-handle`、`minimal-input`、`minimal-send-stop`、`minimal-screenshot`、`minimal-back`、`minimal-attachment-badge`、`answer-window`、`answer-header`、`answer-drag`、`answer-body`、`answer-scroll`、`answer-scroll-bottom`、`answer-collapse`、`answer-close`、`answer-status`、`answer-error`。

### C. 第二窗口实现骨架（建议，t2 可调整内部实现）

```dart
// 主引擎入口（main.dart）
Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  if (args.length >= 2 && args[0] == 'multi_window') {
    // 第二引擎：不初始化 DB/后端/托盘/WindowController
    final controller = await WindowController.fromCurrentEngine();
    final payload = AnswerLaunchPayload.tryParse(controller.arguments);
    LoopTheme.palette = AnswerTheme.resolve(payload?.brightness);
    runApp(AnswerWindowApp(controller: controller, payload: payload));
    return;
  }
  // ... v0.5.0 原逻辑 ...
}

// 主引擎 AnswerWindowHost（t2）
final host = AnswerWindowHost(platform: Win32AnswerWindowPlatform(...));
if (text.trim().isNotEmpty) {
  await host.showOrReplace(AnswerSubmission(
    conversationId: convId,
    question: text,
    runId: runId,
    inputBarPhysical: inputBarRect,
    themeMode: appState.themeMode,
  ));
}
// SSE 事件中：host.push(event) → 80ms 合批 → delta/status/snapshot
// 结束/停止/错误：host.finish(status)
// 主窗 close/quit：await host.shutdown();

// 第二窗 AnswerWindowApp（t3）
final channel = WindowMethodChannel('loop/answer.control.v1.$windowId',
    mode: ChannelMode.unidirectional);
channel.setMethodCallHandler(...); // ready/content_height/moved/...
final stream = WindowMethodChannel('loop/answer.stream.v1.$windowId',
    mode: ChannelMode.unidirectional);
await stream.setMethodCallHandler((call) async { ... });
```

### D. 主引擎 Win32 追加函数（`win32_display.dart` 建议）

```dart
static bool setNoActivate(int hwnd);          // GWL_EXSTYLE |= WS_EX_NOACTIVATE
static bool setToolWindow(int hwnd);          // |= WS_EX_TOOLWINDOW
static bool setFrameless(int hwnd);           // 去 WS_CAPTION/WS_THICKFRAME（按设计保留/去除）
static bool showNoActivateWindow(int hwnd);   // ShowWindow(SW_SHOWNOACTIVATE)
static bool hideWindow(int hwnd);             // ShowWindow(SW_HIDE)
static bool postClose(int hwnd);              // PostMessage(WM_CLOSE)
static bool setForeground(int hwnd);          // SetForegroundWindow
static bool setTitle(int hwnd, String title); // SetWindowTextW
static int? findWindowByClass(int processId, String className); // EnumWindows
```

第二引擎回答窗需要的 FFI（`app/lib/desktop/answer_host/win32_answer.dart`，t2 提供）：

```dart
int? getCursorPos();                 // 物理像素
Rect? getWindowRect(int hwnd);       // 物理像素
bool moveWindowNoActivate(int hwnd, int x, int y); // SetWindowPos(NOSIZE|NOZORDER|NOACTIVATE)
int? getAncestorRoot(int hwnd);      // 可选：WindowFromPoint + GetAncestor(GA_ROOT) 自检
```

- 拖动算法：`onPanStart` 记录 `cursor0`、`rect0`；`onPanUpdate` 取当前 cursor，`new = rect0.topLeft + (cursor - cursor0)`，`moveWindowNoActivate`；`onPanEnd` 发 `moved{rect}`。不做阻塞式 `WM_NCLBUTTONDOWN` move loop。
- 只读约束：第二引擎不得导入 `api.dart/state.dart/backend/**`；只允许 `flutter`、`desktop_multi_window`、`theme.dart`、`markdown_text.dart`、`models.dart` 等纯 UI/模型。

### E. 术语

- **主窗口**：v0.5.0 的 Loop 应用窗口（normal/floating/minimal），持有全部数据与 SSE。
- **第二窗口/回答窗**：`desktop_multi_window` 创建的第二顶层窗口，独立 FlutterEngine，只读。
- **极简条**：主窗口的 minimal 子状态（360×52），输入框+截图+返回三要素。
- **自动模式（auto）**：回答窗跟随输入条定位/高度；**用户模式（user-moved）**：用户拖动后固定顶边。
- **输入条排除区**：输入框容器在屏幕上的物理矩形 + gap，回答窗不得与其相交。

### F. 探针证据摘要（临时工程，不入库）

```text
Flutter 3.47.7 / Dart 3.13.5 / Windows 11 x64
flutter build windows --release: OK (dmw_probe.exe)
createWindow -> windowId; 第二引擎 main args = [multi_window, id, json]
answer_ready -> 主窗; delta -> 第二窗 -> ack; WM_CLOSE -> windows 2→1; 重开 -> 新 windowId/hwnd + IPC OK
EnumWindows 按 class FLUTTER_MULTI_WINDOW_WIN32_WINDOW 可定位第二窗
SetWindowLongPtr(去 WS_CAPTION) + SetWindowPos(HWND_TOPMOST,460x320) => 无标题栏/置顶渲染正常（截图）
主窗 WM_CLOSE 且回答窗未关 => 进程仍存活（孤儿）=> 必须先关回答窗
createWindow 后 GetForegroundWindow=第二窗（hidden 仍发生）=> 需要 WS_EX_NOACTIVATE + 补偿 + SW_SHOWNOACTIVATE
第二引擎 window_manager：ensureInitialized/getId/setSize/setAlwaysOnTop OK；
  setAsFrameless/setSkipTaskbar => window_manager_plugin.dll 0xC0000005 (offset 0xa015) => 禁用
```

### G. 变更记录

| 日期 | 变更 |
|---|---|
| 2026-10-24 | 初版：v0.5.0 审计、第二窗口实测、极简形态/回答窗契约、回归/测试/发布契约 |
