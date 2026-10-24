# 流式输出开关 t4 端到端验证与构建报告

- 任务：t4 [verify] 流式开关端到端验证与正式版构建（attempt 1，attempt_id `b0a8c690-ad31-4833-9362-56f897808c34`）
- 范围：正式版 `D:\DSH_Workspace\Prog2_app`（HEAD `0f0adc6` + 本次未提交改动）；**未改** `D:\DSH_Workspace\Loop-Test`、`server/`、`plugins/`
- 验证日期：2026-10-24（Asia/Shanghai）
- 结论：**通过（可进入评审）**。`flutter analyze` 0 issues；全量 `flutter test` 37/37 通过；真实后端 live E2E 24/24 通过；设置重启持久化 2/2 通过；正式版构建/打包链路在**隔离副本**中验证通过；用户正在运行的正式版实例、`release\` 产物与 `data\` 用户数据未被触碰。
- t6 后续执行（2026-10-24 完成）：v0.4.0 版本提升、正式 release 构建与构建产物冒烟已补做，见 §10 与 `streaming-evidence/v040-build-evidence.md`；`false` 模式“正在思考…”的 **live UI** 打字验证仍受 Flutter 窗口焦点限制（见 §9），该行为由 F7 widget 测试覆盖。

---

## 1. 验证环境

| 项 | 值 |
|---|---|
| OS | Microsoft Windows 11 家庭版 中文版 10.0.26200（Build 26200） |
| Flutter / Dart | Flutter 3.47.7 stable（revision `abaf9c5237`） / Dart 3.13.5 |
| 原生工具链 | Visual Studio 2022 BuildTools（MSVC 19.44） |
| 屏幕/缩放 | 主屏 2048×1152（有效 125% 缩放；Flutter 窗口 1440×900 逻辑 = 1800×1125 物理） |
| 正式版数据 | `D:\DSH_Workspace\Prog2_app\data`（用户实例 PID 67344 正在使用） |
| 隔离测试数据 | `%TEMP%\loop-t4\data`（`LOOP_DATA_DIR`） |
| 隔离测试构建 | `%TEMP%\loop-t4\release\Loop-Desktop`（临时副本） |
| Mock LLM | `%TEMP%\loop-t4\tools\mock_llm.py`，`127.0.0.1:9999`（stdlib only） |
| 临时端口 | 后端 8767（临时副本把 `8765` 改为 `8767`，避免与用户实例冲突） |

**隔离策略（重要）**：用户实例（`release\Loop-Desktop\Loop.exe`，PID 67344，15:11 启动，占用 8765，使用项目 `data\`）在全程保持运行，未被停止/重启；t4 没有向用户 `data\` 写入任何内容。live E2E 使用复制到 `%TEMP%\loop-t4` 的正式版源码副本，只改两处测试隔离参数：

1. `app/lib/backend/server.dart`：`static const int port = 8765;` → `8767`
2. `app/lib/api.dart`：`127.0.0.1:8765` → `8767`（3 处）
3. `app/windows/runner/main.cpp`：窗口标题加 ` T4` 以便与用户窗口区分

副本中执行了与正式仓库完全相同的 `packaging\build_native.ps1`（通过 junction 复用 `.tools\flutter`）。副本与隔离数据在验证后删除；正式 `release\`、`data\`、`Loop-Test` 均未改动。

> 环境备注：临时副本首次构建因 `pdfium_dart` hook 从 GitHub 下载 PDFium 返回 HTTP 404 而失败（本机网络/该 release 资产问题）。把正式仓库 `app\.dart_tool\hooks_runner\shared`（已缓存 pdfium/sqlite3 原生资产）复制到副本后，`flutter build windows` 59.1s 成功。该问题只影响无缓存的全新构建环境，不属于本次产品代码缺陷；正式仓库增量构建已有缓存（随后在正式仓库直接 `flutter build windows --release` 44.6s 成功验证）。

---

## 2. 静态检查与全量自动化测试

命令（正式版仓库）：

```powershell
cd D:\DSH_Workspace\Prog2_app\app
..\.tools\flutter\bin\flutter.bat analyze
..\.tools\flutter\bin\flutter.bat test
```

结果：

| 命令 | 结果 | 证据 |
|---|---|---|
| `flutter analyze` | **No issues found!**（0 issues，ran in 5.0s） | `$env:TEMP\loop-analyze.log` |
| `flutter test` | **All tests passed!** `+37`（约 2s） | `$env:TEMP\loop-test.log` |

37 条构成（与基线对比）：

| 来源 | 条数 | 说明 |
|---|---|---|
| 既有基线 | 17 | 含 `markdown_math_test`（3 组内联/块级公式）、`screenshot_overlay_test`、`update_test`、`widget_test` 等 |
| t2 后端新增 `streaming_backend_test.dart` | 10 | B1–B9 + 有正文时模型失败 |
| t3 前端新增 `streaming_settings_test.dart` + `streaming_chat_test.dart` | 10 | F1–F5 设置/持久化/回滚；F6–F10 true/false、停止、error、approval |

`git diff --check` 无空白错误；`app/pubspec.lock` 未被 `pub get` 改写（`git status` 无该文件）。

---

## 3. Live E2E（真实 Backend + 真实 SQLite + mock LLM + SSE）

### 3.1 启动与隔离

```powershell
# 临时副本（无 build/.dart_tool，复制原生资产缓存后构建）
$tmp = "$env:TEMP\loop-t4"
# 隔离数据目录：先放空 loop.db，AppPaths 才会选 LOOP_DATA_DIR
New-Item -ItemType Directory -Force "$tmp\data" | Out-Null
New-Item -ItemType File "$tmp\data\loop.db" | Out-Null
$env:LOOP_DATA_DIR = "$tmp\data"
Start-Process "$tmp\release\Loop-Desktop\Loop.exe"
# 轮询 http://127.0.0.1:8767/api/health

