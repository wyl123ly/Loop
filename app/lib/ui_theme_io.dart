import 'dart:io';

import 'package:flutter/material.dart';

ThemeMode? themeOverride() {
  final value = Platform.environment['LOOP_THEME'];
  if (value == 'light') return ThemeMode.light;
  if (value == 'dark') return ThemeMode.dark;
  return null;
}
