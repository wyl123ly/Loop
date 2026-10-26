# Loop v0.8.10（主题切换卡顿修复）

## 问题原因

1. `_LoopAppState` 用 `AnimatedBuilder(animation: appState)` 包住整个 `MaterialApp`：
   会话、学科、流式输出等 13 处 `notifyListeners()` 都会重建整棵应用。
2. 每次 build 都调用 `loopTheme(...)` 重新构造两份 `ThemeData`（含 `ColorScheme.fromSeed`）。
3. `MaterialApp` 默认 200ms 主题插值动画，会对整棵树逐帧 lerp 颜色，切换时明显掉帧。
4. 每帧 build 都会向回答浮窗发送一次主题 IPC。

## 修复

- 新增 `AppState.appearanceRevision` / `bootRevision` 两个低频 `ValueNotifier`：
  - 只有在主题/系统深浅色变化、启动状态变化时才重建 `MaterialApp`；
  - 会话、学科、设置等高频通知不再牵连整棵树。
- 两套 `ThemeData` 改为 `late final` 缓存，全程只构造一次。
- `themeAnimationDuration: Duration.zero`：切换瞬间完成，不再逐帧 lerp。
- 回答浮窗主题同步收敛到“主题变化 / 启动完成 / host ready”三个时机。
- `setTheme` 重复选择同一主题直接返回；系统亮度只在“跟随系统”时刷新。

## 兼容性

- 调色板、主题色、各页面布局、圆角、浮窗、更新、学科、笔记、Agent 等逻辑均未改动。
- 全量测试通过，包含窄窗口无 overflow、浮窗主题同步、设置页等既有用例。

## 验证

- `flutter analyze`：0 issues
- 全量测试：**499 passed / 1 skipped**
- 新增主题切换测试 6 条：
  - `theme_switch_test.dart`：单次刷新、低频隔离、系统亮度、保存失败降级
  - `theme_material_app_test.dart`：真实 `LoopApp` 接线——会话通知不重建 `MaterialApp`、主题变化才重建、`ThemeData` 实例复用、动画时长为 0
- Windows Release 构建通过

## 产物

- ZIP：`release/Loop-Desktop-win64.zip`（21,285,594 B）
- ZIP SHA-256：`20561BECAD7CDBFB318C5C9AE586C862DECCA5BD97B92757FCFA3A0191190251`
- `Loop.exe`（启动壳）SHA-256：`C2C8189E081B363E6F6695FAA93F58753FC4B3A71CF5F3266B11386653B056DB`
- `data/app.so`（Dart AOT 代码）SHA-256：`D9A3431DA62A808CB67C57A42B4962AF95135F15391FCA07EF1380B3639843E7`
- `version.json`：`{"version":"0.8.10"}`
- 隔离启动 `/api/health`：`{"ok":true,"version":"0.8.10",...}`
