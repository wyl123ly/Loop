# Loop 多 AI 供应商接入方案（v0.7.0）

> 状态：**M1 已实现**（2026-10-25，用户指示继续目标后开工）
> 已按推荐默认执行：内置 DeepSeek/Kimi/GLM + 自定义；DeepSeek 默认；不自动故障转移；图片不支持时剔除；费用未知暂显示 0；真实 Key 由用户本机验证。  
> 目标版本：v0.7.0  
> 当前版本：v0.6.4（仅 DeepSeek）

---

## 1. 现状

当前只支持 DeepSeek，关键点：

- `lib/backend/llm.dart`：`LlmConfig.fromDb()` 固定读取 `api_key` / `base_url` / `model`。
- 请求固定为 OpenAI 风格 `POST {base_url}/chat/completions`。
- 请求体固定带：
  - `stream_options.include_usage`
  - `thinking: {type: enabled}` + `reasoning_effort`（thinking=high）
- 设置页只有一组：API Key、Base URL、对话模型、推理模型。
- `reason_model` 固定默认 `deepseek-v4-pro`。
- 模型名、价格表、错误文案都写死 DeepSeek。
- 聊天、Agent、子 Agent、后台任务都通过 `LlmConfig.fromDb()` 取配置。

结论：请求层已经是 OpenAI 兼容形态，改造重点是**配置模型抽象 + 能力差异适配**。

---

## 2. 目标

1. 内置支持：
   - DeepSeek（保持默认、完全兼容现有配置）
   - Moonshot / Kimi
   - 智谱 GLM
   - 自定义 OpenAI 兼容供应商
2. 每个供应商独立保存：
   - API Key、Base URL、对话模型、推理模型
3. 不同供应商能力差异可配置：
   - 是否支持图片
   - 是否支持工具调用
   - 是否支持 `stream_options`
   - 思考/推理参数形态
   - 自定义请求头/路径（可选）
4. 设置页可切换供应商、测试连接、查看能力标记。
5. 现有 DeepSeek 用户升级后**零操作**继续可用。
6. 不改动：会话、消息、资料、笔记、待办、截图、浮窗、极简、回答窗、MCP、审计。

---

## 3. 非目标

本次不做：

- OAuth / 账号登录
- 供应商计费/充值页面
- 本地模型下载或内置推理引擎
- 自动故障转移到另一家供应商
- 插件市场接入
- 供应商特定私有协议（只做 OpenAI 兼容层 + 少量适配字段）

---

## 4. 架构设计

### 4.1 配置模型

新增 `ProviderProfile`：

```dart
class ProviderProfile {
  final String id;              // deepseek / kimi / glm / custom_xxx
  final String name;            // 显示名
  final String baseUrl;         // 例：https://api.moonshot.cn/v1
  final String apiKey;
  final String chatPath;        // 默认 /chat/completions
  final String defaultModel;
  final String reasonModel;     // 可为空
  final ProviderCapabilities capabilities;
  final ThinkingStyle thinkingStyle;
  final AuthStyle authStyle;    // bearer / custom header
  final Map<String, String> extraHeaders;
  final Map<String, Object?> extraBody;
  final List<ModelInfo> models; // 内置候选 + 用户自定义
  final bool builtIn;
}
```

能力标记：

```dart
class ProviderCapabilities {
  final bool vision;        // 图片输入
  final bool tools;         // function calling
  final bool streamUsage;   // stream_options.include_usage
  final bool reasoning;     // 思考/推理模式
}
```

思考参数形态：

| thinkingStyle | 行为 |
|---|---|
| `none` | 不发送思考字段 |
| `deepseek` | `thinking:{type:enabled}` + `reasoning_effort` |
| `zhipu` | `thinking:{type:enabled}` |
| `openaiEffort` | 仅 `reasoning_effort` |
| `custom` | 原样合并 `extraBody` |

### 4.2 存储与迁移

新增 settings：

```text
providers_v1   = JSON 数组（所有供应商配置，Key 本地 SQLite）
active_provider = deepseek / kimi / glm / custom_xxx
```

