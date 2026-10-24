# Loop v0.6.0

> 正式版桌面应用，Windows 10/11 x64。重点：**极简形态** + **独立自适配回答浮窗**。主窗口仍是聊天/SSE/数据库唯一数据源，回答窗只读；没有降级为同窗内嵌。

## 新增：独立回答浮窗

- 仅当用户提交**非空问题**后创建第二顶层 Flutter 窗口；空提交不创建。
- 主窗口持有会话、SSE、数据库、附件与流式状态；回答窗通过本地 `WindowMethodChannel` IPC 接收 snapshot / delta / status / resize_ack / theme；回答窗只读，不直接访问 DB/后端。
- 回答窗宽度固定为当前显示器工作区约 **35%**（逻辑 420–900）；高度随流式正文自适应，minH **180**、maxH **min(70%, 760)**；到 maxH 后窗口内滚动，不无限长高。
- 流式 delta 以 80ms 合并节流；自动锚定在输入条上方，与输入条保持 gap，**零遮挡**；可拖动、收起（36px）或关闭；替换问题/停止/错误/stream off 均与主窗一致；会话继续留在主窗口。
- 多显示器/DPI：在 125%/150% 显示器之间自动跟随，宽度逻辑值固定、高度按目标工作区重算；用户手动拖到副屏的回答窗不被主窗移动拉回；userMoved 回答窗在 floating/minimal 形态变化后重新检查真实输入条，必要时仅做最小位移/压缩。

## 新增：极简形态

- 浮窗缩到最小时，或点浮窗「最小化」按钮，切换为 **460×52 逻辑像素**的紧凑条。
- 紧凑条只保留输入框（含发送/停止）、截图、返回三要素；无消息区、无留白；恒置顶、整条可拖动。
- 返回按钮恢复原浮窗/主窗口；双击紧凑条或展开按钮恢复浮窗；截图后恢复极简条；关闭/退出浮窗会关闭回答窗，会话仍留在主窗口。
- 输入条与回答窗零交集；极简输入框可直接点击输入并提交。

## 架构与窗口生命周期

- 第二窗口使用 `desktop_multi_window 0.3.1`（vendored 到 `app/third_party/desktop_multi_window`，Dart API 不变），Windows 原生补丁：`WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW`、`WM_MOUSEACTIVATE → MA_NOACTIVATE`、`WM_DPICHANGED` 不再应用 OS suggested rect、`SW_SHOWNOACTIVATE`。
- 第二引擎不注册 `window_manager`，不启动后端；框架/几何/关闭由主引擎 Win32 FFI 与第二引擎 Dart FFI 协作。
- 主窗 presence 期间 `setPreventClose(true)`；退出顺序先关回答窗再退主窗，托盘退出/外部关闭均无孤儿进程；单实例、ready 超时清理、关闭/重开。
- 回答窗不在任务栏显示、不抢主窗前台；创建瞬间做一次焦点补偿。点击回答窗正文、拖标题、滚动条、滚轮均不改变 `GetForegroundWindow` / 文本输入焦点。
- 主题切换由主窗同步到已打开回答窗，并在重建首帧补发；截图/最小化/托盘隐藏会隐藏并恢复回答窗。

## 修复（评审 findings）

- F-01（BLOCKER/R1-B）：回答窗点击/拖动/滚动条/滚轮抢前台与输入焦点；通过 vendored 原生补丁 + 指针补偿修复，真实 SendInput 复测 0 次点击抢前台、文本焦点不变。
- F-02（MAJOR）：已打开回答窗不跟随主题；`setTheme` 去重/补发/重建首帧修复，运行时浅→深实测 brightness 245→40.6。
- F-03（MAJOR）：150% 副屏创建高度/gap 错误（950/9）；按目标显示器重算 maxH/desired，真机 896×1120@144 / gap 11（1px 检测误差）。
- F-04（MINOR）：永久不激活后 hover 滚轮不滚动；指针信号 fallback + 滚动条保持。
- F-06（MINOR）：窗口样式误报；改为必需位校验 + SetWindowPos 落实 TOPMOST。
- T5-04 resize_ack seq 风暴；T5-05 主窗 resize/形态切换 anchor 重报；T5-06 用户移动跨屏保持；T5-07 创建期 preventClose/无孤儿；T5-10 显示器移除 clamp；T12 跨屏重复 DPI 缩放/程序化 target display；T14 userMoved 输入条遮挡。
- **双击回答窗标题恢复自动位置的行为已移除**（原规格 §4.6 的 reset 未交付）；双击不会再触发位置重置。Release notes 明确此差异，避免用户误期待。

## 兼容性

- 保持 v0.5.0：普通窗口/浮窗切换、最大化还原、截图（隐藏 Loop/框选/上传）、全局快捷键降级、置顶、流式开关、900×600 最小窗口、亮/暗主题、Markdown/KaTeX/代码块、图片/PDF/DOCX/PPTX 附件、停止/审批/审计、token/cost、历史重载、托盘/开机自启。
- 普通窗口默认 1800×1125@(380,157)，minTrack 1125×750；极简条 460×52；回答窗 minH 180/maxH 760。
- 数据目录、SQLite 结构、HTTP API 无破坏性变更；升级保留 `data/loop.db`、`data/files`、API Key、会话、笔记、待办。回答窗/极简状态不写用户数据。
- Loop-Test 未修改，正式版不包含 Loop-Test 插件能力。

