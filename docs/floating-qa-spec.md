# 桌面答疑悬浮窗（Floating Q&A）规格与验收契约 — v0.5.0

- 任务：`t1 [spec]` 浮窗状态机、交互规格与验收契约（attempt 1，attempt_id `740f6382-28b2-454b-940d-c4fea93e7017`）
- 审计对象：正式版 `D:\DSH_Workspace\Prog2_app`，基线 `HEAD 4850848`（v0.4.0）
- 审计方式：只读阅读 `app/lib`、`app/test`、`app/assets`、`app/windows` 与既有文档；本文件为本任务唯一新增文件
- 约束：不修改实现文件，不修改 `D:\DSH_Workspace\Loop-Test`
- 目标版本：**v0.5.0**
- 下游：`t2`（Windows/截图/快捷键）、`t3`（浮窗 UI/会话保活）、`t4`（验证）、`t5`（评审）、`t6`（集成/发布）

---

## 0. 结论速览（TL;DR）

1. **形态方案**：同一 Flutter 进程、同一 Flutter 窗口，在 `Shell` 内切换 `normal` / `floating` 两种窗口形态；不创建第二引擎、第二窗口、第二个 Loop 进程。**禁止重新引入 `setFullScreen`**；截图覆盖沿用 v0.3.8 起的“保存 bounds → 覆盖显示器工作区 → 恢复”方案。
2. **窗口状态**：进入浮窗前保存普通窗口的 `bounds / maximized / alwaysOnTop / minSize(900×600) / displayId`；退出逐项恢复。浮窗默认 `460×600`、最小 `360×420`、`alwaysOnTop=true`、不可最大化；本会话记住上次浮窗大小。
3. **会话保活**：浮窗不是第二个聊天页；`ChatScreen` 的 `State`（`_messages/_attachments/_conversationId/_runId/_approval/_sending`）与 SSE `await for` 必须跨形态保持同一实例。采用“同一树位置 + 稳定 `GlobalKey`”保活，并以 `FakeWindowPlatform` + `FakeLoopApi` 证明 `chatCalls == 1`、State `identical`；**禁止用重载历史或重启冒充保活**。
4. **浮窗 UI**：自绘拖动栏（Loop 标识、会话标题、截图、置顶、返回、关闭）+ 消息区 + 输入区；浮窗内隐藏主窗口标题栏/侧栏/ChatScreen 页头；`360×420` 进入紧凑模式，输入与发送/停止常驻可见，无 RenderFlex 溢出。
5. **截图**：复用 `ScreenshotCapture/ScreenshotOverlay/upload`；浮窗默认“隐藏 Loop 后截图”，保留“直接截图”；按**窗口中心所在显示器**捕获，把该显示器**工作区物理像素**以 `-X/-Y/-W/-H` 传给 `assets/screenshot.ps1`；主屏回退；结束恢复**浮窗**快照（含 `alwaysOnTop/minSize/mode`），不回到普通窗口。
6. **截图交互**：框选/全屏/Esc 取消/**重截**/完成；取消与重截不产生附件；完成后裁切 PNG → `POST /api/upload` → `img_*` 附件 → 随下一条消息 `attachments` 发送。
7. **快捷键**：`Alt+Q` 切换浮窗/主窗口、`Alt+A` 截图；Windows runner 原生 `RegisterHotKey` + MethodChannel 注册/注销/冲突检测；快捷键只发信号，不在快捷键层截图/上传；注册失败/冲突时**按钮始终可用**；禁止低层键盘钩子和周期轮询。
8. **焦点**：Windows 点击输入自然获得焦点；窗口 `focus()` 只允许在用户动作（切换、托盘显示、截图恢复）时最多一次；拖动、缩放、滚动、SSE 增量、刷新、定时器一律不得 `focus()`，也不得反复 `requestFocus()`。
9. **流式兼容**：完全沿用 v0.4.0 后端与事件协议；`stream_output` 开=逐字、关=完整回复后单 `delta`；工具步骤/计划/审批/停止/多轮/token/cost/error/cancelled 行为不变；多模态继续 `upload → img_* → /api/chat`。
10. **验收**：`flutter analyze` 0 issues；全量测试（37 基线 + 新增）通过；真实 Windows 窗口手工矩阵（含多显示器/DPI/屏幕移除）；隔离数据 + mock LLM 端到端；构建正式版并推送代码 + `v0.5.0` tag；**不自动创建 GitHub Release**；不改 Loop-Test。
11. **文件归属**：`t2` 只改 `app/lib/desktop/**`、`app/assets/screenshot.ps1`、`app/windows/runner/**` 与对应测试；`t3` 只改 `main.dart / ChatScreen / 浮窗 widgets / screenshot_overlay / image_preview / markdown_text` 与对应测试；其余人只写文档/证据（详见 §11）。
12. **关键风险**：原生快捷键通道需要改 Windows runner（首版必须编译验证）；混合 DPI 下物理坐标可能偏差（以 Win32 物理矩形为准，失败回退并记录限制）；360×420 空态/宽公式易溢出（必须 widget 测试锁死）。

### 0.1 Definition of Done（t5/t6 判定用）

- [ ] 单进程/单 Flutter 窗口/单 ChatScreen；无第二引擎、无 `setFullScreen`。
- [ ] 浮窗默认 460×600、最小 360×420、置顶、可拖动、可四边/四角缩放、无原生标题栏。
- [ ] 进出浮窗恢复普通 `bounds/maximized/alwaysOnTop/minSize`；失败回滚；重复切换幂等。
- [ ] 切换不断流：同一 `ChatScreenState`（`identical`）+ `chatCalls==1`；返回主窗口同一问答。
- [ ] 截图按窗口中心显示器、display bounds 传 PowerShell、主屏回退、恢复浮窗（含置顶/minSize/mode）、`img_*` 附件。
- [ ] 截图框选/取消/重截/完成/上传闭环；取消与重截不上传。
- [ ] `Alt+Q/Alt+A` 注册/注销/冲突降级；按钮始终可用。
- [ ] 拖动/缩放/流式/刷新不抢焦点；点击输入自然聚焦。
- [ ] `stream_output` 开/关、工具/计划/审批/停止、Markdown/公式/图片预览在 900×600/460×600/360×420、亮/暗主题回归。
- [ ] 隐私/性能预算达标；多显示器/DPI 矩阵有证据或明确限制。
- [ ] `flutter analyze` 0 issues；全量测试通过；正式构建；推送代码 + `v0.5.0` tag；不自动创建 GitHub Release；Loop-Test 未改。

---

## 1. 基线审计（HEAD 4850848 / v0.4.0）

### 1.1 现状文件与职责

| 文件 | 现状职责 | 与浮窗的关系 |
|---|---|---|
| `app/lib/main.dart` | `main()` 初始化 `WindowController`、托盘、后端；`LoopApp` 主题；`Shell` 标题栏+侧栏+`IndexedStack` 六页 | 浮窗形态要在 `Shell` 内切换；**不得再 `runApp`/创建窗口** |
| `app/lib/desktop/window_controls_io.dart` | 单例 `WindowController`：frameless、圆角、`setMinimumSize(900,600)`、初始 1440×900/居中、拖动/缩放/最小化/最大化/关闭、`maximized/resizing` 通知 | 需要扩展模式状态机+快照恢复；现有最小尺寸写死 |
| `app/lib/desktop/window_controls_stub.dart` | Web 占位同名单例 | 必须保持 API 对等，增加 floating 空实现 |
| `app/lib/widgets/title_bar.dart` | 自绘标题栏：拖动、双击最大化、最小化/最大化/关闭 | 主窗口加“浮窗答疑”按钮；浮窗用自绘拖动栏替代 |
| `app/lib/widgets/window_resize_handles.dart` | 8 个边缘/角热区，调用 `startResizing` | 浮窗继续复用；最小尺寸由 OS minSize 保证 |
| `app/lib/screens/chat_screen.dart` | 会话、消息、附件、SSE、截图、审批、停止、输入、Markdown | 浮窗复用同一实例；截图默认值与重截/焦点策略在此 |
| `app/lib/desktop/screenshot_capture_io.dart` | 保存 bounds/maximized → 可选 hide → PS 截图 → 覆盖主屏 → 返回字节；恢复 bounds | 需按窗口显示器捕获、快照升级为含 mode/minSize/alwaysOnTop、恢复浮窗 |
| `app/lib/screens/screenshot_overlay.dart` | 全屏选框：拖拽/全屏/取消/完成/Esc；裁切 PNG 返回 | 需加重截、窄窗适配、结果类型化 |
| `app/assets/screenshot.ps1` | 硬编码 `PrimaryScreen.Bounds` 截图 | 需支持显式物理矩形参数与 per-monitor DPI 感知 |
| `app/lib/desktop/screenshot_types.dart` | `ScreenshotSession{bytes,bounds,maximized}` | 字段不足以恢复浮窗（缺 alwaysOnTop/minSize/mode/display） |
| `app/lib/desktop/tray.dart` | 托盘显示/运行任务/退出；关闭到托盘 | 显示时保持当前形态，不重置模式 |
| `app/lib/state.dart` | `AppState`（settings/currentConversationId/streamOutput）；`newChat/openConversation/deletedConversation` 信号 | 复用；不新增后端状态；浮窗切换不得触发会话重建 |
| `app/lib/api.dart` | `chat()` SSE 解析、`upload()`、`imageUrl()` | 不改协议；截图附件沿用 `img_*` |
| `app/lib/backend/server.dart` | 进程内 8765；`/api/chat` 请求级 `stream_output` 快照；`/api/upload` 返回 `img_*` | 后端不改；浮窗只影响 UI |
| `app/lib/screens/settings_screen.dart` | “流式输出”开关（默认开，失败回滚） | 不改；浮窗遵循同一设置 |
| `app/windows/runner/*` | 标准 Flutter Windows runner；唯一 `FlutterWindow window(project)`；`FlutterWindow::MessageHandler` 处理窗口消息 | 新增 `WM_HOTKEY` 处理与 `loop/hotkeys` MethodChannel |
| `app/pubspec.yaml` | `version: 0.4.0+13`；无全局快捷键依赖 | 不新增第三方依赖；版本由 t6 提升到 `0.5.0+14` |

### 1.2 窗口生命周期现状（关键行号）

- `window_controls_io.dart:24-57` `init()`：`ensureInitialized → setAsFrameless → setResizable(true) → setBackgroundColor(transparent) → setMinimumSize(Size(900,600)) → 计算初始 1440×900/居中 → show/focus → addListener → maximized → DWM 圆角 → ready=true`。
- `:30` 最小尺寸固定 `900×600`；`:64-67` `show()` 每次 `show()+focus()`；`:132-139` `toggleMaximize()` 无模式判断；`:76-105` 只同步 `maximized/resizing`，无显示器/DPI 变化处理。
- `main.dart:230-292`：`Shell` 用 `WindowController.readyNotifier/maximized` 构造圆角容器，`Column(TitleBar, Expanded(Row(Sidebar, Expanded(IndexedStack))))`，`framed && !maximized` 时叠加 `WindowResizeHandles`。
- `main.dart:271`：`IndexedStack(index:_index, children:screens)`；六页常驻，切页不会销毁 `ChatScreen`（这是浮窗保活的既有基础）。
- `screenshot_capture_io.dart:21-26`：只取 `getPrimaryDisplay()` 并把窗口铺满主屏；`:36-51` 恢复只回 `bounds+maximized`，不恢复 `alwaysOnTop/minSize/mode` —— 浮窗截图后会丢置顶、可能回到错误形态。
- `assets/screenshot.ps1:18`：`[System.Windows.Forms.Screen]::PrimaryScreen.Bounds`；`:16` 仅 `SetProcessDPIAware()`（system-aware），混合 DPI 下坐标不可靠。

### 1.3 会话/SSE 现状

- `chat_screen.dart:38-58`：`_messages/_attachments/_controller/_scroll/_focus/_conversationId/_sending/_uploading/_screenshotting/_generating/_loadingMessages/_runId/_approval` 全在 `State` 内。
- `:60-84` `initState` 注册三个全局信号；`didUpdateWidget` 在 `active` 由 false→true 时 `_focus.requestFocus()`。浮窗切换不改变 `active`（对话页始终 true），只有“从非对话页进入浮窗”允许这一分支发生一次。
- `:272-377` `_send()` 内 `await for (api.chat(...))` 驱动增量 UI；只要 `State` 不销毁，切换窗口形态不会中断 SSE。
- `:218-270` `_takeScreenshot()` 固定调用 `ScreenshotCapture.start/restore`，`finally` 兜底恢复，完成后 `_focus.requestFocus()`；无重截。
- `:314-365` 事件处理：`delta/run/plan/approval/cancelled/step/done/error`；`:392-400` 停止 `cancelRun`；`:402-442` 审批卡。

### 1.4 设置/流式现状

- `state.dart:135-153` `streamOutput` 与 `setStreamOutput`；`models.dart:328-368` `SettingsData`；`settings_screen.dart:171-199` 开关与失败回滚。
- `server.dart:301-407`：`_chat` 进入请求时快照 `stream_output`（`:304-305`），`runAgent(streamOutput:...)`；`agent.dart:239` 流式逐 delta、`:461-462` 关闭时整段单 delta；事件协议不变。
- `test/streaming_chat_test.dart` F6/F7/F8/F9/F10 已覆盖开/关/停止/错误/审批，是浮窗回归的直接基线。

### 1.5 截图/快捷键/焦点现状

- 截图入口：`chat_screen.dart:1142-1169` 两个菜单项“直接截图/隐藏 Loop 后截图”；截图菜单/按钮在 `_sending/_uploading/_screenshotting` 时禁用。
- 快捷键：**当前没有任何全局/应用内快捷键实现**；`pubspec.lock` 无 `hotkey_manager/global_hotkey` 依赖。
- 焦点：`WindowController.show()` 无条件 `focus()`；`ScreenshotCapture` 恢复窗口后无条件 `focus()`；`ChatScreen` 多个用户动作后 `requestFocus`。
- 托盘：`tray.dart:47-57` 菜单显示/任务/退出；`onWindowClose` 在托盘激活时隐藏窗口（`window_controls_io.dart:91-93`）。

### 1.6 缺口清单（实现必须逐条消除）

| 编号 | 缺口/风险 | 证据 | 影响 FR |
|---|---|---|---|
| G1 | 无 normal/floating 模式状态机，`WindowController` 只有最大化布尔 | `window_controls_io.dart` 全文 | FR-1/2/3 |
| G2 | `minSize` 固定 900×600，浮窗下无法缩到 360×420 | `:30` | FR-2/3 |
| G3 | 无窗口快照结构；截图 session 只存 `bounds+maximized` | `screenshot_types.dart` | FR-2/8 |
| G4 | 截图只抓主屏、铺满主屏，副屏/窗口所在屏不支持 | `screenshot_capture_io.dart:21-26`、`screenshot.ps1:18` | FR-4/8 |
| G5 | PS 脚本仅 system DPI 感知，混合 DPI 可能偏心 | `screenshot.ps1:9-16` | FR-4/8 |
| G6 | 无“重截”，失败/取消后无法重新取景 | `screenshot_overlay.dart:174-210` | FR-9 |
| G7 | `ChatScreen` 状态在 State 内；Shell 若换树结构/条件包裹会重建并清空 SSE | `main.dart:264-275`、`chat_screen.dart:38-58` | FR-6 |
| G8 | 无稳定 key/保活断言；无“同一 State”测试 | 无 | FR-6/13 |
| G9 | `360×420` 下空态欢迎页不可滚动、示例 chips 换行、页头/输入固定尺寸易溢出 | `chat_screen.dart:644-758,1103-1236` | FR-7/13 |
| G10 | 图片预览宽度下限 420，窄窗被压缩/布局紧张 | `image_preview.dart:27-28` | FR-7/13 |
| G11 | 块级公式/表格无横向滚动，窄窗可能溢出 | `markdown_text.dart:277-291,196-214` | FR-7/13 |
| G12 | 无快捷键注册/注销/冲突处理 | 全仓无实现 | FR-10 |
| G13 | `_scrollToEnd()` 每个 delta 都做 180ms 动画滚动，小窗长回答易抖/抢滚动 | `chat_screen.dart:179-188,315-318` | FR-7/11/14 |
| G14 | 截图恢复/显示无焦点策略，易抢焦点 | `screenshot_capture_io.dart:40-51`、`chat_screen.dart:258` | FR-11 |
| G15 | 无显示器移除/DPI 变化校正 | 全仓无 `ScreenListener/didChangeMetrics` 处理 | FR-4 |
| G16 | 无隐私契约的显式约束与自动检查 | 现状仅临时目录清理 | FR-14 |
| G17 | 禁止项无回归锁：`setFullScreen` 已移除但无静态检查 | v0.3.8 变更说明 | FR-1/8/15 |

