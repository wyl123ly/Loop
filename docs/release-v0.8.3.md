# Loop v0.8.3

## 修复
- **输入框后面的横向背景带是直角**：`ChatScreen` 的 `chat-composer` 容器原来只有顶部 1px 边框，没有圆角，导致底部输入区像一条从内容左边缘铺到窗口右边缘的直角矩阵。
- 现在 `chat-composer` 使用 `BorderRadius.vertical(top: Radius.circular(18))` + `Clip.antiAlias`，顶部两角与整体 UI 的圆角风格一致。
- 输入框本体、附件区、发送按钮、输入条矩形上报和回答窗锚点均未改动。

## 验证
- `flutter analyze`：0 issues
- `flutter test test/floating_chat_test.dart`：14 passed
- 新增断言：`chat-composer` 的 `BoxDecoration.borderRadius` 必须为顶部 18px，`clipBehavior` 为 `Clip.antiAlias`
- 全量测试（不含截图证据用例）：474 passed / 1 skipped
- 截图证据用例单独跑 1/1；验证后已恢复证据目录

## 已知限制
- 继承 v0.8.0 的 R3-1/R3-2 截图证据问题（dark 调色板、04 fixture），本版未处理。

## 产物
- ZIP：`release/Loop-Desktop-win64.zip`（21,145,603 B）
- ZIP SHA-256：`A2652666588F31DC7B8563D9E5D805AAD750780F15EC3F3D1680454D79449DEA`
- `Loop.exe` SHA-256：`C8CAF27D05ECCDAF55E1DBF421BE10D71A573F2B466A986D7C3774C251E8B8F4`
- `version.json`：`{"version":"0.8.3"}`
- 隔离数据 `/api/health`：`{"ok":true,"version":"0.8.3","has_key":false,"active_subject":"default"}`
