import 'dart:ffi';
import 'dart:io';
import 'dart:ui';

import 'package:ffi/ffi.dart';

// ---------------------------------------------------------------------------
// 第二引擎（回答窗）所需的 Win32 FFI：拖动 / 几何自检。
//
// 严格只使用 user32 的窗口操作，**不依赖 window_manager**（子引擎注册
// window_manager 会导致 0xC0000005 崩溃，规格 §2.3 P11）。
// 拖动算法（规格附录 D）：onPanStart 记录 cursor0/rect0；onPanUpdate 用
// GetCursorPos + SetWindowPos(SWP_NOSIZE|SWP_NOZORDER|SWP_NOACTIVATE) 跟手；
// onPanEnd 把最终物理矩形上报主引擎钳制/记忆。
// ---------------------------------------------------------------------------

const int _swpNoSize = 0x0001;
const int _swpNoZOrder = 0x0004;
const int _swpNoActivate = 0x0010;
const int _gaRoot = 2;

final class _AnswerRect extends Struct {
  @Int32()
  external int left;

  @Int32()
  external int top;

  @Int32()
  external int right;

  @Int32()
  external int bottom;
}

final class _AnswerPoint extends Struct {
  @Int32()
  external int x;

  @Int32()
  external int y;
}

/// 回答窗（第二引擎）Win32 最小封装。
class AnswerWin32 {
  const AnswerWin32._();

  static bool get available => Platform.isWindows;

  /// 鼠标物理坐标；失败返回 null。
  static Offset? cursorPosition() {
    if (!available) return null;
    final point = calloc<_AnswerPoint>();
    try {
      if (_getCursorPos(point) == 0) return null;
      return Offset(point.ref.x.toDouble(), point.ref.y.toDouble());
    } catch (_) {
      return null;
    } finally {
      calloc.free(point);
    }
  }

  /// 窗口物理矩形（GetWindowRect）。
  static Rect? windowRect(int hwnd) {
    if (!available || hwnd == 0) return null;
    final rect = calloc<_AnswerRect>();
    try {
      if (_getWindowRect(hwnd, rect) == 0) return null;
      return Rect.fromLTRB(
        rect.ref.left.toDouble(),
        rect.ref.top.toDouble(),
        rect.ref.right.toDouble(),
        rect.ref.bottom.toDouble(),
      );
    } catch (_) {
      return null;
    } finally {
      calloc.free(rect);
    }
  }

  /// 只移动（不改尺寸/不改 Z 序/不激活）。
  static bool moveWindowNoActivate(int hwnd, Offset topLeft) {
    if (!available || hwnd == 0) return false;
    try {
      return _setWindowPos(
            hwnd,
            0,
            topLeft.dx.round(),
            topLeft.dy.round(),
            0,
            0,
            _swpNoSize | _swpNoZOrder | _swpNoActivate,
          ) !=
          0;
    } catch (_) {
      return false;
    }
  }

  /// 移动 + 改尺寸（无激活）；主引擎也会用其实现收起/展开。
  static bool moveResizeNoActivate(int hwnd, Rect physical) {
    if (!available || hwnd == 0) return false;
    try {
      return _setWindowPos(
            hwnd,
            0,
            physical.left.round(),
            physical.top.round(),
            physical.width.round(),
            physical.height.round(),
            _swpNoZOrder | _swpNoActivate,
          ) !=
          0;
    } catch (_) {
      return false;
    }
  }

  static int? foregroundWindow() {
    if (!available) return null;
    try {
      final hwnd = _getForegroundWindow();
      return hwnd == 0 ? null : hwnd;
    } catch (_) {
      return null;
    }
  }

  static bool isWindow(int hwnd) {
    if (!available || hwnd == 0) return false;
    try {
      return _isWindow(hwnd) != 0;
    } catch (_) {
      return false;
    }
  }

