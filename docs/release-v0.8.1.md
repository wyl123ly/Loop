# Loop v0.8.1

## 修复

### 1. 归档学科的管理死锁

原逻辑：删除学科要求先归档；归档学科不能被设为当前学科（后端返回 409），
而删除入口在学科管理页。结果归档后无法进入管理页删除，形成逻辑死锁。

现在：

- 切换器「查看归档」中的归档学科不再尝试设为当前学科，而是打开**只读管理预览**；
- 预览不改变当前 active subject，聊天/资料/检索继续停留在当前学科；
- 管理页横幅显示「学科已归档（只读）」，概览/进度/技能均为只读，写操作按钮禁用；
- 归档学科在管理页可正常「恢复学科」或「删除学科（移入回收站）」；
- 删除/恢复后自动回到当前学科，不残留已消失学科的请求；
- 归档学科仍不能作为当前学科提问/写入，符合只读语义。

### 2. 弹出菜单圆角

学科切换器与学科管理菜单使用 14px 圆角（`RoundedRectangleBorder` + `Clip.antiAlias`），
与左侧圆角列表统一，消除直角突兀。

### 3. README 补充检索说明

资料库章节新增：AI 会结合用户问题做模糊搜索与语义相关性检索，先转检索词，再按
FTS5/BM25 相关性排序取最相关原文片段，回答附「资料名 p.页码」；检索完全本地完成。

## 验证

- `flutter analyze`：0 issues
- 全量 `flutter test`：**474 passed / 1 skipped**
- 新增 `UI-03b`：归档学科从切换器进入只读管理页、active 不变、删除入口可用
- 正式 `data/loop.db` 未被触碰

## 已知限制（继承 v0.8.0）

- v0.8.0 的 R3-1/R3-2 截图证据问题仍在（dark 截图调色板、04 fixture 同屏矛盾），本版未处理；
- `skill_hub_url` 由白名单固定；pinned 仅展示；Ctrl+Shift+S 未实现；§8.7 迁移期进度回填可选未做；
- 真实 Kimi/GLM Key 的端到端验证仍需用户本机完成。

## 产物

- ZIP：`release/Loop-Desktop-win64.zip`（21,145,404 B）
- ZIP SHA-256：`CADB8C171C681213A6DD0EBF257F03D41E4D0C55BF94E6C5D9F703F974492FDB`
- `Loop.exe` SHA-256：`47463534A60F0D91678249A00BCE67EB9E3184DFD6109D217BC5D4F32AEE0E28`
- `version.json`：`{"version":"0.8.1"}`
- 隔离 `LOOP_DATA_DIR` 真实进程探活：`{"ok":true,"version":"0.8.1","has_key":false,"active_subject":"default"}`
