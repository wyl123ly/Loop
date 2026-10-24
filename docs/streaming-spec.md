# 流式输出开关（stream_output）契约与兼容性设计

- 状态：定稿（t1，2026-10-24）
- 适用版本：正式版 `D:\DSH_Workspace\Prog2_app`，目标发布 **v0.4.0**
- 读者：stream-backend（t2）、stream-frontend（t3）、stream-verifier（t4）、stream-reviewer（t5）、集成（t6）
- 作用：把**已经存在**的逐字输出做成一个设置项，并补齐“关闭输出流”模式；**不是从零加流，也不是重写对话链路**
- 只读审计基线：`main` @ `0f0adc6`；`flutter analyze` 0 issues、`flutter test` 17 passed（2026-10-24，`app` 目录，`..\.tools\flutter\bin\flutter.bat`）
- 不改范围：`D:\DSH_Workspace\Loop-Test` 一律不动；本文件之外不产生实现改动

---

## 0. 结论速览（TL;DR）

1. 现状**已经是流式**：前端 `POST /api/chat` → 后端同进程 `runAgent` → `llm.dart` 的 `streamChat`（`stream: true`）→ DeepSeek SSE → 后端逐个 `delta` 事件 → `chat_screen` 逐块 `setState` 渲染。
2. 本次新增 `settings.stream_output`（默认 `true`），语义是**“正文如何呈现”**，而不是“是否调用流式 API”：
   - `true`：与现在完全一致，每个 provider 正文增量立即转发 `delta`。
   - `false`：后端**仍然**消费 provider 流（取消检查、工具调用累积、usage、多轮都照旧），但**不转发中间正文**；整个 run（含多轮工具调用）结束后在终态事件前**只发一次** `delta`，`text` 等于最终完整正文。
3. 工具步骤 `step`、计划 `plan`、审批 `approval`、子 Agent `agent`、`done`（token/cost/refs/plan）、`cancelled`、`error` 的事件名与实时性**全部不变**；`done` 不带正文。
4. 前端 `chat_screen` **不按开关分支**：它只认 `delta` 增量。`false` 模式下等待期间沿用现有“正在思考…”占位，最终 `delta` 一次到达后照常走 Markdown/公式/代码块/滚动。
5. 设置在后端读一次、按“请求级快照”生效：切换只影响**下一条消息**，不影响进行中的回答。
6. 首版采用**后端缓冲**，不切 provider `stream:false`：保留取消、工具调用、多轮与协议稳定性；非目标见 §5.4。

---

## 1. 现状审计

### 1.1 端到端链路（已实现，逐字）

```
ChatScreen._send()                                  app/lib/screens/chat_screen.dart:267
  └─ appState.api.chat(...)                         app/lib/screens/chat_screen.dart:300
       └─ LoopApi.chat()  POST /api/chat            app/lib/api.dart:273
            └─ Backend._chat()  (Dart HttpServer)   app/lib/backend/server.dart:297
                 ├─ 落 user message、建/取会话       app/lib/backend/server.dart:321-360
                 ├─ SSE 响应头 + bufferOutput=false  app/lib/backend/server.dart:362-367
                 ├─ 先写 event: run                  app/lib/backend/server.dart:369-371
                 └─ runAgent(...)                    app/lib/backend/agent.dart:133
                      ├─ LlmConfig.fromDb()/模型选择  app/lib/backend/agent.dart:144-146
                      ├─ streamChat(stream:true)     app/lib/backend/llm.dart:64-112
                      │    └─ DeepSeek SSE data:     app/lib/backend/llm.dart:98-108
                      └─ 每个 delta 立即 yield       app/lib/backend/agent.dart:221-225
            └─ SSE 事件逐条 write + flush           app/lib/backend/server.dart:384-390
       └─ LoopApi 解析 event:/data: 成 SseEvent     app/lib/api.dart:308-339
  └─ switch(event.event) 增量更新 Message           app/lib/screens/chat_screen.dart:309-360
```

### 1.2 `/api/chat` 的 SSE 协议（现状，保持不变）

事件名（`docs/agent-design.md:21` 已有记录）：

| 事件 | data 关键字段 | 产生位置 |
|---|---|---|
| `run` | `run_id` | `server.dart:370`（在消费模型流之前） |
| `delta` | `text` | `agent.dart:224` |
| `step` | `name`、`status`、`detail` | `agent.dart:285/305/358` |
| `plan` | `items` | `agent.dart:346/355/403/408` |
| `approval` | `run_id`、`tool`、`args`、`risk` | `agent.dart:293-298` |
| `agent` | 子 Agent 摘要 | `agent.dart:325` |
| `cancelled` | `message_id`、`partial:true` | `agent.dart:445` |
| `error` | `message` | `agent.dart:449` |
| `done` | `run_id`、`message_id`、`tokens_in/out`、`cost`、`steps`、`refs`、`plan`、`error` | `agent.dart:453-463` |

- 响应为 `text/event-stream; charset=utf-8`，`Cache-Control: no-cache`、`X-Accel-Buffering: no`、`bufferOutput=false`，每条事件 `write + flush`（`server.dart:362-390`）。
- 前端解析：空行分帧、`event:`/`data:` 两行，多行 `data:` 以 `\n` 连接（`api.dart:308-339`）。后端 `jsonEncode` 会把正文换行转义，所以一条 `delta` 始终是**一行** `data:`。
- **`done` 不携带正文**；正文只能通过 `delta` 到达前端，历史正文落库在 `messages.content`（`agent.dart:423-434`）。

### 1.3 `llm.dart` 恒为流式

- `streamChat` 请求体固定 `'stream': true`、`stream_options.include_usage: true`（`llm.dart:74-82`），思考强度 `high` 时附加 `thinking`/`reasoning_effort`。
- 逐行消费 `data:`，解析为 Map 后 `yield`（`llm.dart:98-108`）。
- 另有一个非流式 `complete()`（`llm.dart:114-147`），**只**用于设置页连通性测试与 `/api/generate/*`（笔记/待办），**不参与聊天**。所以“关闭流式输出”不能走 `complete()`，否则会丢掉工具调用与取消能力。

### 1.4 `agent.dart` 逐个 delta 转发 + 多轮工具

- 主循环最多 20 轮（`_maxRounds`，`agent.dart:23`），每轮 `await for (final chunk in streamChat(...))`（`agent.dart:204-242`）。
- usage 先累计（`agent.dart:211-215`）；正文 `roundText += text; fullText += text; yield AgentEvent('delta', ...)`（`agent.dart:220-225`）。
- `tool_calls` delta 累积到 `pending`，一轮结束后组成 OpenAI 格式 assistant 消息回填（`agent.dart:226-259`）。
- **`fullText` 是整个 run 的正文累加器**（跨轮），落库 `messages.content = fullText`（`agent.dart:419-434`）；`done` 里没有正文。
- 强制收尾分支会补写正文：空正文时生成“已完成：…”，非空时追加“（已停止重复验证。）/（…工具上限…）”（`agent.dart:387-400`）——该分支**也会 yield delta**，是 false 模式下最容易产生重复正文的位置。
- 收尾：cancelled 落库后通知（`agent.dart:444-447`）；`error` 仅在**正文为空**时发（`agent.dart:448-451`）；否则走 `done` 并在 `done.error` 里带错误（`agent.dart:453-463`）。

### 1.5 `chat_screen` 增量渲染