## 验证（t15/t13/t8 + t6 最终产物）

- `flutter analyze --no-pub`：**No issues found**（0）。
- `flutter test --no-pub`：**261/261 All tests passed**（含 U-AL-28..34、A-IPC/A-UI、窗口/截图/极简/回答窗）。
- `flutter build windows --release` + `packaging/build_native.ps1`：成功。
- 真机双屏（主 2560×1440@125%，副 2560×1600@150%）：
  - 真实拖动 125→150：回答窗 **1075×1120@144**；150→125：**896×950@120**；副屏创建 **896×1120@144**、gap 11；程序化主→副/副→主、userMoved 跨屏保持通过。
  - 极简 3 次循环/拖到最小 450×65；回答窗 35%/minH/maxH/内部滚动；tray 退出无孤儿。
  - T9-01：轻拖 userMoved 后 floating/minimal 与真实 inputBarPhysical 零交集，极简输入提交成功，无遮挡时位置不变；host `userMoved nudged=2`、`overlapWarn=0`。
- 正式产物启动冒烟（隔离 `LOOP_DATA_DIR`，mock LLM）：`/api/health` = `{"ok":true,"version":"0.6.0"}`；第二回答窗/极简/输入提交/替换全通过；无残留进程/端口。
- 证据：`docs/minimal-overlay-test-report.md`、`docs/evidence/minimal-overlay-v0.6.0/`（t8/t13/t15 + t6-release）。

## 已知限制

- **T5-08 首次可见延迟（accepted EXCEPTION，不是 PASS）**：回答窗从 Enter 到首次可见实测 **1032/1099/1093ms**（t15），另有 **4290ms** 冷启动孤例（t13）；主要来自第二个 Flutter 引擎冷启动。等待期间主窗有“正在思考…”反馈、无空窗、输入不中断。按 captain 决策记录为 accepted EXCEPTION，不单独卡交付；若后续要求 <400ms，需要预热/常驻第二引擎等方案（当前规格禁止启动预热）。
- 真实中文 IME 组合无法在自动化中启动（`ImmGetContext=0`）；已用“文本焦点 hwnd 不变 + 连续中文输入/提交成功”等价验证，建议人工用 Microsoft Pinyin 复测。
- 100% DPI 显示器本机不存在，跨屏 100% 由单测 U-AL-30 覆盖；未修改用户显示设置。
- 物理拔插/禁用显示器、可见任务栏（左侧/上方）未真机全矩阵复测；单测 U-AL-26 + 本机自动隐藏任务栏覆盖。
- 输入注入边界：焦点/几何测试使用系统级 SendInput，不等同真实 IME/真实用户手速；回答窗为 `WS_EX_NOACTIVATE` 工具窗，不进入任务栏/Alt-Tab 常规切换。
- 回答窗/极简条依赖第二顶层窗口；若系统/安全软件拦截第二引擎创建，会清理并保留主窗会话，不静默降级同窗内嵌。
- 无代码签名，首次运行可能触发 SmartScreen。

## 升级与发布

- 直接替换程序目录即可升级；用户 `data/`、API Key、会话、笔记、待办保留。本版无破坏性 SQLite 迁移。
- 正式产物：
  - `release/Loop-Desktop/`（`Loop.exe`、DLL、`data/`、`version.json`、`使用说明.txt`）
  - `release/Loop-Desktop-win64.zip`
- 版本：`version.json` = `{"version":"0.6.0"}`；`Loop.exe` FileVersion = `0.6.0+15`；`AppVersion.current = 0.6.0`；Git tag `v0.6.0`。
- **本版本不自动创建 GitHub Release**；保留手动上传 `release/Loop-Desktop-win64.zip` 并在 GitHub Releases 填写本说明。

### 构建产物

| 文件 | 大小 | SHA-256 |
|---|---|---|
| `release/Loop-Desktop/Loop.exe` | 114,688 B | `4CC23EDDA929D27BEADDA81B6B9257E680DD839B0F7137E2310B49B9EE7A6416` |
| `release/Loop-Desktop/version.json` | 19 B | `9F2A0F085AF1D8D75C044CB7D0B9B45DB4E975A2FA9354CFDF62731A791A0899` |
| `release/Loop-Desktop-win64.zip` | 20,773,594 B（19.81 MiB） | `F63F539BEDACC0297C30A82A0B685AFF3DC486F2CD52EA10FB62E33097A1D7C9` |

> ZIP 内含：`Loop.exe`、`version.json`、`使用说明.txt`、`desktop_multi_window_plugin.dll`、`flutter_windows.dll`、`data/app.so` 等运行时文件；不含用户 `loop.db`。
