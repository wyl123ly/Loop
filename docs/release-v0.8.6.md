# Loop v0.8.6

## 新增：单实例检测

再次启动 `Loop.exe` 时：

- 通过 Windows 命名互斥量 `Local\\LoopDesktopApp.SingleInstance` 判断是否已有实例；
- 如果已有 Loop 进程，枚举该进程的窗口并激活：
  - 最小化 → 恢复
  - 托盘隐藏 → 显示
  - 置前；置前失败时闪烁任务栏
- 第二个进程直接退出（退出码 0），不再启动第二个后端、托盘、数据库连接。

## 验证

- 首次启动：正常进入主窗口；
- 第二次启动：进程立即退出，系统中只有 1 个 `Loop.exe`，原有 `/api/health` 继续可用；
- 单实例判断按进程名 `Loop.exe` + 窗口类，避免误激活其它 Flutter 程序。

## 已知限制

- 互斥量按 Windows 登录会话隔离；不同用户会话可各自运行一个 Loop。
- 如果首个实例在创建窗口前卡死，第二次启动会等待约 3 秒后退出；不会无限重试。
- 本版不包含 v0.9.0 扫描件 OCR；扫描 PDF 仍按 v0.8.5 的限制处理。

## 产物
- ZIP：`release/Loop-Desktop-win64.zip`（21,146,855 B）
- ZIP SHA-256：`DCE833E20CF5DA125EE2EEC7CB7D424A5D13FE36DA4ED8BD41EF47D8A28E56B0`
- `Loop.exe` SHA-256：`F5628DD3065468CC9D23A6D11CEBB7CA3E577A6472239A0D013B05A478A4EE59`
- `version.json`：`{"version":"0.8.6"}`

## 实测
- 第二次启动退出，系统中仅 1 个 `Loop.exe`
- 第二次启动后 `GetForegroundWindow()` 等于第一个主窗口句柄



## 关于 Supabase 云同步

- v0.8.7 的 Supabase 云同步功能已全部回退，本版不包含云端账号、快照上传/恢复。
- 本地 SQLite、资料、学科和单实例运行保持不变。
- `v0.8.7` tag 已删除，避免自动更新再次升级到云同步版本。