- `_send()` 先插入占位 assistant 消息，再 `await for` 事件（`chat_screen.dart:267-372`）。
- `delta`：`assistant.content += delta` + `setState` + `_scrollToEnd()`（`chat_screen.dart:310-313`）。`_scrollToEnd` 是 180ms 动画滚动到 `maxScrollExtent + 120`（`chat_screen.dart:174-183`）。
- `step`：按工具名合并/追加 chips（`chat_screen.dart:333-342`，渲染 `chat_screen.dart:1019-1066`）。
- `plan`：`AgentPlanCard`（`chat_screen.dart:316-321`、`964`）。
- `approval`：`_approvalCard()` 显示在输入框上方（`chat_screen.dart:322-325`、`397-437`、`464`）。
- `cancelled`：停止发送态、清审批卡、提示“已停止本次执行”（`chat_screen.dart:326-332`）；已收到的正文**不删除**。
- `done`：回填 `message_id`、tokens/cost、refs（`chat_screen.dart:343-356`）；操作按钮与 token 行只在 `message.id != null` 时出现（`chat_screen.dart:1001-1013`）。
- `error`：直接移除 assistant 消息 + 错误 SnackBar（`chat_screen.dart:357-359`）。
- 空正文 + 发送中显示“正在思考…”（`chat_screen.dart:951`、`969-980`）。
- 停止按钮复用发送按钮：`_sending ? _stop : _send`，`_stop()` 调 `/api/agent/cancel`（`chat_screen.dart:387-395`、`1205-1209`）。

### 1.6 停止 / 审批 / 工具 / 计划的运行时控制

- `AgentRun.cancel()` 置 `cancelRequested`，并让挂起的审批 Completer 返回 `false`（`agent_run.dart:31-37`）；`checkCancelled()` 在流循环和每个工具前抛 `AgentCancelled`（`agent.dart:200/210/262`、`agent_run.dart:39-41`）。
- 审批：`requestApproval` 挂起 `runAgent`，SSE 保持打开，前端 `POST /api/agent/approve` 唤醒（`agent.dart:292-309`、`server.dart:549-568`）。
- **结论：这些能力与“是否逐字显示正文”完全解耦**，只要后端继续消费 provider 流即可原样保留。

### 1.7 设置现状

- 设置存在 SQLite `settings(key,value)`（`db.dart:92-95`），默认值由 `_defaults` + `INSERT OR IGNORE` 写入（`db.dart:180-185`、`188-202`），老库升级同样生效。
- `GET /api/settings` 返回 `api_key`（打码）、`has_key`、`base_url`、`model`、`reason_model`、`theme`、`custom_modes`、`auto_check_updates`、`sidebar_collapsed`（`server.dart:74-87`）；`PUT` 逐字段校验类型（`server.dart:88-117`）。
- 客户端：`LoopApi.settings()` / `saveSettings()`（`api.dart:107-130`）；`SettingsData`（`models.dart:328-362`）；`AppState.bootstrap/refreshSettings`（`state.dart:30-77`）；设置页各开关直接调 `AppState` 方法（如 `setAutoCheckUpdates`，`settings_screen.dart:317-327`）。
- 注意：设置页顶部“保存”按钮只保存 API Key/Base URL/模型（`settings_screen.dart:59-83`），**新增开关必须像“启动时自动检查更新”一样即时持久化**，不要混入该按钮。
- 注意：`AppState.setSidebarCollapsed`、`setAutoCheckUpdates` 会**手工重建** `SettingsData`（`state.dart:114-149`），新增字段后必须在这里补拷贝，否则一触发侧栏/更新开关就会把流式开关“重置”为默认值。

### 1.8 审计结论

- 当前体验已经是“真流式”，本次改动 = **新增一个持久化开关 + 后端一个缓冲分支 + 设置页一个开关**。
- 不应改：`llm.dart` 的请求形态、SSE 事件名、`/api/chat` 请求字段、前端增量渲染机制、工具/审批/取消逻辑。

---

## 2. 行为矩阵

### 2.1 开关语义

| 项 | 定义 |
|---|---|
| 存储键 | `stream_output`，字符串 `"true"` / `"false"` |
| 默认 | `true`（升级后保持现有体验） |
| 生效时机 | 每次 `POST /api/chat` 开始时读取一次（请求级快照）；进行中的请求不受后续切换影响 |
| 影响范围 | 仅交互式 `/api/chat` 的 **正文 `delta` 发送方式** |
| 不影响 | provider 请求（始终 `stream:true`）、工具执行、审批、取消、usage/token/cost、落库内容、历史消息、后台任务/子 Agent |

### 2.2 事件级矩阵

| 事件 | `stream_output=true`（默认） | `stream_output=false` | 是否变化 |
|---|---|---|---|
| `run` | 立即发 | 立即发 | 无 |
| `delta` | provider 每个正文增量一条，逐字 | 全程 **0 条或 1 条**；1 条时 `text` = 最终完整正文，且位于终态事件之前 | **仅此事件** |
| `step` | 工具执行前/后实时 | 同左 | 无 |
| `plan` | `update_plan`/自动收尾时实时 | 同左 | 无 |
| `approval` | 需要审批时实时；等待期间 SSE 保持打开 | 同左 | 无 |
| `agent` | 子 Agent 完成时实时 | 同左 | 无 |
| `cancelled` | 已流出的正文已在前端 | 先补发一次 `delta`（若有正文），再 `cancelled` | 见 I4 |
| `error` | 正文为空时的错误 | 同左（该分支正文必为空，不会 flush） | 无 |
| `done` | 正文已全部通过 `delta` 到达 | 先 `delta` 后 `done`；`done` 结构不变、不含正文 | 无结构变化 |

### 2.3 场景矩阵

| 场景 | `true` | `false` | 验收点 |
|---|---|---|---|
| 普通问答 | 多个 `delta`，逐字 | 等待期间“正在思考…”；结束时 1 个 `delta`（完整正文）+ `done` | `delta.text == messages.content` |
| 长回复（如 5k+ 字） | 多次 `setState`/滚动 | 1 次 `setState`/1 次滚动；单条大 `data:` 行 | 内容完整、无截断；Markdown 一次渲染 |
| Markdown/公式/代码块 | 中途可能出现未闭合语法，最终正常 | 只渲染完整文档，无中间态 | 最终渲染与历史重载一致 |
| 工具多轮 | 轮 1 正文 + 工具 chips + 轮 2 正文 | 工具 chips/plan 实时；正文在最后一次 `delta` 中 = 所有轮正文拼接 | 与 `true` 的最终 `content` **逐字符一致** |
| 计划 `update_plan` | 实时更新计划卡 | 实时更新计划卡 | 计划卡出现时机不变 |
| 审批允许/拒绝 | 审批卡实时；允许后继续，拒绝回填模型 | 同左 | 审批卡不因关闭流式而延迟 |
| 取消（正文已生成） | 已显示部分正文 | 终态前补发 1 次 `delta`，保留已生成正文，再 `cancelled` | 正文不丢、不重复 |
| 取消（审批等待中） | 审批 Completer 返回 false → cancelled | 同左；通常无正文 → 无 `delta` | 不悬挂、不重复事件 |
| 模型错误（无正文） | `error` | `error`（无 `delta`） | 前端移除气泡 + SnackBar |
| 模型错误（有正文） | 已逐字显示；随后 `done.error`（现有行为） | 补发 1 次 `delta` 后 `done.error` | 不新增错误形态 |
| 空回复（无正文/无步骤） | 无 `delta`，`done`（`message_id=null`） | 同左 | 不产生空 `delta` |
| 空正文但有步骤 | 无 `delta`，`done`（`message_id` 非空） | 同左 | 保持现状空卡片，不造占位文案 |
| 强制收尾补正文 | 补写文本以 `delta` 发出 | 补写文本并入最终缓冲，只发一次 | 无重复正文 |
| 达到工具上限 | 同上 | 同上 | 计划自动收尾事件照常 |
| 切换开关 | 下一条消息生效 | 下一条消息生效 | 进行中的请求行为不变 |
| 后台任务 `JobScheduler` | 现状（不展示 UI） | 现状（显式保持 `streamOutput:true`，或不传） | 落库内容一致 |

