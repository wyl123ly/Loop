# t14 / T9-01 修复证据摘要（userMoved 回答窗重新检查输入条遮挡）

证据目录：`%TEMP%\loop-t14-evidence\`
release 构建；隔离 `LOOP_DATA_DIR`；未触碰用户实例/Loop-Test。

## 根因
`updateAnchors` / `onMainWindowMoved` 的 `_userMoved` 分支只调 `ensureOnScreen()`；
而 `ensureOnScreen` 用 `inputBarPhysical: Rect.zero` 调 planner，且不触发高度/位置
重排。用户轻拖回答窗后（userMoved=true），主窗切浮窗/极简，输入条移到回答窗
矩形内时不会重查遮挡 → TOPMOST 回答窗覆盖输入条，输入不可用。

## 修复（`answer_window_host.dart`）
- 新增 `_reconcileUserMovedWithInputBar()`：仅 userMoved + 与真实
  `_inputBarPhysical`（含 gap）相交时，用 `AnswerWindowPlanner.place(userMoved:true)`
  做最小位移/压缩；保持回答窗所在显示器/dpr/width，不无故改变用户位置。
- 调用点：
  - `updateAnchors` userMoved 分支：ensureOnScreen 后重查；
  - `onMainWindowMoved` userMoved 分支：ensureOnScreen 后重查；
  - `ensureOnScreen`（clamp 后/无需 clamp 时）与 `syncGeometryToAnchors` 末尾。
- 不覆盖输入条时位置完全不变（T5-06 保持：不拉回、不改 dpr）。
- 单测：`U-AL-33`（浮窗输入条遮挡→最小位移/压缩、dpr/宽度保持、不遮挡后位置不变）、
  `U-AL-34`（极简条遮挡→最小位移、仍在主屏/按 1.25 dpr）；既有 U-AL-28..32 跨屏回归
  全过。

## 真机 E2E（release，125% 主屏）
流程：normal 长回答（896×950@120，auto 在输入条上方）→ 轻拖回答窗标题
（userMoved，1323,188）→ 点浮窗按钮 → 点极简收起 → 在极简输入条输入“测试好”并提交。

| 状态 | 回答窗物理 rect | 输入条物理 rect（host 日志） | 重叠 |
|---|---|---|---|
| userMoved（normal） | (1323,188,896,950) | normal 输入条（下方） | 无 |
| 浮窗（userMoved nudge #1） | (1158,188,896,950) | (2064,964,1018,133) | **0**（gap 10） |
| 极简（nudge #2） | (1050,188,896,950) | (1956,961,573,133) | **0**（gap 10） |
| 极简提交后（新回答） | (1050,188,896,225) | 同上 | 0 |

- `answer userMoved nudged for input bar` = 2；`still overlaps` = 0；`overlaps input bar` = 0。
- 极简输入条点击 (2271,1062) + 输入“测试好” + Enter 成功：`/api/conversations`
  messages 从 2 → **4**，回答窗替换为新回答（高度 950→225，minH），证明输入可用。
- 截图：N0-normal-auto.png、F1-floating-answer.png、M1-minimal-answer.png、
  M2-minimal-after-submit.png；退出 `exited=True`。
- 跨屏/dpr：U-AL-28..32 全过（t12 真机证据仍有效；本次 userMoved 逻辑仅在同屏输入条
  相交时触发，不改 target display/dpr）。

## 质量门
- `flutter analyze --no-pub` → No issues found
- `flutter test --no-pub` → **261/261** All tests passed（新增 U-AL-33/34）
- `flutter build windows --release` → 成功
- Loop-Test：0 文件改动
- T5-08 EXCEPTION 未改动；T5-13 双击 reset 不在本次范围。