---

## 2. 用户需求 FR-1 ~ FR-15（权威定义）

> 编号供 t2/t3/t4/t5/t6 引用；每条附可判定验收标准（AC）。AC 是最终验收的最小集合，不得删减；可以追加。

### FR-1 单进程、单 Flutter 窗口、floating 模式状态机

**需求**：同一 Flutter 进程与同一窗口内切换普通/浮窗；不创建第二引擎、第二窗口、第二进程；禁止 `setFullScreen`；状态机只含 `normal/floating`，切换幂等、串行。

**规格**
- `FloatingWindowController`（纯 Dart，`desktop/floating_window.dart`）持有 `mode`、`pinned`、`transitioning`、`normalSnapshot`、`lastFloatingSnapshot`；所有窗口变更只经它。
- 同一时刻只允许一个 `ChatScreen` 实例、一个 `FlutterWindow`；截图用的 `powershell.exe` 是一次性子进程，不属于“另起悬浮进程”。
- 任何路径都不得调用 `windowManager.setFullScreen`。

**验收**
- **AC-1.1** 全程 `Get-Process Loop` 只有 1 个实例；`app/lib` 中 `runApp(` 仅 1 处、`FlutterEngine` 0 处。
- **AC-1.2** `app/windows/runner` 仅 1 处 `FlutterWindow window(project)`；任务栏仅 1 个窗口。
- **AC-1.3** `app/lib`、`app/test`、`app/windows/runner` 无 `setFullScreen`（静态命令见 §10.7）。
- **AC-1.4** 连续快速点击切换 10 次：无并发错乱（`transitioning` 期间事件被忽略）、最终状态与最后一次点击一致。

### FR-2 普通窗口快照与恢复

**需求**：进入浮窗前保存普通 `bounds / maximized / alwaysOnTop / minSize / displayId`；退出逐项恢复；最大化进入浮窗要先还原；重复切换不漂移；失败回滚。

**规格**
- `WindowSnapshot` 见 §4.2；`normalSnapshot` 在**任何窗口改动前**采集。
- 退出顺序：`setMinimumSize(900×600)` → `setAlwaysOnTop(snapshot.alwaysOnTop)` → `maximize()` 或恢复物理/逻辑 bounds → `show()` →（仅用户动作）`focus()` → `mode=normal` → 读回校验（±2px）一次重试。
- 进入失败：尝试恢复快照；若仍失败，保持 `normal` 并用默认 900×600 居中，提示一次错误。

**验收**
- **AC-2.1** 非最大化普通窗口（例如 1200×800 @ (100,80)）进入再退出：bounds 误差 ≤2px、`maximized=false`、`alwaysOnTop=false`、minSize 恢复 900×600。
- **AC-2.2** 最大化状态进入浮窗：先还原为浮窗 460×600；退出后重新最大化（`isMaximized()==true`）。
- **AC-2.3** 连续 10 次切换：bounds/maximized/minSize/mode 无累积漂移；不会越切越小。
- **AC-2.4** 注入平台失败（fake 抛错）：UI 与窗口形态一致、提示一次、不崩溃；下一次切换仍可成功。

### FR-3 浮窗几何、拖动与缩放

**需求**：默认约 460×600，最小 360×420；位于当前显示器工作区；可拖动、四边/四角缩放；不可最大化；本会话记住上次浮窗大小。

**规格**
- 常量：`normalMin=900×600`、`floatingDefault=460×600`、`floatingMin=360×420`、`margin=24`（逻辑像素）。
- 首次进入：右边缘内缩 24、垂直居中（公式见 §4.3）；再次进入优先上次浮窗尺寸（若仍满足工作区与最小值），否则默认。
- 拖动：仅拖动栏空白区触发 `startDragging()`；双击拖动栏**不做**最大化；`toggleMaximize()` 在 floating 直接 no-op。
- 缩放：沿用 `WindowResizeHandles` + 原生 `startResizing`；OS `WM_GETMINMAXINFO` 保证最小尺寸。

**验收**
- **AC-3.1** 首次进入尺寸 460×600（±1px，逻辑）。
- **AC-3.2** 拖拽边/角无法小于 360×420；主窗口仍无法小于 900×600。
- **AC-3.3** 1920×1080@100%（工作区 1920×1040）时浮窗 `x=1436, y=220`（±2px）；其他分辨率位置始终在工作区内。
- **AC-3.4** 拖动栏可拖动、可跨显示器；双击不变最大化；最大化按钮/标题栏不存在于浮窗。
- **AC-3.5** 缩放浮窗后退出再进入：恢复上次浮窗尺寸（仍合法时）。

### FR-4 显示器、工作区、屏幕移除与 DPI 回退

**需求**：按窗口中心所在显示器定位与截图；负坐标副屏可用；显示器移除/分辨率/DPI/任务栏变化时保持可见；无法识别时主屏回退；DPI 获取失败回退，不崩溃。

**规格**
- 目标显示器 = 包含窗口中心物理点的显示器；否则取与窗口物理矩形交集最大的显示器；否则主屏；否则列表第一个；列表为空则主屏回退链 `Win32 → screen_retriever → 当前窗口位置兜底`。
- `Win32` 优先：`GetWindowRect + MonitorFromPoint(MONITOR_DEFAULTTONEAREST) + GetMonitorInfo(rcWork) + GetDpiForMonitor(MDT_EFFECTIVE_DPI)`；`windowManager.getId()`（0.5.2 返回 HWND）作为句柄。
- DPI 回退：`GetDpiForMonitor → display.scaleFactor → systemScaleFactor() → 1.0`；值域 `[0.5, 4.0]` 外按 1.0。
- 事件：`screen_retriever` 的 `display-added/removed` 与 `didChangeMetrics`（DPI/缩放）触发 300ms 去抖的 `ensureGeometry()`；**不改变 mode、不 focus**。
- 浮窗越界校正：若窗口与所有显示器交集为 0 或超出工作区，钳制到目标工作区；普通窗口仅在全屏外时回到主屏居中；最大化窗口不处理。

**验收**
- **AC-4.1** 副屏上进入浮窗：浮窗在该副屏工作区；截图捕获该副屏。
- **AC-4.2** 浮窗所在副屏被禁用/拔出：≤2s 回到主屏工作区、仍 floating、可交互、无崩溃/隐藏。
- **AC-4.3** 100%↔125%↔150% 切换：窗口仍可见、可缩放；截图输出像素 = 框选区域 × 该屏 scaleFactor（±2px）。
- **AC-4.4** 副屏位于主屏左侧（负 X）或上方（负 Y）：定位与截图正确。
- **AC-4.5** DPI API 失败（fake 抛错）：使用回退值，功能可用并记录一次 debug 日志。
- **AC-4.6** 显示器 API 全失败：截图明确提示失败并恢复窗口，不抓虚拟桌面。

### FR-5 浮窗 UI 结构与标识

**需求**：自绘拖动栏（Loop 标识、截图按钮、返回按钮、置顶、关闭）+ 消息区 + 输入区；无 Windows 原生标题栏；主窗口提供进入浮窗的按钮。

**规格**
- `FloatingBar`（新组件，t3）：高 44（紧凑 40）；左侧拖动区含 Loop 渐变标识 20×20 + “回路” + 会话标题（省略号）+ “浮窗”小标签；右侧按钮顺序：截图、置顶、返回主窗口、关闭；全部带 Tooltip（含快捷键）。
- 浮窗隐藏：主窗口 `TitleBar`、侧栏、`ChatScreen` 页头（标题/模式/新对话/模型 chip）；保留消息区+输入区。
- 主窗口 `TitleBar` 在最小化按钮左侧新增“浮窗答疑”图标按钮（key `window-floating-toggle`，tooltip `浮窗答疑 (Alt+Q)`）。
- 圆角：浮窗 16、普通窗口 18（非最大化），边框 1px `pal.windowBorder`；沿用 `AuroraBackground` 与现有配色，不新增调色板键。
- 浮窗关闭按钮语义与主窗口一致：托盘激活时隐藏到托盘，否则退出；不影响模式记忆。

**验收**
- **AC-5.1** 浮窗无原生标题栏（截图/录屏可见），退出/截图恢复后仍无。
- **AC-5.2** 拖动栏含上述元素；点击热区 ≥32×32（紧凑 ≥30×30）；tooltip 文案含 `Alt+Q/Alt+A`。
- **AC-5.3** 主窗口按钮进入浮窗；浮窗返回按钮回主窗口；快捷键与按钮等效。
- **AC-5.4** 主窗口除新增按钮外无可见 UI 变化；浮窗内不出现侧栏/页头。

### FR-6 会话状态与 SSE 保活（核心）

**需求**：复用同一 `ChatScreen`/`AppState`/当前 conversation/`_messages`/`_attachments`/SSE；切换不中断生成；返回主窗口看到同一问答；禁止用重启加载历史冒充状态保持。

**规格**
- 复用对象（全部保持同一实例/同一请求）：`AppState`（`currentConversationId/settings/conversations`）、`ChatScreenState` 的 `_messages/_attachments/_conversationId/_runId/_approval/_sending/_scroll`、`LoopApi.chat` 的 SSE 迭代。
- 结构：`Shell` 始终渲染 `FloatingQaScaffold(floating, chrome, sidebar, content)`，其中 `content` 固定为同一个 `IndexedStack(key: _contentKey, children: screens)`；`ChatScreen(key: _chatKey, ...)`。浮窗只替换 `chrome`（`FloatingBar`）、把 `sidebar` 换成 `SizedBox.shrink`、把 `IndexedStack.index` 固定为 0；**不改变 `ChatScreen` 的父子槽位**。
- 保活：`_chatKey = GlobalKey<ChatScreenState>()`；`ChatScreenState` 由私有类改为公开类（仅类名公开，字段仍私有），提供只读 `@visibleForTesting` getter（`conversationId/messageCount/attachmentCount/isSending/isGenerating/runId/approvalVisible`）。
- 切换期间：不调用 `_bootstrap/_loadConversation/messages()`；不 `setState` 重建 `ChatScreen`；SSE 的 `await for` 继续消费。
- 进入浮窗时若当前页不是“对话”，记录 `_index`、强制 `IndexedStack.index=0`（`ChatScreen.active=true`）；退出恢复原页；浮窗内不提供切页/历史/新建对话。
- 兜底：若未来重构导致树位置变化，`GlobalKey` 必须仍能保 State；测试断言 `identical(before, after)`。

**验收**
- **AC-6.1** 切换前后 `ChatScreenState` 实例 `identical == true`。
- **AC-6.2** 切换前后 `conversationId/messageCount/attachmentCount/runId` 不变；`FakeLoopApi.chatCalls == 1`。
- **AC-6.3** 慢速流式回答中切换 2 次：增量继续、最终完整、无重复字符；停止按钮仍可用并触发一次 `cancelRun`。
- **AC-6.4** 返回主窗口：同一回答气泡、同一会话 id、内容与浮窗最后一帧一致（不重新 `messages()`）。
- **AC-6.5** 切换不触发 `_bootstrap`、不新增 `createConversation`、不产生第二个 `ChatScreen`（可用 `find.byType(ChatScreen)` 计数 1）。

### FR-7 浮窗输入、消息与紧凑模式

**需求**：输入/发送/停止；附件/截图预览；错误/空态；Markdown/公式/代码；长回答滚动；小窗折叠不溢出、输入常驻。

**规格**
- 输入：Enter 发送、Shift+Enter 换行（沿用现有 `Focus.onKeyEvent`）；`_sending` 时按钮变停止；附件区、上传/截图进度条保留。
- 紧凑阈值：`floating && (width < 420 || height < 520)` → `compact=true`；消息区左右 padding 24→12、气泡内边距 18→12、用户气泡左边距 48→20、输入区 padding 24→12、隐藏页脚提示行、输入 `maxLines 6→4`、按钮 38→34。
- 空态：紧凑模式欢迎页改为可滚动/精简（36 标识 + 18px 标题 + 单行说明），隐藏示例 chips，避免 360×420 溢出。
- 滚动：`_scrollToEnd` 改为“接近底部才跟随”；流式期间 `jumpTo`（不动画）或 ≤50ms 合批；用户上滚后暂停跟随并显示“回到底部”胶囊；`ScrollController` 偏移在截图覆盖/恢复后尽量保持。
- Markdown：代码块已横向滚动；块级公式包横向滚动；宽表格窄窗不得溢出（必要时横向滚动）。
- 图片预览：`width=(size.width*0.9).clamp(240,1100)`、`height=(size.height*0.9).clamp(200,820)`、`insetPadding` 紧凑 12；360×420 下不溢出、可关闭。
- 错误/空态：SSE error、上传失败、未配置 Key、空回复与主窗口一致；snackbar 不遮挡发送按钮。

**验收**
- **AC-7.1** 460×600 与 360×420 均可输入/发送/停止；Enter/Shift+Enter 行为一致。
- **AC-7.2** 空会话、单条长回答（≥8000 字）、图片附件、截图附件在 360×420 下 `tester.takeException()==null` 且关键控件可见。
- **AC-7.3** 流式时上滚不被拉回；回到底部可用；输入区始终可见。
- **AC-7.4** Markdown/KaTeX/代码块/表格在 360 宽无溢出；代码/公式可横向滚动。
- **AC-7.5** 错误（error/上传失败/无 Key）提示可见、不崩溃、不溢出。

### FR-8 截图服务复用与“按窗口显示器”捕获

**需求**：复用现有截图链路；浮窗默认“隐藏 Loop 后截图”，保留直接截图；按窗口中心所在显示器；display bounds 传 PowerShell；主屏回退；截图结束恢复浮窗而非普通窗口；禁止 `setFullScreen`。

**规格**
- `ScreenshotCapture.start({required bool hideLoop})` 内部：`WindowController.floating.snapshot()` 取完整快照 → `snapshot` 前读取捕获显示器（窗口中心）→ 若 `hideLoop` `hide()`+280ms → 调用 `powershell.exe -File capture.ps1 -Out <png> -X <物理x> -Y <物理y> -W <物理w> -H <物理h>` → 覆盖窗口：Win32 `SetWindowPos` 到同一物理工作区（失败回退 `windowManager.setBounds(logical)`）→ `setAlwaysOnTop(true)` → `show()+focus()`（一次）→ 返回 `ScreenshotSession{bytes, snapshot, display, hidden}`。
- 恢复：`ScreenshotCapture.restore(session)` → `WindowController.floating.applySnapshot(session.snapshot, focus: session.hidden)`；恢复 `minSize/alwaysOnTop/maximized/bounds/mode`，**不改变 mode**；`ensureGeometry` 兜底。
- 失败：任何异常都走 `finally` 恢复；错误提示“截图失败”并保留浮窗。
- 覆盖窗口期间：`captureInProgress=true`，禁止模式切换/再次截图。

**验收**
- **AC-8.1** 浮窗截图默认 `hideLoop=true`；右键/次级菜单可“直接截图”。
- **AC-8.2** 捕获显示器 = 窗口中心所在显示器；PowerShell 收到正确物理矩形；PNG 尺寸 = W×H。
- **AC-8.3** 主屏回退：显示器解析失败时仍能抓主屏，且覆盖窗口与主屏对齐。
- **AC-8.4** 截图完成/取消/重截后：浮窗 bounds/置顶/minSize/mode 与截图前一致；不出现普通窗口/原生标题栏。
- **AC-8.5** 全链路无 `setFullScreen`。
- **AC-8.6** `hideLoop` 截图不含 Loop；直接截图含 Loop（与 v0.3.9 行为一致）。

### FR-9 截图交互闭环

**需求**：框选、全屏、取消、重截、上传；取消/重截不产生附件；完成后 PNG → `img_*` 附件 → 预览/发送；失败恢复窗口。