### 2.4 不变量（实现必须满足，测试逐条覆盖）

- **I1 单次性**：`stream_output=false` 的每次 run，`delta` 数量 ∈ {0,1}。
- **I2 完整性**：若 `false` 模式发出 1 条 `delta`，其 `text` 必须等于落库的 `messages.content`（即最终 `fullText`）。
- **I3 一致性**：同一输入下，`true` 模式所有 `delta.text` 拼接 == `false` 模式唯一 `delta.text` == 落库正文。多轮工具调用时必须跨轮累加，不能每轮重置。
- **I4 不丢正文**：`cancelled` 前若已有正文，必须且只补发一次 `delta`；不得重复补发。
- **I5 终态唯一**：`done`/`cancelled`/`error` 仍然互斥且各至多一次；`done` 不新增正文。
- **I6 实时事件不变**：`run/step/plan/approval/agent` 的顺序与时机不受开关影响。
- **I7 持久化一致**：`messages.content`、`steps`、`plan`、`refs`、`model`、`tokens_*`、`usage` 写入与 `true` 模式一致；历史重载看不出模式差异。
- **I8 单点读取**：开关在请求开始时读取一次并作为参数传入；`runAgent` 内部不再读设置，保证运行中切换不影响当前请求。

### 2.5 时序对比（普通问答）

```
true:
  run → delta("你") → delta("好") → delta("呀") → done

false:
  run ─────────────（正文在内存缓冲，无 delta）─────────────→ delta("你好呀") → done
        ↑ step/plan/approval 仍可在中途实时出现
```

---

## 3. 设置契约

### 3.1 数据层（`app/lib/backend/db.dart`，backend 负责）

1. `_defaults` 增加：
   ```dart
   'stream_output': 'true',
   ```
   位置：`db.dart:188-202`（与 `theme`/`auto_check_updates` 同组）。
2. 无需建表/迁移语句：`INSERT OR IGNORE INTO settings(key,value)` 会在每次启动补上默认值（`db.dart:180-185`），老库升级自动获得 `true`。
3. 读取统一用：
   ```dart
   Db.setting('stream_output', 'true') == 'true'
   ```
   缺键、空值、旧库都得到 `true`；写入统一走 `Db.setSetting('stream_output', value ? 'true' : 'false')`（`db.dart:237-250`）。
4. 不新增列、不新增表、不改其它 key。

### 3.2 HTTP API（`app/lib/backend/server.dart`，backend 负责）

**GET `/api/settings`**（`server.dart:74-87`）响应增加一个布尔字段：

```json
{
  "api_key": "sk-••••••••abcd",
  "has_key": true,
  "base_url": "https://api.deepseek.com",
  "model": "deepseek-flash",
  "reason_model": "deepseek-v4-pro",
  "theme": "system",
  "custom_modes": "[]",
  "auto_check_updates": true,
  "sidebar_collapsed": false,
  "stream_output": true
}
```

**PUT `/api/settings`**（`server.dart:88-117`）接受并持久化：

```json
{ "stream_output": false }
```

- 仅当 `body['stream_output'] is bool` 时写入；其它类型静默忽略（与现有 `auto_check_updates`/`sidebar_collapsed` 的处理一致，不新增 400）。
- PUT 响应维持现状（可附加 `stream_output`，但**前端不得依赖** PUT 响应里其它字段——现状只回 `has_key/base_url/model`）。
- 不新增端点、不在 `/api/chat` 请求体加字段。

**`/api/chat`**（`server.dart:297-400`）：

```dart
// 请求开始时读取一次，作为本次 run 的快照
final streamOutput = Db.setting('stream_output', 'true') == 'true';
...
final events = runAgent(
  ...,
  streamOutput: streamOutput,
);
```

- 读取点放在 `_chat` 内、`runAgent` 调用前即可；不得在 `runAgent` 内部再次读库。
- `/api/health` 不加字段。

### 3.3 `SettingsData`（`app/lib/models.dart`，frontend 负责）

```dart
final bool streamOutput;

SettingsData({
  ...,
  this.streamOutput = true,
});

factory SettingsData.fromJson(Map<String, dynamic> json) => SettingsData(
      ...,
      streamOutput: (json['stream_output'] ?? true) as bool,
    );
```

- 默认值必须是 `true`；后端字段缺失（旧后端/旧响应）时保持 `true`。
- 不新增 `toJson`；保存由 `LoopApi.saveSettings` 负责。

### 3.4 `LoopApi`（`app/lib/api.dart`，frontend 负责）

`saveSettings`（`api.dart:110-130`）新增可选参数并写入 payload：

```dart
Future<SettingsData> saveSettings({
  ...,
  bool? streamOutput,
}) async {
  ...
  if (streamOutput != null) payload['stream_output'] = streamOutput;
  ...
}
```

`settings()`（`api.dart:107-108`）无需改，`SettingsData.fromJson` 自动带上新字段。

### 3.5 `AppState`（`app/lib/state.dart`，frontend 负责）

新增 getter/setter：

```dart
bool get streamOutput => settings?.streamOutput ?? true;

/// 返回是否保存成功；失败时已回滚到旧值。
Future<bool> setStreamOutput(bool value) async {
  final current = settings;
  if (current == null) return false;
  if (current.streamOutput == value) return true;
  settings = /* 复制 current 的全部字段，仅替换 streamOutput */;
  notifyListeners();
  try {
    await api.saveSettings(streamOutput: value);
    return true;
  } catch (_) {
    settings = /* 恢复 current */;
    notifyListeners();
    return false;
  }
}
```

硬性要求：

1. **乐观更新 + 失败回滚**：开关立即变化；保存失败恢复旧值并 `notifyListeners()`，由设置页提示。
2. **全字段拷贝**：不要只保留少数字段。建议在 `state.dart` 内加一个私有 `_copySettings(SettingsData s, {bool? streamOutput})`，显式复制 `apiKeyMasked/hasKey/baseUrl/model/reasonModel/theme/customModes/autoCheckUpdates/sidebarCollapsed/streamOutput`；同步修复 `setSidebarCollapsed`（`state.dart:114-131`）与 `setAutoCheckUpdates`（`state.dart:133-149`）里的手工 `SettingsData(...)`，加上 `streamOutput: current?.streamOutput ?? true`，否则触发这两个开关会重置流式开关（回归风险 R7）。
3. **不要用 `saveSettings` 的返回值覆盖 `settings`**：PUT 响应字段不全，沿用“先本地更新 → 调 API → 失败回滚 / 或再 `refreshSettings()`”的现有模式。
4. 切换后不主动重新加载会话、不重发消息、不清空输入框。
5. 建议（为测试）：`AppState({LoopApi? api}) : api = api ?? LoopApi();`，全局 `appState` 不变；便于注入假 API 做单元测试。

### 3.6 设置页 UI（`app/lib/screens/settings_screen.dart`，frontend 负责）

在「外观」卡片（`settings_screen.dart:131-158`）之后、「DeepSeek 接入」卡片（`:160`）之前，新增一张独立卡片，标题 **「对话与模型」**：

