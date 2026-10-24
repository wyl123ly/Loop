# Loop v0.5.0

## 桌面答疑悬浮窗

- 同一 Flutter 进程、同一窗口在 normal / floating 两种形态间切换，不创建第二个 FlutterEngine、不重启后端、不重载会话。
- 主窗口标题栏最小化按钮左侧新增「浮窗答疑」按钮。
- 浮窗默认 **460×600**（逻辑像素），最小 **360×420**；自绘拖动栏替代原生标题栏，栏内含截图、置顶、返回主窗口、关闭按钮。
- 浮窗可拖动、四边/四角缩放、置顶/取消置顶；Windows `WM_GETMINMAXINFO` 保证最小尺寸；双击拖动栏不会最大化。
- 普通窗口的 `bounds / maximized / alwaysOnTop / minSize / displayId` 在进入浮窗前快照，退出时逐项恢复；最大化状态进入浮窗后返回仍保持最大化。
- 记住本次会话上次浮窗尺寸；显示器/DPI 变化时 300ms 去抖校正，保持可见且不改变形态、不抢焦点。

## 会话与流式

- 浮窗复用主窗口的 `ChatScreen` State、当前 conversation、附件、SSE，不重建、不重载历史。
- 流式输出进行中切换 normal↔floating，回答不中断、不重复；返回主窗口看到同一会话与同一回答。
- 流式输出开关（设置 → 对话与模型）在浮窗形态下同样生效：开启逐字、关闭等待完整回复一次性显示。
- 工具步骤、计划卡、审批、停止、错误、token/cost 在浮窗中均可用，仅做紧凑展示。

## 截图问答

- 浮窗截图默认“隐藏 Loop 后截图”，截取**窗口中心所在显示器**的工作区（物理像素），支持负坐标副屏与 125%/150% 等不同 DPI。
- 覆盖窗口铺满目标显示器工作区进行框选；支持取消、全屏、重截（最多 3 次）、完成；取消/重截/失败均恢复截图前的浮窗尺寸、位置、置顶与 minSize。
- 框选完成自动裁切 PNG 并经现有上传 API 成为 `img_` 图片附件，可继续输入问题随消息发送；图片附件在输入区与消息中可预览。
- 不再调用 `setFullScreen`；窗口从隐藏/普通/最大化/浮窗任何状态截图后都恢复原状态。

## 全局快捷键

- `Alt+Q`：切换普通/浮窗（窗口隐藏或最小化时只显示，不切换形态）。
- `Alt+A`：截图（浮窗内隐藏 Loop，普通窗口保持 Loop 可见）。
- 原生 `RegisterHotKey` + Windows runner `loop/hotkeys` MethodChannel，`MOD_ALT|MOD_NOREPEAT`，Dart 层 300ms 去抖，退出时注销。
- 单个键或多键被其他程序占用（Win32 错误 1409）时：记录状态、tooltip 提示“被占用，可用按钮”、按钮始终可用；不阻塞启动。
- 焦点策略：形态切换/截图恢复只在用户动作白名单内聚焦；托盘显示与隐藏/后台恢复使用 Win32 无激活显示，避免反复抢焦点。

## 修复（评审 findings）

- **最大化还原位置丢失**：进入浮窗前保存 Windows `WINDOWPLACEMENT.rcNormalPosition`；退出浮窗（含重新最大化）时优先通过 `SetWindowPlacement` 一次写回 restore-down placement + 最大化，失败回退“unmaximize → 恢复 placement → maximize”。最大化 → 浮窗 → 返回 → 点“还原”现在回到最大化前的普通窗口 rect，而不是浮窗位置/最小尺寸。
- **最大化窗口截图恢复**：截图覆盖前先 `unmaximize` 再铺满工作区；`applySnapshot` 恢复最大化 + 原 normal placement；异常路径 `finally` 清理 `captureInProgress` 与全局信号，可重试。
- **浮窗 360×420 隐藏页溢出**：floating 时其余五页仍常驻以保留状态，但按普通窗口最小尺寸 900×600 通过 `OverflowBox` 布局并由 Stack 裁剪，不再以 360 窄宽排版。
- **normal→floating 过渡帧页头溢出**：`FloatingQaScaffold` 在帧约束小于当前形态最小尺寸时按最小尺寸布局并 ClipRect 裁剪，1–2 帧过渡不再产生 81px RenderFlex overflow。
- **Agent 页无后端兜底**：权限页加载失败时显示可重试的降级卡片，不再 `null` 崩溃（仅影响错误路径 UI）。

## 兼容性

