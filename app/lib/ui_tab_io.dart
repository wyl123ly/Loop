import 'dart:io';

/// 启动页签上界（0..6 = 对话/今日/笔记/资料/学科/代理/设置，§10.1）。
///
/// **索引变更说明（v0.8.0）**：新增「学科」页后，原
/// `代理=4`、`设置=5` 变为 `5`、`6`。旧截图脚本若硬编码
/// `LOOP_TAB=4`，现在打开的是**学科页**而不是代理页；
/// `LOOP_TAB=5` 打开代理页（原设置页），`LOOP_TAB=6` 打开设置页。
/// 该范围与 `main.dart` 的 `_lastPageIndex` 一致，并有
/// `test/subject_ui_test.dart`（UI-09）覆盖。
const int kInitialTabMax = 6;

/// 支持用环境变量 LOOP_TAB 或当前目录 ui_tab.txt 指定启动页签，方便截图/调试。
///
/// 合法范围 `0..kInitialTabMax`；越界或非法值一律回退到 0（对话页）。
int initialTabOverride() {
  final env = Platform.environment['LOOP_TAB'];
  if (env != null) {
    final value = int.tryParse(env);
    if (value != null && value >= 0 && value <= kInitialTabMax) return value;
  }
  try {
    final file = File('ui_tab.txt');
    if (file.existsSync()) {
      final value = int.tryParse(file.readAsStringSync().trim());
      if (value != null && value >= 0 && value <= kInitialTabMax) return value;
    }
  } catch (_) {}
  return 0;
}