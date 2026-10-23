import 'dart:io';

import 'package:launch_at_startup/launch_at_startup.dart';

Future<bool> isAutostartEnabled() async {
  try {
    _setup();
    return await LaunchAtStartup.instance.isEnabled();
  } catch (_) {
    return false;
  }
}

Future<void> setAutostart(bool enabled) async {
  _setup();
  if (enabled) {
    await LaunchAtStartup.instance.enable();
  } else {
    await LaunchAtStartup.instance.disable();
  }
}

void _setup() {
  LaunchAtStartup.instance.setup(
    appName: 'Loop',
    appPath: Platform.resolvedExecutable,
  );
}
