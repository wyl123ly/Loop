# Loop v0.8.2

## 修复
- 侧栏右侧与内容区之间的直边/直角：`Sidebar` 的 `AnimatedContainer` 增加右侧间距（展开 12px / 紧凑 8px），玻璃面板四边圆角不再被内容区贴住，和左侧圆角列表统一。
- 保持 v0.8.1 的归档学科只读管理预览、学科菜单 14px 圆角与 README 检索说明。

## 验证
- `flutter analyze`：0 issues
- 全量 `flutter test`（不含截图证据用例）：**473 passed / 1 skipped**
- 截图证据用例（`subject_screenshots_test.dart`）未重跑，v0.8.0 的证据限制仍在（R3-1/R3-2）。

## 已知限制
- v0.8.0 的 dark 截图调色板/04 fixture 证据问题未修；
- 归档学科只读预览下不能提问/写入，这是设计语义；
- 真实 Kimi/GLM Key 验证仍需本机完成。

## 产物
- ZIP：`release/Loop-Desktop-win64.zip`（21,145,709 B）
- ZIP SHA-256：`1A03DD81414FFAD9FD23A28342D04DA27C990C9F4D030EFFF083A95AD8EF0EFA`
- `Loop.exe` SHA-256：`03925FCA60F56216239DFD77314C549601FFB89565A7430B1C80D722AC5C35DD`
- `version.json`：`{"version":"0.8.2"}`
- 隔离数据 `/api/health`：`{"ok":true,"version":"0.8.2","has_key":false,"active_subject":"default"}`
