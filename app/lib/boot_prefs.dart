import 'package:flutter/material.dart';

import 'boot_prefs_stub.dart' if (dart.library.io) 'boot_prefs_io.dart' as impl;

ThemeMode loadBootTheme() => impl.loadBootTheme();