迁移规则：

1. 首次启动 v0.7.0：
   - 把现有 `api_key` / `base_url` / `model` / `reason_model` 写成 `deepseek` profile。
   - `active_provider = deepseek`。
2. 旧字段保留只读，不删除：
   - 新代码优先读 `providers_v1`
   - 缺失/损坏时回退到旧字段
3. 以后 `PUT /api/settings` 旧字段仍然可用（兼容旧前端/脚本）。
4. 用户已有 Key 不丢失；测试只用隔离 `LOOP_DATA_DIR`。

### 4.3 解析入口

新增：

```dart
class ProviderRegistry {
  static ProviderProfile active();
  static List<ProviderProfile> all();
  static ProviderProfile? byId(String id);
  static LlmConfig toLlmConfig(ProviderProfile p, {String? modelOverride});
}
```

替换所有 `LlmConfig.fromDb()` 调用点：

- `lib/backend/server.dart`（聊天、测试连接）
- `lib/backend/agent.dart`
- `lib/backend/sub_agent.dart`
- 后台任务相关入口

---

## 5. 内置供应商预置

> 模型名/端点以官方文档为准；设置页允许手动编辑模型 ID，并优先尝试 `/models` 拉取列表。

| 供应商 | 默认 Base URL | 候选模型（可编辑） | 图片 | 工具 | 思考 |
|---|---|---|---|---|---|
| DeepSeek | `https://api.deepseek.com` | `deepseek-flash`、`deepseek-v4-pro` | flash 支持 | 支持 | deepseek 形态 |
| Moonshot / Kimi | `https://api.moonshot.cn/v1` | `kimi-k2-*`、`moonshot-v1-*`、视觉模型 | 部分模型 | 支持 | 按模型能力 |
| 智谱 GLM | `https://open.bigmodel.cn/api/paas/v4` | `glm-4.5`、`glm-4.5-air`、`glm-4v-*` | 4v 系列 | 支持 | zhipu 形态 |
| 自定义 | 用户填写 | 用户填写 | 用户勾选 | 用户勾选 | none/custom |

可选预置（默认折叠，不内置 Key）：

- 通义千问 DashScope 兼容模式
- SiliconFlow
- OpenRouter
- Ollama / LM Studio 本地端点

---

## 6. 请求适配

### 6.1 头部

- 默认：`Authorization: Bearer <key>`
- 自定义供应商允许：
  - 自定义鉴权头名（如 `api-key`）
  - 额外请求头（JSON 键值）
- Key 只在本地拼接，不写日志。

### 6.2 请求体

| 字段 | 规则 |
|---|---|
| `model` | 当前供应商对话/推理模型 |
| `messages` | 不变 |
| `stream` | 不变 |
| `temperature` | 不变 |
| `stream_options` | 仅 `streamUsage=true` 时发送 |
| `tools` / `tool_choice` | 仅 `tools=true` 时发送 |
| `thinking` / `reasoning_effort` | 按 `thinkingStyle` 映射 |
| `extraBody` | 原样合并，冲突时以用户配置为准（除 model/messages） |
| 图片块 | 仅 `vision=true` 时组装，否则不上传图片并给出提示 |

### 6.3 端点

- 默认：`{baseUrl}{chatPath}`，`chatPath` 默认 `/chat/completions`
- 自动兼容：
  - `baseUrl` 以 `/` 结尾时去重
  - 已包含 `/chat/completions` 时不再拼接
- `/models`：
  - 设置页「刷新模型列表」按钮
  - 失败则使用内置候选，不阻塞

### 6.4 能力降级

| 场景 | 行为 |
|---|---|
| 模型不支持图片 | 发送前提示“当前模型不支持图片”，图片不随请求发送；文本仍可发送 |
| 模型不支持工具 | Agent 面板提示“当前模型不支持工具调用”，可切“纯聊天模式” |
| 不支持 stream usage | 不发送 `stream_options`，token 统计可能缺失，显示“未提供” |
| 不支持思考 | 忽略 thinking=high，使用普通请求 |
| 未配置推理模型 | 回退到默认模型 |

