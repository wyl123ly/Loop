# Loop v0.7.0 · 多 AI 供应商

## 新增
- 内置供应商：DeepSeek、Moonshot / Kimi、智谱 GLM。
- 自定义供应商：任意 OpenAI 兼容端点，可配置 Base URL、模型、鉴权头、额外请求头/请求体。
- 设置 → AI 供应商：
  - 切换供应商
  - 独立 API Key / Base URL / 对话模型 / 推理模型
  - 能力开关：图片、工具、思考、流式用量
  - 思考参数形态：不发送 / DeepSeek / 智谱 / reasoning_effort / 自定义
  - 保存、测试连接、设为当前、添加/删除自定义供应商
  - Key 掩码显示；留空保存不会清空已存 Key

## 请求适配
- `stream_options.include_usage` 仅在供应商支持时发送。
- `tools` 仅在模型支持工具调用时发送；模型不支持时自动降级为纯聊天。
- 图片：当前模型不支持图片时，不组装 base64 图片，避免供应商 400。
- 思考：
  - DeepSeek：`thinking:{type:enabled}` + `reasoning_effort`
  - 智谱 GLM：`thinking:{type:enabled}`
  - Kimi K3.1：顶层 `reasoning_effort`
  - 自定义：`extra_body` 原样合并
- 鉴权：默认 Bearer；自定义供应商可用自定义头（如 `api-key`）。
- Kimi K3.1 Pro 固定 temperature/top_p，因此 provider 预设不发送 temperature。
- 端点：`{Base URL}/chat/completions`；Base URL 已含 `/chat/completions` 时不重复拼接。

## 预置模型
- DeepSeek：`deepseek-flash`（视觉）、`deepseek-v4-pro`（推理）
- Kimi：`kimi-k3.1-pro`、`kimi-k3.1-pro-highspeed`，并保留 K2/长文本/视觉候选
- GLM：`glm-5.3`、`glm-5.3-flash`、`glm-5.2`、`glm-4.5` 系列、`glm-4v-plus`、`glm-4.5v`
- 所有模型 ID 均可在设置页手动编辑。

## 迁移与兼容
- 首次启动 v0.7.0：
  - 旧 DeepSeek Key/URL/模型迁移成 `deepseek` profile。
  - 旧自定义 Base URL 迁移成 `custom_migrated`，思考参数形态为 none，避免误发 DeepSeek 专有字段。
- 旧 settings 键保留为回退；旧 `PUT /api/settings` 仍可用。
- 会话、消息、资料、笔记、待办、截图、浮窗、极简、回答窗、MCP、审计逻辑不变。

## 验证
- `flutter analyze`：0 issues
- `flutter test`：**280/280**
- 新增测试：
  - 供应商预置/能力合并/迁移（P1–P7）
  - 请求体契约：DeepSeek / Kimi / GLM / 自定义头 / 无工具 / 非流式（R1–R7）
  - 设置页 UI：渲染、切换供应商、设为当前、测试连接（S1–S3）
- 真实 Kimi / GLM Key 端到端验证：**待用户在本机完成**（本环境无第三方 Key）。

## 已知限制
- 未做 `/models` 自动拉取；模型 ID 变更需用户手动编辑。
- 未知模型无价格表，费用显示 0（后续可改为“费用未知”）。
- 模型不支持图片时当前仅静默剔除图片，尚未弹提示。
- 工具调用兼容性依赖各供应商 OpenAI 兼容度；不支持时降级纯聊天。
- 本版本未做自动故障转移。

## 升级
- 从 v0.6.4 启动会收到自动更新提示。
- 也可以下载 `Loop-Desktop-win64.zip` 覆盖程序目录；用户 `data` 会保留。

## 产物
- ZIP：`release/Loop-Desktop-win64.zip`（20,802,469 B）
- ZIP SHA-256：`797AE60DBE007A27FE25F6241925529A350CF0641ACFEEF0D618FDDFB5A749AD`
- `Loop.exe` SHA-256：`3813900D6F3751E85C3EC8EE641CD1F77AFCF9A8EE35CA1A07B48926D0CFA21B`
- `version.json`：`{"version":"0.7.0"}`

## 隔离数据冒烟
- 启动 v0.7.0（`LOOP_DATA_DIR` 指向临时目录，不碰正式数据）
- 读取设置：`active_provider=deepseek`，预置供应商 3 个，`has_key=false`
- 写入 Kimi Key 并切为当前：`active_provider=kimi`，`model=kimi-k3.1-pro`
- 回读：Kimi Key 为掩码 `sk-••••••••7890`，`send_temperature=false` 保留，DeepSeek Key 未被污染
