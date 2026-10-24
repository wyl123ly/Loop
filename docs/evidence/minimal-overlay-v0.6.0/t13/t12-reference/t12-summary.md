# t12 修复证据摘要（跨屏 auto-follow 双重 DPI / 程序化 target display）

证据目录：`%TEMP%\loop-t12-evidence\`
release 构建；隔离 `LOOP_DATA_DIR`；未触碰用户实例/Loop-Test。

## 根因
1. 回答窗被 host 用 SetWindowPos 移到另一 DPI 显示器时，Windows 会向第二窗发
   `WM_DPICHANGED`；vendored `desktop_multi_window` 的 `win32_window.cpp` 会把
   OS suggested rect 再 `SetWindowPos` 一次 → 在 host 已按新 DPI 写 bounds 后
   再乘 1.2/0.833，形成 1290×1344 / 747×792 的双重缩放。
2. `ensureOnScreen()` 在 DPI/screen event 上按回答窗旧位置 clamp 并把
   `_userMoved=true`，导致 auto-follow 被误标为用户移动，程序化主窗跨屏时
   回答窗留在旧屏。
3. auto 模式下 500ms anchor sync 只更新输入条，未重定向 target display。

## 修复
- `third_party/desktop_multi_window/windows/win32_window.cpp`
  - `WM_DPICHANGED` 不再应用 OS suggested rect，只重新布局 Flutter child；
    物理几何完全由主引擎 FFI/用户拖动控制（README-LOOP-PATCH.md 已更新）。
- `AnswerWindowHost`
  - `updateAnchors`：auto 模式用输入条 anchor 重选显示器、更新 work/dpr，
    display/dpr 变化时调度 500ms 稳定同步；
  - `onMainWindowMoved`：auto 模式重选 target display/dpr；userMoved 分支
    不再 auto 布局，仅 `ensureOnScreen` 离屏 clamp；
  - 新增 `syncGeometryToAnchors()`（500ms stabilize）：按当前 anchor 重算
    target display + dpr + 最终物理 rect 并强制写回；
  - `ensureOnScreen`：auto 模式不再按回答窗旧位置 clamp/误标 userMoved；
    userMoved 才按回答窗所在显示器 clamp（且不因输入条移动而重排）。
- 单测：`U-AL-28..32` 覆盖 125→150、150→125、100%、强制稳定写回、
  userMoved 跨屏保持。

## 真机实测（系统级 SendInput 真实拖动，主屏 125% ↔ 副屏 150%）
| 场景 | 实测 | 期望 | 结果 |
|---|---|---|---|
| A0 主屏创建长回答 | 896×950@120 | 716.8×760 逻辑@120 | PASS |
| A1 真实拖主窗 125→150 | **1075×1120@144** | 1075×1120@144 | PASS（无 1290×1344） |
| A2 真实拖回 150→125 | **896×950@120** | 896×950@120 | PASS |
| B0 副屏创建（宽 597.3 逻辑） | 896×1120@144 | 896×1120@144 | PASS |
| B1 真实拖回 150→125 | **747×950@120** | 747×950@120 | PASS（无 747×792） |
| C1 程序化 SetWindowPos 主屏→副屏 | **896×1120@144** | 896×1120@144 | PASS |
| C2 程序化 副屏→主屏 | **747×950@120** | 747×950@120 | PASS |
| D0 用户拖回答窗到副屏 | (-1800,422,896,1120)@144 | userMoved | PASS |
| D1 主窗移到副屏 | **(-1800,422,896,1120)@144** | 位置/dpr 不变 | PASS |
| D2 主窗移回主屏 | **(-1800,422,896,1120)@144** | 位置/dpr 不变 | PASS |

日志：`answer auto-follow` 8 次（125↔150 双向）、`answer geometry stabilized`
6 次、`answer overlaps input bar` = 0；退出干净。
T5-08 首次可见 1.0–1.2s 的 EXCEPTION 未改动（等待态/稳定性未降低）。

## 质量门
- `flutter analyze --no-pub` → No issues found
- `flutter test --no-pub` → 259/259 All tests passed（含 U-AL-28..32）
- `flutter build windows --release` → 成功
- Loop-Test：0 文件改动
