import 'package:flutter/material.dart';

import 'ui_theme_stub.dart' if (dart.library.io) 'ui_theme_io.dart' as impl;

/// 截图/调试用：LOOP_THEME=light|dark 覆盖设置里的主题。
ThemeMode? themeOverride() => impl.themeOverride();