# mock LLM
python "$tmp\tools\mock_llm.py"   # 127.0.0.1:9999

# E2E 驱动
python "$tmp\tools\e2e.py" full
```

脚本见 `streaming-evidence/tools/e2e.py`（SSE 逐帧解析、事件名/时间戳/正文断言）；mock 见 `streaming-evidence/tools/mock_llm.py`（新增空回复、长回复、慢速分支）。

### 3.2 结果：24/24 通过

| # | 用例 | 断言要点 | 结果 |
|---|---|---|---|
| E0 | 启动健康 | `/api/health` `ok=true`、`version=0.3.9` | ✅ |
| E1 | 新库默认 | `GET /api/settings` → `stream_output: true`（布尔） | ✅ |
| E2 | 设置写入/读取 | `PUT stream_output=false` + mock base_url + key → GET 回读 false/base_url/has_key | ✅ |
| E2b | 工作区隔离 | `PUT/GET /api/agent/settings` 指向临时 workspace | ✅ |
| E3 | `false` 普通问答 | SSE `run→delta(1)→done`；单条文本完整；落库一致；token 260/90；cost 0.000186 | ✅ |
| E4 | `true` 普通问答 | 4 条 delta 逐段；拼接 == false 单条；落库一致 | ✅ |
| E5 | `false` 计划/工具 | `run→plan→step×3→plan→delta(1)→done`；plan_t=0.082/0.227，step_t=0.082/0.139/0.174，delta_t=0.230 → **工具/计划先于正文实时到达**；plan/steps 落库 | ✅ |
| E5b | `true` 计划/工具 | 4 条 delta 拼接 == false；plan/step 照常 | ✅ |
| E7 | `false` 审批 | `approval` 实时（t=0.045）→ 自动 allow → fs_write/fs_read 执行 → 文件生成 → audit 有记录 → 单 delta | ✅ |
| E8 | 审批等待中取消 | `run→approval→cancelled`；无 delta、无 done | ✅ |
| E8b | 流式过程中取消 | `run→delta(仅已生成前缀“慢速回答：第一段内容和第”)→cancelled`；无 done、不重复 | ✅ |
| E8c | 取消后可用性 | 下一条消息 `run→delta→done` 正常 | ✅ |
| E9 | `false` 空回复 | 0 delta；done 一次；token 17/0；无空助手消息 | ✅ |
| E10 | `false` 长回复 | 单条 delta 7967 字；与 mock 原文逐字符一致；含标题/公式/```dart 代码块/引用；落库一致 | ✅ |
| E10b | `true` 长回复 | 100 条 delta；拼接 7967 字 == false 单条 | ✅ |
| E11 | 运行中切换 | 运行中 `PUT stream_output=true`，本次仍 1 条 delta（请求级快照） | ✅ |
| E11b | 切换后下一条 | 下一条按 true：9 条 delta 拼接一致 | ✅ |
| E12 | 模型不可达 | 指向 9998（无服务）→ `run→error`，error.message 可读，无 done，服务不崩 | ✅ |
| E12b | 恢复 base_url | 下一条 `run→delta→done` 正常 | ✅ |
| E13 | 布尔校验/字段独立 | `stream_output:"false"` 字符串被忽略；改 `sidebar_collapsed` 不会重置 `stream_output` | ✅ |
| E14 | 自定义模式 + thinking=high | `mode=custom-t4` + `mode_prompt` + `thinking=high`：false 仍单 delta 完整 | ✅ |
| E15 | 图片/截图附件 | 两张 PNG（`t4-image.png`、`截图-t4.png`）上传成功；false 单 delta；attachments 元数据落库 `is_image=true` | ✅ |
| E16 | 历史重载一致性 | false/true 同问题：正文、tokens_in/out 完全一致 | ✅ |
| E17 | 收尾设置 | 保持 false，供重启验证 | ✅ |

