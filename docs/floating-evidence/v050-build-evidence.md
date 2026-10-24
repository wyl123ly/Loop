# v0.5.0 正式版构建与交付证据（t6）

- 日期：2026-10-24（Asia/Shanghai）
- 仓库：`D:\DSH_Workspace\Prog2_app`
- 交付 commit：`cf89a08`（`feat: 桌面答疑悬浮窗 (v0.5.0)`），tag：`v0.5.0`（annotated，指向该 commit）
- 版本：`app/pubspec.yaml` `0.5.0+14`；`AppVersion.current='0.5.0'`

## 1. 构建前置

- 用户 Loop 实例：无；`8765/8767/9999` 无监听。未停止/覆盖任何用户实例。
- 旧版 `release/` 备份到 `%TEMP%\loop-release-v040-backup-t6`（Loop-Desktop、zip、README.txt），构建后按交付预期替换；备份在验证完成后删除。
- 构建命令（正式仓库）：

```powershell
cd D:\DSH_Workspace\Prog2_app
powershell -ExecutionPolicy Bypass -File packaging\build_native.ps1
```

- 构建日志：`docs/floating-evidence/logs/build-release-t6.log`；`flutter build windows --release` 53.3s，组装 `release\Loop-Desktop` 与 zip 成功。

## 2. 版本与产物

| 文件 | 值/大小 | SHA-256 |
|---|---|---|
| `release/Loop-Desktop/version.json` | `{"version":"0.5.0"}`（19 B） | `1CA74BD4BC478F15FD14BEA176074894A7A169D54ACC3CDE5594969D8FEE8123` |
| `release/Loop-Desktop/Loop.exe` | 114,688 B；FileVersion `0.5.0+14` | `B626915EAA58E314FFC0BB55F7E6EA241D3165CF60AEBBEF5020AFCD51C036AC` |
| `release/Loop-Desktop-win64.zip` | 20,609,950 B | `1F335A94D96F570DFF3E5BE18FEA5D0FE9520105F5E612F46215C54E5176A5BD` |

必需文件检查：`Loop.exe`、`flutter_windows.dll`、`sqlite3.dll`、`pdfium.dll`、`pdfrx_pdfium_gate.dll`、`window_manager_plugin.dll`、`screen_retriever_windows_plugin.dll`、`tray_manager_plugin.dll`、`version.json`、`使用说明.txt`、`data\` 均存在；zip 内含 `Loop.exe`、`flutter_windows.dll`、`sqlite3.dll`、`version.json`。

## 3. 正式产物冒烟与真实闭环

- 隔离数据 `%TEMP%\loop-t6\data`（`LOOP_DATA_DIR`）启动 `release\Loop-Desktop\Loop.exe`：
  - `/api/health` → `{ok:true, version:"0.5.0", has_key:false}`；
  - 单进程窗口 1800×1125 @(380,157)、minTrack 1125×750、topmost=false；关闭后 8765 释放；
  - 截图：`docs/floating-evidence/screens/t06-04-release-v050-running.png`。
- 最终版 live E2E（真实 Backend+SQLite+mock LLM，隔离数据）：
  - `e2e_floating.py full` → **27/27**；`e2e_floating.py restart` → **4/4**；
  - 证据：`docs/floating-evidence/logs/e2e-floating-full.json`、`e2e-floating-restart.json`、`e2e-full-console-t6.log`。
- 最终版本地检查：`flutter analyze --no-pub` **0 issues**；`flutter test --no-pub` **142/142**（`flutter-analyze-t6.log`、`flutter-test-t6.log`）。
- v0.5.0 debug 真实窗口冒烟（隔离数据）：
  - normal 1800×1125@(380,157) → 浮窗 575×750@(1955,345) topmost/minTrack 450×525 → 360×420 compact，无 overflow 日志；
  - 最大化 → 浮窗 → 返回最大化 → 点“还原”精确回到 1800×1125@(380,157)（t7 修复生效）；
  - 截图：`t06-01-floating-v050.png`、`t06-02-floating-360-v050.png`、`t06-03-final-restore-v050.png`。

## 4. 推送与发布边界

- `git push origin main`：`4850848..cf89a08  main -> main`；
- `git push origin v0.5.0`：`* [new tag] v0.5.0 -> v0.5.0`；
- 远端核对：`refs/heads/main = cf89a08`；`refs/tags/v0.5.0` annotated → `cf89a08`；
- **未自动创建 GitHub Release**：交付后 GitHub API `releases/latest` 仍为 `v0.3.4`（仓库历史最新 Release），未出现 v0.5.0 Release；
- 手动发布：维护者上传 `release/Loop-Desktop-win64.zip` 到 GitHub Releases 并引用 `docs/release-v0.5.0.md`。

## 5. 未污染检查

| 对象 | 结果 |
|---|---|
| 用户 `data\loop.db` | SHA256 `6C259E6E9B2CF11C0B81D010DFDB28AEABF5E64380CBF4383A6B4C3EBEB8A2C7`，大小 113,467,392 B、mtime 16:32:15（与 t4 基线一致） |
| 用户 `data\loop.db-wal` | 0 B，SHA256 `E3B0C442…B855`（未变） |
| `D:\DSH_Workspace\Loop-Test` | 17:40 后无文件修改 |
| 用户 Loop 进程/端口 | 无进程、无监听；验证实例/构建进程已停止 |
| 临时目录 | `%TEMP%\loop-t6`、旧版本备份已删除；仓库仅含正式源码/测试/docs |
| `.agent-teams/` | 未提交（保留为团队本地状态） |