```
对话与模型
────────────────────────────────────────────
流式输出                                  [开关]
开启后逐字显示；关闭后等待完整回复；对下一条消息生效。
```

- 控件：`SwitchListTile`（`contentPadding: EdgeInsets.zero`、`dense: true`，风格与 `settings_screen.dart:317-327` 的更新开关一致）。
- 标题文案：`流式输出`；说明文案**逐字固定**为：
  > 开启后逐字显示；关闭后等待完整回复；对下一条消息生效。
- 初始值：`appState.settings?.streamOutput ?? true`。
- `onChanged`：
  ```dart
  final ok = await appState.setStreamOutput(value);
  if (!mounted) return;
  setState(() {});
  if (!ok) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('流式设置保存失败，已恢复原状态'),
      backgroundColor: pal.danger,
    ));
  }
  ```
- **即时保存**，不依赖页面的「保存」按钮；不改动现有「保存」按钮的职责。
- 切换只影响下一条消息；页面不需要“保存成功”提示（静默成功即可），失败必须提示并回滚。
- 窄窗口（900×600）下与现有卡片一样自适应，无横向溢出。

### 3.7 “对下一条消息生效”的精确含义

- 后端在**新请求进入时**取快照：请求 A 运行中把开关从 `false` 改成 `true`，A 仍是 `false` 行为；紧接着的请求 B 用 `true`。
- 前端不需要把开关值塞进 `/api/chat` 请求；后端 DB 是唯一事实源（Web/Windows 共用同一后端数据库）。
- 设置页的开关只改 DB，不触碰当前正在跑的 SSE 流。
- 保存是本地环回 PUT，正常在再次发送前已完成；极端竞态（切换开关后立刻回车）可能让这一条消息仍按旧值执行。首版接受该毫秒级窗口，不做“发送前强制刷新设置”；设置页刷新后会显示 DB 中的真实值。

---

## 4. 兼容性

### 4.1 Markdown / 公式 / 代码块

- 渲染入口不变：`MarkdownText(message.content)`（`chat_screen.dart:981`）与 `app/lib/widgets/markdown_text.dart`（含 KaTeX、行内代码、加粗内公式等；见 `markdown_math_test.dart` 6 条回归）。
- `true`：仍可能在生成中出现未闭合代码围栏/公式，最终收敛；`false`：只在完整正文到达后渲染一次，中间态更少。
- 不在本次引入增量 Markdown 解析/打字机动画；不改 `markdown_text.dart`。

### 4.2 附件图片 / 截图

- 上传链路独立：`POST /api/upload`（`server.dart:701-758`）→ 附件 id `img_*`/`mat_*` → `/api/chat` 透传 → `agent.dart:64-79/97-131/181-183` 组装多模态消息。
- 图片展示：附件缩略图（`chat_screen.dart:755-830`）、用户消息里的图片（`:909-948`）、`/api/uploads/<id>`（`server.dart:204-213`）、大图预览（`image_preview.dart`）。
- 截图：`_takeScreenshot`（`chat_screen.dart:213-265`）→ 上传 → 附件，与 SSE 开关无交互。
- 历史消息附件元数据落库 `messages.attachments`（`server.dart:345-353`、`db.dart:163`），不受影响。

### 4.3 插件命令

- 现状：正式版**没有**插件命令的运行时集成——仓库只有 `plugins/registry.json`、`plugins/examples/study-plan/*`、`plugins/packages/*.loopplugin` 资源，`app/lib` 中没有任何插件代码引用（已全量检索）。
- 因此本开关与插件命令无交叉；**本次不改 `plugins/`**。未来若插件通过 `/api/chat` 发消息，自动继承同一设置。

### 4.4 自定义模式 / 思考强度

- 模式与思考强度是**请求级参数**：`mode`、`mode_prompt`、`thinking`（`chat_screen.dart:300-307`、`api.dart:283-290`、`server.dart:379-381`）。
- 自定义模式 CRUD 走 `appState.saveCustomModes` → `POST/PUT /api/settings` 的 `custom_modes`（`state.dart:106-112`、`server.dart:108-110`），与 `stream_output` 是独立 key，互不覆盖。
- `thinking == 'high'` 时使用 `reason_model`（`agent.dart:144-146`），与开关无关；切换开关不改变模型、不改变系统提示。

### 4.5 停止按钮

- 交互不变：`_sending` 时按钮变红/停止图标（`chat_screen.dart:1205-1213`），调用 `_stop()` → `POST /api/agent/cancel`（`:387-395`）→ `AgentRun.cancel()`。
- `false` 模式下：
  - 正文缓冲期间取消：若已有正文，缓冲在 `cancelled` 前一次性补发；前端保留正文并提示“已停止本次执行”。
  - 审批等待中取消：Completer 返回 `false`，`checkCancelled` 抛 `AgentCancelled`，照常 `cancelled`。
- `run` 事件未到时点停止仍是现有 no-op（`_runId == null`），本次不修。

### 4.6 审批

- `approval` 事件实时性不变；审批卡仍插在输入框上方。
- 审批期间 SSE 连接保持打开（可能长时间无事件），与本开关无关；**不新增心跳/超时**。
- 允许/拒绝逻辑在 `agent.dart:292-309`，与正文呈现无关。

### 4.7 审计

- `agent_audit` 每次工具调用仍记录 `tool/args/result/risk/approval/duration_ms`（`agent.dart:81-95`、`:283-337`）。
- 工具照常执行（`false` 只是不转发正文），因此审计条数/内容与 `true` 一致。

### 4.8 token / cost

- usage 累计在流循环中（`agent.dart:211-215`），与正文转发无关；`estimateCost` 与高峰倍率不变（`llm.dart:38-45`）。
- `done` 的 `tokens_in/tokens_out/cost` 不变；`messages.tokens_*` 与 `usage` 表写入不变（`agent.dart:419-442`）。
- 前端 token/cost 行渲染不变（`chat_screen.dart:1005-1013`）。

### 4.9 历史消息

- 落库内容始终是 `fullText`（跨轮最终正文）；`false` 模式只是把同一字符串延后一次性发送。
- 重新加载会话（`GET /api/conversations/{id}/messages`，`server.dart:281-293`）时不区分模式；`content/steps/refs/plan/attachments/tokens` 与 `true` 完全一致。
- 因此“关闭流式”不会造成历史消息缺失或顺序变化。

### 4.10 Web / Windows

- Windows：`main.dart:42` 起进程内 Dart UI+后端；`start_io.dart` 启动 `Backend`。
- Web：`start_stub.dart` 为空实现，前端按 `LoopApi.defaultBaseUrl` 连 `127.0.0.1:8765` 或同源（`api.dart:29-39`）；设置同样存在后端 DB，开关语义一致。
- SSE 传输不变：`package:http` 流式读取；`false` 模式单条 `delta` 可能较大（几十 KB～数百 KB），仍是一行 JSON，解析逻辑无需变化。
- 版本配套：Web 前端与新后端须同版本；旧后端没有 `stream_output` 时新前端按默认 `true` 显示，保存会被忽略（刷新后回到 `true`）——发布只发 Windows 正式版，不承诺跨版本 Web 混用。

### 4.11 后台任务 / 子 Agent / MCP / 浏览器

- `JobScheduler.runJob` 只消费事件更新状态（`job_scheduler.dart:81-100`），无 UI；`runAgent` 的 `streamOutput` 参数默认 `true`，后台任务**不读取该设置**，行为保持现状。
- 子 Agent `runSubAgent` 直接用 `llm.streamChat` 聚合摘要（`sub_agent.dart:49-115`），不经过 `runAgent` 的 delta 转发，完全不受影响。
- MCP/浏览器/Shell/文件工具与审计逻辑不改。

