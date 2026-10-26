# Loop v0.8.7（学习使用反馈 1）

## 反馈落地

1. **输出时间/上下文**：旧消息滚动压缩为摘要（保留最近 10 条原文，注入时截断到 8 条/1500 字），长对话输入 token 明显下降。
2. **拖拽上传**：聊天输入框支持直接拖入文件/图片（可多选），带拖拽高亮提示；Windows 插件已打包。
3. **Agent 权限**：新增 `delete_note` / `delete_notes`；审批策略支持「逐次确认 / 自动批准工作区文件 / 全部自动」。
4. **长期记忆**：每个学科内置 `memories` 表 + FTS5 索引，Agent 通过 `memory_write/search/list/delete` 使用；每轮自动注入高价值记忆，跨对话可用。
5. **资料访问上限**：Agent 工具调用上限 24 → 300；`search_materials` 默认 8 段、最大 30 段。
6. **学习时长**：真实活跃会话统计（15 分钟连续窗口、单次封顶 5 分钟、新会话起步 1 分钟），日汇总取真实活跃与模型自报的较大值；模型自报单次上限收紧到 180 分钟。
7. **笔记下载**：笔记页新增「下载」，导出 Markdown 文件（文件名自动清理非法字符）。

## 验证

- `flutter analyze`：0 issues
- 测试：**488 passed / 1 skipped**
- 新增测试：笔记删除工具、批量删除、真实学习时长、长期记忆隔离/检索、上下文压缩、审批策略
- Windows Release 构建通过（含 desktop_drop 原生插件）

## 产物

- ZIP：`release/Loop-Desktop-win64.zip`（21,280,731 B）
- ZIP SHA-256：`6C7D0169CA5B4CA93152F5DCC4982765E90FFB29E4321D27E9DB0DFC2CFCF0D4`
- `Loop.exe` SHA-256：`116C9D4267B2ECC9CF78EB76FBAAC3C80C0C71F1F93B9FC99E690DE4D294A9A6`
- `version.json`：`{"version":"0.8.7"}`
- 已确认打包 `desktop_drop_plugin.dll`（拖拽上传原生插件）
