# Loop v0.9.0

## 新功能：扫描 PDF 多模态转写

以前资料上传只抽 PDF 文本层；扫描件会被 `抽不到文字` 拒绝。现在：

1. PDF 文本不足 10 字符且页数 >0 时，不再删除文件，返回 `scan_pdf`。
2. 上传弹窗显示页数、可用视觉模型、隐私确认和进度。
3. 用户确认后，后端逐页用 PDFium 渲染（长边 1600px），调用所选多模态模型转写。
4. 转写文本进入现有 `materials/chunks/chunks_fts`，保留页码引用。
5. 资料列表显示「扫描件 · AI 转写」；失败页记录在 `material_ocr_pages`。

## 行为与限制

- 需要先配置支持图片的供应商/模型（Kimi、GLM 视觉等）；没有可用模型会明确提示。
- 单文件最多 **30 页**；页面图会发送给所选模型供应商，首次需勾选隐私确认。
- 失败页 >20% 或首页失败时整体失败，不产生半成品资料；取消会删除临时文件。
- 目录导入中的扫描 PDF 暂不自动触发 OCR；仍走原解析错误。
- 转写是 AI 结果，公式/表格/低清晰度页面可能有误差；资料列表有来源标记。

## 实现

- `ocr_vision.dart`：视觉模型筛选、转写提示词、输出清洗
- `parsing_io.dart`：PDF 页渲染 PNG
- `server.dart`：扫描检测、临时文件、OCR 任务进度/取消、异常阈值、入库
- `db.dart` / `subject_store.dart`：`materials` OCR 字段 + `material_ocr_pages`，只加不删
- `materials_screen.dart`：确认弹窗、模型选择、隐私确认、进度/取消、徽标

## 验证

- `flutter analyze`：0 issues
- 全量测试（不含截图证据用例）：**480 passed / 1 skipped**
- 真实空白 PDF + mock 视觉模型端到端：上传 → 扫描检测 → 渲染 → 转写 → 入库 → 搜索预览
- 隐私确认缺失返回 400；扫描件临时文件不被提前删除

## 产物
- ZIP：`release/Loop-Desktop-win64.zip`（21,177,891 B）
- ZIP SHA-256：`E31343227DB54367404C7FD718B44F333CB47F2515DFC8A9006B7E58B10C8571`
- `Loop.exe` SHA-256：`9294DA4FC993A0EDDD4CBB5464433B4B8C4D88935937493DA21F88FB32B00521`
- `version.json`：`{"version":"0.9.0"}`
- 隔离数据 `/api/health`：`{"ok":true,"version":"0.9.0","has_key":false,"active_subject":"default"}`
