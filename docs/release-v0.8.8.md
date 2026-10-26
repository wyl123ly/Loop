# Loop v0.8.8（自动更新修复）

## 修复

- **`Bad state: Process is detached`**：`UpdateService.launchInstaller` 使用
  `ProcessStartMode.detached` 启动 `updater.ps1` 后，又调用了
  `unawaited(process.exitCode)`；Dart 对 detached 进程读取 `exitCode` 会直接抛错，
  导致更新流程在「正在准备重启安装…」中断。现已移除该调用，只负责拉起脚本。
- 更新失败弹窗新增「打开下载页」，自动替换失败时可手动下载 zip 覆盖安装。

## 重要：如何升级到本版

`v0.8.6` / `v0.8.7` 自带的更新器仍有这个 bug，**无法自动升级**。请：

1. 手动下载 `Loop-Desktop-win64.zip`
2. 完全退出 Loop
3. 解压覆盖到原安装目录（或解压后直接运行新的 `Loop.exe`）
4. 之后版本的自动更新即可正常使用

## 验证

- `flutter analyze`：0 issues
- 全量测试通过
- Windows Release 构建通过
- 说明：自动替换流程无法在隔离环境里完整端到端模拟，需要在真实安装目录验证一次

## 产物

- ZIP：`release/Loop-Desktop-win64.zip`（21,281,359 B）
- ZIP SHA-256：`0804BF88D255DC821F13181E7549584DA62CC75F8A7150D8F4F639A3F333D687`
- `Loop.exe` SHA-256：`8173F9688E91221A41090AEA989DAE0ACC5AFB77F0B30B9F41BC3C225D25E306`
- `version.json`：`{"version":"0.8.8"}`
- 隔离启动 `/api/health`：`{"ok":true,"version":"0.8.8",...}`