**规格**
- Overlay 返回类型：`ScreenshotOverlayResult?`（`null`=取消/Esc；`done(bytes)`；`retake`）。
- ChatScreen 每次截图最多 4 次捕获会话（1 次初始 + 3 次重截）；每次会话 `start`/`restore` 严格 1:1；重截时先恢复再重新 `start`。
- 完成后：`api.upload(cropped, '截图-<epoch>.png')` → 必须 `kind=image` 且 id 以 `img_` 开头 → 加入 `_attachments` → snack “截图已加入附件”；不自动发送。
- 取消/重截：不调用 upload；不新增附件。
- 恢复后焦点：若截图前输入框有焦点，则在流程结束后 `requestFocus()` 一次；否则不聚焦输入。

**验收**
- **AC-9.1** 框选/全屏/Esc/取消/重截/完成均可用；重截 ≤3 次，超出提示。
- **AC-9.2** 裁切尺寸与选择区域一致（±2px）；上传响应 `img_*`；附件 tile 出现且可预览；发送后消息带图，重载仍在。
- **AC-9.3** fake service 断言每次 `start` 恰好对应一次 `restore`；异常路径也恢复。
- **AC-9.4** 取消后无上传、无附件；窗口恢复浮窗且置顶正确。

### FR-10 快捷键 Alt+Q / Alt+A

**需求**：Alt+Q 切换、Alt+A 截图；注册/注销/冲突失败处理；按钮始终可用；快捷键层只透传 UI，不自动截图/上传；不重复触发。

**规格**
- Windows 原生：`RegisterHotKey(hwnd, 0x4C51, MOD_ALT|MOD_NOREPEAT, 'Q')`、`0x4C52/Alt+A`；`WM_HOTKEY` 经 `loop/hotkeys` 通道回调；Dart 回调只做 `toggleFloating()` / `screenshotRequestSignal`。
- 生命周期：`WindowController.init()` 注册；`quit()`/`OnDestroy` 注销；重复 `register` 先注销再注册（幂等）；支持“重试注册”。
- 冲突：`RegisterHotKey` 返回 false，`GetLastError()==1409` 记为 conflict；只影响冲突键；状态可读、按钮可用、一次性提示、不循环重试。
- 防重复：`MOD_NOREPEAT` + Dart 300ms 去抖；同一时刻只处理一次切换。
- 降级：非 Windows/非桌面 stub 返回 unsupported；主窗口按钮隐藏；浮窗按钮仍可用。
- 隐藏/最小化时 Alt+A 不截图（不抢焦点、不后台采集）；Alt+Q 先显示窗口再决定是否切换（见 §8.1）。

**验收**
- **AC-10.1** 焦点在记事本时 Alt+Q 切换浮窗；Alt+A 在浮窗可见时进入截图流程。
- **AC-10.2** 退出应用后热键失效（无残留注册）；重复注册无泄漏。
- **AC-10.3** 用第二个程序抢占 Alt+Q：状态显示冲突、Alt+A 仍可用、按钮可切换、无崩溃。
- **AC-10.4** 连按 Alt+A 5 次不产生并发截图/多次上传；快捷键层无 upload 调用。
- **AC-10.5** 冲突/不支持时主窗口“浮窗答疑”与浮窗截图/返回按钮均可用。

### FR-11 焦点与不打断

**需求**：点击输入自然获得焦点；拖动/刷新/流式输出不得反复 focus；不抢其它应用焦点。

**规格**
- 焦点调用白名单：启动、托盘显示、用户切换形态（≤1 次）、截图恢复（≤1 次）、用户点击输入/示例。
- 禁止：拖动/缩放事件、SSE delta/step/plan/approval/done、滚动跟随、定时器/去抖、`build/initState`（除用户动作后的 postFrame）、模式切换的重复调用。
- 浮窗切换不得让 `ChatScreen.didUpdateWidget` 因 `active false→true` 反复聚焦：只有进入浮窗前不在对话页时才允许一次。
- 输入框焦点丢失由用户点击恢复；不自动抢回。

**验收**
- **AC-11.1** 点击输入框获得焦点；流式 20 条 delta 后主焦点不变（`FocusManager.primaryFocus`）。
- **AC-11.2** fake platform `focusCount`：一次切换 + 1；随后拖动/缩放/20 条 delta/`ensureGeometry` 不增加。
- **AC-11.3** 截图恢复：窗口 focus ≤1 次；输入框仅在截图前聚焦时恢复 1 次。
- **AC-11.4** 静态检查：`focus()/requestFocus` 调用点均在白名单（代码评审 + grep 清单）。

### FR-12 流式、工具、审批、停止与多模态兼容

**需求**：遵循 `stream_output`；工具步骤/计划/审批/停止正常；`upload→img_id→/api/chat` 不变。

**规格**
- 不改后端、不改 SSE 协议、不改 ChatScreen 事件分支（除滚动/紧凑展示）。
- 浮窗与主窗口读取同一 `AppState.settings.streamOutput`；不新增开关。
- 附件：截图/文件上传走 `POST /api/upload`；发送时 `attachments:['img_*'|'mat_*']`；服务端保存 `attachments` 元数据，历史重载可见。

**验收**
- **AC-12.1** `stream_output=true` 多 delta 逐字；`false` 单 delta + 等待期“正在思考…”（与 `streaming_chat_test` F6/F7 一致，浮窗形态重跑）。
- **AC-12.2** step/plan/approval/cancelled/error/done 在浮窗正常；允许/拒绝/停止调用正确 API。
- **AC-12.3** 截图→`img_*`→发送→模型收到附件；文件→`mat_*` 同理；重载历史附件预览正常。
- **AC-12.4** 切换形态不产生额外 chat/upload 请求；请求数符合用户动作。

### FR-13 主题与尺寸回归

**需求**：亮/暗主题；900×600 主窗口；460×600/360×420 浮窗；无溢出；截图/附件预览/Markdown/公式/停止/审批回归。

**规格**
- 不新增调色板键；浮窗使用 `pal` 现有颜色；`LoopTheme.palette` 切换即时生效。
- 900×600 主窗口必须与 v0.4.0 一致（除新增按钮）。
- 360×420 最小浮窗：所有关键控件可见可点；允许内容滚动，不允许裁剪不可达控件。

**验收**
- **AC-13.1** 亮/暗主题下浮窗与主窗口文字/边框/背景/按钮对比可读；截图记录。
- **AC-13.2** 900×600 主窗口六页可用；最大化/还原/缩放正常。
- **AC-13.3** 460×600、360×420 无 RenderFlex overflow（自动测试 + 手工截图）。
- **AC-13.4** v0.4.0 回归项（Markdown/公式/代码/图片预览/停止/审批/流式开关/历史）全部通过。

### FR-14 隐私与性能

**需求**：隐私、快捷键、性能（秒级截图、流式渲染/滚动）、多显示器矩阵；不得周期性截图或未经用户动作采集。

**规格**
- 截图仅由：浮窗/输入区截图按钮、`Alt+A`、用户菜单触发；无定时器、无启动/切换自动截图、无后台屏幕采集、无 OCR 链路。
- 不上传/不记录图像到日志；临时脚本与 PNG 在 `finally` 删除；`uploads` 只保存用户确认后的图片。
- 快捷键使用 `RegisterHotKey`（非 `WH_KEYBOARD_LL`），不记录按键内容。
- 性能预算：切换 ≤300ms；截图点击→可框选 p95 ≤2.5s；裁切→附件 ≤1.5s；8600 字流式时输入/滚动可交互；10 次切换无内存持续增长。

**验收**
- **AC-14.1** 空闲 60s：无 `powershell.exe` 截图子进程、无新临时目录、无上传请求。
- **AC-14.2** 性能预算逐项达标（手工计时 10 次取 p95；截图工具/日志为证）。
- **AC-14.3** 静态检查：浮窗/截图文件中无 `Timer.periodic`、无屏幕轮询、无低层键盘钩子；日志无 base64/图像。
- **AC-14.4** 多显示器矩阵（§10.5）通过或明确记录不可测项（禁止伪报）。

### FR-15 发布边界与交付

**需求**：目标 v0.5.0；构建正式版；推送代码/tag；不自动创建 GitHub Release；不改 Loop-Test；文件归属与验收命令明确。

**规格**
- 版本：`pubspec.yaml 0.5.0+14`、`AppVersion.current='0.5.0'`、`version.json={"version":"0.5.0"}`、`Loop.exe FileVersion 0.5.0+14`。
- 文档：README 当前版本/功能/changelog；`docs/release-v0.5.0.md`；`docs/floating-qa-test-report.md`（t4）。
- 提交与 tag：`git push origin main` + `git push origin v0.5.0`；**不自动创建 GitHub Release**（保留维护者手动上传 ZIP）。
- 不改 `D:\DSH_Workspace\Loop-Test`；不提交 `.agent-teams/`；不污染 `data/`；构建时如用户实例在运行则不得覆盖 `release/`（沿用 t6 安全策略）。

**验收**
- **AC-15.1** 版本四项一致；`flutter analyze` 0 issues；全量测试通过。
- **AC-15.2** 正式构建成功；产物 SHA-256/大小记录在 `docs/floating-evidence/` 与 release 文档。
- **AC-15.3** 代码与 `v0.5.0` tag 已推送；GitHub Release 未创建（可见证据）。
- **AC-15.4** `git status --short` 仅剩允许的未跟踪项（`.agent-teams/`）；Loop-Test 无新修改。

### 2.1 用户需求（8 条）→ FR 映射

| 用户需求条目（任务原文） | 覆盖 FR |
|---|---|
| 1) 单进程单窗口、floating 状态机、bounds/maximized/置顶/minSize 保存恢复；禁止第二引擎与 setFullScreen | FR-1、FR-2、FR-3、FR-14 |
| 2) 默认 460×600、最小 360×420、当前显示器定位、拖动/缩放、返回恢复、屏幕移除/DPI 回退；主窗口 900×600 与窄布局 | FR-3、FR-4、FR-5、FR-13 |
| 3) 复用 ChatScreen/AppState/conversation/_messages/_attachments/SSE；切换不断流；返回同一问答；稳定 key/保活 | FR-6、FR-12 |
| 4) 浮窗 UI：拖动栏、Loop 标识、截图、返回、消息区、输入/发送/停止；小窗折叠；截图/附件预览、错误/空态、Markdown/公式、长回答滚动 | FR-5、FR-7、FR-13 |
| 5) 截图复用：默认隐藏 Loop 后截图，保留直接；框选/取消/重截/上传；按窗口显示器与 display bounds 传 PS；主屏回退；结束恢复浮窗 | FR-8、FR-9、FR-14 |
| 6) Alt+Q/Alt+A；注册/注销/冲突；按钮始终可用；无周期截图；点击输入自然焦点；禁止反复 focus | FR-10、FR-11、FR-14 |
| 7) stream_output 开逐字/关完整；工具/计划/审批/停止；多模态 upload→img_id→/api/chat | FR-12 |
| 8) 隐私、性能、多显示器矩阵、文件归属、验收命令；非目标；v0.5.0；不自动 GitHub Release | FR-14、FR-15 |

### 2.2 FR → 实现落点（文件/接口）

| FR | 主要实现落点（owner） |
|---|---|
| FR-1 | `desktop/floating_window.dart`（状态机，t2）、`desktop/window_controls_io.dart`（唯一的 `WindowController`，t2）；截图覆盖不引入全屏 API（t2） |
| FR-2 | `desktop/floating_window.dart` 的 `snapshot/applySnapshot/enterFloating/exitFloating`（t2）；`desktop/window_mode.dart` 的 `WindowSnapshot`（t2） |
| FR-3 | `desktop/window_mode.dart` 的 `FloatingWindowPlanner.placeFloating` + 常量（t2）；`window_controls_io.dart` 的 `startResizing/setMinimumSize/toggleMaximize`（t2）；`widgets/floating_bar.dart` 拖动区（t3） |
| FR-4 | `desktop/win32_display.dart`（Win32/DPI，t2）、`floating_window.ensureGeometry`（t2）、`main.dart` 的 `didChangeMetrics` 回调（t3）、`window_controls_io` 的 `ScreenListener`（t2） |
| FR-5 | `widgets/floating_bar.dart`、`widgets/floating_qa_scaffold.dart`（t3）、`widgets/title_bar.dart` 浮窗按钮（t3） |
| FR-6 | `main.dart` Shell（稳定槽位 + `_chatKey` + `screensOverride`，t3）、`screens/chat_screen.dart`（公开 State + `floating/compact` 参数，t3） |
| FR-7 | `screens/chat_screen.dart` 的紧凑布局/滚动策略（t3）、`widgets/markdown_text.dart`（横向滚动，t3）、`widgets/image_preview.dart`（自适应，t3） |
| FR-8 | `desktop/screenshot_capture_io.dart`（快照/显示器/覆盖/恢复，t2）、`assets/screenshot.ps1`（参数/DPI，t2）、`desktop/screenshot_types.dart`（session v2，t2）、`desktop/screenshot_service.dart`（t2） |
| FR-9 | `screens/screenshot_overlay.dart`（重截/结果类型/紧凑，t3）、`chat_screen.dart` 的 `_takeScreenshot` 重截循环（t3） |
| FR-10 | `desktop/hotkeys*.dart`（Dart 服务，t2）、`app/windows/runner/flutter_window.{h,cpp}`（WM_HOTKEY/channel，t2）、`floating_window.dart` 的 `captureInProgress/transitioning` 守卫（t2） |
| FR-11 | `window_controls_io.dart` 的 `show/focusOnce` 拆分（t2）、`screenshot_capture_io.dart` 的 `focus: hidden`（t2）、`chat_screen.dart` 的 `didUpdateWidget` 聚焦条件（t3） |
| FR-12 | 不改后端；`api.dart`/`backend/server.dart`/`backend/agent.dart` 保持只读；`chat_screen.dart` 事件分支仅做滚动/紧凑展示（t3） |
| FR-13 | `theme.dart`/`palette.dart` 只读；`image_preview.dart`/`markdown_text.dart`（t3）；既有 37 测试作为回归基线 |
| FR-14 | `screenshot_capture_io.dart`/`hotkeys_io.dart` 无定时采集（t2）；`chat_screen.dart` 仅用户动作触发（t3）；静态检查与手工证据（t4） |
| FR-15 | `pubspec.yaml`、`update/app_version.dart`、`README.md`、`docs/release-v0.5.0.md`、构建脚本使用（t6） |

---

## 3. 状态机与生命周期

### 3.1 窗口形态状态机

```text
                 enterFloating() [user button / Alt+Q]
   ┌──────────┐ ───────────────────────────────────────► ┌───────────┐
   │  normal  │                                          │ floating  │
   │ (可最大化)│ ◄─────────────────────────────────────── │ (置顶/非最大化) │
   └──────────┘        exitFloating() [返回 / Alt+Q]       └───────────┘
        ▲                                                      │
        │ 失败回滚（enter/exit 任一步骤异常）                    │
        └──────────────────────────────────────────────────────┘
```

| 状态 | 关键属性 | 允许的 UI |
|---|---|---|
| `normal` | `minSize=900×600`；`alwaysOnTop` 取快照（通常 false）；可最大化 | `TitleBar` + 侧栏 + 六页；浮窗按钮可见 |
| `floating` | `minSize=360×420`；`alwaysOnTop=pinned`（默认 true）；非最大化；尺寸 460×600 或记忆值 | `FloatingBar` + 仅对话；返回/截图/置顶/关闭 |
| `capturing`（临时子态，不改变 mode） | 窗口临时覆盖捕获显示器工作区；`captureInProgress=true` | 全屏 `ScreenshotOverlay`；禁止切换/再次截图 |

**转换表**

| 当前 | 事件 | 守卫 | 动作 | 结果 |
|---|---|---|---|---|
| normal | 浮窗按钮 / Alt+Q | `supported && !transitioning && !captureInProgress && ready` | 快照 → 选屏 → unmaximize(如需) → minSize 360×420 → 置顶 → 定位/尺寸 → show/focus(≤1) → 校验 | floating |
| floating | 返回按钮 / Alt+Q | `!transitioning && !captureInProgress` | minSize 900×600 → 恢复置顶 → maximize 或恢复 bounds → show/focus(≤1) → 校验 | normal |
| 任意 | 再次 enter/exit | 已处于目标态 | no-op（幂等） | 不变 |
| 任意 | 转换中再次触发 | `transitioning` | 忽略 | 不变 |
| floating | 截图开始 | `!transitioning && 非发送/上传中` | `captureInProgress=true` → 保存快照 → 覆盖捕获屏 | capturing（mode 仍 floating） |
| capturing | 取消/完成/重截 | — | 恢复快照 → `captureInProgress=false`；（重截则重新开始） | floating |
| 任意 | 显示器移除/DPI 变化 | 去抖 300ms | `ensureGeometry()`（不 focus、不改 mode） | 不变 |
| 任意 | 关闭/托盘隐藏/最小化 | — | 不改 mode；托盘显示保持当前形态 | 不变 |
| 任意 | 应用退出 | — | 注销热键；不再恢复窗口 | — |

