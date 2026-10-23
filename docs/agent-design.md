# Agent 能力设计（Phase 1）

## 已完成
- **Agent 循环**：计划 → 工具执行 → 回读 → 汇总；最多 12 次工具调用。
- **计划卡**：模型通过 `update_plan` 维护 1–8 步计划，SSE `plan` 事件实时更新，写入 `messages.plan` 可恢复。
- **工具集（19 个）**：资料检索/列表、待办查询/创建/修改/批量改期、今日统计、笔记列表/读取/创建/修改、工作区文件列表/读取/写入/建目录/移动/删除、Shell。
- **逐次审批**：文件写入/移动/删除、Shell 命令每次弹出审批卡；允许后继续当前 SSE，拒绝则把拒绝结果回填给模型。
- **停止**：发送中显示停止按钮，调用 `/api/agent/cancel`，run 标记 cancelled，保存已生成内容。
- **持久化**：`agent_runs` 运行表；`messages.plan` 增量列；启动时把遗留 running 标记 error。
- **推理参数**：高强度模式发送 `thinking:{type:enabled}` + `reasoning_effort:high` 并使用推理模型。
- **Phase 0 验证**：本地 MCP stdio server 的 list/call 成功；Puppeteer + 本地 Edge 打开网页、读取正文、截图成功。
- **浏览器**：Agent 可打开/读取/点击/输入/截图/返回；打开/点击/输入每次审批；禁止内网/file/下载。
- **MCP**：设置页添加 stdio/HTTP 服务器，测试连接、启停、删除；工具以 mcp__server__tool 注入，每次调用审批；修复了 mcp_dart 新版协议兼容（legacy 初始化）。
- **多 Agent**：delegate_task 委派 researcher/planner/reviewer/analyst 只读子 Agent，独立上下文、最多 3 轮，主 Agent 汇总。
- **代理页**：权限/工作区、能力开关、MCP 管理、审计、后台任务四个 Tab；复用现有主题与组件。
- **审计**：agent_audit 记录每次工具调用（参数/结果摘要/审批/耗时）。
- **后台任务**：应用内每 30 秒检查到期任务（间隔/每天），后台运行禁用危险工具；支持立即运行、启停、删除。
- **托盘/开机自启**：Windows 托盘图标、显示/运行到期任务/退出菜单；关闭窗口最小化到托盘；设置页可开启登录自启。

## 事件协议
`run` / `plan` / `step` / `approval` / `delta` / `done` / `cancelled` / `error`

## 待接入（后续阶段）
- 关闭应用后的 Windows 任务计划（当前托盘常驻 + 自启已可用）
- 后台任务的预授权工具范围与系统通知
- 安全测试自动化（路径逃逸/内网 URL/未授权命令）

## 安全边界（当前）
- 工作区默认 `%USERPROFILE%\LoopWorkspace`；路径归一化 + 符号链接解析，越界拒绝。
- Shell 在工作区执行，60s 超时，输出截断，无管理员权限；**不是内核沙箱**。
- 文件写入/移动/删除、Shell 每次审批；拒绝不执行。
- 资料/工具结果视为不可信数据。
