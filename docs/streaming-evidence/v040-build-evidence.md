# v0.4.0 正式构建与构建产物冒烟证据（t6）

- 任务：t6 [integrate] 正式版 v0.4.0 集成、构建与交付（attempt 1，attempt_id `3a980de4-c27a-4be9-bd66-3d3a34f80e0d`）
- 时间：2026-10-24 15:53–16:0x（Asia/Shanghai）
- 操作目录：`D:\DSH_Workspace\Prog2_app`

## 0. 前置状态检测（按 captain 指示）

```text
Get-Process -Name Loop        -> none
netstat :8765 LISTEN          -> 无
```

- t6 开始时用户实例 PID 67344 已不在、8765 空闲；用户已自行关闭应用。
- 因此按 captain 补充指示，允许 `packaging\build_native.ps1` 正常重建 `release\Loop-Desktop`（若检测到运行实例则改用 staging；实际未出现）。
- 构建前已备份旧 v0.3.9 产物到 `%TEMP%\loop-release-v039-backup`（含 Loop-Desktop、zip、README.txt）。

## 1. 版本提升

| 文件 | 变化 |
|---|---|
| `app/pubspec.yaml` | `version: 0.3.9+12` → `0.4.0+13` |
| `app/lib/update/app_version.dart` | `static const current = '0.3.9'` → `'0.4.0'` |
| `README.md` | 当前版本、对话/设置功能、v0.4.0 changelog、release 文档链接 |
| `docs/release-v0.4.0.md` | 新增 v0.4.0 说明 |
| `docs/streaming-test-report.md` | 增加 t6 集成/构建/冒烟章节 |
| `release/README.txt` | v0.4.0、zip 大小与 SHA-256 |

## 2. 静态检查与测试（版本提升后重跑）

```text
flutter analyze: No issues found! (ran in 5.9s)
flutter test:    +37 All tests passed!（17 基线 + 10 backend + 10 frontend）
```

## 3. 正式构建

```powershell
cd D:\DSH_Workspace\Prog2_app
powershell -ExecutionPolicy Bypass -File packaging\build_native.ps1
```

结果：

```text
[1/3] 构建原生 Flutter Windows...
Building Windows application... 50.7s
√ Built build\windows\x64\runner\Release\loop.exe
[2/3] 组装 release\Loop-Desktop ...
[3/3] 压缩...
完成：D:\DSH_Workspace\Prog2_app\release\Loop-Desktop
压缩包：D:\DSH_Workspace\Prog2_app\release\Loop-Desktop-win64.zip
```

产物校验：

| 文件 | 大小 | SHA-256 | 说明 |
|---|---|---|---|
| `release/Loop-Desktop/Loop.exe` | 71,168 B | `8528C667F78E2112431888E1E6EB8E4D60265D111D9C0F4D51449723F287324F` | FileVersion/ProductVersion `0.4.0+13` |
| `release/Loop-Desktop/version.json` | 19 B | `9CCD6C17176229B2B611BE1794E6874477EA965BC0E75FCB624E911E65B7F863` | 内容 `{"version":"0.4.0"}` |
| `release/Loop-Desktop-win64.zip` | 20,521,998 B | `7D1BF2101CF53259BD6CBC82C464A898330A84BA7A39B19FD8D768CD752D09E0` | 含 Loop.exe/version.json/sqlite3.dll 等 |

zip 内单独复核：`version.json` 内容 `{"version":"0.4.0"}`，`Loop.exe` FileVersion `0.4.0+13`。

## 4. 构建产物冒烟（真实 `release/Loop.exe` + mock LLM + 隔离数据）

环境：`LOOP_DATA_DIR=%TEMP%\loop-v040-smoke\data`（新库），mock LLM `127.0.0.1:9999`，release 实例监听 8765；测试结束即停止并清理，未使用正式 `data\`。

```text
PASS S0 正式构建启动健康/版本 0.4.0 - health={'ok': True, 'version': '0.4.0', 'has_key': False}
PASS S1 新库默认 stream_output=true - stream_output=True
PASS S2 设置写入 false + mock - stream_output=False base_url=http://127.0.0.1:9999
PASS S3 false 普通问答：单 delta 完整 + done token - events=['run', 'delta', 'done'] deltas=1
PASS S4 false 正文落库一致 - saved='直接回答：这是一条普通问答，不调用工具。'
PASS S5 true 普通问答：多 delta 拼接一致 - delta_count=4
PASS S6 收尾设置 false - ok

（重启同一 LOOP_DATA_DIR 后）
PASS R1 构建产物重启后 health/version - health={'ok': True, 'version': '0.4.0', 'has_key': True}
PASS R2 重启后 stream_output=false 持久化 - stream_output=False
```

> 注：冒烟脚本第一次运行时 S4 失败，原因是脚本首个 chat 请求未带 `conversation_id`，服务端新建会话而脚本去旧会话取消息（测试脚本缺陷）。修正为传入会话 id 后，重置隔离库重跑 6/6 通过；产品行为本身正常（t4 的 E3/E16 已覆盖落库一致性）。

## 4b. 老库升级冒烟（真实用户 DB 副本，不触碰原库）

把正式 `data/loop.db` 复制到 `%TEMP%\loop-v040-upgrade\data` 后，用 v0.4.0 `release\Loop.exe` 启动（`LOOP_DATA_DIR` 指向副本）：

```text
health: {"ok":true,"version":"0.4.0","has_key":true}
settings: stream_output=True  has_key=True
conversations: 2（max id 48，历史会话保留）
```

- 老库启动时自动补 `stream_output` 默认值 `true`，无迁移脚本、无历史数据丢失。
- 正式 `data\loop.db` 前后均为 113,467,392 B、mtime `2026-10-24T13:24:42.6261651+08:00`（只读复制，未被启动）。
- 升级副本在验证后删除。

## 5. 收尾与隔离

- 冒烟结束停止 release 实例；8765/9999 均无监听，临时数据目录已删除。
- 正式用户数据 `data/loop.db`：验证前/后均为 113,467,392 B、mtime `2026-10-24T13:24:42.6261651+08:00`（未打开、未写入）。
- 旧 v0.3.9 产物备份：`%TEMP%\loop-release-v039-backup`（构建前生成，未提交）。
- 未创建 commit / 未 push / 未打 `v0.4.0` tag / 未创建 GitHub Release；`git tag --list 'v0.4*'` 为空。
- `D:\DSH_Workspace\Loop-Test` 无 15:30 后修改。