### 6.5 错误文案

按供应商名动态显示，例如：

- `Moonshot API Key 无效或已过期`
- `智谱 GLM 账户余额不足`
- `OpenAI 兼容端点连接失败：<原因>`

### 6.6 成本

- 每个模型可选配置输入/输出单价
- 未配置单价的模型：
  - 不估算金额
  - 仍显示 token
  - UI 显示“费用未知”
- DeepSeek 现有价格保留。

---

## 7. 设置页改造

「设置」新增/调整：

### AI 供应商

- 供应商下拉/卡片列表：DeepSeek / Kimi / GLM / 自定义
- 「添加自定义供应商」
- 当前使用标记
- 每个供应商：
  - API Key（掩码显示，留空不修改）
  - Base URL
  - 对话模型（下拉 + 可编辑）
  - 推理模型（下拉 + 可编辑，可为空）
  - 能力勾选：图片、工具、流式用量、思考
  - 思考参数形态
  - 自定义请求头（高级折叠）
  - 测试连接
  - 刷新模型列表
  - 删除（内置不可删；自定义可删，删前确认）
- 顶部显示：`当前：Kimi · kimi-k2-...`

### 聊天页

- 可选：输入框附近显示当前供应商/模型 chip（小字，不干扰布局）
- 切换供应商不需要重开会话
- 下一条消息生效

### Agent 页

- 当前供应商不支持工具时显示明确提示
- 工具/审批/审计逻辑不变

---

## 8. 改动文件清单（预估）

后端：

- `lib/backend/llm.dart`：ProviderProfile、能力、请求适配、错误文案、成本
- `lib/backend/provider_registry.dart`（新增）：解析、迁移、预置
- `lib/backend/db.dart`：新增 `providers_v1`、`active_provider` 默认值
- `lib/backend/server.dart`：`/api/settings` GET/PUT、`/api/settings/test`、模型列表代理
- `lib/backend/agent.dart` / `sub_agent.dart`：改用 registry
- `lib/backend/agent_tools.dart`（如涉及）：能力门槛

前端：

- `lib/models.dart`：`SettingsData` 扩展供应商数据
- `lib/api.dart`：保存/测试供应商
- `lib/state.dart`：`AppState` 供应商状态
- `lib/screens/settings_screen.dart`：供应商管理 UI
- `lib/screens/chat_screen.dart`（可选）：当前模型 chip

测试：

- `test/provider_registry_test.dart`（新增）
- `test/llm_provider_request_test.dart`（新增，mock HTTP）
- `test/settings_providers_test.dart`（新增）
- 迁移测试：旧库 → 新库不丢 Key
- 回归：现有 263 条全部保持通过

文档：

- `docs/provider-plan-v0.7.0.md`（本文件）
- `docs/release-v0.7.0.md`
- 更新 `README.md`、功能说明文档

---

## 9. 测试策略

### 单元/契约测试

- 旧设置迁移：DeepSeek Key/URL/模型完整保留
- 供应商解析：active、缺失、损坏 JSON、回退旧字段
- 请求体快照：
  - DeepSeek 带 thinking/reasoning_effort + stream_options
  - Kimi 不发 DeepSeek 专有字段
  - GLM 发 zhipu thinking
  - 自定义 extraBody 合并
- 能力降级：
  - 无 vision 不组装图片
  - 无 tools 不发送 tools
  - 无 streamUsage 不发送 stream_options
- 错误映射
- 成本：已知价格/未知价格

### 集成测试（mock）

- 本地 mock OpenAI 兼容服务器
- 每个预置供应商一组 fixture：
  - 正常流
  - 工具调用流
  - 401/402/429/5xx
  - 带/不带 usage

### UI 测试

- 供应商切换、Key 掩码、测试连接、能力勾选
- 删除自定义供应商确认
- 窄窗/深色主题不溢出