### 3.2 进入浮窗时序（事务式）

1. 若 `mode==floating` 返回 true；若 `transitioning||captureInProgress` 返回 false。
2. `transitioning=true`（UI 禁用切换按钮）。
3. `normalSnapshot = platform.snapshot()`（bounds/maximized/alwaysOnTop/minSize/displayId/dpr/物理矩形）。
4. `displays = platform.displays()`；`target = chooseDisplay(displays, normalSnapshot.physicalBounds)`（窗口中心 → 交集最大 → 主屏 → 首个）。
5. 若 `maximized`：`unmaximize()`；轮询 `isMaximized()==false`（50ms×10，超时继续）。
6. `setResizable(true)`；`setMinimumSize(360×420)`。
7. `targetLogical = placeFloating(target.physicalWorkArea, dpr, lastFloatingSize ?? 460×600, 360×420, 24)`；`targetPhysical = targetLogical × dpr`（矩形缩放到物理像素，保证跨屏/混合 DPI 落位一致）。
8. `setAlwaysOnTop(true)`；`setBoundsPhysical(targetPhysical)`（失败回退 `setBoundsLogical(targetLogical)`）；`show()`；`focus()` 仅当 `focus==true` 且由用户动作触发。
9. 读回校验：尺寸/位置偏差 ≤2px（逻辑）或 ≤4px（物理）；失败重试一次，仍失败则回滚。
10. `pinned=true`；`lastFloatingSnapshot` 记录；`mode=floating`；`transitioning=false`。
11. 任一步抛错：`applySnapshot(normalSnapshot)` 一次；`mode=normal`；`transitioning=false`；返回 false；`onError` 回调（UI 提示一次）。

### 3.3 退出浮窗时序

1. 非 floating → true；`transitioning||captureInProgress` → false。
2. `snapshot = normalSnapshot ?? defaultNormalSnapshot()`。
3. `transitioning=true`；`setAlwaysOnTop(snapshot.alwaysOnTop)`；`setMinimumSize(snapshot.minSize)`。
4. `snapshot.maximized ? maximize() : setBoundsPhysical/Logical(snapshot)`；`show()`；必要时 `focus()` 一次。
5. 校验（bounds ±2px / maximized 一致）；失败重试一次；仍失败 → 默认 900×600 居中 + 提示“恢复主窗口失败，已使用默认窗口”。
6. `mode=normal`；记录 `lastFloatingSnapshot = platform.physicalRect()`（便于会话内记忆尺寸）；`transitioning=false`。

### 3.4 截图子状态机（见 §7）

```text
idle ──截图按钮/Alt+A──► captureStart ──► overlay(框选/全屏/取消/重截/完成)
  ▲                                                     │
  └──────── restore(snapshot) ◄── upload(仅完成) ◄───────┘
                    ▲
                    └── retake（≤3）：restore → 重新 captureStart
```

### 3.5 不变量（实现与测试必须满足）

- **I-1** 单进程、单 Flutter 窗口、单 `ChatScreen` 实例。
- **I-2** `mode` 只由 `FloatingWindowController` 修改；UI 只读。
- **I-3** `floating` 时 `normalSnapshot != null`；`normal` 时无未完成事务。
- **I-4** `minSize` 必须与当前 mode 匹配（normal 900×600；floating 360×420）。
- **I-5** `alwaysOnTop == (mode==floating && pinned)`；截图覆盖期间临时 true，恢复后回快照值。
- **I-6** 截图/覆盖窗口不改变 `mode`。
- **I-7** 每次 `ScreenshotCapture.start` 成功返回后，必须且只能 `restore` 一次。
- **I-8** 任何路径不得调用 `setFullScreen`。
- **I-9** 窗口 `focus()` 仅由用户动作触发，单次动作 ≤1 次；流式/拖动/定时器为 0。
- **I-10** SSE 请求生命周期与 UI 形态解耦；切换不得取消/重建请求。
- **I-11** 截图只由用户动作触发；无周期/后台采集。
- **I-12** 转换串行化；并发触发不改变最终状态。
- **I-13** `applySnapshot` 幂等；重复恢复不累积置顶/尺寸副作用。
- **I-14** 显示器失效时窗口必须回到主屏工作区并保持可交互。

---

## 4. 窗口契约

### 4.1 常量

| 名称 | 值（逻辑 px） | 说明 |
|---|---|---|
| `normalMinSize` | 900×600 | 与 v0.4.0 一致 |
| `floatingDefaultSize` | 460×600 | 首次进入浮窗 |
| `floatingMinSize` | 360×420 | OS 最小尺寸；自动测试必须覆盖 |
| `floatingMargin` | 24 | 距工作区右/上/下边距 |
| `floatingRadius` | 16 | 普通窗口 18 |
| `compactWidth` | 420 | `<420` 或 `<520` 高 → 紧凑 |
| `compactHeight` | 520 | 同上 |
| `captureHideDelay` | 280ms | 隐藏后等待 DWM 动画（沿用） |
| `transitionDebounce` | 300ms | 显示器/DPI 变化去抖 |
| `hotkeyDebounce` | 300ms | 快捷键去抖（叠加 MOD_NOREPEAT） |
| `maxRetakes` | 3 | 每次截图流程最多重截次数 |

### 4.2 `WindowSnapshot`（快照结构）

```dart
class WindowSnapshot {
  final LoopWindowMode mode;   // normal | floating
  final Rect bounds;           // 逻辑像素，当前窗口 DPR 空间
  final Rect physicalBounds;   // Win32 物理像素（权威，用于恢复/截图对齐）
  final double dpr;            // 采集时窗口 DPR（Flutter view）
  final bool maximized;
  final bool alwaysOnTop;
  final Size minSize;          // 逻辑像素，最近一次应用值
  final bool pinned;           // 仅 floating 有意义
  final String? displayId;     // 例如 \\.\DISPLAY2（Win32）
  const WindowSnapshot({...});
  WindowSnapshot copyWith({...});
}
```

规则：

- 恢复优先 `physicalBounds`（`SetWindowPos`）；Win32 不可用时用 `bounds`（`windowManager.setBounds`）。
- `dpr/bounds/physicalBounds` 三者必须自洽（`physical ≈ bounds × dpr`，容差 2px）；不自洽时以物理矩形为准并记录一次日志。
- `Snapshot` 只在内存中保存，不落盘；应用重启从 `normal` 开始（浮窗形态不持久化）。
- 截图 session 内嵌**完整** `WindowSnapshot`，因此恢复包含 `mode/minSize/alwaysOnTop`。

### 4.3 纯几何规划（`FloatingWindowPlanner`，可单测）

```text
placeFloating(workPhysical, dpr, preferred, min, margin) -> Rect(logical)
  work = workPhysical / dpr
  availW = max(0, work.width  - 2*margin)
  availH = max(0, work.height - 2*margin)
  w = clamp(preferred.width,  min.width,  max(min.width,  availW))
  h = clamp(preferred.height, min.height, max(min.height, availH))
  x = clamp(work.right - margin - w, work.left + margin,
            max(work.left + margin, work.right - margin - w))
  y = clamp(work.top + (work.height - h)/2, work.top + margin,
            max(work.top + margin, work.bottom - margin - h))
  return Rect.fromLTWH(x, y, w, h)

chooseDisplay(displays, windowPhysicalRect) -> DisplayInfo?
  1) 含 windowPhysicalRect.center 的 workArea
  2) 与 windowPhysicalRect 交集面积最大
  3) isPrimary
  4) displays.first
  5) null（调用方主屏回退）
```

边界用例（必须单测）：

| 场景 | 工作区（物理） | dpr | 期望 |
|---|---|---|---|
| 1920×1080，任务栏 40 | (0,0,1920,1040) | 1.0 | 460×600 @ (1436,220) |
| 2560×1440@150% | (0,0,3840,2080) | 1.5 | 逻辑工作区 2560×1386.67；x=2076，垂直居中 |
| 小屏 800×500 | (0,0,800,500) | 1.0 | 460×452 @ (316,24)（高度受工作区限制） |
| 极小屏 300×300 | (0,0,300,300) | 1.0 | 360×420，x/y 钳到 margin（允许超出工作区，记录限制） |
| 左副屏 | (-1920,0,1920,1040) | 1.0 | 460×600 @ (-484,220) |
| 上副屏 | (0,-1080,1920,1040) | 1.0 | 460×600 @ (1436,-860)（负 Y 正确） |
| 窗口中心在副屏 | 双屏 | 任意 | `chooseDisplay` 返回副屏 |
| 窗口完全离屏 | 双屏 | 任意 | 主屏；`ensureGeometry` 回主屏居中 |
| DPI 缺失/0/NaN | 任意 | fallback | 使用 `systemScaleFactor()` 或 1.0 |

### 4.4 平台接口（实现契约）

```dart
// app/lib/desktop/window_mode.dart —— 纯 Dart，不 import Flutter 插件
enum LoopWindowMode { normal, floating }

class DisplayInfo {
  final String id;               // Win32 device name 或 screen_retriever id
  final Rect physicalBounds;
  final Rect physicalWorkArea;   // 已排除任务栏
  final double scaleFactor;
  final bool isPrimary;
}

class CaptureDisplay {
  final String id;
  final Rect physicalWorkArea;
  final double scaleFactor;
  final bool isPrimary;
}

abstract class FloatingModeHost implements Listenable {
  LoopWindowMode get mode;
  bool get isFloating;
  bool get pinned;
  bool get transitioning;
  bool get supported;
  WindowSnapshot? get normalSnapshot;
  WindowSnapshot? get lastFloatingSnapshot;
  Future<bool> enterFloating({bool focus = true});
  Future<bool> exitFloating({bool focus = true});
  Future<bool> toggleFloating({bool focus = true});
  Future<void> setPinned(bool value);
  Future<void> ensureGeometry();
  Future<WindowSnapshot> snapshot();
  Future<CaptureDisplay?> captureDisplay();
  Future<void> beginCaptureOverlay(CaptureDisplay display);
  Future<void> applySnapshot(WindowSnapshot snapshot, {bool focus = false});
}

abstract class WindowPlatform {           // io/stub 各自实现
  bool get supported;
  Future<WindowSnapshot> snapshot();
  Future<void> setMinimumSize(Size logical);
  Future<void> setAlwaysOnTop(bool value);
  Future<bool> isAlwaysOnTop();
  Future<void> setBoundsPhysical(Rect physical);
  Future<void> setBoundsLogical(Rect logical);
  Future<Rect> physicalRect();
  Future<double> dpr();
  Future<bool> isMaximized();
  Future<void> maximize();
  Future<void> unmaximize();
  Future<void> show();
  Future<void> hide();
  Future<bool> isVisible();
  Future<void> focus();
  Future<void> restore();
  Future<void> setResizable(bool value);
  Future<List<DisplayInfo>> displays();
  Future<String?> displayIdAt(Offset physicalPoint);
}
```

- `FloatingWindowController`（`desktop/floating_window.dart`，纯 Dart）实现 `FloatingModeHost`，构造参数含 `WindowPlatform` 与常量；单测时用 fake platform 即可覆盖完整状态机。
- `platform.snapshot()` 只返回可读的几何/最大化/置顶/dpr/displayId；`mode/minSize/pinned` 由 controller 组合进 `WindowSnapshot`（平台不知道 UI 形态）。
- `WindowController`（`desktop/window_controls_io.dart`）保留单例，新增 `late final FloatingWindowController floating`，平台实现 `_DesktopWindowPlatform`（`window_manager` + `win32_display.dart`）、`_StubWindowPlatform`（stub）。
- `FloatingQaScaffold`/`Shell` 只依赖 `FloatingModeHost`，测试注入 fake host（或真实 controller + `FakeWindowPlatform`）。
- `window_controls_stub.dart` 必须提供同签名：`supported=false`，`enter/exit` 返回 false，`mode=normal`。

### 4.5 置顶、最大化、拖动、缩放规则

| 行为 | normal | floating |
|---|---|---|
| 最大化 | 允许（标题栏按钮/双击） | **禁止**；`toggleMaximize` no-op；双击拖动栏 no-op |
| 置顶 | 不主动设置；恢复快照 | 默认 true；置顶按钮可切；退出恢复快照 |
| 拖动 | 标题栏 | 拖动栏空白区；按钮区域不拖动 |
| 缩放 | 8 热区；最小 900×600 | 8 热区；最小 360×420；可跨屏拖动 |
| 关闭 | 托盘隐藏或退出 | 同左 |
| 双击标题/拖动栏 | 最大化切换 | 无操作（不改变置顶/尺寸） |

### 4.6 Win32/DPI 说明

- `windowManager.getId()` 在 0.5.2 Windows 实现返回 HWND；`win32_display.dart` 用它调用 `GetWindowRect / SetWindowPos / MonitorFromPoint / GetMonitorInfo / GetDpiForMonitor`。
- 物理坐标约定：进程为 Per-Monitor-V2 DPI 感知（Flutter Windows 默认），Win32 与 PowerShell（`SetProcessDpiAwarenessContext(-4)`）均使用**物理像素**；截图矩形、覆盖窗口矩形必须完全一致（≤2px）。
- `window_manager` 的 `getBounds/setBounds/setMinimumSize` 使用**逻辑像素**（内部按 `devicePixelRatio` 换算）。浮窗定位优先用物理接口，保证跨混合 DPI 准确；失败时用逻辑接口并按当前 `dpr` 换算。
- 显示器变化：`screen_retriever.addListener` + `didChangeMetrics`；`ensureGeometry` 300ms 去抖、串行、不 focus。
- 已知限制（必须在 release 文档说明）：RDP/虚拟显示器、极端混合 DPI、Windows 10 无 DWM 圆角时，允许有 1–2px 视觉差异，但截图裁剪必须正确；若物理/逻辑不自洽则回退逻辑路径并记录。

### 4.7 失败与降级矩阵

| 失败点 | 处理 | 用户可见结果 |
|---|---|---|
| `setMinimumSize` 抛错 | 回滚快照，`enter` 返回 false | snack “切到浮窗失败，已恢复窗口” |
| `setBounds` 抛错/越界 | 重试一次 → 回滚 | 同上 |
| 显示器列表为空 | 主屏回退；再失败用当前屏幕逻辑尺寸 | 仍可进入浮窗 |
| 物理接口不可用 | 逻辑 fallback（按 dpr 换算） | 功能可用，日志记录 |
| 恢复普通窗口失败 | 默认 900×600 居中 | snack “恢复主窗口失败，已使用默认窗口” |
| 截图脚本失败 | 恢复浮窗快照 | snack “截图失败：…” |
| 快捷键注册失败/冲突 | 状态记录，按钮可用 | 一次性提示 + tooltip 状态 |
| 上传失败 | 不添加附件；恢复窗口 | snack 错误信息 |

---

## 5. 会话与状态保活契约

### 5.1 为什么不能用“重启加载历史”冒充保活

验收明确要求“切换不中断生成、返回同一问答”。重载历史只能证明持久化，不能证明：
- SSE `await for` 未被取消；
- `_attachments`（未发送附件）、`_runId`、`_approval` 未丢；
- `_sending` 状态仍在、停止可用；
- 无重复 `chat` 请求。

因此测试必须同时断言**同一 State 实例**与 **chatCalls==1**（见 §10.3 W-CHAT 用例）。

### 5.2 稳定结构（必须实现）