### 4.12 发布 / 自动更新

- 版本升到 `0.4.0`：`app/pubspec.yaml:19`（`version: 0.4.0+13`）、`app/lib/update/app_version.dart:3`（`current = '0.4.0'`）、`README.md` 顶部版本与 changelog、`docs/release-v0.4.0.md`。
- `packaging/build_native.ps1` 从 `pubspec.yaml` 读取版本写 `version.json`（`build_native.ps1:33-37`），无需额外改脚本。
- 不自动创建 GitHub Release；不推 tag；构建产物在 `release\Loop-Desktop` 与 `release\Loop-Desktop-win64.zip`。

---

## 5. 技术边界与非目标

### 5.1 为什么首版用“后端缓冲”，而不是 provider `stream:false`

| 维度 | 继续消费 provider 流 + 后端缓冲（选用） | 改成 `stream:false`（不选） |
|---|---|---|
| 取消 | 每 chunk / 每个工具前检查 `run.checkCancelled()`，可精确中断并保留部分正文 | 只能等完整响应或断开 HTTP；拿不到“已生成到哪” |
| 工具调用 | 现有 tool_call delta 累积逻辑原样复用 | 需另写一条非流式 tool_calls 解析分支 |
| 多轮循环 | 单一 `runAgent` 路径，轮次/预算/防重复逻辑不变 | 需并行维护两种响应形态，测试面翻倍 |
| usage | 现有 chunk usage 处理不变 | 形态不同，需另写 |
| 审批 | 审批挂起期间流仍活着 | 非流式请求挂起模型调用，超时/重试风险更高 |
| 协议稳定 | 事件名、请求体、前端解析器都不动 | 至少多一条代码路径与回归面 |

结论：**provider 层永远 `stream:true`；开关只决定 agent 是否把正文 delta 立即转发。**

### 5.2 缓冲位置与实现草图（backend 负责）

只改 `app/lib/backend/agent.dart`，`llm.dart` 不改：

```dart
Stream<AgentEvent> runAgent({
  ...,
  bool streamOutput = true,   // 默认 true：背景任务/旧调用不受影响
}) async* {
  ...
  // 正文 token：
  if (text is String && text.isNotEmpty) {
    roundText += text;
    fullText += text;
    if (streamOutput) yield AgentEvent('delta', {'text': text});   // 所有 delta yield 都受开关控制
  }
  ...
  // forceFinish 的两处补正文（agent.dart:392-399）：
  //   仍然修改 fullText，但仅在 streamOutput == true 时 yield delta
  ...
  // 终态前（cancelled / done 之前）统一 flush，最多一次：
  if (!streamOutput && fullText.isNotEmpty) {
    yield AgentEvent('delta', {'text': fullText});
  }
  if (cancelled) { yield AgentEvent('cancelled', ...); return; }
  if (errorMessage.isNotEmpty && fullText.isEmpty) { yield AgentEvent('error', ...); return; }
  yield AgentEvent('done', ...);
}
```

要点：

1. **所有** `yield AgentEvent('delta', ...)` 点（token 转发 `:224`、forceFinish `:394`/`:398`）都要受 `streamOutput` 控制；否则 false 模式会出现 2 条以上 delta 或重复正文。
2. flush 只放在终态分发之前（推荐紧接在持久化之后）：`cancelled` 分支会 `return`，`done` 分支在末尾，只执行一次；不要在流循环中途 flush。
3. `roundText` 仍要作为工具轮 assistant 消息内容回填（`:259`），**不能**因为不转发就清空；`fullText` 跨轮累加不变。
4. `error` 分支按现有条件（正文为空）不会 flush；如实现想“防御性 flush”，也必须保证空正文不发 `delta`。
5. 不改 `done` 结构、不加 `content` 字段、不改事件名。
6. 测试注入（推荐，t2 可用等价方案）：
   - `runAgent` 增加可选 `ChatChunkStream? chatStream`（默认 `null` → 内部包一层 `streamChat` 适配器），测试传假 chunk 流，避免真实网络。参考签名：
     ```dart
     typedef ChatChunkStream = Stream<Map<String, dynamic>> Function(
       LlmConfig config,
       List<Map<String, dynamic>> messages,
       List<Map<String, dynamic>>? tools,
       String thinking,
     );
     ```
     默认适配器：`(c, m, t, th) => streamChat(config: c, messages: m, tools: t, thinking: th)`。
   - `db.dart` 增加 `static void initInMemoryForTests()`（`sqlite3.openInMemory()` + `_migrate()` + `_ready=true`），测试用 `setUpAll` 初始化一次。

### 5.3 API / 事件兼容性承诺

- `/api/chat` 请求体**不新增**字段（`stream_output` 不通过请求体传）。
- `GET/PUT /api/settings` 只增加一个布尔字段；旧客户端忽略未知字段。
- SSE 事件集合仍为 `run / step / plan / approval / agent / delta / cancelled / done / error`，不重命名、不新增、不删除。
- 前端不应依据设置值改变事件处理逻辑；唯一差异是 `delta` 何时到达。

### 5.4 明确非目标

1. 不切换模型、不改变默认模型/推理模型，不改系统提示。
2. 不把 provider 请求改成 `stream:false`，不加“非流式回退”。
3. 不改 SSE 事件名/字段/顺序语义，不新增 `content` 到 `done`。
4. 不做打字机动画、逐字定时器、假流式（前端重放）。
5. 不做每条消息/每个会话的独立开关（只做全局设置）。
6. 不改插件系统/插件命令（当前未接入运行时）。
7. 不改 `Loop-Test`、不改 `server/`（旧 Python 后端）、不自动发 GitHub Release。
8. 不重构 `chat_screen` 的渲染管线，不做 Markdown 增量渲染。
9. 不修历史遗留的“有正文时错误通过 `done.error` 下发、前端不提示”的行为（见 R11）。

---

## 6. 测试矩阵与验收清单

### 6.1 所有权与文件（避免并行冲突）

| 任务 | 可直接修改 | 不要修改 |
|---|---|---|
| t2 backend | `app/lib/backend/db.dart`、`server.dart`、`agent.dart`；新增 `app/test/streaming_backend_test.dart` | `llm.dart`（无需改）、前端文件、`app/test` 其它文件 |
| t3 frontend | `app/lib/models.dart`、`api.dart`、`state.dart`、`screens/settings_screen.dart`、`screens/chat_screen.dart`；新增 `app/test/streaming_settings_test.dart`、`app/test/streaming_chat_test.dart` | 后端文件、`markdown_text.dart`、`plugins/` |
| t4 verify | 只读代码 + 运行命令 + `.tools/` 本地脚本（未跟踪）+ 新增 `docs/streaming-test-report.md` | 不改实现；不改 `Loop-Test` |
| t6 integrate | 版本/README/release 文档/构建 | 不改功能代码语义 |

### 6.2 后端测试（`app/test/streaming_backend_test.dart`）

前置：`Db.initInMemoryForTests()`（`setUpAll`）；把 `workspace_path` 指向测试临时目录（避免 `allToolDefinitions/系统提示` 触碰真实 `%USERPROFILE%\LoopWorkspace`）；每个用例清理 `messages/conversations/agent_runs/agent_audit/usage/notes/tasks`，并把 `stream_output` 复位为 `true`。用假 `chatStream` 按 `messages` 内容决定返回第几轮 chunk（不需要网络/API Key）。