### 真实账号测试（需要用户配合）

- 用户提供 Kimi / GLM 测试 Key（或用户本机测试）
- 只验证：连接、纯聊天、流式、图片、工具调用
- 使用隔离数据目录，不碰正式数据

---

## 10. 安全与隐私

- 所有 Key 只存本机 SQLite，不上传
- API 返回 Key 一律掩码
- 日志不打印 Key、Authorization、完整请求体
- 自定义 Base URL 允许 http://localhost，但设置页给出风险提示
- 第三方 MCP/工具授权逻辑不变
- 测试连接不写入 Key，除非用户点保存

---

## 11. 兼容与回滚

- 旧版本配置升级后不丢
- 旧 `PUT /api/settings` 仍可用
- 新字段未知时忽略
- 如果发现供应商配置损坏：
  - 回退 DeepSeek 旧字段
  - 设置页显示恢复提示
- 回滚到 v0.6.x 时：
  - 旧代码继续读 `api_key/base_url/model`（迁移时同步写入 DeepSeek 值）
  - 不破坏旧版可用性

---

## 12. 里程碑

### M1：多供应商骨架（核心）

- ProviderProfile / Registry / 迁移
- DeepSeek + Kimi + GLM 预置
- 请求适配（stream_options/tools/thinking/vision）
- 设置页供应商切换 + Key/URL/模型 + 测试连接
- 单元/契约测试

### M2：自定义供应商 + 能力降级

- 自定义供应商（含本地 Ollama/LM Studio）
- 模型列表刷新
- 图片/工具/思考能力门槛与提示
- 成本表按供应商
- UI/集成测试

### M3：文档与发布

- README/功能说明/发布说明
- 回归 263+ 测试
- 真实 Key 人工验证（用户配合）
- v0.7.0 构建与发布

---

## 13. 风险与缓解

| 风险 | 缓解 |
|---|---|
| 各家 OpenAI 兼容度不同 | 能力标记 + 每供应商契约测试 |
| 模型名/端点变化 | 预置可编辑；优先 `/models`；失败回退 |
| 工具调用差异 | 不支持时明确降级为纯聊天，不静默失败 |
| 图片模型差异 | vision 标记；不支持时阻止上传并提示 |
| 思考参数差异 | ThinkingStyle 枚举 + custom extraBody |
| 成本价格不统一 | 未知即“费用未知”，不编造 |
| 真实 Key 无法自动测试 | 用户本机人工验证，或提供测试 Key |
| 现有功能回归 | 263 条测试全量回归 + 手工验收清单 |

---

## 14. 需要你审批的点

1. **内置供应商范围**
   - A（推荐）：DeepSeek + Kimi + GLM + 自定义
   - B：再加通义/SiliconFlow/OpenRouter/Ollama 预置
2. **默认供应商**：保持 DeepSeek 为默认？（推荐是）
3. **故障行为**：当前供应商失败时，是否自动切到另一家？
   - A（推荐）：不自动切，只提示
   - B：允许配置备用供应商自动切换
4. **图片能力不支持时**：
   - A（推荐）：阻止发送图片并提示
   - B：静默忽略图片只发文本
5. **费用未知的模型**：
   - A（推荐）：显示“费用未知”
   - B：隐藏费用行
6. **真实 Key 验证**：
   - 你是否能提供 Kimi/GLM 测试 Key，或愿意在本机自行验证？
7. **发布版本**：目标 v0.7.0 是否同意？

---

## 15. 审批后我做什么

收到你的确认和上述选择后，我会：

1. 先做 M1（骨架 + 三家预置 + 设置页 + 测试）
2. 每完成一个里程碑跑全量回归
3. 中途不碰正式用户数据，使用隔离 `LOOP_DATA_DIR`
4. 全部完成后再构建、写发布说明、版本号 v0.7.0
5. GitHub 推送如果仍无网络，会本地提交并明确告知

批准方式：直接回复“批准 + 选项”，例如：

```text
批准 1A 2 3A 4A 5A 6我自己验证 7同意
```