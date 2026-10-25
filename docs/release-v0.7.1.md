# Loop v0.7.1 · 模型自动拉取

## 新增
- 设置 → AI 供应商新增「刷新模型列表」按钮。
- 后端新增 `POST /api/settings/models`：
  - 按 `provider_id` 使用该供应商的 Base URL / Key / 鉴权头
  - 请求 `{Base URL}/models`（Base URL 已含 `/chat/completions` 时自动替换）
  - 返回模型 ID 列表
- 设置页合并策略 `mergeFetchedModels`：
  - 已有模型保留原有能力标记（图片/工具/思考）、标签和顺序
  - 远端新增的模型 ID 追加到末尾
  - 合并结果自动保存回 `providers_v1`
- 解析兼容：
  - `{"data":[{"id":"..."}]}`
  - `{"models":[...]}`
  - `["model-a","model-b"]`

## 错误处理
- 未填 Key：提示「还没有配置 <供应商> API Key」
- 401/403/404/429/5xx：使用统一供应商错误文案，测试连接/刷新共用
- 端点没有返回模型：提示「<供应商> 端点没有返回模型」，不清空既有列表

## 验证
- `flutter analyze`：0 issues
- `flutter test`：**284/284**
  - R8：`/v1/models` 拉取、去重、Bearer 鉴权
  - R9：401 抛出 LlmException 且带供应商名
  - P8：合并保留已有能力/标签，只追加新模型
  - S4：设置页刷新后新模型出现在 chips 并保存
- 隔离数据 E2E：Loop v0.7.1 + 本地 mock `/v1/models`，验证后端端点真实返回模型列表

## 升级
- 从 v0.7.0 启动会收到自动更新提示。
- 也可以下载 `Loop-Desktop-win64.zip` 覆盖程序目录；用户 `data` 会保留。

## 产物
- ZIP：`release/Loop-Desktop-win64.zip`（20,806,413 B）
- ZIP SHA-256：`21F3236A997A377BD2441E528E9C862B0553B02110F5A4C16BBD6FDFC30290EF`
- `Loop.exe` SHA-256：`DD8EB6502FDF421B8BF0BD45209102F105CABF47C0C4D251D76F0CB39FDC6562`
- `version.json`：`{"version":"0.7.1"}`

## 隔离数据 E2E
- 本地 mock `/v1/models` 返回 `mock-alpha/mock-beta`（含重复项）
- Loop v0.7.1 写入自定义供应商并切为当前
- `POST /api/settings/models` 返回：`ok=true, models=mock-alpha,mock-beta, 拉取到 2 个模型`
- 证明真实进程内后端按供应商配置拉取、去重并返回
