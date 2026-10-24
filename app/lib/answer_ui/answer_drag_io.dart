import 'dart:ui' show Rect;

import '../desktop/answer_host/win32_answer.dart';
import 'answer_window_app.dart';

/// 创建回答窗拖动代理（Windows 第二引擎）。
///
/// 只用 t2 提供的 user32 FFI（`AnswerWin32` + `AnswerWindowDragSession`），
/// 不依赖 window_manager（子引擎会崩溃，规格 §2.3 P11）。
AnswerDragDelegate? createAnswerDragDelegate() =>
    AnswerWin32.available ? _Win32AnswerDragDelegate() : null;

class _Win32AnswerDragDelegate implements AnswerDragDelegate {
  AnswerWindowDragSession? _session;

  @override
  bool get available => AnswerWin32.available;

  @override
  bool start(int? hwnd) {
    if (!available || hwnd == null || hwnd == 0) return false;
    _session = AnswerWindowDragSession.start(hwnd);
    return _session != null;
  }

  @override
  void update() {
    final session = _session;
    if (session == null) return;
    final cursor = AnswerWin32.cursorPosition();
    if (cursor == null) return;
    session.update(cursor);
  }

  @override
  Rect? finish() {
    final session = _session;
    _session = null;
    return session?.finish();
  }

  @override
  void cancel() {
    _session?.cancel();
    _session = null;
  }
}
