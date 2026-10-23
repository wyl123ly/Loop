import 'dart:io';

import 'package:flutter/scheduler.dart';

/// 仅用于诊断：LOOP_FRAME_LOG=1 时把每帧耗时写入 CSV。
void installFrameLogger() {
  if (Platform.environment['LOOP_FRAME_LOG'] != '1') return;
  final path = Platform.environment['LOOP_FRAME_LOG_PATH'] ??
      '${Directory.systemTemp.path}${Platform.pathSeparator}loop_frames.csv';
  final sink = File(path).openSync(mode: FileMode.write);
  SchedulerBinding.instance.addTimingsCallback((timings) {
    for (final timing in timings) {
      sink.writeStringSync(
        '${timing.buildDuration.inMicroseconds},'
        '${timing.rasterDuration.inMicroseconds},'
        '${timing.totalSpan.inMicroseconds}\n',
      );
    }
  });
}
