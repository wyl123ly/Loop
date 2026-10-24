# Loop v0.6.1

## 修复
- 回答浮窗的 Flutter 圆角面板外，会露出第二窗口的黑色背景，形成左下角/四角黑块。
- 修复方式：在 Windows 第二窗口上使用 `SetWindowRgn` 设置与面板一致的圆角窗口区域，并在 WM_SIZE / WM_DPICHANGED 时更新。
- 回答窗收起/展开、动态改高、跨屏/DPI 变化时区域同步更新。
- 主窗口、极简条、常规浮窗仍使用主窗口原有 DWM 圆角，无此问题。

## 验证
- Windows release 构建通过。
- flutter analyze / flutter test 通过。
- 检查回答窗、主窗口、极简条三类窗口：仅第二回答窗需要额外区域裁剪；主窗口系 DWM 圆角。

## 升级
- 从 v0.6.0 启动时会收到自动更新提示。
- 也可以下载 `Loop-Desktop-win64.zip` 覆盖程序目录；用户 `data` 会保留。
