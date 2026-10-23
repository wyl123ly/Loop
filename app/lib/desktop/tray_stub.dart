Future<bool> initTray({
  required void Function() onShow,
  required void Function() onQuit,
  required Future<void> Function() onRunJobs,
  required void Function() onTrayReady,
}) async =>
    false;
