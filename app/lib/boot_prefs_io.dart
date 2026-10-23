import 'package:flutter/material.dart';

import 'backend/db.dart';
import 'backend/paths.dart';

ThemeMode loadBootTheme() {
  try {
    AppPaths.init();
    Db.init();
    return switch (Db.setting('theme', 'system')) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
  } catch (_) {
    return ThemeMode.system;
  }
}