- v0.4.0 的流式输出开关、Markdown/KaTeX、代码块、表格、图片/截图附件、自定义模式、历史重载、停止/审批/审计、token/cost：保持。
- 900×600 主窗口、侧栏自动 compact、亮/暗主题：保持。
- 数据目录、SQLite 结构、HTTP API 无破坏性变更；升级保留 `data/loop.db`、`data/files`、API Key、会话、笔记与待办。
- 正式版仍无插件运行时；插件能力仅存在于 Loop-Test，不随本版本发布。

## 验证

- `flutter analyze --no-pub`：**No issues found**（0 issues）。
- `flutter test --no-pub`：**142/142 All tests passed**（37 条 v0.4.0 基线 + 浮窗/窗口/几何/截图/布局新增测试；含 t7 的 5 条最大化恢复测试与 t8 的 4 条窄布局/过渡测试）。
- 真实 Windows 窗口（隔离数据）：
  - 按钮进入浮窗 460×600、topmost、minTrack 360×420；返回精确恢复普通窗口 bounds/topmost/minSize；
  - 最大化 → 浮窗 → 返回（最大化）→ 还原回到原 bounds；最大化窗口截图覆盖/恢复；
  - 360×420 真实六页与逐帧过渡 RenderFlex/RenderLine 扫描 0；
  - 真实双屏（主屏 2560×1440@125%、副屏 2560×1600@150%）：浮窗定位、minSize、按显示器截图、框选 400×300 逻辑 → PNG 600×450。
- 隔离 Backend + SQLite + mock LLM live E2E：27/27（截图 PNG → `img_` 附件 → 随问题发送（image_url data URI）→ 流式回答；stream on/off；运行中切换；停止；审批 allow/reject；空回复/500/无 Key/长回复/计划）；重启持久化 4/4。
- 评审：t5/t9 对窗口/最大化/截图/窄布局 findings 复评 **pass**。
- 详细证据：[docs/floating-qa-test-report.md](floating-qa-test-report.md)；规格：[docs/floating-qa-spec.md](floating-qa-spec.md)。

## 已知限制

- 真实全局快捷键注册在本机被其他程序占用（`RegisterHotKey` 1409，Alt+Q/Alt+A 均冲突），已验证降级为按钮可用与冲突提示；**按键注册成功路径**由单测覆盖，未在真机复测。
- 物理拔插/禁用显示器、任务栏方位（左/上）矩阵未逐项真机复跑（本机任务栏自动隐藏）；显示器选择、负坐标、DPI 与越界校正由单测/真实双屏覆盖。
- 悬浮窗形态下“保 State”仅对 `ChatScreen` 成立；其余五页跨形态会 remount（返回普通窗口时重建），不影响会话。
- 截图“重截 / 上传失败 / 大图预览点击缩放 / 无 Key UI”的 live 复测不完全，由对应 widget/API 测试覆盖。
- 真实鼠标拖动/缩放热区与真实按键注入受测试机前台全屏程序限制；几何/minTrack 由 Win32 探针 + widget 测试覆盖。
- 自动化证据中的桌面缩略图已打码；原始截图不随仓库分发。

## 升级与发布

- 直接替换程序目录即可升级；用户 `data/` 保留。老库启动自动补齐新增设置（此版本无新增 SQLite 迁移）。
- 正式产物：
  - `release/Loop-Desktop/`（`Loop.exe`、DLL、`data/`、`version.json`）
  - `release/Loop-Desktop-win64.zip`
- 版本：`version.json` = `{"version":"0.5.0"}`；`Loop.exe` FileVersion = `0.5.0+14`。
- 发布步骤（手动）：GitHub Releases 上传 `release/Loop-Desktop-win64.zip` 并填写本说明即可；**本版本不自动创建 GitHub Release**。
- 正式产物启动冒烟（隔离 `LOOP_DATA_DIR`）：`/api/health` = `{ok:true,version:"0.5.0"}`；单进程窗口 1800×1125@(380,157)、minTrack 1125×750；关闭后 8765 释放。启动截图：`docs/floating-evidence/screens/t06-04-release-v050-running.png`。

### 构建产物（t6 填充）

| 文件 | 大小 | SHA-256 |
|---|---|---|
| `release/Loop-Desktop/Loop.exe` | 114,688 B | `B626915EAA58E314FFC0BB55F7E6EA241D3165CF60AEBBEF5020AFCD51C036AC` |
| `release/Loop-Desktop/version.json` | 19 B | `1CA74BD4BC478F15FD14BEA176074894A7A169D54ACC3CDE5594969D8FEE8123` |
| `release/Loop-Desktop-win64.zip` | 20,609,950 B | `1F335A94D96F570DFF3E5BE18FEA5D0FE9520105F5E612F46215C54E5176A5BD` |

## 版本

- `app/pubspec.yaml`：`0.5.0+14`
- `AppVersion.current`：`0.5.0`
- Git tag：`v0.5.0`