```dart
// Shell（t3）
FloatingModeHost get _host => widget.modeHost ?? WindowController.instance.floating;
final GlobalKey<ChatScreenState> _chatKey = GlobalKey<ChatScreenState>();
final GlobalKey _contentKey = GlobalKey();

// build（在 LayoutBuilder/MediaQuery 内取 size）
final floating = _host.isFloating;
final size = MediaQuery.sizeOf(context);
final compact = floating && (size.width < 420 || size.height < 520);
final screens = widget.screensOverride ?? [
  ChatScreen(key: _chatKey, active: floating || _index == 0, floating: floating,
      compact: compact, state: widget.state, screenshots: widget.screenshots),
  TodayScreen(active: !floating && _index == 1),
  NotesScreen(active: !floating && _index == 2),
  MaterialsScreen(active: !floating && _index == 3),
  AgentScreen(active: !floating && _index == 4),
  SettingsScreen(active: !floating && _index == 5),
];
return Stack(fit: StackFit.expand, children: [
  FloatingQaScaffold(
    floating: floating,
    compact: compact,
    chrome: floating
        ? FloatingBar(host: _host, title: _title, onClose: WindowController.instance.close)
        : TitleBar(pageTitle: ..., modeHost: _host),
    sidebar: floating ? const SizedBox.shrink() : _ResponsiveSidebar(...),
    content: IndexedStack(key: _contentKey, index: floating ? 0 : _index, children: screens),
  ),
  if (framed && !maximized) const Positioned.fill(child: WindowResizeHandles()),
]);
```

- `FloatingQaScaffold` 在两种形态下都是同一个 widget 类、同一个 `Column(chrome, Expanded(Row(sidebar, Expanded(content))))` 槽位；因此 `ChatScreen` 元素不会因浮窗而移动/重建。**它不是“只在浮窗出现的第二个壳”**；normal 模式的圆角/边框/Aurora/Stack 结构必须与现有 `main.dart:230-292` 逐项一致，浮窗仅改变 radius（16）、sidebar（shrink）、chrome（`FloatingBar`）与 `IndexedStack.index`。
- 替代方案（仅当 t3 证明等价时可用）：normal/floating 分别渲染，但 `ChatScreen` 使用同一个 `GlobalKey` 跨父级重挂；必须通过 W-SHELL-03/04、无重复绘制、无 GestureDetector 丢失焦点测试。默认采用稳定槽位方案。
- 浮窗时 `IndexedStack.index=0`；其余页仍常驻但不接收事件。
- 进入/退出时 Shell 仅在 host 通知后 `setState`；记录/恢复 `_index`（进入前页 → 退出恢复）。

### 5.3 测试可观测接口（t3 必须提供）

- `ChatScreenState` 公开类（重命名 `_ChatScreenState`），字段保持私有；新增：
  - `@visibleForTesting int? get conversationId`
  - `@visibleForTesting int get messageCount`
  - `@visibleForTesting int get attachmentCount`
  - `@visibleForTesting bool get isSending`
  - `@visibleForTesting bool get isGenerating`
  - `@visibleForTesting int? get runId`
  - `@visibleForTesting bool get approvalVisible`
- `ChatScreen` 构造新增：`floating=false`、`compact=false`、`ScreenshotService? screenshots`、`ValueListenable<ScreenshotRequest?>? screenshotSignal`。
- 信号（`desktop/floating_signals.dart`，t2 提供、t3 监听）：
  ```dart
  class ScreenshotRequest {
    const ScreenshotRequest({required this.hideLoop, required this.nonce});
    final bool hideLoop;   // true=隐藏 Loop 后截图；false=直接截图
    final int nonce;       // 每次请求自增，避免重复消费
  }
  final ValueNotifier<ScreenshotRequest?> screenshotRequestSignal = ValueNotifier(null);
  final ValueNotifier<bool> captureInProgress = ValueNotifier(false);
  ```
- `ScreenshotService` 抽象（`desktop/screenshot_service.dart`）：
  ```dart
  abstract class ScreenshotService {
    Future<ScreenshotSession?> start({required bool hideLoop});
    Future<void> restore(ScreenshotSession session);
  }
  class PlatformScreenshotService implements ScreenshotService { ... } // 调用 ScreenshotCapture
  ```
- Shell 测试接缝（生产也可用，默认 null）：`Shell({AppState? state, FloatingModeHost? modeHost, List<Widget>? screensOverride, ScreenshotService? screenshots})`。
- 测试 fake：
  - `test/support/fake_window_platform.dart`（t2）：实现 `WindowPlatform`，记录 `calls`、维护 `physicalRect/maximized/alwaysOnTop/minSize/displays/dpr`、`focusCount`、可注入延迟/异常。
  - `FakeLoopApi` 沿用 `test/streaming_chat_test.dart` 模式。

### 5.4 明确禁止的“伪保活”

- 切换时调用 `_bootstrap()`/`api.messages()`/重建 `ChatScreen`/切换 `key`。
- 新开 `Conversation` 或把当前会话置空。
- 用应用重启后加载历史充当“切换后状态保持”。
- 创建第二个 `ChatScreen`/第二个 `FlutterEngine`/第二个 `FlutterWindow`。
- 切换时取消 SSE 后重新发请求（会产生重复消息/计费）。

### 5.5 浮窗内的会话规则

- 浮窗内固定显示进入前的当前会话；不提供新建/切换历史（返回主窗口操作）。
- 生成中切换：允许；对话输入在浮窗可用；`_sending` 时发送变停止。
- 若生成过程中删除会话（主窗口侧栏操作）后再进入浮窗：沿用现有 `deletedConversationSignal` 行为，不新增特殊逻辑。

---

## 6. 浮窗 UI 规格

### 6.1 布局

```text
┌──────────────────────────────────────────────┐ 460×600
│ FloatingBar 44：⧉ Loop 回路 · 标题 · 浮窗  ⤢ 📌 ↩ ✕ │
├──────────────────────────────────────────────┤
│ 消息区（ListView，仅此处滚动）                    │
│  · 用户气泡 / 助手卡片 / 计划 / 步骤 / 审批         │
│  · 空态：欢迎（紧凑精简）                          │
│  · 流式：接近底部时跟随；上滚暂停 + “回到底部”      │
├──────────────────────────────────────────────┤
│ 输入区：附件/截图/输入/发送（生成中=停止）          │
└──────────────────────────────────────────────┘
```

- 浮窗内不渲染：主 `TitleBar`、侧栏、`ChatScreen` 页头（标题/模式/新对话/模型 chip）。
- `FloatingQaScaffold`（t3）是稳定布局壳：normal 与 floating 共用同一 widget 类与槽位；normal 视觉必须与 v0.4.0 完全一致，floating 仅调整 radius/侧栏/chrome/index。
- 消息区宽度约束沿用 `maxWidth 880`；紧凑模式 padding 12。
- 输入区固定底部，不被消息区覆盖；键盘 Enter/Shift+Enter 生效。

### 6.2 拖动栏（`FloatingBar`）

| 元素 | Key | Tooltip | 行为 |
|---|---|---|---|
| 拖动区（含标识/标题） | `floating-drag-area` | `拖动移动浮窗；双击不最大化` | `onPanStart → startDragging()`；双击 no-op |
| Loop 标识 | — | — | 渐变圆角 7 + `Icons.loop_rounded` |
| 标题 | — | — | 当前会话标题，省略号；紧凑时隐藏 |
| 截图 | `floating-screenshot` | `截图（Alt+A）· 默认隐藏 Loop 后截图` | 主点击：`ScreenshotRequest(hideLoop:true)`；次点击/右键菜单：`直接截图` |
| 置顶 | `floating-pin` | `置顶/取消置顶` | `host.setPinned(!pinned)`；图标实心/空心 |
| 返回主窗口 | `floating-back` | `返回主窗口 (Alt+Q)` | `host.exitFloating(focus:true)` |
| 关闭 | `floating-close` | `关闭` | `onClose`（Shell 注入 `WindowController.instance.close`；托盘则隐藏） |

- 栏高 44；紧凑 40；按钮 36×30（紧凑 32×28），间隔 2。
- 拖动区 `HitTestBehavior.opaque`，但按钮子节点优先命中；拖动期间不调用 `focus`。
- 截图按钮在 `_sending/_uploading` 时仍可点击，由 `ChatScreen` 统一提示“等这条回答结束再截图”（不静默丢失）；截图流程进行中（`_screenshotting`）禁用。
- 置顶按钮仅在 floating 出现；`pinned` 变化只调用 `setAlwaysOnTop`，不 focus。
- `FloatingBar` 不直接依赖窗口插件：返回/置顶走 `FloatingModeHost`，关闭走注入的 `onClose`，便于 widget 测试。

### 6.3 消息区

- 复用 `_messageView/_steps/_approvalCard/MarkdownText/ImagePreview`；不复制实现。
- 空态（紧凑）：36 渐变标识 + `今天想学点什么？` 18px + 单行说明；隐藏示例 chips；外层 `SingleChildScrollView`。
- 空态（标准 460×600）：可复用现有欢迎页，但去掉 30px 大标题/示例 chips 换行溢出风险（缩小到 20px、chips 最多 2 个或隐藏）。
- 错误：SSE error 移除助手气泡 + snack；上传失败 snack；未配置 Key 时发送失败提示（与主窗口一致）。
- 长回答：流式 `setState` 合批（建议 50ms）或仅在帧回调刷新；用户上滚时暂停自动跟随，显示 `回到底部`（key `chat-scroll-bottom`）胶囊；输入区不受滚动影响。
- 图片附件：tile 66（紧凑 54），点击预览；预览对话框紧凑适配（§6.5）。
- Markdown/公式/代码/表格：沿用现有组件；窄窗开启横向滚动（代码块已有；公式/表格补齐）。

### 6.4 输入区

- 附件区（截图/文件）、上传/截图进度条、输入框、发送/停止按钮沿用现有逻辑。
- 浮窗中**隐藏**输入区左侧“截图”菜单（改由拖动栏提供），保留附件按钮；主窗口保持两个入口。
- 输入框 hint 在紧凑模式缩短为“问点什么，或贴截图…”。
- `Enter` 发送、`Shift+Enter` 换行；IME 组合输入不被 Enter 误发送（沿用现有 `Focus.onKeyEvent`，需手工验证中文输入法）。
- 发送/停止按钮 38（紧凑 34），始终可见；`_sending` 时显示停止。

### 6.5 尺寸断点与折叠模式

| 尺寸 | 模式 | 要求 |
|---|---|---|
| 900×600 主窗口 | normal | 与 v0.4.0 一致（侧栏自动紧凑 <1080 已有） |
| 460×600 浮窗 | floating 标准 | 标题可见；消息区 ≥380 高；输入 ≥2 行 |
| 宽度 <420 或 高度 <520（含 360×420） | floating 紧凑 | 隐藏标题/模型 chip；消息区 padding 12；输入 hint 缩短 |
| 360×420（最小） | floating 紧凑 | 所有关键控件可见；欢迎页可滚动；图片预览 336×396 内；无溢出 |
| <360 宽 / <420 高 | 不允许（OS 最小尺寸拦截） | 若程序化设置更小，平台钳制并记录 |

折叠模式（P1 可选，不影响验收）：拖动栏右侧“收起”把浮窗折叠为高 46 的胶囊条；`v0.5.0` 不作为必选，若实现需另立任务，不得挤占上述必选验收。

> 术语澄清：任务中的“小窗口折叠模式”按**必选**解释为上述 `compact` 自适应（360×420 下全部关键控件可达、无溢出、输入常驻）；“折叠为迷你胶囊”是 P1 可选增强，不纳入 v0.5.0 验收。

### 6.6 主题、圆角、性能

- 不新增调色板键；使用 `pal.bgTop/windowBorder/glassFill/chip/accent/muted/ink` 等。
- 浮窗圆角 16、1px `pal.windowBorder`；DWM 圆角保持；无原生标题栏。
- `AuroraBackground` 保留；`resizing` 时沿用现有纯色降级（`glass.dart` 读取 `WindowController.instance.resizing`）。
- 拖动/缩放中不做重布局动画；消息区 `RepaintBoundary` 可选；流式合批降低重建。

### 6.7 Widget Keys（测试契约）

| Key | 所在 |
|---|---|
| `window-floating-toggle` | 主窗口 `TitleBar` 浮窗按钮 |
| `floating-bar` / `floating-drag-area` | `FloatingBar` 根/拖动区 |
| `floating-screenshot` / `floating-pin` / `floating-back` / `floating-close` | 浮窗按钮 |
| `floating-welcome` | 浮窗空态 |
| `chat-message-list` | 消息 ListView |
| `chat-composer` / `chat-input` / `chat-send-stop` | 输入区 |
| `chat-scroll-bottom` | 回到底部胶囊 |
| `screenshot-overlay` / `screenshot-cancel` / `screenshot-select-all` / `screenshot-retake` / `screenshot-done` | 截图覆盖层 |

---

## 7. 截图契约

### 7.1 端到端时序

```text
用户点击截图 / Alt+A
  └─ ChatScreen 检查：active、非 _sending/_uploading/_screenshotting、非 capturing
      ├─ captureInProgress=true；截图按钮禁用
      ├─ 读取当前 WindowSnapshot（含 mode/minSize/alwaysOnTop/bounds/displayId）
      ├─ 计算 CaptureDisplay（窗口中心所在显示器；主屏回退）
      ├─ hideLoop ? window.hide() + 280ms : 无
      ├─ PowerShell：-X/-Y/-W/-H（物理工作区）→ PNG bytes（≤20s 超时）
      ├─ 覆盖窗口：SetWindowPos 物理矩形（失败→logical）→ alwaysOnTop(true) → show+focus(1)
      ├─ ScreenshotOverlay：框选/全屏/取消/重截/完成（Esc=取消）
      ├─ restore(snapshot)：minSize/alwaysOnTop/maximized/bounds/mode 全恢复；ensureGeometry
      ├─ 取消/重截：不上传；重截则回到“计算显示/隐藏/捕获”（≤3 次）
      └─ 完成：裁切 PNG → api.upload → img_* → _attachments → 预览/发送
参数：hideLoop 默认 = 当前是否 floating；主窗口保持 v0.4.0 的菜单选择。
```

### 7.2 捕获显示器与 PowerShell 参数

- 目标显示器选择：`chooseDisplay(displays, windowPhysicalRect)`（§4.3），主屏回退。
- “display bounds”在本规格中取该显示器**工作区** `rcWork`（排除任务栏）：覆盖窗口、截图矩形、选框三者必须一致；这样任务栏不被遮住、坐标无歧义。若后续需要整屏捕获，另立任务扩展 `rcMonitor`，v0.5.0 不做。
- 传给脚本的矩形 = **显示器工作区物理像素**（排除任务栏），四舍五入为 int：
  `-X <left> -Y <top> -W <width> -H <height>`；负坐标合法。
- 覆盖窗口矩形必须与之一致（物理），保证截图 1:1 对齐。
- 若脚本输出尺寸 ≠ W×H：判为失败，恢复窗口并提示（不裁错误图）。

### 7.3 `assets/screenshot.ps1` 契约（v2）

```powershell
param(
  [Parameter(Mandatory=$true)][string]$Out,
  [int]$X, [int]$Y, [int]$W, [int]$H
)
```

- 若 `W/H` 缺失或 ≤0：回退 `[System.Windows.Forms.Screen]::PrimaryScreen.Bounds`（兼容旧调用）。
- DPI：优先 `SetProcessDpiAwarenessContext(-4)`（PER_MONITOR_AWARE_V2）；失败回退 `SetProcessDPIAware()`；再失败继续（记录）。
- 抓取：`Graphics.CopyFromScreen(Point(X,Y), Point.Empty, Size(W,H))`；输出 PNG；目录不存在则创建。
- 错误码：`0` 成功；`2` 参数非法；`3` 抓取失败；`4` 保存失败；stderr 输出简短原因。
- 安全：`-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden`，15–20s 超时；临时目录 `loop_shot_*` 用后删除。
- 不做：全屏/虚拟桌面拼接、OCR、上传、循环/定时截图。

### 7.4 `ScreenshotSession`（v2）与恢复

```dart
class ScreenshotSession {
  final Uint8List bytes;
  final WindowSnapshot snapshot;   // 截图前完整状态（mode/minSize/alwaysOnTop/...）
  final CaptureDisplay display;    // 捕获显示器（物理工作区/scale）
  final bool hidden;               // 是否 hideLoop
  final DateTime startedAt;
}
```

恢复顺序（`WindowController.floating.applySnapshot`）：
`setResizable(true)` → `setMinimumSize(snapshot.minSize)` → `setAlwaysOnTop(snapshot.alwaysOnTop)` → (`maximized ? maximize : setBoundsPhysical/Logical`) → `show()` →（`hidden` 时）`focus()` 一次 → `mode=snapshot.mode`（不变） → 读回校验一次。