证据文件：`streaming-evidence/e2e-full.json`（含每个事件的名称、时间戳与断言详情）。

### 3.3 重启持久化（同一隔离 `LOOP_DATA_DIR`）

停止进程 → 确认 8767 释放 → 用同一数据目录重启 → 重新执行 `/api/settings` 检查：

| # | 断言 | 结果 |
|---|---|---|
| R1 | 重启后 `stream_output=false` 仍持久化；后端健康（8767） | ✅ |
| R2 | `base_url`、`api_key`（has_key）、`auto_check_updates` 等其它设置不丢 | ✅ |

证据：`streaming-evidence/e2e-restart.json`。默认 `true` 与重启保持 `false` 均有自动证据；**切换只影响下一条消息**（E11/E11b）已在同一进程内验证。

---

## 4. 实机 UI 验证（隔离实例，未干扰用户窗口）

使用 `PrintWindow`（PW_RENDERFULLCONTENT）离屏截图 + 向 FlutterView 投递鼠标消息，未切换用户前台、未操作正式实例。截图为 125% 缩放的物理像素，已缩放存档。

| 证据 | 内容 | 结论 |
|---|---|---|
| `settings-stream-off-dark.png` | 暗色设置页：“对话与模型”卡片位于“外观”与“DeepSeek 接入”之间；标题“流式输出”；说明逐字“开启后逐字显示；关闭后等待完整回复；对下一条消息生效。”；开关为关 | ✅ 文案/位置/默认关闭值（启动前已持久化 false）正确 |
| `settings-stream-on-dark.png` | 同一位置开关为开；点击后 `GET /api/settings` 立即返回 `stream_output=true` | ✅ UI → 后端持久化链路正确 |
| `settings-stream-on-light.png` | 浅色主题下同一卡片与开关（开） | ✅ 亮色主题正常 |
| `settings-900x600-light.png` | 900×600（逻辑）窄窗口：侧栏收成图标，卡片、文案、开关完整可见 | ✅ 最小窗口无截断 |
| `chat-markdown-false-dark.png` / `chat-markdown-false-light.png` | 由 `false` 模式生成的 7967 字长回答，从 SQLite 历史重载后渲染：标题、$r(A)$ 公式、```dart 代码块、引用、列表均正常；token 行 900 in / 1500 out | ✅ Markdown/公式/代码块 + 历史重载 + 亮暗主题 |
| 设置页版本区（`settings-stream-off-dark.png` 右下） | 显示 `v0.3.9`（当前源码版本，t4 未提升版本） | ✅ 版本显示与构建一致 |

补充说明：

- 设置页“DeepSeek 接入”显示 `Base URL http://127.0.0.1:9999`、“已配置”、模型 `deepseek-flash`，证明隔离实例使用 mock 且 key 已配置。
- 开关两次切换后再次通过 HTTP 读取：一次 true、一次 false，与 UI 状态一致；失败回滚由 F3/F5 widget 测试覆盖（本机未注入 PUT 失败）。
- 侧栏折叠/自动更新开关不重置流式开关：后端字段独立性 E13 + 前端 F4 双证据。

