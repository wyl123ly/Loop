# Loop v0.4.0

## 流式输出开关

- 设置页新增「对话与模型」卡片，位于「外观」与「DeepSeek 接入」之间。
- 卡片内新增「流式输出」开关，默认开启。
  - 开启：保持 v0.3.9 体验，回答逐字显示。
  - 关闭：等待完整回复后一次性显示；等待期间显示“正在思考…”，工具步骤、计划、审批仍实时出现。
- 说明文案：**开启后逐字显示；关闭后等待完整回复；对下一条消息生效。**
- 开关切换即时保存；保存失败时恢复原状态并提示“流式设置保存失败，已恢复原状态”。
- 切换按请求级快照生效：运行中修改不会改变当前回答的呈现方式，只影响下一条消息。

## 关闭流式时的后端行为

- 后端仍正常消费模型的流式响应，取消、工具调用、多轮工具、usage 统计逻辑不变。
- 正文跨轮缓冲，在整次 run 结束（或取消）前统一发送一次 `delta`，内容与落库正文一致；空回复不产生空 `delta`。
- `step`、`plan`、`approval`、`agent`、`token`、`done`、`error`、`cancelled` 事件结构与实时性不变；审批、停止、强制收尾照常。
- 多轮工具正文拼接与开启流式时逐字符一致；正文有内容时的错误仍按既有 `done.error` 语义处理（本版本不改变）。

## 设置与数据

- SQLite `settings` 新增 `stream_output`，默认 `true`；老库启动时用 `INSERT OR IGNORE` 自动补默认值，无需迁移脚本。
- `GET/PUT /api/settings` 增加布尔 `stream_output`；非布尔类型写入会被忽略。
- 侧栏折叠、自动更新等其它设置开关不会重置流式开关。
- 升级后保留用户原有 `data/loop.db`、`data/files`、API Key、会话与笔记。

## 兼容性

- Markdown、KaTeX 公式、代码块、引用、列表：正常。
- 图片附件、聊天截图附件、图片预览：正常。
- 自定义模式、思考强度（high 使用 reason_model）、多会话历史：正常。
- 停止/取消、审批允许/拒绝、审计、token/cost、历史重载：正常。
- 正式版当前没有插件运行时，插件相关能力不在本版本范围（插件仅存在于 Loop-Test 测试版，未合并）。

## 验证

- `flutter analyze`：No issues found。
- `flutter test`：37/37 通过（17 基线 + 10 后端流式 + 10 前端流式）。
- mock LLM 真实后端 E2E（隔离数据）：24/24 通过；重启持久化 2/2 通过。
- 实机 UI（隔离实例）：开关位置/文案、暗/亮主题、900×600、开关 on/off 与 API 一致；false 生成的 7967 字长回答从历史重载后 Markdown/公式/代码块正常。
- v0.4.0 构建产物冒烟：`/api/health` 返回 `version=0.4.0`；新库默认 `stream_output=true`；false 单 delta、true 多 delta；重启后 false 持久化（6/6 + 2/2 通过）。

## 构建产物

| 文件 | 说明 |
|---|---|
| `release/Loop-Desktop/Loop.exe` | FileVersion `0.4.0+13`，SHA-256 `8528C667F78E2112431888E1E6EB8E4D60265D111D9C0F4D51449723F287324F` |
| `release/Loop-Desktop/version.json` | `{"version":"0.4.0"}` |
| `release/Loop-Desktop-win64.zip` | 20,521,998 字节，SHA-256 `7D1BF2101CF53259BD6CBC82C464A898330A84BA7A39B19FD8D768CD752D09E0` |

## 升级

- 从 v0.3.9 启动时，自动更新检查会提示 v0.4.0。
- 也可手动下载 `Loop-Desktop-win64.zip` 覆盖程序目录；`data/loop.db`、`data/files` 等用户数据会保留。
- 本版本只完成了本地构建与验证：**未自动创建 GitHub Release、未打 tag、未推送**；上传附件与发布由维护者按现有流程手动完成。
