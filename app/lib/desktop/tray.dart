import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:tray_manager/tray_manager.dart';

import '../backend/paths.dart';

/// 初始化系统托盘；返回是否成功。
Future<bool> initTray({
  required void Function() onShow,
  required void Function() onQuit,
  required Future<void> Function() onRunJobs,
  required void Function() onTrayReady,
}) async {
  try {
    final bytes = await rootBundle.load('assets/icons/tray.ico');
    final file = File(p.join(AppPaths.data.path, 'tray.ico'));
    file.writeAsBytesSync(bytes.buffer.asUint8List());
    await trayManager.setIcon(file.path);
    await trayManager.setContextMenu(Menu(items: [
      MenuItem(key: 'show', label: '显示回路'),
      MenuItem(key: 'jobs', label: '运行到期任务'),
      MenuItem.separator(),
      MenuItem(key: 'quit', label: '退出回路'),
    ]));
    trayManager.addListener(_TrayListener(
      onShow: onShow,
      onQuit: onQuit,
      onRunJobs: onRunJobs,
    ));
    onTrayReady();
    return true;
  } catch (error) {
    stderr.writeln('tray init failed: $error');
    return false;
  }
}

class _TrayListener with TrayListener {
  _TrayListener({required this.onShow, required this.onQuit, required this.onRunJobs});

  final void Function() onShow;
  final void Function() onQuit;
  final Future<void> Function() onRunJobs;

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show':
        onShow();
      case 'jobs':
        onRunJobs();
      case 'quit':
        onQuit();
    }
  }

  @override
  void onTrayIconMouseDown() => onShow();

  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();
}