---

## 5. 构建与打包（隔离副本，验证 `packaging\build_native.ps1` 全链路）

```powershell
# $tmp = %TEMP%\loop-t4（正式源码副本 + 8767 端口 + 窗口标题区分）
powershell -ExecutionPolicy Bypass -File "$tmp\packaging\build_native.ps1"
Get-Content "$tmp\release\Loop-Desktop\version.json"
```

| 项 | 结果 |
|---|---|
| 正式仓库 release 模式编译（不组装 `release\`） | 成功（44.6s，输出 `app\build\windows\x64\runner\Release\loop.exe`，build 目录为 gitignore）；未触碰 `release\Loop-Desktop` |
| 隔离副本 `flutter build windows --release` | 成功（59.1s，含全部插件/原生资产） |
| `release\Loop-Desktop\Loop.exe` | 存在，71168 字节（脚本把 `loop.exe` 重命名为 `Loop.exe`） |
| `release\Loop-Desktop\version.json` | `{"version":"0.3.9"}`（与当前 `app/pubspec.yaml` `0.3.9+12` 一致，脚本从 pubspec 读取，无 BOM） |
| `release\Loop-Desktop-win64.zip` | 20,521,814 字节，组装自 `Loop-Desktop\*` |
| 启动健康 | 隔离数据目录启动后 `GET /api/health` → `{"ok":true,"version":"0.3.9"}` |
| 数据位置 | 仅 `%TEMP%\loop-t4\data`；未读取/写入正式 `data\` |
| 用户实例端口 | 8765 仍由 PID 67344 监听；未重启、未覆盖其 exe |
| 8899 端口 | 正式版代码无 8899 引用、无监听；**不适用**（正式版仅 8765 后端端口） |

**未在 t4 执行的版本步骤**：按 `docs/streaming-spec.md` §6.7 与任务 t6，`v0.4.0` 的 `pubspec.yaml`（`0.4.0+13`）、`app_version.dart`、`README.md`、`docs/release-v0.4.0.md` 与**最终正式产物替换**属于 t6。t4 的构建是在隔离副本上验证打包链路与产物结构，未覆盖用户正在运行的 `release\`。因此本报告中 staging `version.json` 为 0.3.9 是**预期值**，不是 R16 失败。**t6 已完成版本提升与正式构建**（`release\version.json` 现为 `{"version":"0.4.0"}`），详见 §10；本节 0.3.9 内容保留为 t4 历史证据。

### 5.1 用户数据与正式产物未被触碰（前后对照）

| 对象 | 验证前 | 验证后 |
|---|---|---|
| 用户实例 PID 67344 | 运行，8765 | 仍运行，8765，`/api/health` ok、version 0.3.9 |
| `data\loop.db` | 113,467,392 B，mtime 13:24:42 | 同尺寸同 mtime（进程独占锁，未打开写） |
| `data\loop.db-wal` | 0 B，mtime 15:11:02 | 同尺寸同 mtime |
| 会话数 / 最大会话 id | 2 / 48（`GET /api/conversations` 只读） | 2 / 48 |
| `release\Loop-Desktop\Loop.exe` SHA256 | `BF33E594…77482` | 相同（未替换） |
| `release\Loop-Desktop\version.json` SHA256 | `23F71624…CC21` | 相同 |
| `release\Loop-Desktop-win64.zip` SHA256 | `F5609CF5…E176C` | 相同 |
| `D:\DSH_Workspace\Loop-Test` | 最近修改 14:58 | 15:30 后无任何文件修改 |
| 正式仓库 `git status` | 8 个既有修改 + 3 个新测试 + `docs/streaming-spec.md` | 同上（t4 新增 `docs/streaming-test-report.md` 与证据目录） |

正式 `server\`、`plugins\`、`Loop-Test` 无改动。

---

## 6. 兼容性/回归矩阵（t4 覆盖）

| 项目 | 验证方式 | 结果 |
|---|---|---|
| true 逐字（与 v0.3.9 等价） | E4/E5b/E10b + F6 | ✅ |
| false 单条完整正文 | E3/E5/E7/E10/E11/E14 + B2 等 | ✅ |
| 工具 steps / plan 实时 | E5：plan/step t=0.082–0.227，delta t=0.230；E5b | ✅ |
| 审批实时 + allow 执行 | E7 + F10 | ✅ |
| 停止/取消（流中、审批中） | E8/E8b/E8c + F8 | ✅ |
| 错误事件 | E12 + F9 | ✅ |
| 空回复 | E9（0 delta，done 一次，token 正常） | ✅ |
| 长回复 / 大单条 delta | E10（7967 字单 delta）/E10b（100 delta） | ✅ |
| Markdown / 公式 / 代码块 | E10 原文逐字 + 亮暗实机截图 + `markdown_math_test` | ✅ |
| 图片附件 | E15（上传 + 落库 + false 单 delta） | ✅ |
| 截图附件 | E15（同一 upload API，`截图-t4.png`）+ `screenshot_overlay_test`；UI 截图按钮路径未改动 | ✅（通道）/ 未做 UI 点击 |
| 自定义模式 + thinking=high | E14 | ✅ |
| token / cost / 历史落库 | E3/E16（260/90、cost 0.000186、重载一致） | ✅ |
| 亮色/暗色主题 | 实机截图 dark/light | ✅ |
| 900×600 窄窗口 | 实机 900×600 截图 | ✅ |
| 设置页文案/默认/持久化/回滚 | 实机 + F1–F5 + R1/R2 | ✅ |
| 切换只影响下一条 | E11/E11b + B9 | ✅ |
| 侧栏/自动更新不重置流式开关 | E13 + F4 | ✅ |
| 插件命令 | 正式版当前**没有插件模块/运行时**（插件仅在 Loop-Test/0.4.0-test.2）；本次未合并其代码 | N/A（不适用） |

---

## 7. 失败项与已知限制（如实记录）

### 7.1 验证过程中出现过、已解决的环境/脚本失败

| 失败 | 原因 | 处理/结论 |
|---|---|---|
| 临时副本 `build_native.ps1` 报“找不到 flutter” | 副本根无 `.tools\flutter`，脚本回退路径不适用 | 在副本根建 `.tools\flutter` junction 到正式 SDK；产品代码无关 |
| `flutter build windows` 失败：`Building native assets failed` | `pdfium_dart` hook 从 GitHub 下载 PDFium 返回 404 | 复制正式仓库已缓存的 `hooks_runner\shared` 后构建成功；正式仓库构建不受影响（已有缓存） |
| 首次 E2E 在 E5 抛 `TypeError` | 脚本把 `GET /messages` 已解析的 `plan` 列表再次 `json.loads` | 修正脚本（测试代码问题，非产品问题） |
| 第二次 E2E E12b 断言失败 | 该步处于 true 模式却按 false 单 delta 断言 | 在 E12 前显式置 false（顺便覆盖 false 错误路径）；最终 24/24 |
| 实机 UI 通过 `WM_CHAR` 向 Flutter TextField 输入“慢速”无效 | Flutter 窗口无真实前台键盘焦点，离屏消息不进入文本输入 | **未做 live UI 等待态**；不写成通过。该行为由 F7 widget 测试（“正在思考…” + step/plan 实时 + 单次正文）覆盖，HTTP 层 false 等待/单 delta 由 E3/E5/E11 覆盖 |

### 7.2 已知限制（不属本次范围）

- 有正文时模型中断仍走 `done.error`（前端不展示错误），E12 只验证了“正文为空 → error 事件”；与 spec R11 一致，本迭代不修。
- `false` 模式等待期只有工具/计划/审批可见，正文一次性到达；这是产品语义（D3），不是缺陷。
- 运行中切换存在极小的毫秒级竞态（R19），由请求级快照保证当前请求不受影响。
- 正式产物 v0.4.0 版本升级/最终替换与 GitHub Release 发布均未在 t4 执行：版本步骤属 t6；未自动创建 Release、未推 tag。

---

## 8. 证据文件

均在 `docs/streaming-evidence/`：

| 文件 | 说明 |
|---|---|
| `e2e-full.json` | live E2E 24 条断言 + 事件序列/时间戳/摘要（UTF-8） |
| `e2e-restart.json` | 重启持久化 2 条断言 |
| `baseline-user-artifacts.json` | 正式 release 产物 SHA256/大小/mtime 与用户 DB 基线 |
| `settings-stream-off-dark.png` | 暗色设置页（流式关闭、文案逐字正确） |
| `settings-stream-on-dark.png` | 暗色设置页（UI 点击后开启） |
| `settings-stream-on-light.png` | 浅色设置页（开启） |
| `settings-900x600-light.png` | 900×600 窄窗口浅色设置页 |
| `chat-markdown-false-dark.png` | false 生成长回答的暗色渲染（公式/代码块/引用） |
| `chat-markdown-false-light.png` | false 生成长回答的浅色渲染 |
| `tools/e2e.py` | E2E 驱动脚本（SSE 解析/断言，可复现） |
| `tools/mock_llm.py` | 本次使用的 mock LLM（新增空/长/慢分支） |
| `v040-build-evidence.md` | t6 v0.4.0 正式构建/版本提升/构建产物冒烟与哈希证据 |

---

## 9. 复现命令摘要

```powershell
# 1) 静态检查 + 全量测试（正式仓库）
cd D:\DSH_Workspace\Prog2_app\app
..\.tools\flutter\bin\flutter.bat analyze   # No issues found
..\.tools\flutter\bin\flutter.bat test      # +37 All tests passed

