# Loop v0.8.5

## 修复
- 主窗口创建样式改为无标题栏的 frameless：
  `WS_THICKFRAME | WS_MINIMIZEBOX | WS_MAXIMIZEBOX | WS_CLIPCHILDREN | WS_CLIPSIBLINGS`
- 去掉 `WS_CAPTION` 的非客户区绘制，并在 `WM_NCCALCSIZE` 中让客户区覆盖整个窗口；消除 8px 原生非客户区边框在圆角外露出的浅色方块/白弧。
- **顶层圆角半径统一为 8px**：Windows DWM 原生圆角固定约 8px，Flutter 面板原来的 18px 会与原生圆角形成两套弧线；`normalRadius` / `floatingRadius` / `minimalRadius` 均改为 8px（DPI 缩放由系统处理）。
- 处理最大化：`WM_NCCALCSIZE` 在 `IsZoomed` 时把客户区 clamp 到显示器工作区；`WS_THICKFRAME` 保留原生缩放/贴靠。
- 设置 `WS_EX_APPWINDOW`，保持任务栏/Alt-Tab 可见。
- 注：曾尝试 `WS_POPUP`，但其 `SC_MAXIMIZE` 不生效，故最终采用无标题栏 + `WM_NCCALCSIZE` 方案。
- 保留 DWM 圆角、透明边框、根层主题底色。

## 诊断依据
- 运行中窗口探针：`WS_CAPTION=True`、`WS_THICKFRAME=True`、`WS_POPUP=False`，window 1936×1096 vs client 1920×1080（8px frame）。
- `window_manager.setAsFrameless()` 只 `SetWindowPos(SWP_FRAMECHANGED)`，未清 `WS_CAPTION`。

## 验证
- `flutter analyze`：0 issues
- 全量 `flutter test`（不含截图证据用例）：473 passed / 1 skipped
- Windows release 编译通过
- 运行中探针：client = window（frame = 0），左上/右上圆角无浅色方块
- `SC_MAXIMIZE`（激活窗口后）：`IsZoomed=True`，窗口进入最大化；`SC_RESTORE` 可恢复
- 还需在正式包上补测：任务栏/Alt-Tab、八向缩放、贴靠、最小化/托盘、浮窗/极简/回答窗

## 产物
- ZIP：`release/Loop-Desktop-win64.zip`（21,146,012 B）
- ZIP SHA-256：`70EA41330BAB4529F8309FEB56C3CC18D3CA836378EB334CBE96404F0381730B`
- `Loop.exe` SHA-256：`2EBCB857A19DD0700080B9633E5077A535133E12A4D44BB0F72D3BF319FF4281`
- `version.json`：`{"version":"0.8.5"}`
- 官方 `release/Loop-Desktop` 已更新为 v0.8.5

## 已知限制
- 顶层圆角已统一到 Windows 原生 8px；Windows 阴影/抗锯齿在极近距离下仍可能有 1px 过渡，不是第二套圆角。
- 正式包的任务栏/Alt-Tab、八向缩放、贴靠、最小化/托盘、浮窗/极简/回答窗仍需人工回归。