| # | 用例 | 断言 |
|---|---|---|
| B1 | `true` 模式逐 delta | 3 个正文 chunk → `delta` 事件 3 条，拼接 `"你好呀"`，`done` 最后 |
| B2 | `false` 模式单次 | 同 3 chunk → `delta` 恰好 1 条、`text=="你好呀"`、位于 `done` 之前 |
| B3 | `false` 工具多轮 | 轮 1：正文 `"我先查一下。"` + `get_today` tool_call；轮 2：正文 `"今天有 0 个待办。"` → `step` 事件存在、工具真的执行（`done.steps` 含 `get_today/done`、`agent_audit` 有行）；`delta` 恰好 1 条且 `== "我先查一下。今天有 0 个待办。"`；落库 `messages.content` 相同 |
| B4 | 取消（有正文） | 第 1 个 chunk 后 `run.cancel()` → `false`：`delta` 1 条 + `cancelled`（`partial:true`），正文不重复；落库正文 = 已生成部分 |
| B5 | 取消（无正文） | 审批等待中取消 → 无 `delta`，`cancelled` 一次 |
| B6 | 空回复 | 只返回 usage/空 choices → `true`/`false` 均 0 条 `delta`，`done` 一次；tokens 正常 |
| B7 | 强制收尾 | 构造 `forceFinish` 路径（如重复工具/预算耗尽）→ `false` 仍只有 1 条 `delta`，内容含补写后缀，不重复 |
| B8 | 设置默认/持久化 | 新库 `Db.setting('stream_output','true')=='true'`；`setSetting(...,'false')` 后读回 `false`；`_defaults` 覆盖缺键 |
| B9 | 快照语义 | `runAgent(streamOutput:false)` 运行中把 DB 改 `true`，本次仍单 delta；下一次调用参数为 `true` 时多 delta（可在 B2 中顺带验证） |

### 6.3 前端测试

**`app/test/streaming_settings_test.dart`**

| # | 用例 | 断言 |
|---|---|---|
| F1 | `SettingsData` 默认 | `fromJson({})` → `streamOutput == true`；`fromJson({'stream_output': false})` → `false` |
| F2 | 设置 API 契约 | 测试内 `HttpServer` + `LoopApi(baseUrl: ...)`：`GET /api/settings` 返回 `stream_output:false` → `settings()` 解析为 false；`saveSettings(streamOutput:false)` 请求体含 `"stream_output": false`（布尔，不是字符串） |
| F3 | AppState 乐观/回滚 | 假 `LoopApi` 注入 `AppState(api: fake)`：`setStreamOutput(false)` → `settings!.streamOutput==false`、调用一次 `saveSettings`；fake 抛错时 → 返回 false 且恢复旧值 |
| F4 | 字段不被重置 | 先 `streamOutput=false`，再 `setSidebarCollapsed(true)`/`setAutoCheckUpdates(false)` → `streamOutput` 仍为 false（覆盖 R7） |
| F5 | 设置页渲染 | `appState.settings = SettingsData(... streamOutput:false ...)`，pump `SettingsScreen(active:true)`：存在 `流式输出` 文案、完整说明文案、Switch 值为 false；不触发网络 |

**`app/test/streaming_chat_test.dart`**（建议给 `ChatScreen` 增加可选 `AppState? state` 测试注入；生产不传，`main.dart:234` 保持 `ChatScreen(active: ...)`。测试用假 `AppState` 覆盖 `refreshConversations`，假 `LoopApi` 覆盖 `chat/createConversation/messages/cancelRun/approveRun`，全程不碰网络）：

| # | 用例 | 断言 |
|---|---|---|
| F6 | `true` 增量 | 假 `chat()` 用 `StreamController`：先 `run`，加 `delta("你")` pump → 显示“你”；再加 `delta("好")` → 显示“你好”；`done` 后 `_sending` 结束、token 行出现 |
| F7 | `false` 等待态 + 单次 | 只发 `run`/`step`/`plan`（无 delta）→ 显示“正在思考…”，工具 step chip 与计划卡可见；随后单条 `delta("完整回答")` → 正文出现；再 `done` → 正常结束 |
| F8 | 停止/取消 | `run` 后点“停止” → 假 API 收到 `cancelRun`；`cancelled` 后正文保留、`_sending` 结束、出现“已停止本次执行” |
| F9 | 错误不崩 | `error` 事件 → assistant 气泡移除、错误 SnackBar；无异常 |
| F10 | 审批不因 false 延迟 | `approval` 事件在 false 流中仍渲染审批卡；允许/拒绝按钮可点并调用 `approveRun` |

> 若 t3 不愿引入 `AppState` 注入，至少保留 F1–F5，并用 F6–F9 的等价纯函数/组件测试覆盖（如把 `_send` 的事件 switch 抽成可测函数）；但 `false` 等待态与 step 实时性必须有自动化证据。

### 6.4 命令（Windows PowerShell，仓库根目录开始）

```powershell
# 1) 静态检查 + 全量测试（app 目录）
cd D:\DSH_Workspace\Prog2_app\app
..\.tools\flutter\bin\flutter.bat analyze      # 必须 No issues found
..\.tools\flutter\bin\flutter.bat test         # 必须 All tests passed（含新增用例）

# 2) 只跑新增用例
..\.tools\flutter\bin\flutter.bat test test\streaming_backend_test.dart
..\.tools\flutter\bin\flutter.bat test test\streaming_settings_test.dart
..\.tools\flutter\bin\flutter.bat test test\streaming_chat_test.dart

# 3) 基线（t1 已跑，供对比）
#    analyze: No issues found (10.3s)
#    test: 17 passed
```

### 6.5 端到端验证（mock LLM，t4）

现有可复用工具（未跟踪，不改 `Loop-Test`）：

- `.tools/mock_llm.py`：OpenAI 兼容 SSE mock，监听 `127.0.0.1:9999`；正文按 6 字一段发送（`mock_llm.py:77-81`），可触发计划/工具/审批/普通问答（`:83-156`）。
- `.tools/agent_smoke.py`：把 `base_url` 指到 9999 并驱动 `/api/chat`（`:49-74`），可作为脚本骨架。

推荐步骤（隔离数据，避免碰真实用户库）：

```powershell
$root = 'D:\DSH_Workspace\Prog2_app'
$data = Join-Path $env:TEMP 'loop-stream-verify'
New-Item -ItemType Directory -Force $data | Out-Null
# AppPaths 只有在候选目录已存在 loop.db 时才选 LOOP_DATA_DIR，因此先建空文件
if (-not (Test-Path (Join-Path $data 'loop.db'))) {
  New-Item -ItemType File (Join-Path $data 'loop.db') | Out-Null
}
$env:LOOP_DATA_DIR = $data

# 前置：确认没有其它 Loop 实例占用 8765（否则新实例会静默复用旧后端/旧数据）
Get-NetTCPConnection -LocalPort 8765 -ErrorAction SilentlyContinue

# 终端 1：mock 模型（9999 端口）
& "$root\server\.venv\Scripts\python.exe" "$root\.tools\mock_llm.py"

# 终端 2：带隔离数据目录启动（或 flutter run -d windows）
$env:LOOP_DATA_DIR = $data
Start-Process "$root\release\Loop-Desktop\Loop.exe"
# 轮询 http://127.0.0.1:8765/api/health 直到 ok，再开始脚本
```

开始断言前先隔离工作区（否则 `fs_write` 会写到真实 `%USERPROFILE%\LoopWorkspace`）：

