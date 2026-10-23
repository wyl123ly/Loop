import 'dart:io';

/// 支持用环境变量 LOOP_TAB 或当前目录 ui_tab.txt 指定启动页签，方便截图/调试。
int initialTabOverride() {
  final env = Platform.environment['LOOP_TAB'];
  if (env != null) {
    final value = int.tryParse(env);
    if (value != null && value >= 0 && value <= 5) return value;
  }
  try {
    final file = File('ui_tab.txt');
    if (file.existsSync()) {
      final value = int.tryParse(file.readAsStringSync().trim());
      if (value != null && value >= 0 && value <= 5) return value;
    }
  } catch (_) {}
  return 0;
}