- `restore` 必须幂等；重复调用不改变结果。
- 恢复后调用 `ensureGeometry()`，但不 focus。
- `applySnapshot` **不修改** `mode`；恢复后断言 `mode == snapshot.mode`。如果 `snapshot.mode==floating`，恢复后必须仍是浮窗（这是 FR-8 的核心回归）。

### 7.5 框选/取消/全屏/重截/完成

```dart
class ScreenshotOverlayResult {
  const ScreenshotOverlayResult.done(this.bytes) : retake = false;
  const ScreenshotOverlayResult.retake() : bytes = null, retake = true;
  final Uint8List? bytes;
  final bool retake;
}
// Navigator.pop: null=取消；done(bytes)=完成；retake=重截
```

- 覆盖层与窗口尺寸同宽高比；若图片宽高比与视口偏差 >1%，判失败并恢复（防止错误裁剪）。
- 拖拽选框 ≥4×4 才可完成；`完成` 裁切映射 `image.width/viewport.width`，输出 PNG。
- 取消：`Esc`、取消按钮、`Navigator.pop(null)`；不上传。
- 全屏：选择整屏。
- 重截：返回 `retake`；ChatScreen 先恢复窗口，再重新开始捕获（同一显示器、同一 hideLoop 设置）；最多 3 次。
- 覆盖层紧凑（<420 宽）：底部按钮不换行；提示文案缩短；`完成` 在无选择时禁用。

### 7.6 上传与多模态

- `POST /api/upload`，`Content-Type: application/octet-stream`，`X-Filename: 截图-<epoch>.png`。
- 成功响应 `{kind:'image', id:'img_<n>', name}`；`imageUrl(id)` → `/api/uploads/<n>`。
- 失败响应 4xx/5xx：不添加附件、snack 错误、窗口已恢复。
- 发送：`attachments` 数组包含 `img_*`；服务端 `/api/chat` 校验并落库 `attachments` 元数据；模型侧作为图片输入（v0.4.0 既有能力）。
- 不新增后端接口、不改数据库 schema。

### 7.7 隐私与安全

- 截图只在用户点击/按键后发生；**禁止** `Timer.periodic`、启动截图、切换形态截图、后台轮询屏幕。
- 不使用 `WH_KEYBOARD_LL`/按键记录；`RegisterHotKey` 只注册两个组合键。
- 截图字节不写日志、不写 `data/`（临时目录删除；上传文件只存用户确认的图片）。
- 取消/重截/失败不产生 upload；`uploads` 目录中不出现未确认图片。
- 临时脚本/PNG 清理在 `finally`；异常不吞掉用户提示。
- 测试隔离：验证使用 `LOOP_DATA_DIR` 临时目录 + 关闭用户实例；不得把测试截图写入用户 `data`。

### 7.8 性能预算

| 指标 | 目标 | 测量 |
|---|---|---|
| 点击/Alt+Q → 浮窗可见 | ≤300ms（p95） | 秒表/录屏 10 次 |
| 点击截图 → 覆盖层可框选 | ≤2.5s（p95，1920×1080@100%） | 秒表 10 次（含 280ms 隐藏） |
| 框选完成 → 附件出现 | ≤1.5s（p95） | 秒表 10 次 |
| 重截一轮 | ≤1.2s（p95） | 秒表 5 次 |
| 8600 字流式 | 输入/滚动可交互；无 >200ms 卡顿 | 手工 + 可选 Timeline |
| 10 次模式切换 | 内存增长 ≤50MB；无 listener/timer 泄漏 | 任务管理器/DevTools |

---

## 8. 快捷键与焦点契约

### 8.1 快捷键行为矩阵

| 快捷键 | 当前状态 | 行为 |
|---|---|---|
| `Alt+Q` | normal 可见 | 进入浮窗（focus 1 次） |
| `Alt+Q` | floating 可见 | 回主窗口（focus 1 次） |
| `Alt+Q` | 最小化 | `restore()+show()+focus()`；**不切模式** |
| `Alt+Q` | 隐藏到托盘 | `show()+focus()`；**不切模式** |
| `Alt+Q` | 正在切换/截图覆盖/启动未 ready | 忽略（无提示或一次性提示） |
| `Alt+A` | floating 可见且空闲 | 发起截图，`hideLoop=true` |
| `Alt+A` | normal 且对话页可见 | 发起截图，`hideLoop=false`（直接截图） |
| `Alt+A` | 非对话页/最小化/隐藏/覆盖层/发送中/上传中 | 忽略；不抢焦点、不自动显示、不采集 |
| 任意 | 注册冲突/不支持 | 按钮仍可用；tooltip 显示状态；一次性提示 |

### 8.2 原生实现契约（Windows runner）

```text
MethodChannel: 'loop/hotkeys'
Dart -> native:
  'register'   {} -> {'toggle': bool, 'screenshot': bool,
                      'errors': {'toggle': int?, 'screenshot': int?}}
  'unregister' {} -> bool
  'retry'      {} -> 同 register
native -> Dart:
  'hotkey'     int   // 1 = Alt+Q, 2 = Alt+A
```

- native：`FlutterWindow::OnCreate` 创建 channel；`register` 先 `UnregisterHotKey` 再 `RegisterHotKey(hwnd, id, MOD_ALT|MOD_NOREPEAT, VK)`；id `0x4C51/0x4C52`；`WM_HOTKEY` 在 `FlutterWindow::MessageHandler`（先让插件处理）中分发 `InvokeMethod('hotkey', id)`；`OnDestroy`/`unregister` 释放。
- 冲突：`RegisterHotKey` FALSE + `GetLastError()==1409` → 该键 `conflict`；其他错误 → `failed`；两键独立。
- Dart：`HotkeyService.instance.register({onToggle, onScreenshot})`、`unregister()`、`retry()`；`ValueNotifier<HotkeyStatus> status`；只回调信号，不直接截图/上传。
- 无第三方依赖；不引入 `hotkey_manager`（离线/构建风险）；禁止低层键盘钩子。
- 非 Windows/stub：`unsupported`；不注册；主窗口浮窗按钮隐藏。

### 8.3 状态与提示

- 状态枚举：`bothRegistered`、`toggleConflict`、`screenshotConflict`、`bothConflict`、`unsupported`、`failed`。
- 主窗口浮窗按钮 tooltip：正常 `浮窗答疑 (Alt+Q)`；冲突 `浮窗答疑（Alt+Q 被占用，可用按钮）`。
- 启动时若冲突/失败：**一次** snackbar（3s），不重复；后续可在 tooltip 查看。
- 不新增设置页 UI；不因快捷键失败阻止进入浮窗。

### 8.4 焦点策略

| 事件 | 是否允许窗口 `focus()` | 是否允许输入 `requestFocus()` |
|---|---|---|
| 应用启动/托盘显示 | 是（1 次） | 否（除非用户点击） |
| 用户切换 normal↔floating | 是（1 次） | 仅当进入浮窗前不在对话页且进入后输入本应聚焦：最多 1 次 |
| 点击输入框/示例 chip | 否（窗口已聚焦） | 是（用户动作） |
| 拖动/缩放 | 否 | 否 |
| SSE delta/step/plan/approval/done/cancelled/error | 否 | 否 |
| 滚动跟随/回到底部 | 否 | 否 |
| 显示器/DPI 校正 | 否 | 否 |
| 截图开始（hideLoop） | 隐藏前不 focus；覆盖层显示时 1 次 | 否 |
| 截图恢复 | ≤1 次 | 仅当截图前输入框有焦点：1 次 |
| 上传完成/附件添加 | 否 | 仅当截图前有焦点：1 次（同恢复合并） |

实现约束：
- `WindowController.show()` 不得再无条件 `focus()`；拆为 `show()` + `focusOnce()`；`focusOnce` 只在白名单调用（托盘“显示回路”显式 `show(focus:true)`）。
- `ScreenshotCapture` 的 focus 由 `applySnapshot(focus: hidden)` 控制，不在其他路径调用。
- `ChatScreen.didUpdateWidget` 的 `active false→true` 聚焦仅在**页签切换/首次从非对话页进入浮窗**发生一次；浮窗↔主窗口且一直在对话页时不得触发。

### 8.5 自动/手工验证

- fake platform `focusCount`：切换 1 次 +1；20 条 delta/拖动/`ensureGeometry` 不增；截图恢复 +1。
- `FocusManager.instance.primaryFocus` 在输入聚焦后 20 条 delta 不变。
- 手工：在记事本输入时 Alt+Q/Alt+A 后回到记事本继续输入不丢焦点（除用户意图的窗口切换）；拖动浮窗时输入法/键盘不被打断。

---

## 9. 后端/设置兼容

### 9.1 `stream_output`

| 设置 | 事件表现 | 浮窗要求 |
|---|---|---|
| `true`（默认） | 多次 `delta` 增量 | 逐字渲染，滚动跟随策略生效 |
| `false` | 等待期 `step/plan/approval` 实时；正文一次 `delta` | “正在思考…”可见；停止可用；完成后完整显示 |

- 后端请求级快照不变（`server.dart:304-305`）；运行中改开关只影响下一条（v0.4.0 契约）。
- 浮窗不读取/缓存开关；`ChatScreen` 不分支（由后端决定事件），仅渲染。

### 9.2 工具/计划/审批/停止/多轮

- 事件：`run/step/plan/approval/agent/token/done/error/cancelled`。
- 浮窗中 `AgentPlanCard`、步骤 chips、审批卡按现有 UI 渲染；窄窗可折叠/换行，不溢出。
- 审批 `approveRun(runId, allow)`、停止 `cancelRun(runId)` 不变。
- `done` 后 token/cost 展示（如空间不足可换行/隐藏 cost，不丢 token）。

### 9.3 上传/附件/多模态

- `upload()` 响应契约：`kind=image` + `id=img_<n>`；`imageUrl` 支持 `img_` 前缀。
- 附件元数据 `AttachmentItem(id,name,isImage)` 随消息落库；重载历史仍显示图片/文件。
- 浮窗发送与主窗口完全同一路径（`_send`），不新增 API。

### 9.4 数据库/HTTP API

- **无 schema 变更、无新 endpoint、无非 Windows 兼容层**。
- `settings` 仍只有现有字段；不持久化浮窗几何/形态（避免迁移风险）。
- 托盘、后台任务、自动更新、MCP、Agent 均不感知浮窗。

### 9.5 Web/非 Windows 降级

- `window_controls_stub.dart`：`supported=false`；`enter/exit` 返回 false；Shell 保持 normal；主窗口浮窗按钮隐藏；`Alt+Q/Alt+A` 不注册。
- `screenshot_capture_stub.dart`：返回 null（现有提示“截图仅支持 Windows 桌面版”）。
- 现有 Web 构建/测试不得因新增接口编译失败。

---

## 10. 验收与测试矩阵

### 10.1 分层

1. **纯单测**：几何规划、快照、状态机、快捷键状态映射、脚本参数、上传响应解析。
2. **Widget 测试**：`Shell`/`FloatingQaScaffold`/`FloatingBar`/`ChatScreen`/`ScreenshotOverlay`，使用 `FakeWindowPlatform` + `FakeLoopApi` + fake `ScreenshotService`。
3. **真实 Windows 手工**：窗口/快捷键/多显示器/DPI/焦点/截图视觉。
4. **端到端**：正式构建 + 隔离数据 + mock LLM（复用 `docs/streaming-evidence/tools/mock_llm.py`）。
5. **评审**：t5 对抗性检查（只读）。

### 10.2 FR → 测试映射

| FR | 自动测试（文件/用例 ID） | 手工验收 | 判定 |
|---|---|---|---|
| FR-1 | `floating_window_test.dart` U-WM-01/02/03；静态命令 | M-01/02 | AC-1.1~1.4 |
| FR-2 | U-WM-04~08（快照/幂等/最大化/失败回滚） | M-03/04/05 | AC-2.1~2.4 |
| FR-3 | `display_geometry_test.dart` U-GEO-01~08；U-WM-09/10 | M-06/07/08 | AC-3.1~3.5 |
| FR-4 | U-GEO-09~14；U-WM-11（显示器变化 fake） | M-09~M-14 | AC-4.1~4.6 |
| FR-5 | `floating_layout_test.dart` W-UI-01~04 | M-15/16 | AC-5.1~5.4 |
| FR-6 | `floating_shell_test.dart` W-SHELL-01~05；`floating_chat_test.dart` W-CHAT-01~05 | M-17/18/19 | AC-6.1~6.5 |
| FR-7 | W-UI-02/07/08/09/10；W-CHAT-06~08；markdown/image_preview 窄窗用例 | M-20~M-24 | AC-7.1~7.5 |
| FR-8 | `screenshot_capture_test.dart` U-CAP-01~05（参数/选择/恢复） | M-25/26/27/30/31 | AC-8.1~8.6 |
| FR-9 | `screenshot_flow_test.dart` W-SHOT-01~07 | M-28/29/32 | AC-9.1~9.4 |
| FR-10 | `hotkey_status_test.dart` U-HK-01~05；静态检查 | M-33~M-35 | AC-10.1~10.5 |
| FR-11 | W-FOCUS-01~03（fake focusCount / primaryFocus） | M-36/37 | AC-11.1~11.4 |
| FR-12 | 复用 streaming F6/F7/F8/F9/F10 + W-CHAT-09/10 | M-38~M-41 | AC-12.1~12.4 |
| FR-13 | W-UI-02/06/07/11（主题/尺寸/切换）；既有 37 测试 | M-42~M-46 | AC-13.1~13.4 |
| FR-14 | 静态检查；性能手工；隐私手工 | M-47~M-50 | AC-14.1~14.4 |
| FR-15 | 命令/构建/证据 | M-51 | AC-15.1~15.4 |

### 10.3 自动测试清单（建议命名）

**t2（`app/test/`）**
- `display_geometry_test.dart`
  - U-GEO-01 1920×1040@1 → (1436,220,460,600)
  - U-GEO-02 2560×1386.67 逻辑@1.5 → 尺寸/位置合法
  - U-GEO-03 800×500 小屏 → 460×452，不越界
  - U-GEO-04 300×300 极小屏 → 保持 360×420（记录限制）
  - U-GEO-05 左/上负坐标副屏
  - U-GEO-06 chooseDisplay：中心命中/交集最大/主屏回退/空列表
  - U-GEO-07 clamp 离屏普通窗口 → 主屏居中
  - U-GEO-08 dpr 缺失/0/NaN → 1.0 回退
- `floating_window_test.dart`（真实 `FloatingWindowController` + FakeWindowPlatform）
  - U-WM-01 enter：快照保存、unmaximize、minSize 360×420、置顶、尺寸/位置
  - U-WM-02 exit：minSize 900×600、置顶恢复、bounds/maximized 恢复
  - U-WM-03 幂等/并发：重复 enter/exit、transitioning 忽略
  - U-WM-04 最大化进入与退出恢复最大化
  - U-WM-05 平台异常回滚与提示回调一次
  - U-WM-06 focusCount：每次用户切换 +1，ensureGeometry/setPinned 不增
  - U-WM-07 10 次切换无漂移
  - U-WM-08 截图快照恢复 mode/minSize/alwaysOnTop
  - U-WM-09 上次浮窗尺寸记忆
  - U-WM-10 captureInProgress 时禁止切换
  - U-WM-11 显示器移除/DPI 变化 → ensureGeometry 钳制、不 focus、不改 mode
- `hotkey_status_test.dart`
  - U-HK-01 原生成功映射 bothRegistered
  - U-HK-02 单键 1409 → toggleConflict/screenshotConflict
  - U-HK-03 unsupported（stub/非 Windows）
  - U-HK-04 500ms 内重复事件只回调一次（去抖）
  - U-HK-05 unregister 后事件不再回调
- `screenshot_capture_test.dart`
  - U-CAP-01 参数：物理工作区 → `-X/-Y/-W/-H`（含负数）
  - U-CAP-02 脚本缺参回退主屏（脚本级 PowerShell 测试，可选）
  - U-CAP-03 start 失败 → restore 一次
  - U-CAP-04 restore 快照含 mode/floating minSize/alwaysOnTop
  - U-CAP-05 图片宽高比偏差 >1% 判失败
- `test/support/fake_window_platform.dart`（t2 提供；t3 复用）

