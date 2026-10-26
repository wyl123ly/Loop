# Loop v0.8.4

## 修复
- **主窗口右上圆角白弧**：
  - 根因不是 DWM 边框本身，而是圆角面板外的透明像素让桌面/引擎背景从「Flutter 圆角」与「DWM 裁剪」之间透出。
  - 修复：主窗口根层增加 `ColoredBox(color: pal.bgTop)`，普通窗口整面不透明；浮窗/极简仍保持透明，避免破坏自己的圆角形态。
  - 同时设置 `DWMWA_BORDER_COLOR = DWMWA_COLOR_NONE`、`DWMWA_WINDOW_CORNER_PREFERENCE = DWMWCP_ROUND`，去掉 Windows 11 的浅色非客户区描边。
- 保留 v0.8.3 的输入框横向背景圆角、v0.8.2 的侧栏圆角、v0.8.1 的归档学科只读管理。

## 验证
- `flutter analyze`：0 issues
- 全量 `flutter test`（不含截图证据用例）：**473 passed / 1 skipped**
- 真实窗口截图：修复后右上圆角白弧消失（截图复核）
- 浮窗/极简未加底色，保持原透明圆角行为

## 产物
- ZIP：`release/Loop-Desktop-win64.zip`（21,145,909 B）
- ZIP SHA-256：`0A2679E97365F43191BC353C6C6109C0463125B25A5C765A96D9F5E1541BABCA`
- `Loop.exe` SHA-256：`3E5E3791FDAC418084A5E6AF1FCE94F4C696F15777FDEE266C2DD39D7D5F9DAA`
- `version.json`：`{"version":"0.8.4"}`
- 隔离数据 `/api/health`：`{"ok":true,"version":"0.8.4","has_key":false,"active_subject":"default"}`

## 已知限制
- 截图证据用例未重跑，v0.8.0 的 R3-1/R3-2 证据限制仍在。