```powershell
# POST /api/agent/settings {"workspace_path":"<临时目录>"}
```

再用 `.tools/streaming_smoke.py`（建议新建，逻辑见附录 C）断言：

1. 新库 `GET /api/settings` 的 `stream_output == true`。
2. `PUT {"stream_output": false}` → `GET` 为 false；`PUT {"base_url":"http://127.0.0.1:9999"}`。
3. 发 `"直接回答"`（普通问答）：统计 SSE 事件 → **仅 1 条 `delta`**，`text` 为 mock 的完整回答；`done.tokens_in==260/tokens_out==90`。
4. `PUT {"stream_output": true}` → 同样问题 → `delta` **> 1** 条，拼接结果与步骤 3 的单条文本一致。
5. `PUT {"stream_output": false}` + 发 `"计划"`：`plan`/`step` 事件在最终 `delta` 之前出现；`delta` 恰好 1 条；最终文本含“计划已执行”。
6. 审批：发 `"文件"`，收到 `approval` 后自动 `POST /api/agent/approve {allow:true}`；`delta` 1 条；工作区文件生成；`GET /api/audit` 有对应记录。
7. 取消：发 `"文件"` 后在 `approval` 事件时 `POST /api/agent/cancel`；收到 `cancelled`，无悬挂；再发一条普通消息确认服务仍可用。
8. 重启应用（同一 `LOOP_DATA_DIR`；先停掉旧进程并确认 8765 已释放）→ `GET /api/settings` 仍为 false（持久化）。
9. 运行中切换：发慢速问题（可给 mock 加“慢速”分支或在 `delta` 间隔上放大），运行中 `PUT stream_output=true`，当前请求仍按 false 单 delta；下一条消息多 delta。
10. 关闭 mock 后发消息：`error` 事件 + 前端可读提示；恢复 `base_url`。

证据留存：把命令、SSE 事件序列（至少 `run/delta/step/plan/approval/done/cancelled` 的名称与数量）、`GET /api/settings` 前后值、`version.json` 与构建时间写入 `docs/streaming-test-report.md`。

### 6.6 手工验收（Windows 正式版）

- 设置页：新卡片可见、文案逐字正确、开关默认开；切换后离开再回来仍保持；关闭应用重启仍保持。
- `false`：发送后正文区显示“正在思考…”；工具/计划/审批实时出现；回答完整后一次性显示；Markdown、公式、代码块、引用角标正常。
- `true`：与 v0.3.9 体验一致（逐字）。
- 会话中操作：停止、审批允许/拒绝、存笔记、加待办、复制 Markdown、图片/截图附件、图片大图预览、历史切换、新建/删除会话、窄窗口 900×600、浅色/深色主题均无回归。
- 检查 `messages` 历史重载：关闭流式生成的回答与开启流式生成的回答，正文/步骤/计划/refs/token 完全一致。
- 版本：设置页“关于与更新”显示 v0.4.0；`release\Loop-Desktop\version.json` 为 `{"version":"0.4.0"}`。

### 6.7 构建与发布（t6）

```powershell
cd D:\DSH_Workspace\Prog2_app
powershell -ExecutionPolicy Bypass -File packaging\build_native.ps1
Get-Content release\Loop-Desktop\version.json   # {"version":"0.4.0"}
Test-Path release\Loop-Desktop\Loop.exe
Test-Path release\Loop-Desktop-win64.zip
```

- 构建前改版本：`app/pubspec.yaml`（`0.4.0+13`）、`app/lib/update/app_version.dart`、`README.md`、`docs/release-v0.4.0.md`。
- **不**自动创建 GitHub Release、不推 tag；保留用户手动发布步骤。
- 确认 `git status` 只含本次改动 + 既有未跟踪 `.agent-teams/`；`D:\DSH_Workspace\Loop-Test` 无改动。

### 6.8 最终验收清单

- [ ] `docs/streaming-spec.md` 覆盖 §1–§7（t1）
- [ ] `stream_output` 默认 true，老库升级自动补齐，缺键回退 true（B8）
- [ ] GET/PUT `/api/settings` 布尔契约正确，布尔类型校验（F2、§3.2）
- [ ] `true` 模式行为与 v0.3.9 等价（B1、F6、E2E-4）
- [ ] `false` 模式每次 run 恰好 0/1 条 `delta`，`text==落库正文`（B2/B3/B7、E2E-3/5）
- [ ] 多轮工具正文拼接与 `true` 一致（B3）
- [ ] 取消保留已生成正文、无重复（B4/B5、E2E-7）
- [ ] 空回复不产生空 delta（B6）
- [ ] `step/plan/approval/agent` 实时性不变（F7/F10、E2E-5/6）
- [ ] token/cost/audit/refs/plan 落库与展示不变（B3、E2E-3/6）
- [ ] 设置页开关 + 说明文案 + 失败回滚（F3/F5、手工）
- [ ] 切换只影响下一条消息（B9、E2E-9）
- [ ] 侧栏折叠/自动更新开关不重置流式开关（F4）
- [ ] `flutter analyze` 0 issues；`flutter test` 全通过（含新增）
- [ ] 构建 v0.4.0 产物与 `version.json` 正确；未自动发布 Release（§6.7）
- [ ] `Loop-Test`、`server/`、`plugins/` 未改

---

## 7. 回归风险清单

| # | 风险 | 症状 | 规避/检测 |
|---|---|---|---|
| R1 | `false` 模式仍逐 chunk `setState` | 性能没变好、滚动抖动 | 缓冲只在内存；不要为每个 chunk `notifyListeners`/`setState`；B2 断言单 delta |
| R2 | 滚动位置/动画 | 每次 delta 触发 180ms `animateTo`；false 模式一次到达时跳到底部 | 保持 `_scrollToEnd` 只在 `delta` 后调用；不新增 step/plan 滚动触发；手工看长回答 |
| R3 | 工具轮次正文拼接错误 | 每轮重置缓冲，最终只剩最后一轮 | 只累加 `fullText`、不重置；B3 逐字符比对 |
| R4 | 完成事件重复正文 | `forceFinish` 补写又单独 yield，或 flush 两次，出现重复段落 | 所有 delta yield 受 `streamOutput` 控制 + 单次 flush；B7 |
| R5 | `done` 被塞正文 | 前端重复追加/历史与实时不一致 | 不改 `done` schema；I5 |
| R6 | 缺键默认值 | 老库/旧响应把开关显示成 false | DB 默认 + `INSERT OR IGNORE`；`SettingsData` 默认 true（F1） |
| R7 | `setSidebarCollapsed`/`setAutoCheckUpdates` 重建 `SettingsData` 漏字段 | 动一下侧栏/更新开关，流式开关自动变回“开” | §3.5 第 2 条 + F4 单测 |
| R8 | PUT 响应字段不全 | 用 `saveSettings` 返回值覆盖 `settings` 后其它设置丢失 | 不覆盖；失败回滚或 `refreshSettings` |
| R9 | 取消/错误路径残留缓冲 | 取消后正文丢失，或取消事件后又冒出一条 delta | 终态前统一 flush 一次；B4/B5 |
| R10 | 运行中切换影响当前请求 | 当前回答显示方式突变、或后端两套逻辑 | 请求级快照；B9 |
| R11 | 有正文时的错误走 `done.error` | 前端只显示正文、不提示错误（现状） | 本迭代不修，避免扩大范围；记入已知限制 |
| R12 | 空回复 | 空卡片、无“没有内容”提示（现状） | 保持现状，不造占位正文；B6 |
| R13 | 大正文单行 SSE | 数百 KB 单行 JSON、内存翻倍 | 现有解析可处理；E2E 用长回答（>5k 字）验证；不设人为分片 |
| R14 | 后台任务被误改 | 关闭流式后后台任务事件/耗时变化 | `runAgent` 默认 `streamOutput:true`，`job_scheduler.dart` 不传；§4.11 |
| R15 | 并行任务写冲突 | t2/t3 同时改 `models.dart`/`state.dart` | 按 §6.1 所有权；`models.dart`/`api.dart` 归 t3，后端不碰 |
| R16 | 版本/构建遗漏 | `version.json` 仍是 0.3.9、exe 未替换 | §6.7；构建后核对 `version.json` 与设置页版本 |
| R17 | 误改 `Loop-Test`/`server/` | 违反范围、污染交付 | `git status` + 只改 `app/` 与 `docs/`；`server/` 是旧 Python 后端，不动 |
| R18 | 插件命令被牵连 | 无代码路径却改了 `plugins/` | 不改；§4.3 |
| R19 | 切换后立刻发送的毫秒级竞态 | 极快操作下这一条消息仍按旧值呈现 | 本地 PUT 通常 <50ms；§3.7 已声明接受；不做发送前同步 |