**t3（`app/test/`）**
- `floating_shell_test.dart`
  - W-SHELL-01 点击 `window-floating-toggle` → 浮窗 UI（bar/无侧栏/无页头）
  - W-SHELL-02 返回 → 主窗口 UI 恢复，原页签恢复
  - W-SHELL-03 ChatScreen State `identical` across toggle（GlobalKey）
  - W-SHELL-04 `find.byType(ChatScreen)` 始终 1
  - W-SHELL-05 host 失败（返回 false）→ 保持 normal + 提示
- `floating_chat_test.dart`（`FakeLoopApi` + fake screenshots）
  - W-CHAT-01 发送后切换浮窗：消息仍在，chatCalls==1
  - W-CHAT-02 流式中切换 2 次：delta 继续、done 完整、无重复
  - W-CHAT-03 停止在浮窗可用，cancelRun 一次
  - W-CHAT-04 附件（fake upload）切换后仍在
  - W-CHAT-05 返回主窗口同一回答（文本一致）
  - W-CHAT-06 360×420 空态/长文/附件无溢出
  - W-CHAT-07 上滚不被拉回；回到底部可用
  - W-CHAT-08 图片附件预览在 360×420 不溢出
  - W-CHAT-09 stream_output on/off 在浮窗形态下与 F6/F7 一致
  - W-CHAT-10 approval 在浮窗可允许/拒绝
- `floating_layout_test.dart`
  - W-UI-01 460×600 bar 元素/key 齐全
  - W-UI-02 360×420 紧凑：标题隐藏、按钮可见、无溢出
  - W-UI-03 置顶按钮调用 setPinned；返回调用 exitFloating
  - W-UI-04 截图按钮发送 `ScreenshotRequest(hideLoop:true)`；次级菜单 false
  - W-UI-05 拖动区 pan → startDragging；双击不 toggleMaximize
  - W-UI-06 亮/暗主题（palette 颜色断言）
  - W-UI-07 900×600 主窗口布局不变（快照/关键点）
  - W-UI-08 页脚/输入在紧凑模式隐藏/缩小
  - W-UI-09 长公式/宽表格无溢出（`MarkdownText` 窄宽）
  - W-UI-10 图片预览 360×420 尺寸受限
  - W-UI-11 切换 10 次无异常/无泄漏（listener 计数可选）
  - W-UI-12 浮窗关闭按钮调用 close（fake）
- `screenshot_flow_test.dart`（fake `ScreenshotService` + fake api）
  - W-SHOT-01 浮窗截图默认 hideLoop=true
  - W-SHOT-02 完成 → upload 一次 → img_ 附件出现
  - W-SHOT-03 取消 → 无 upload、无附件、restore 一次
  - W-SHOT-04 重截 → start 两次、restore 两次、最终完成上传一次
  - W-SHOT-05 重截 4 次触发上限提示
  - W-SHOT-06 上传失败 → 无附件、snack、restore 一次
  - W-SHOT-07 恢复保持浮窗：fake service 的 session.snapshot.mode==floating、minSize 360×420、alwaysOnTop true
- `focus` 用例（可并入 W-SHELL/W-CHAT）
  - W-FOCUS-01 输入聚焦后 20 条 delta primaryFocus 不变
  - W-FOCUS-02 切换浮窗/返回：fake focusCount 每次 +1
  - W-FOCUS-03 截图恢复：hidden 时 +1，不 hidden 时 +0

### 10.4 手工验收清单（Windows 正式版）

> 使用隔离数据目录（§10.7），关闭用户实例；每项记录 PASS/FAIL + 证据。

| ID | 步骤 | 期望 |
|---|---|---|
| M-01 | 主窗口点“浮窗答疑” | 460×600 浮窗、置顶、无原生标题栏、无侧栏 |
| M-02 | Alt+Q 两次 | 回主窗口（原 bounds）→ 再回浮窗；仅 1 个 Loop 进程/窗口 |
| M-03 | 最大化后进入浮窗→返回 | 浮窗非最大化；返回恢复最大化 |
| M-04 | 记录普通 bounds → 进出 5 次 | bounds/maximized 恢复 ≤2px、无漂移 |
| M-05 | 浮窗关闭→托盘“显示回路” | 仍为浮窗、置顶、位置不变 |
| M-06 | 拖动浮窗到副屏再 Alt+Q 返回 | 主窗口回到原显示器位置 |
| M-07 | 拖动栏拖动/四边四角缩放 | 可移动/缩放；不能小于 360×420；双击不最大化 |
| M-08 | 浮窗拖到屏幕边缘 | 保持可见，位置在工作区内 |
| M-09 | 副屏进入浮窗并截图 | 浮窗在副屏；截图捕获副屏 |
| M-10 | 禁用浮窗所在副屏 | ≤2s 回主屏、仍浮窗、可交互 |
| M-11 | 100%→125%→150% 缩放（含跨屏拖动） | 窗口可见/可缩放；截图裁剪正确 |
| M-12 | 副屏在左/上（负坐标） | 定位/截图正确 |
| M-13 | 任务栏改左/上 | 浮窗不压任务栏、工作区定位正确 |
| M-14 | 拔插显示器后重启应用 | 默认正常窗口；进入浮窗正常 |
| M-15 | 亮/暗主题切换 | 浮窗 UI 正常、可读 |
| M-16 | 浮窗按钮 tooltip | 含 Alt+Q/Alt+A；状态正确 |
| M-17 | 发送慢速回答，生成中 Alt+Q 两次 | 回答不中断、无重复、最终完整 |
| M-18 | 生成中返回主窗口 | 同一会话、同一回答、输入/停止状态一致 |
| M-19 | 浮窗中停止 | 立即停止、正文保留、提示 |
| M-20 | 浮窗输入中文（IME）Enter/Shift+Enter | 不误发送、换行正确 |
| M-21 | 360×420 空态 | 欢迎页无溢出、可滚动 |
| M-22 | 360×420 长回答（8000+ 字） | 仅消息区滚动、输入常驻、上滚不被拉回 |
| M-23 | Markdown/公式/代码块/表格 | 渲染正常、窄窗不溢出、可横向滚动 |
| M-24 | 图片附件预览 | 360×420 内完整显示、可关闭 |
| M-25 | 浮窗点截图（默认） | Loop 隐藏后截图；覆盖窗口与显示器对齐 |
| M-26 | 直接截图（次级菜单） | Loop 出现在截图中 |
| M-27 | 截图后取消/Esc | 回浮窗（置顶/尺寸不变）、无附件 |
| M-28 | 截图完成 → 附件 | PNG 正确、img_ 附件、可预览/发送 |
| M-29 | 截图重截 3 次 | 每次回浮窗再重截；第 4 次提示上限 |
| M-30 | 截图恢复后置顶/尺寸 | 置顶仍 true、minSize 360×420、bounds 不变 |
| M-31 | 截图失败（禁用显示器/脚本错误） | 提示失败、窗口恢复、不隐藏 |
| M-32 | 截图上传失败（停后端） | 提示、无附件、窗口恢复 |
| M-33 | Alt+Q（焦点在记事本） | 切换浮窗；记事本不崩溃 |
| M-34 | 第二程序占用 Alt+Q | 冲突提示一次、按钮可用、Alt+A 可用 |
| M-35 | 退出应用后按 Alt+Q/Alt+A | 无效（热键已注销） |
| M-36 | 拖动浮窗/流式输出时观察焦点 | 不抢焦点、输入不丢 |
| M-37 | 截图前聚焦输入→完成→继续输入 | 输入框恢复焦点一次、可继续输入 |
| M-38 | 关闭流式开关后在浮窗提问 | 等待完整回复后一次显示；工具/审批实时 |
| M-39 | 开启流式后在浮窗提问 | 逐字显示、可上滚 |
| M-40 | 浮窗审批允许/拒绝 | 行为与主窗口一致 |
| M-41 | 截图附件发送 | 模型收到图片、回答正常 |
| M-42 | 900×600 主窗口六页 | 布局/功能与 v0.4.0 一致（除新按钮） |
| M-43 | 主窗口最大化/还原/缩放 | 正常、无回归 |
| M-44 | 亮/暗 + 主窗口 900×600 | 正常 |
| M-45 | 历史对话/附件重载 | 正常 |
| M-46 | 侧栏折叠/自动紧凑 | 正常 |
| M-47 | 空闲 60s 观察进程 | 无 powershell 截图子进程/临时目录 |
| M-48 | 10 次截图计时 | p95 ≤2.5s |
| M-49 | 10 次切换计时 | p95 ≤300ms |
| M-50 | 10 次切换内存 | 增长 ≤50MB |
| M-51 | 构建/版本/tag/Release | §12 契约 |

### 10.5 多显示器 / DPI 测试矩阵

| ID | 配置 | 重点 |
|---|---|---|
| D1 | 单屏 1920×1080@100% | 基准：定位/截图/恢复 |
| D2 | 单屏 2560×1440@150% | DPI 换算、最小尺寸、裁剪像素 |
| D3 | 双屏同 DPI（左右） | 中心选屏、跨屏拖动、截图目标屏 |
| D4 | 双屏混合 DPI（主 150% + 副 100%，副屏在右） | 物理/逻辑换算、截图对齐 |
| D5 | 副屏在主屏左侧（负 X） | 负坐标定位/截图参数 |
| D6 | 副屏在主屏上方（负 Y） | 负坐标定位/截图参数 |
| D7 | 任务栏在左/上 | 工作区（rcWork）扣除 |
| D8 | 浮窗所在屏被禁用/拔出 | 回主屏、保持浮窗、不崩溃 |
| D9 | 浮窗中改分辨率（1920→1366） | 钳制、可交互 |
| D10 | RDP/远程会话 | 允许记录为“不适用”，不得伪报通过 |
| D11 | 最小浮窗 360×420@100%/150% | 无溢出、可缩放 |
| D12 | 单屏（无法物理多屏） | 用 U-GEO 单测覆盖坐标逻辑，报告限制 |

### 10.6 隐私与性能验收

- 隐私：空闲 60s 无截图子进程/临时目录；无 `Timer.periodic` 截图；取消/重截无 upload；日志无图像；临时文件清理。
- 性能：按 §7.8 表格计时并记录 p95；长文流式交互手工验证。
- 静态检查：
  ```powershell
  # 禁止 setFullScreen（应无输出）
  Get-ChildItem app\lib,app\test,app\windows\runner -Recurse -File -Include *.dart,*.cpp,*.h |
    Select-String -Pattern 'setFullScreen'
  # 第二引擎/第二入口（runApp 应为 1，FlutterEngine 应为 0）
  Get-ChildItem app\lib -Recurse -Filter *.dart | Select-String -Pattern 'runApp\('
  Get-ChildItem app\lib -Recurse -Filter *.dart | Select-String -Pattern 'FlutterEngine'
  # 浮窗/截图文件不得有周期定时器/低层键盘钩子
  Get-ChildItem app\lib\desktop -Recurse -Filter *.dart | Select-String -Pattern 'Timer\.periodic|WH_KEYBOARD_LL'
  ```

### 10.7 命令（Windows PowerShell，仓库根目录开始）

```powershell
# 0) 前置：关闭用户正在运行的 Loop；确认 8765 空闲（避免新实例静默复用旧后端）
Get-Process Loop -ErrorAction SilentlyContinue
Get-NetTCPConnection -LocalPort 8765 -ErrorAction SilentlyContinue

# 1) 静态检查 + 全量测试（app 目录）
cd D:\DSH_Workspace\Prog2_app\app
..\.tools\flutter\bin\flutter.bat analyze
..\.tools\flutter\bin\flutter.bat test

# 2) 只跑新增用例
..\.tools\flutter\bin\flutter.bat test test\display_geometry_test.dart test\floating_window_test.dart test\hotkey_status_test.dart test\floating_shell_test.dart test\floating_chat_test.dart test\floating_layout_test.dart test\screenshot_flow_test.dart

# 3) 脚本独立验证（不依赖 UI；参数为物理像素，负坐标亦可）
$shot = Join-Path $env:TEMP 'loop-shot-test.png'
powershell -NoProfile -ExecutionPolicy Bypass -File ..\app\assets\screenshot.ps1 -Out $shot -X 0 -Y 0 -W 800 -H 600
Add-Type -AssemblyName System.Drawing
$img = [System.Drawing.Image]::FromFile($shot); "PNG: $($img.Width)x$($img.Height)"; $img.Dispose(); Remove-Item $shot -Force

# 4) 隔离数据目录（AppPaths 只有候选目录已存在 loop.db 才选 LOOP_DATA_DIR）
$env:LOOP_DATA_DIR = Join-Path $env:TEMP 'loop-v050-floating\data'
New-Item -ItemType Directory -Force (Split-Path $env:LOOP_DATA_DIR) | Out-Null
New-Item -ItemType File -Force (Join-Path $env:LOOP_DATA_DIR 'loop.db') | Out-Null

# 5) mock LLM（长回复/慢速/工具/审批），新开一个 PowerShell 窗口
python D:\DSH_Workspace\Prog2_app\docs\streaming-evidence\tools\mock_llm.py

# 6) 在“步骤 4 的同一个会话”里启动正式构建（Start-Process 继承当前会话环境变量）
Start-Process -FilePath 'D:\DSH_Workspace\Prog2_app\release\Loop-Desktop\Loop.exe'

# 6b) 等 /api/health 就绪后，把模型指向 mock 并设置流式开关
$base = 'http://127.0.0.1:8765'
for ($i = 0; $i -lt 60; $i++) {
  try { $health = Invoke-RestMethod -Uri "$base/api/health" -TimeoutSec 2; break }
  catch { Start-Sleep -Milliseconds 500 }
}
$health | ConvertTo-Json -Compress
Invoke-RestMethod -Method Put -Uri "$base/api/settings" -ContentType 'application/json' `
  -Body '{"api_key":"test-key","base_url":"http://127.0.0.1:9999","model":"mock"}'
# 流式开/关切换（验证浮窗两种模式）
Invoke-RestMethod -Method Put -Uri "$base/api/settings" -ContentType 'application/json' -Body '{"stream_output":true}'
Invoke-RestMethod -Method Put -Uri "$base/api/settings" -ContentType 'application/json' -Body '{"stream_output":false}'

# 7) 构建/产物（t6）
cd D:\DSH_Workspace\Prog2_app
powershell -ExecutionPolicy Bypass -File packaging\build_native.ps1
Get-Content release\Loop-Desktop\version.json
(Get-Item release\Loop-Desktop\Loop.exe).VersionInfo.FileVersion
(Get-FileHash release\Loop-Desktop-win64.zip -Algorithm SHA256).Hash

# 8) 提交/推送/tag（不创建 GitHub Release）
git status --short
git add <t1/t2/t3/t6 允许文件>
git commit -m "feat: 桌面答疑悬浮窗 (v0.5.0)"
git tag -a v0.5.0 -m "Loop v0.5.0 桌面答疑悬浮窗"
git push origin main
git push origin v0.5.0

# 9) Loop-Test 未修改（输出应为空；时间以任务开始为准）
Get-ChildItem D:\DSH_Workspace\Loop-Test -Recurse -File -ErrorAction SilentlyContinue |
  Where-Object { $_.LastWriteTime -gt (Get-Date '2026-10-24T16:00:00') } |
  Select-Object FullName, LastWriteTime