# 2) live E2E（隔离副本，示例；详见 §3）
$tmp = "$env:TEMP\loop-t4"
#  copy app source -> $tmp\app; port 8765->8767; copy hooks_runner cache; junction .tools\flutter
powershell -ExecutionPolicy Bypass -File "$tmp\packaging\build_native.ps1"
New-Item -ItemType File "$tmp\data\loop.db" | Out-Null
$env:LOOP_DATA_DIR = "$tmp\data"; Start-Process "$tmp\release\Loop-Desktop\Loop.exe"
python "$tmp\tools\mock_llm.py"             # 127.0.0.1:9999
python "$tmp\tools\e2e.py" full             # 24 passed
# 重启同一 LOOP_DATA_DIR 后：
python "$tmp\tools\e2e.py" restart          # 2 passed

# 3) 正式构建（t6 已执行；执行前确认无 Loop 进程、8765 空闲）
# powershell -ExecutionPolicy Bypass -File packaging\build_native.ps1
# Get-Content release\Loop-Desktop\version.json   # 实际 {"version":"0.4.0"}
```

---

## 10. t6 正式版 v0.4.0 集成、构建与交付（2026-10-24 补充）

### 10.1 前置状态与构建方式

- t6 开始时检测：`Get-Process -Name Loop` 无进程、8765 无监听；用户实例 PID 67344 已由用户自行关闭。
- 按 captain 补充指示：确认无运行实例后，允许 `packaging\build_native.ps1` 正常重建 `release\Loop-Desktop`；若发现运行实例则改用 staging（实际未出现）。
- 构建前把旧 v0.3.9 产物备份到 `%TEMP%\loop-release-v039-backup`（Loop-Desktop、zip、README.txt），未提交仓库。

### 10.2 版本与文档

- `app/pubspec.yaml`：`0.4.0+13`；`app/lib/update/app_version.dart`：`current = '0.4.0'`。
- `README.md`：当前版本 v0.4.0、对话/设置功能描述、v0.4.0 changelog、release 文档链接。
- 新增 `docs/release-v0.4.0.md`；更新 `release/README.txt`（版本、zip 大小与 SHA-256）。
- 版本提升后重跑：`flutter analyze` No issues found（5.9s）；`flutter test` +37 All tests passed（5s）。

### 10.3 正式构建结果

- `packaging\build_native.ps1` 成功：`flutter build windows --release` 50.7s，随后组装 `release\Loop-Desktop` 并压缩 zip。
- `release\Loop-Desktop\version.json` → `{"version":"0.4.0"}`（zip 内同值）。
- `release\Loop-Desktop\Loop.exe`：FileVersion/ProductVersion `0.4.0+13`，SHA-256 `8528C667F78E2112431888E1E6EB8E4D60265D111D9C0F4D51449723F287324F`。
- `release\Loop-Desktop-win64.zip`：20,521,998 B，SHA-256 `7D1BF2101CF53259BD6CBC82C464A898330A84BA7A39B19FD8D768CD752D09E0`。

### 10.4 构建产物冒烟（真实 release 二进制，隔离数据）

- 用 `release\Loop-Desktop\Loop.exe` + `LOOP_DATA_DIR=%TEMP%\loop-v040-smoke\data`（新库）+ mock LLM 9999 启动，`/api/health` → `version=0.4.0`。
- 6/6 通过：新库默认 `stream_output=true`；PUT false 生效；false 普通问答 `run→delta(1)→done`、token 260/90、落库一致；true 多 delta（4 条）拼接一致；收尾设置 false。
- 同一数据目录重启后 2/2 通过：health `version=0.4.0`；`stream_output=false` 持久化。
- 老库升级冒烟：复制正式 `data/loop.db` 到隔离目录后用 v0.4.0 启动，`stream_output` 自动补为 true、`has_key=true`、2 个历史会话保留；原库尺寸/mtime 未变（只读复制）。
- 冒烟结束已停止实例，8765/9999 无监听，临时数据目录删除；正式 `data\loop.db` 前后均为 113,467,392 B、mtime `2026-10-24T13:24:42.6261651+08:00`，未被写入。
- 详细证据与第一次脚本缺陷说明见 `streaming-evidence/v040-build-evidence.md`。

### 10.5 交付边界

- **未**创建 commit、**未** push、**未**打 `v0.4.0` tag、**未**创建 GitHub Release（`git tag --list 'v0.4*'` 为空）；发布由维护者手动完成。
- `D:\DSH_Workspace\Loop-Test` 无 15:30 后修改；`server/`、`plugins/` 无改动。
- 已知限制沿用 §7：false 等待态 live UI 打字未做（F7 覆盖）；有正文错误走 `done.error`；插件在正式版无运行时（N/A）。