---

## 8. 决策记录与已知限制

- **D1**：开关存后端 DB（非 SharedPreferences/浏览器本地），因为 Web/Windows 共用同一后端，且 `.env`/进程内后端没有客户端持久层。
- **D2**：不在 `/api/chat` 请求体里传开关：避免前端/后端双事实源，也让“请求级快照”由后端自然保证。
- **D3**：`false` 模式跨整个 run（含多轮工具）缓冲，而不是“每轮 flush”：满足“完成时一次性”的产品语义；代价是等待期间只有工具/计划/审批事件可见。
- **D4**：`done` 不携带正文：保持协议稳定，前端不需要“delta 与 done 二选一”的分支。
- **D5**：后台任务不读该设置：它没有展示层，改为缓冲只会增加内存/时序风险。
- 已知限制：有正文时的错误不会发 `error` 事件（`done.error`，前端不展示）；停止在 `run` 事件到达前是 no-op；空回复可能留下空卡片——均为现状，不属本次范围。

---

## 附录 A：关键文件与行号索引

| 文件 | 关键位置 | 用途 |
|---|---|---|
| `app/lib/backend/llm.dart` | 64-112（streamChat）、77（`stream:true`）、98-108（SSE 解析）、114-147（complete，仅测试/生成） | provider 流，**不改** |
| `app/lib/backend/agent.dart` | 133（runAgent）、204-242（流循环）、211-215（usage）、221-225（delta）、292-309（审批）、387-400（强制收尾补正文）、419-442（落库）、444-463（终态） | 缓冲与 flush 的唯一实现点 |
| `app/lib/backend/server.dart` | 74-117（settings GET/PUT）、297-400（_chat/SSE）、362-390（头/flush/事件循环） | 读设置并传参 |
| `app/lib/backend/db.dart` | 180-202（默认值）、237-250（setting/setSetting） | `stream_output` 默认与读写 |
| `app/lib/api.dart` | 107-130（settings/saveSettings）、273-340（chat/SSE 解析） | 客户端契约 |
| `app/lib/models.dart` | 328-362（SettingsData） | 新字段 |
| `app/lib/state.dart` | 19-164（AppState）、114-149（重建 SettingsData 的位置） | getter/setter 与字段拷贝 |
| `app/lib/screens/settings_screen.dart` | 59-83（保存按钮）、131-158（外观卡）、160-277（接入卡）、317-327（更新开关样式） | 新卡片插入点 |
| `app/lib/screens/chat_screen.dart` | 174-183（滚动）、267-372（_send/switch）、310-313（delta）、333-342（step）、387-395（stop）、909-1017（消息渲染）、969-980（思考中）、1005-1013（token 行） | 前端行为（预计不改逻辑） |
| `app/lib/backend/agent_run.dart` | 31-41（cancel/checkCancelled） | 取消语义 |
| `app/lib/backend/job_scheduler.dart` | 81-100（消费 runAgent） | 后台任务，保持默认 |
| `app/lib/backend/sub_agent.dart` | 49-115（直接 streamChat） | 子 Agent，不受影响 |
| `.tools/mock_llm.py` | 77-81（chunk 文本）、83-156（分支）、166（9999 端口） | E2E mock |
| `.tools/agent_smoke.py` | 49（设 base_url）、19-45（SSE 驱动） | E2E 脚本骨架 |
| `packaging/build_native.ps1` | 12（build windows）、33-42（version.json/zip） | 构建 |
| `app/pubspec.yaml` | 19（version） | 版本 |
| `app/lib/update/app_version.dart` | 3（current） | 版本 |

## 附录 B：`GET /api/settings` 目标形态（示例）

```json
{
  "api_key": "sk-••••••••abcd",
  "has_key": true,
  "base_url": "https://api.deepseek.com",
  "model": "deepseek-flash",
  "reason_model": "deepseek-v4-pro",
  "theme": "system",
  "custom_modes": "[]",
  "auto_check_updates": true,
  "sidebar_collapsed": false,
  "stream_output": true
}
```

兼容规则：旧客户端忽略 `stream_output`；新客户端在字段缺失时用 `true`。

## 附录 C：E2E smoke 断言思路（建议放 `.tools/streaming_smoke.py`，未跟踪工具）

```python
# 伪代码：按 event: 分帧读取 /api/chat，统计事件名与 delta 文本
def read_sse(resp):
    event, data, events = None, [], []
    for raw in resp:
        line = raw.decode("utf-8", "replace").rstrip("\n")
        if line == "":
            if event is not None or data:
                events.append((event or "message", "\n".join(data)))
            event, data = None, []
        elif line.startswith("event:"):
            event = line[6:].strip()
        elif line.startswith("data:"):
            data.append(line[5:].strip())
    return events

def assert_mode(stream_output, prompt, expect_deltas):
    put_settings({"stream_output": stream_output, "base_url": "http://127.0.0.1:9999"})
    events = post_chat(prompt)
    deltas = [json.loads(d)["text"] for e, d in events if e == "delta"]
    assert len(deltas) == expect_deltas, (stream_output, prompt, len(deltas))
    if expect_deltas == 1:
        text = deltas[0]
        assert text == full_text_from_true_mode  # 同 prompt 对照
    print(prompt, "events:", [e for e, _ in events], "deltas:", len(deltas))

# 用例：普通问答 true(>1) / false(1)；计划 false 仍见 plan/step；
#       文件 false 仍见 approval；取消后 cancelled 且无重复 delta。
```

## 附录 D：需求 → 下游任务对照

| 本 spec 章节 | t2 backend | t3 frontend | t4 verify | t6 integrate |
|---|---|---|---|---|
| §2 行为矩阵 / §5 缓冲 | 实现 + B1–B9 | 兼容性测试 | E2E 真/假模式 | 回归 |
| §3.1/3.2 设置存储与 API | db.dart/server.dart | `SettingsData`/`LoopApi` | 持久化验证 | 版本 |
| §3.5/3.6 AppState/UI | — | state.dart + settings_screen.dart + F1–F5 | 手工验收 | README |
| §4 兼容性 | 事件不变 | ChatScreen 测试 F6–F10 | Markdown/附件/历史/审批/token | 构建 |
| §6.4 命令 | analyze/test | analyze/test | analyze/test + E2E + build | build/release docs |
| §7 风险 | R1–R14 | R6/R7/R15/R19 | 全量 | R16–R18 |
