# Loop v0.8.9（更新链路加固）

## 本版修复

1. **Release 列表回退**
   - 改用 `releases?per_page=10`，自动跳过 draft/prerelease。
   - 最新 Release 还没上传 zip 时，回退到上一个带 `Loop-Desktop-win64.zip` 的版本，不再直接报「Release 里没有找到附件」。

2. **更新包兼容性**
   - zip 多包一层目录时自动展平。
   - 支持 `Loop.exe` / `loop.exe` 两种大小写。
   - 安装前删除更新包内的用户数据路径，绝不覆盖本机 `loop.db`、`subjects`、`files`、`skills`、`mcp`、`logs` 等。

3. **updater.ps1**
   - 全 ASCII 注释：Windows PowerShell 5.1 在没有 BOM 时按 ANSI 读取脚本，中文注释会破坏语法（本版实测确认并修复）。
   - 等待父进程退出时间 30s → 120s。
   - 备份排除用户数据，避免 374MB 数据被复制进 updates 目录。
   - 新增 `-NoRestart` 开关，便于自动化测试替换逻辑。

4. **可测试性**
   - 新增 5 条回归测试：Release 回退、draft 跳过、列表接口解析、stage 展平/数据清理、updater.ps1 真实替换 + 数据保留 + 备份排除。

## 验证

- `flutter analyze`：0 issues
- 全量测试：**493 passed / 1 skipped**
- updater.ps1 在临时目录真实执行通过（替换文件、保留 `data/loop.db`、备份不含用户数据、日志 `update done`）
- Windows Release 构建通过

## 升级说明

- v0.8.6 / v0.8.7 的更新器仍有 detached 崩溃，**需要手动安装一次** v0.8.8 或更高版本。
- 自动更新可用性还取决于 GitHub Release 是否上传了对应 zip 附件。

## 产物

- ZIP：`release/Loop-Desktop-win64.zip`（21,283,341 B）
- ZIP SHA-256：`72069FF4E274FDBF75CE6AFF38EC2537C6E6CB53EE4C62CAED70AF21303BD4BB`
- `Loop.exe` SHA-256：`22717D7B595FB467EB373F6DDE1068CFE8ACFCEF66945ABCE7169754AE365043`
- `version.json`：`{"version":"0.8.9"}`
- 隔离启动 `/api/health`：`{"ok":true,"version":"0.8.9",...}`
- 真实包安装模拟：解压本版 zip 作为 staging，运行 `updater.ps1 -NoRestart` 后
  `version.json` 变为 0.8.9，`data/loop.db` 与 `data/subjects/...` 原样保留，备份目录不含用户数据。