```

### 10.8 证据产物

| 产物 | 归属 | 内容 |
|---|---|---|
| `docs/floating-qa-test-report.md` | t4 | 自动/手工/E2E 逐项 PASS/FAIL、限制说明、命令输出摘要 |
| `docs/floating-evidence/` | t4 | 日志、计时、多屏/DPI 截图、隔离数据路径、清理记录 |
| `docs/screenshots/floating-*.png` | t4 | 460×600/360×420/亮暗/截图/预览 |
| `docs/release-v0.5.0.md` | t6 | 功能/兼容/验证/产物 SHA/升级说明 |
| `docs/floating-evidence/v050-build-evidence.md` | t6 | 构建日志、版本/大小/SHA、隔离冒烟、推送/tag 证据、Release 未创建 |

---

## 11. 文件归属与并行协作

### 11.1 所有权（避免冲突）

| 成员 | 只允许修改/新增 | 只读依赖 | 禁止 |
|---|---|---|---|
| **t1 floating-architect** | `docs/floating-qa-spec.md`（本文件） | 全仓只读 | 任何实现/测试/团队状态文件 |
| **t2 floating-windows** | `app/lib/desktop/window_mode.dart`(新)、`floating_window.dart`(新)、`win32_display.dart`(新)、`screenshot_service.dart`(新)、`floating_signals.dart`(新)、`hotkeys.dart`/`hotkeys_io.dart`/`hotkeys_stub.dart`(新)、`window_controls_io.dart`、`window_controls_stub.dart`、`screenshot_capture_io.dart`、`screenshot_capture_stub.dart`、`screenshot_types.dart`、`app/assets/screenshot.ps1`、`app/windows/runner/flutter_window.{h,cpp}`、`app/test/support/fake_window_platform.dart`、`app/test/{display_geometry,floating_window,hotkey_status,screenshot_capture}_test.dart` | `main.dart`、`chat_screen.dart`、`screenshot_overlay.dart`、`pubspec.yaml` | `main.dart`、`ChatScreen`、`FloatingBar/Scaffold`、`pubspec`、`server.dart`、Loop-Test |
| **t3 floating-frontend** | `app/lib/main.dart`、`app/lib/widgets/title_bar.dart`、`app/lib/widgets/floating_bar.dart`(新)、`floating_qa_scaffold.dart`(新)、`app/lib/screens/chat_screen.dart`、`screenshot_overlay.dart`、`app/lib/widgets/image_preview.dart`、`markdown_text.dart`、`app/test/{floating_shell,floating_chat,floating_layout,screenshot_flow}_test.dart` | t2 的接口文件、`models.dart`、`api.dart`、`state.dart` | `app/lib/desktop/**`、`screenshot.ps1`、runner、pubspec、server、Loop-Test |
| **t4 floating-verifier** | `docs/floating-qa-test-report.md`、`docs/floating-evidence/**`、`docs/screenshots/floating-*.png` | 全部 | 生产代码/测试源码（发现问题交 captain 建修复）、release、用户 data |
| **t5 floating-reviewer** | 无文件（只读评审，结论写任务输出） | 全部 | 代码/测试/文档/Loop-Test |
| **t6 floating-verifier** | `app/pubspec.yaml`、`app/lib/update/app_version.dart`、`README.md`、`docs/release-v0.5.0.md`、`docs/floating-evidence/v050-build-evidence.md`、`release/**`（构建产物，gitignore）；**提交但不改内容**：`docs/floating-qa-spec.md`（t1）、`docs/floating-qa-test-report.md` 与 `docs/floating-evidence/**`（t4） | 其余只读 | 测试报告归属 t4；不创建 GitHub Release；不改他人文档内容 |

### 11.2 接口冻结与变更流程

- 本文件 §4.2/4.4/7.4/8.2 是冻结接口（类型、字段、语义）。t2 实现可增补私有成员，但不得改语义；如确需改签名，**先** `agent_teams_send_message` 通知 t3 + captain，并在提交信息中说明。
- t2 必须尽早（建议先于 UI 工作）提交接口骨架（`window_mode.dart` + stub 实现 + `fake_window_platform.dart`），保证 t3 能编译并行开发；t3 在骨架落地前只写不依赖新文件的 UI 草稿。
- 任何一方不得重复定义 `FloatingModeHost/WindowSnapshot/ScreenshotSession/ScreenshotRequest`。
- 共用文件只允许 t3 改（`main.dart/chat_screen.dart/screenshot_overlay.dart`）；t2 需要挂钩时通过接口完成，不改这些文件。
- 同一文件同一时刻只允许一个 owner 改动；发现他人未提交改动先沟通。

### 11.3 禁止修改清单

- `D:\DSH_Workspace\Loop-Test`（任何文件）。
- `.agent-teams/`（团队状态，只能通过工具）。
- 用户数据 `data/`（验证只用 `LOOP_DATA_DIR` 临时目录；不得打开用户 `data/loop.db`）。
- 后端 `app/lib/backend/server.dart`、`agent.dart`、`db.dart`、`llm.dart`（本版本不需要改动）。
- `app/lib/state.dart`、`models.dart`、`api.dart`（无新字段/接口）。
- `app/lib/screens/settings_screen.dart`（不改设置 UI；快捷键状态通过 tooltip/一次性提示）。
- `app/pubspec.yaml` 仅在 t6 版本提升时改；**不新增依赖**。
- 不提交 `release/`、`data/`、`app/build/`、`.tools/`、`.agent-teams/`。

### 11.4 提交/推送与冲突规则

- 只 `git add` 自己归属的文件；禁止 `git add -A`。
- t2 与 t3 在并行阶段各自 commit；建议顺序：t2 骨架提交 → t3 UI 提交 → t2 截图/热键完善提交；由 captain 协调，避免同一工作树互相覆盖。
- t1 不提交本文件；由 t6 在最终提交中纳入 `docs/floating-qa-spec.md`（只提交不改内容）。
- 提交前必须跑 `flutter analyze`；涉及测试的提交跑对应测试。
- t6 只做最终提交/tag/推送；不创建 GitHub Release；t4 的报告/证据由 t6 一并提交。

### 11.5 合并顺序（逻辑）

```text
t1 spec
  └─ t2 接口骨架 + 窗口/截图/热键实现
       ├─ t3 UI/保活/截图闭环（依赖 t2 接口）
       └─ t2 测试补齐
            └─ t4 验证（读代码 + 真实窗口 + E2E）
                 └─ t5 评审
                      └─ t6 版本/构建/推送 tag
```

---

## 12. 发布契约（v0.5.0）

### 12.1 版本与文案

| 项 | 变化 |
|---|---|
| `app/pubspec.yaml` | `version: 0.4.0+13` → `0.5.0+14` |
| `app/lib/update/app_version.dart` | `AppVersion.current = '0.4.0'` → `'0.5.0'` |
| `README.md` | 当前版本 v0.5.0；新增“答疑浮窗”功能与 v0.5.0 改动；文档链接 |
| `docs/release-v0.5.0.md` | 新增；含功能、兼容、验证、产物、升级、已知限制 |
| `docs/floating-qa-spec.md` | 本文件（t1）；t6 可引用但不再改语义 |

### 12.2 构建

```powershell
cd D:\DSH_Workspace\Prog2_app
powershell -ExecutionPolicy Bypass -File packaging\build_native.ps1
```

- 仅在**无用户 Loop 实例运行**时覆盖 `release/`；否则用 staging 并把最终替换交维护者。
- 产物：`release/Loop-Desktop/Loop.exe`、`version.json`、`release/Loop-Desktop-win64.zip`。
- 校验：`version.json={"version":"0.5.0"}`、`Loop.exe FileVersion=0.5.0+14`、zip SHA-256、zip 内文件齐全。
- 构建后隔离冒烟：`/api/health` 返回 `version=0.5.0`；新库 `stream_output=true`；mock LLM 单/多 delta；重启持久化。

### 12.3 提交与 tag

```powershell
git add <允许文件>
git commit -m "feat: 桌面答疑悬浮窗 (v0.5.0)"
git tag -a v0.5.0 -m "Loop v0.5.0 桌面答疑悬浮窗"
git push origin main
git push origin v0.5.0
```

- **不自动创建 GitHub Release**；ZIP 由维护者手动上传。
- 自动更新读取 GitHub latest Release；在维护者发布 v0.5.0 Release 前，客户端不会收到 v0.5.0 更新提示（release 文档注明）。
- tag 命名沿用 `v0.5.0`（与既有 v0.4.0 一致）。

### 12.4 回滚

- 代码回滚：`git revert` 浮窗相关提交；tag 删除需维护者确认。
- 运行时回滚：无数据库/设置迁移，旧版本可直接读取数据；浮窗几何不落盘，回滚无残留。
- 若原生热键通道导致构建问题：回滚 runner 改动并要求按钮可用；不得以“仅应用内快捷键”冒充全局快捷键（需评审/队长批准并写入限制）。

---

## 13. 风险与开放问题

| ID | 风险 | 缓解/验收 |
|---|---|---|
| R1 | Windows runner 原生热键改动导致构建失败 | t2 先单独编译；失败则优先修复；不得静默降级为“无快捷键”还不记录 |
| R2 | 混合 DPI 物理/逻辑不自洽 | 物理 Win32 为权威；截图宽高比校验；失败回退并记录限制；D3/D4 矩阵 |
| R3 | `window_manager` minSize 在 DPI 变化后失效 | 每次 `ensureGeometry/enter/exit` 重设；手工 M-11 |
| R4 | 焦点回归（拖动/流式抢焦点） | `focusCount` 单测 + 白名单 + M-36/37 |
| R5 | 重建 ChatScreen 导致 SSE 断流 | 稳定槽位 + GlobalKey + `identical/chatCalls` 测试 |
| R6 | 360×420 溢出 | W-CHAT/W-UI 窄窗测试 + 手工 M-21/22 |
| R7 | 截图重截/异常导致窗口残留隐藏/置顶 | `try/finally` + 每 session restore 一次 + U-CAP/W-SHOT |
| R8 | 截图覆盖导致滚动跳动 | 保持 offset/回到底部策略；手工 M-22 |
| R9 | 托盘/关闭/退出时热键或截图未清理 | `quit/OnDestroy` 注销；U-HK-05；M-35 |
| R10 | 快捷键冲突（QQ/输入法等） | 1409 检测 + 一次性提示 + 按钮兜底；M-34 |
| R11 | 验证污染用户数据/覆盖 release | 隔离 `LOOP_DATA_DIR`；关闭用户实例；t6 检测进程 |
| R12 | `setFullScreen`/原生标题栏回归 | 静态检查 + 评审 + M-01/03/30 |

**非目标（v0.5.0 明确不做）**

- macOS/Linux/Web 的浮窗形态；
- OCR 独立链路、屏幕文字识别；
- 后台/周期自动截屏、录制；
- 另起悬浮进程/第二 Flutter 引擎/第二窗口；
- 浮窗形态跨重启持久化、浮窗几何落盘；
- 浮窗内切换历史对话/新建对话/设置；
- 折叠为迷你胶囊（P1，另立任务）；
- 生成过程中截图（沿用 v0.4.0 限制）；
- 自动创建 GitHub Release、自动上传 ZIP；
- 修改 Loop-Test。

**开放但非阻塞**：图标/文案微调；快捷键状态是否额外显示在设置页（P2）；是否记忆浮窗置顶状态（当前每次进入默认置顶）。

---

## 14. 附录

### A. 现状关键文件/行号索引

| 主题 | 位置 |
|---|---|
| Shell 布局/IndexedStack | `app/lib/main.dart:171-293`（`IndexedStack` :271；`TitleBar` :266；`WindowResizeHandles` :284-285） |
| WindowController init/minSize/show/maximize | `app/lib/desktop/window_controls_io.dart:24-57`（minSize :30）、`:64-67`、`:76-105`、`:122-139` |
| Web stub | `app/lib/desktop/window_controls_stub.dart:1-26`、`screenshot_capture_stub.dart:1-6` |
| 截图服务 | `app/lib/desktop/screenshot_capture_io.dart:10-34`（主屏 :21、覆盖 bounds :24-26）、`:36-51`、`:53-81` |
| 截图类型 | `app/lib/desktop/screenshot_types.dart:1-16` |
| 选图/裁切 | `app/lib/screens/screenshot_overlay.dart:41-100`、`:102-108`、`:110-224` |
| 截图脚本 | `app/assets/screenshot.ps1:1-27`（PrimaryScreen :18） |
| ChatScreen 状态/生命周期 | `app/lib/screens/chat_screen.dart:38-58`、`:60-84`、`:141-168` |
| 截图流程/发送/事件 | `:218-270`、`:272-377`、`:314-365`、`:379-400` |
| 消息/空态/输入 | `:644-758`、`:760-844`、`:914-1022`、`:1103-1236` |
| 附件/图片预览 | `app/lib/widgets/image_preview.dart:21-29` |
| Markdown 代码/公式 | `app/lib/widgets/markdown_text.dart:196-214`、`:252-291` |
| SSE/上传/图片 URL | `app/lib/api.dart:275-342`、`:344-373` |
| 后端 chat/upload/settings | `app/lib/backend/server.dart:301-407`、`:708-730`、`:70-122` |
| 流式缓冲/事件 | `app/lib/backend/agent.dart:239`、`:409-413`、`:461-462`、`:464-484` |
| 设置数据/开关 | `app/lib/models.dart:328-368`、`app/lib/state.dart:135-153`、`app/lib/screens/settings_screen.dart:171-199` |
| 托盘 | `app/lib/desktop/tray.dart:10-38`、`:47-57` |
| Windows runner | `app/windows/runner/flutter_window.cpp:12-71`、`app/windows/runner/main.cpp:1-43`、`app/windows/runner/win32_window.cpp:157-177` |
| 版本 | `app/pubspec.yaml:19`、`app/lib/update/app_version.dart:3-4` |

### B. 新增文件清单（建议）

| 文件 | 归属 | 说明 |
|---|---|---|
| `app/lib/desktop/window_mode.dart` | t2 | 枚举/快照/显示器模型/`FloatingModeHost`/`WindowPlatform`/纯规划函数 |
| `app/lib/desktop/floating_window.dart` | t2 | `FloatingWindowController` 状态机与快照恢复 |
| `app/lib/desktop/win32_display.dart` | t2 | HWND/物理矩形/显示器/DPI FFI + 回退 |
| `app/lib/desktop/screenshot_service.dart` | t2 | `ScreenshotService` 抽象 + 平台实现 |
| `app/lib/desktop/floating_signals.dart` | t2 | `ScreenshotRequest`/`screenshotRequestSignal`/`captureInProgress` |
| `app/lib/desktop/hotkeys.dart`/`_io`/`_stub` | t2 | 原生热键/状态/注销 |
| `app/lib/widgets/floating_bar.dart` | t3 | 拖动栏 |
| `app/lib/widgets/floating_qa_scaffold.dart` | t3 | 稳定槽位布局（两种形态复用） |
| `app/test/support/fake_window_platform.dart` | t2 | 平台 fake（t3 复用） |
| `app/test/*_test.dart`（见 §10.3） | t2/t3 | 新增测试 |

### C. 术语

- **形态（mode）**：同一窗口的 normal/floating 布局与窗口属性组合，不是新窗口。
- **快照（snapshot）**：恢复窗口所需的状态集合（§4.2）。
- **覆盖窗口（capture overlay）**：截图为框选而临时铺满目标显示器工作区的同一窗口状态。
- **保活**：切换形态不销毁 `ChatScreenState`、不重建 SSE、不重载历史。
- **主屏回退**：无法确定目标显示器时使用主显示器工作区。

### D. 变更记录

| 版本 | 日期 | 说明 |
|---|---|---|
| v0.5.0-spec-1 | 2026-10-24 | t1 初版：基线 4850848 审计、FR-1~15、状态机、窗口/截图/快捷键/焦点/保活契约、验收矩阵、文件归属、发布边界 |

---

## 15. 交付定稿（t6，2026-10-24）

本规格的冻结接口、状态机、验收契约与发布边界在 v0.5.0 正式交付中按以下最终口径执行：

| 项 | 最终状态 |
|---|---|
| FR-1~FR-15 / AC-1.1~AC-15.4 | 实现完成；自动化 + 真实窗口 + live E2E 证据见 `docs/floating-qa-test-report.md` |
| 自动化测试 | `flutter analyze` 0 issues；`flutter test` **142/142**（t7/t8 修复后最终；t4 阶段 133/133 为历史） |
| t4 发现 F1/F2/F3 | **已修复**：F1/F2 由 t8（隐藏页 900×600 布局 + 过渡最小尺寸守卫），F3 由 t7（`WINDOWPLACEMENT.rcNormalPosition` + `SetWindowPlacement` 恢复最大化与还原位置）；t9 独立复评 **pass** |
| 评审 T5-01/02/03/06 | 最大化恢复、最大化截图覆盖/恢复、异常回滚清理：已修复并复评通过 |
| 评审 T5-04/05 | 360×420 隐藏页窄宽溢出、normal→floating 过渡帧溢出：已修复并复评通过 |
| 快捷键 | 原生注册 + 1409 冲突降级；本机 Alt+Q/Alt+A 均被占用时按钮可用、不阻塞启动；真实注册成功路径未在真机复测（单测覆盖） |
| 已知限制 | 物理任务栏矩阵/拔插显示器未全部真机复跑；非聊天页跨形态 remount（ChatScreen 保持）；真实鼠标热区/按键与输入注入边界；均已写入测试报告 §7 与 `docs/release-v0.5.0.md` |
| 发布 | v0.5.0 构建、提交并推送 tag；**不自动创建 GitHub Release**；Loop-Test 未修改 |