  /// 物理坐标点的根窗口（WindowFromPoint + GetAncestor(GA_ROOT)），用于自检。
  static int? rootWindowAt(Offset physical) {
    if (!available) return null;
    final point = calloc<_AnswerPoint>();
    try {
      point.ref
        ..x = physical.dx.round()
        ..y = physical.dy.round();
      final hwnd = _windowFromPoint(point);
      if (hwnd == 0) return null;
      final root = _getAncestor(hwnd, _gaRoot);
      return root == 0 ? hwnd : root;
    } catch (_) {
      return null;
    } finally {
      calloc.free(point);
    }
  }
}

/// 回答窗拖动会话（第二引擎 Dart 侧，纯 Win32 无激活移动）。
///
/// 用法：
/// ```dart
/// final session = AnswerWindowDragSession.start(hwnd);
/// session.update(AnswerWin32.cursorPosition()!);  // onPanUpdate
/// final rect = session.finish();                   // onPanEnd -> moved{rect}
/// ```
class AnswerWindowDragSession {
  AnswerWindowDragSession._(this.hwnd, this._startCursor, this._startRect);

  final int hwnd;
  final Offset _startCursor;
  final Rect _startRect;
  Rect? _current;

  /// 开始拖动；hwnd 无效或 GetCursorPos/GetWindowRect 失败返回 null。
  static AnswerWindowDragSession? start(
    int hwnd, {
    Offset? cursor,
  }) {
    final startCursor = cursor ?? AnswerWin32.cursorPosition();
    final startRect = AnswerWin32.windowRect(hwnd);
    if (startCursor == null || startRect == null) return null;
    return AnswerWindowDragSession._(hwnd, startCursor, startRect);
  }

  Rect? get current => _current;

  /// 根据当前鼠标物理坐标移动窗口；返回本次物理矩形。
  Rect? update(Offset cursor) {
    final delta = cursor - _startCursor;
    final rect = _startRect.translate(delta.dx, delta.dy);
    if (AnswerWin32.moveWindowNoActivate(hwnd, rect.topLeft)) {
      _current = rect;
    }
    return _current;
  }

  /// 结束拖动，返回最终物理矩形（用于 `moved{physicalRect}` 上报）。
  Rect? finish() => _current ?? AnswerWin32.windowRect(hwnd);

  void cancel() {
    _current = null;
  }
}

// ---------------------------------------------------------------------------
// user32 绑定
// ---------------------------------------------------------------------------

final DynamicLibrary _user32 = DynamicLibrary.open('user32.dll');

final int Function(Pointer<_AnswerPoint>) _getCursorPos =
    _user32.lookupFunction<
        Int32 Function(Pointer<_AnswerPoint>),
        int Function(Pointer<_AnswerPoint>)>('GetCursorPos');

final int Function(int, Pointer<_AnswerRect>) _getWindowRect =
    _user32.lookupFunction<
        Int32 Function(IntPtr, Pointer<_AnswerRect>),
        int Function(int, Pointer<_AnswerRect>)>('GetWindowRect');

final int Function(int, int, int, int, int, int, int) _setWindowPos =
    _user32.lookupFunction<
        Int32 Function(IntPtr, IntPtr, Int32, Int32, Int32, Int32, Uint32),
        int Function(int, int, int, int, int, int, int)>('SetWindowPos');

final int Function() _getForegroundWindow =
    _user32.lookupFunction<IntPtr Function(), int Function()>(
        'GetForegroundWindow');

final int Function(int) _isWindow =
    _user32.lookupFunction<Int32 Function(IntPtr), int Function(int)>('IsWindow');

final int Function(Pointer<_AnswerPoint>) _windowFromPoint =
    _user32.lookupFunction<
        IntPtr Function(Pointer<_AnswerPoint>),
        int Function(Pointer<_AnswerPoint>)>('WindowFromPoint');

final int Function(int, int) _getAncestor =
    _user32.lookupFunction<IntPtr Function(IntPtr, Uint32),
        int Function(int, int)>('GetAncestor');
