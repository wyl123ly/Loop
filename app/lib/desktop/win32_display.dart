import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';

import 'package:ffi/ffi.dart';

import 'system_scale.dart';
import 'window_mode.dart';

// ---------------------------------------------------------------------------
// Win32 / DPI 访问（物理像素为权威）。规格 §4.6。
//
// 仅在 Windows 上可用；所有入口都做了异常保护，失败时返回 null/false 由调用方
// 回退到逻辑坐标（window_manager / screen_retriever）。
// ---------------------------------------------------------------------------

const int _monitorInfoFPrimary = 0x1;
const int _monitorDefaultToNearest = 0x2;
const int _gwlStyle = -16;
const int _gwlExStyle = -20;
const int _wsPopup = 0x80000000;
const int _wsExTopmost = 0x00000008;
const int _wsExToolWindow = 0x00000080;
const int _wsExNoActivate = 0x08000000;
const int _swpNoZOrder = 0x0004;
const int _swpNoActivate = 0x0010;
const int _swpNoOwnerZOrder = 0x0200;
const int _swpNoMove = 0x0002;
const int _swpNoSize = 0x0001;
const int _swpShowWindow = 0x0040;
const int _swpFrameChanged = 0x0020;
const int _swHide = 0;
const int _swShowNoActivate = 4;
const int _swShowNormal = 1;
const int _swShowMaximized = 3;
const int _wmClose = 0x0010;

final class _Rect extends Struct {
  @Int32()
  external int left;

  @Int32()
  external int top;

  @Int32()
  external int right;

  @Int32()
  external int bottom;
}

final class _Point extends Struct {
  @Int32()
  external int x;

  @Int32()
  external int y;
}

final class _MonitorInfoEx extends Struct {
  @Uint32()
  external int cbSize;

  external _Rect rcMonitor;

  external _Rect rcWork;

  @Uint32()
  external int dwFlags;

  @Array(32)
  external Array<Uint16> szDevice;
}

final class _WindowPlacement extends Struct {
  @Uint32()
  external int length;

  @Uint32()
  external int flags;

  @Uint32()
  external int showCmd;

  external _Point ptMinPosition;

  external _Point ptMaxPosition;

  external _Rect rcNormalPosition;
}

typedef _EnumWindowsProcNative = Int32 Function(IntPtr hwnd, IntPtr data);

typedef _MonitorEnumProcNative = Int32 Function(
    IntPtr hMonitor, IntPtr hdc, Pointer<_Rect> rect, IntPtr data);

class Win32Display {
  const Win32Display._();

  static bool get available => Platform.isWindows;

  /// 枚举显示器（Win32 物理矩形 + rcWork + 有效 DPI + 主屏标记）。
  static List<DisplayInfo> displays() {
    if (!available) return const [];
    final result = <DisplayInfo>[];
    final callback = NativeCallable<_MonitorEnumProcNative>.isolateLocal(
      (int hMonitor, int hdc, Pointer<_Rect> rect, int data) {
        final info = calloc<_MonitorInfoEx>();
        try {
          info.ref.cbSize = sizeOf<_MonitorInfoEx>();
          if (_getMonitorInfo(hMonitor, info) != 0) {
            result.add(_toDisplayInfo(hMonitor, info.ref));
          }
        } catch (_) {
          // 单个显示器失败不影响其它显示器。
        } finally {
          calloc.free(info);
        }
        return 1; // continue enumeration
      },
      exceptionalReturn: 0,
    );
    try {
      _enumDisplayMonitors(0, nullptr, callback.nativeFunction, 0);
    } catch (_) {
      return const [];
    } finally {
      callback.close();
    }
    return result;
  }

  /// 窗口物理矩形（Win32 GetWindowRect）。
  static Rect? windowRect(int hwnd) {
    if (!available || hwnd == 0) return null;
    final rect = calloc<_Rect>();
    try {
      if (_getWindowRect(hwnd, rect) == 0) return null;
      return _fromRect(rect.ref);
    } catch (_) {
      return null;
    } finally {
      calloc.free(rect);
    }
  }

  /// 窗口 restore-down placement（`WINDOWPLACEMENT.rcNormalPosition`，物理像素）。
  ///
  /// 最大化窗口的 GetWindowRect 是最大化矩形；用户点“还原”后实际回到的位置由该
  /// 字段决定，必须在进入浮窗/截图覆盖前单独保存。
  static Rect? normalPlacement(int hwnd) {
    if (!available || hwnd == 0) return null;
    final placement = calloc<_WindowPlacement>();
    try {
      placement.ref.length = sizeOf<_WindowPlacement>();
      if (_getWindowPlacement(hwnd, placement) == 0) return null;
      return _fromRect(placement.ref.rcNormalPosition);
    } catch (_) {
      return null;
    } finally {
      calloc.free(placement);
    }
  }

  /// 一次设置 restore-down placement 与最大化状态（`SetWindowPlacement`）。
  ///
  /// 比 “unmaximize → setBounds → maximize” 少一次可见的中间尺寸/动画，且不会让
  /// 浮窗 bounds 污染 rcNormalPosition。失败返回 false，由调用方回退。
  static bool setWindowPlacement(
    int hwnd,
    Rect normalPlacement, {
    required bool maximized,
  }) {
    if (!available || hwnd == 0) return false;
    if (normalPlacement.width < 1 || normalPlacement.height < 1) return false;
    final placement = calloc<_WindowPlacement>();
    try {
      placement.ref.length = sizeOf<_WindowPlacement>();
      placement.ref.flags = 0;
      placement.ref.showCmd = maximized ? _swShowMaximized : _swShowNormal;
      placement.ref.rcNormalPosition.left = normalPlacement.left.round();
      placement.ref.rcNormalPosition.top = normalPlacement.top.round();
      placement.ref.rcNormalPosition.right = normalPlacement.right.round();
      placement.ref.rcNormalPosition.bottom = normalPlacement.bottom.round();
      return _setWindowPlacement(hwnd, placement) != 0;
    } catch (_) {
      return false;
    } finally {
      calloc.free(placement);
    }
  }

  /// 按物理矩形移动/缩放窗口；默认不激活窗口（不抢焦点）。
  static bool setWindowPos(
    int hwnd,
    Rect physical, {
    required bool topmost,
    bool activate = false,
    bool frameChanged = false,
  }) {
    if (!available || hwnd == 0) return false;
    final width = math.max(1, physical.width.round());
    final height = math.max(1, physical.height.round());
    var flags = _swpNoOwnerZOrder;
    if (!activate) flags |= _swpNoActivate;
    if (!topmost) flags |= _swpNoZOrder;
    if (frameChanged) flags |= _swpFrameChanged;
    try {
      final ok = _setWindowPos(
        hwnd,
        topmost ? -1 : 0, // HWND_TOPMOST : HWND_TOP
        physical.left.round(),
        physical.top.round(),
        width,
        height,
        flags,
      );
      return ok != 0;
    } catch (_) {
      return false;
    }
  }

  /// 物理点所在显示器（最近显示器，不回退主屏）；失败返回 null。
  static DisplayInfo? displayAt(Offset physicalPoint) {
    if (!available) return null;
    final point = calloc<_Point>();
    final info = calloc<_MonitorInfoEx>();
    try {
      point.ref
        ..x = physicalPoint.dx.round()
        ..y = physicalPoint.dy.round();
      final monitor = _monitorFromPoint(point, _monitorDefaultToNearest);
      if (monitor == 0) return null;
      info.ref.cbSize = sizeOf<_MonitorInfoEx>();
      if (_getMonitorInfo(monitor, info) == 0) return null;
      return _toDisplayInfo(monitor, info.ref);
    } catch (_) {
      return null;
    } finally {
      calloc.free(point);
      calloc.free(info);
    }
  }

  /// 显示窗口但**不激活**（不抢焦点）。已最小化时先无激活恢复。
  ///
  /// window_manager 0.5.2 的 `show()` 在 Windows 上无条件
  /// `SetForegroundWindow`，不能用于浮窗切换/截图覆盖等非用户聚焦路径。
  static bool showNoActivate(int hwnd) {
    if (!available || hwnd == 0) return false;
    try {
      return _setWindowPos(
            hwnd,
            0,
            0,
            0,
            0,
            0,
            _swpNoMove |
                _swpNoSize |
                _swpNoZOrder |
                _swpNoActivate |
                _swpShowWindow,
          ) !=
          0;
    } catch (_) {
      return false;
    }
  }

  /// 从最小化恢复（依然不激活）。
  static bool restoreNoActivate(int hwnd) {
    if (!available || hwnd == 0) return false;
    try {
      _showWindow(hwnd, _swShowNoActivate);
      return true;
    } catch (_) {
      return false;
    }
  }

  static bool isMinimized(int hwnd) {
    if (!available || hwnd == 0) return false;
    try {
      return _isIconic(hwnd) != 0;
    } catch (_) {
      return false;
    }
  }

  /// 窗口物理矩形中心所在显示器的设备名。
  static String? displayIdAt(Offset physicalPoint) =>
      displayAt(physicalPoint)?.id;

  /// 窗口所在显示器的有效 DPI 缩放；失败回退 systemScaleFactor()。
  static double scaleForWindow(int hwnd) {
    if (!available || hwnd == 0) return systemScaleFactor();
    try {
      final dpi = _getDpiForWindow(hwnd);
      if (dpi > 0) return (dpi / 96.0).clamp(0.5, 4.0).toDouble();
    } catch (_) {}
    return systemScaleFactor();
  }

  /// 窗口是否为置顶窗口（WS_EX_TOPMOST）。
  static bool isAlwaysOnTop(int hwnd) {
    if (!available || hwnd == 0) return false;
    try {
      final style = _getWindowLongPtr(hwnd, _gwlExStyle);
      return (style & _wsExTopmost) != 0;
    } catch (_) {
      return false;
    }
  }

  /// 逻辑 bounds × dpr 的兜底（Win32 不可用时）。
  static Rect scaleRect(Rect logical, double dpr) => Rect.fromLTWH(
        logical.left * dpr,
        logical.top * dpr,
        logical.width * dpr,
        logical.height * dpr,
      );

  // -------------------------------------------------------------------------
  // 第二顶层窗口（回答窗）支持：进程/枚举/样式/无激活显示/关闭。规格 §2.6、附录 D。
  // -------------------------------------------------------------------------

  /// 当前进程 id。
  static int currentProcessId() {
    if (!available) return 0;
    try {
      return _getCurrentProcessId();
    } catch (_) {
      return 0;
    }
  }

  /// 顶层窗口所属进程 id（GetWindowThreadProcessId）。
  static int? windowProcessId(int hwnd) {
    if (!available || hwnd == 0) return null;
    final pid = calloc<Uint32>();
    try {
      final thread = _getWindowThreadProcessId(hwnd, pid);
      if (thread == 0) return null;
      return pid.value;
    } catch (_) {
      return null;
    } finally {
      calloc.free(pid);
    }
  }

  /// 顶层窗口类名（GetClassNameW）。
  static String? classNameOf(int hwnd) {
    if (!available || hwnd == 0) return null;
    final buffer = calloc<Uint16>(256);
    try {
      final length = _getClassName(hwnd, buffer, 256);
      if (length <= 0) return null;
      final units = <int>[];
      for (var i = 0; i < length; i++) {
        units.add(buffer[i]);
      }
      return String.fromCharCodes(units);
    } catch (_) {
      return null;
    } finally {
      calloc.free(buffer);
    }
  }

  /// 当前进程内所有指定类名的顶层窗口（EnumWindows）。
  static List<int> windowsOfClass(String className) {
    if (!available) return const <int>[];
    final result = <int>[];
    final callable = NativeCallable<_EnumWindowsProcNative>.isolateLocal(
      (int hwnd, int data) {
        try {
          if (classNameOf(hwnd) == className) result.add(hwnd);
        } catch (_) {}
        return 1;
      },
      exceptionalReturn: 0,
    );
    try {
      _enumWindows(callable.nativeFunction, 0);
    } catch (_) {
      return const <int>[];
    } finally {
      callable.close();
    }
    return result;
  }

  /// 当前进程内的顶层窗口（不按类名过滤）。
  static List<int> topLevelWindows() {
    if (!available) return const <int>[];
    final result = <int>[];
    final callable = NativeCallable<_EnumWindowsProcNative>.isolateLocal(
      (int hwnd, int data) {
        result.add(hwnd);
        return 1;
      },
      exceptionalReturn: 0,
    );
    try {
      _enumWindows(callable.nativeFunction, 0);
    } catch (_) {
      return const <int>[];
    } finally {
      callable.close();
    }
    return result;
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

  static bool setForeground(int hwnd) {
    if (!available || hwnd == 0) return false;
    try {
      return _setForegroundWindow(hwnd) != 0;
    } catch (_) {
      return false;
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

  static bool isWindowVisible(int hwnd) {
    if (!available || hwnd == 0) return false;
    try {
      return _isWindowVisible(hwnd) != 0;
    } catch (_) {
      return false;
    }
  }

  /// `ShowWindow(SW_SHOWNOACTIVATE)`：显示但不激活/不抢焦点。
  static bool showNoActivateWindow(int hwnd) {
    if (!available || hwnd == 0) return false;
    try {
      _showWindow(hwnd, _swShowNoActivate);
      return true;
    } catch (_) {
      return false;
    }
  }

  static bool hideWindow(int hwnd) {
    if (!available || hwnd == 0) return false;
    try {
      _showWindow(hwnd, _swHide);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// `PostMessage(WM_CLOSE)`（不等待销毁；由 onWindowsChanged/轮询确认）。
  static bool postClose(int hwnd) {
    if (!available || hwnd == 0) return false;
    try {
      return _postMessage(hwnd, _wmClose, 0, 0) != 0;
    } catch (_) {
      return false;
    }
  }

  static bool setWindowTitle(int hwnd, String title) {
    if (!available || hwnd == 0) return false;
    final pointer = title.toNativeUtf16();
    try {
      return _setWindowText(hwnd, pointer) != 0;
    } catch (_) {
      return false;
    } finally {
      malloc.free(pointer);
    }
  }

  static int windowStyle(int hwnd) {
    if (!available || hwnd == 0) return 0;
    try {
      return _getWindowLongPtr(hwnd, _gwlStyle);
    } catch (_) {
      return 0;
    }
  }

  static int windowExStyle(int hwnd) {
    if (!available || hwnd == 0) return 0;
    try {
      return _getWindowLongPtr(hwnd, _gwlExStyle);
    } catch (_) {
      return 0;
    }
  }

  static bool setWindowStyle(int hwnd, int style) {
    if (!available || hwnd == 0) return false;
    try {
      _setWindowLongPtr(hwnd, _gwlStyle, style);
      return true;
    } catch (_) {
      return false;
    }
  }

  static bool setWindowExStyle(int hwnd, int exStyle) {
    if (!available || hwnd == 0) return false;
    try {
      _setWindowLongPtr(hwnd, _gwlExStyle, exStyle);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 回答窗样式：无边框 + 无激活 + 工具窗口（不出现在任务栏/Alt+Tab）+ 置顶。
  ///
  /// F-06：不能用“样式必须完全等于期望值”判断成功——Windows/Flutter 会附加
  /// WS_CLIPSIBLINGS/WS_VISIBLE 等位，且 WS_EX_TOPMOST 不能靠 SetWindowLongPtr
  /// 判断（需 SetWindowPos(HWND_TOPMOST) 建立）。这里只检查必要位，置顶用
  /// SetWindowPos 落实；失败时重试一次，仍失败才返回 false。
  static bool applyAnswerWindowChrome(int hwnd, {required bool topmost}) {
    if (!available || hwnd == 0) return false;
    final baseExStyle = _wsExNoActivate | _wsExToolWindow;
    for (var attempt = 0; attempt < 2; attempt++) {
      setWindowStyle(hwnd, _wsPopup);
      setWindowExStyle(hwnd, baseExStyle);
      final style = windowStyle(hwnd);
      final ex = windowExStyle(hwnd);
      final styleOk = (style & _wsPopup) != 0;
      final exOk = (ex & baseExStyle) == baseExStyle;
      if (!styleOk || !exOk) continue;
      try {
        _setWindowPos(
          hwnd,
          topmost ? -1 : 0,
          0,
          0,
          0,
          0,
          _swpNoMove |
              _swpNoSize |
              _swpNoActivate |
              _swpFrameChanged |
              (topmost ? 0 : _swpNoZOrder),
        );
      } catch (_) {}
      return true;
    }
    return false;
  }

  /// 无激活把窗口抬到最上层（主窗重新激活时调用；不改变焦点）。
  static bool raiseNoActivate(int hwnd) {
    if (!available || hwnd == 0) return false;
    try {
      return _setWindowPos(
            hwnd,
            -1, // HWND_TOPMOST
            0,
            0,
            0,
            0,
            _swpNoMove | _swpNoSize | _swpNoActivate | _swpNoOwnerZOrder,
          ) !=
          0;
    } catch (_) {
      return false;
    }
  }

  /// 鼠标物理坐标（GetCursorPos）。
  static Offset? cursorPosition() {
    if (!available) return null;
    final point = calloc<_Point>();
    try {
      if (_getCursorPos(point) == 0) return null;
      return Offset(point.ref.x.toDouble(), point.ref.y.toDouble());
    } catch (_) {
      return null;
    } finally {
      calloc.free(point);
    }
  }

  static DisplayInfo _toDisplayInfo(int monitor, _MonitorInfoEx info) {
    final dpi = _effectiveDpi(monitor);
    final scale = dpi > 0
        ? (dpi / 96.0).clamp(0.5, 4.0).toDouble()
        : systemScaleFactor();
    final id = _readSzDevice(info);
    return DisplayInfo(
      id: id.isEmpty ? 'monitor-$monitor' : id,
      physicalBounds: _fromRect(info.rcMonitor),
      physicalWorkArea: _fromRect(info.rcWork),
      scaleFactor: scale,
      isPrimary: (info.dwFlags & _monitorInfoFPrimary) != 0,
    );
  }

  static int _effectiveDpi(int monitor) {
    final dpiX = calloc<Uint32>();
    final dpiY = calloc<Uint32>();
    try {
      final hr = _getDpiForMonitor(monitor, 0, dpiX, dpiY);
      if (hr == 0 && dpiX.value > 0) return dpiX.value;
    } catch (_) {
    } finally {
      calloc.free(dpiX);
      calloc.free(dpiY);
    }
    return 0;
  }

  static String _readSzDevice(_MonitorInfoEx info) {
    final units = <int>[];
    for (var i = 0; i < 32; i++) {
      final unit = info.szDevice[i];
      if (unit == 0) break;
      units.add(unit);
    }
    return String.fromCharCodes(units);
  }

  static Rect _fromRect(_Rect rect) => Rect.fromLTRB(
        rect.left.toDouble(),
        rect.top.toDouble(),
        rect.right.toDouble(),
        rect.bottom.toDouble(),
      );
}

// ---------------------------------------------------------------------------
// 绑定的 Win32 函数（静态缓存，失败由调用处捕获）。
// ---------------------------------------------------------------------------

final DynamicLibrary _user32 = DynamicLibrary.open('user32.dll');

final int Function(int, Pointer<_MonitorInfoEx>) _getMonitorInfo =
    _user32.lookupFunction<Int32 Function(IntPtr, Pointer<_MonitorInfoEx>),
        int Function(int, Pointer<_MonitorInfoEx>)>('GetMonitorInfoW');

final int Function(int, Pointer<_Rect>) _getWindowRect =
    _user32.lookupFunction<Int32 Function(IntPtr, Pointer<_Rect>),
        int Function(int, Pointer<_Rect>)>('GetWindowRect');

final int Function(int, Pointer<_WindowPlacement>) _getWindowPlacement =
    _user32.lookupFunction<Int32 Function(IntPtr, Pointer<_WindowPlacement>),
        int Function(int, Pointer<_WindowPlacement>)>('GetWindowPlacement');

final int Function(int, Pointer<_WindowPlacement>) _setWindowPlacement =
    _user32.lookupFunction<Int32 Function(IntPtr, Pointer<_WindowPlacement>),
        int Function(int, Pointer<_WindowPlacement>)>('SetWindowPlacement');

final int Function(int, int, int, int, int, int, int) _setWindowPos =
    _user32.lookupFunction<
        Int32 Function(IntPtr, IntPtr, Int32, Int32, Int32, Int32, Uint32),
        int Function(int, int, int, int, int, int, int)>('SetWindowPos');

final int Function(Pointer<_Point>, int) _monitorFromPoint =
    _user32.lookupFunction<IntPtr Function(Pointer<_Point>, Uint32),
        int Function(Pointer<_Point>, int)>('MonitorFromPoint');

final int Function(int, int) _getWindowLongPtr = _lookupGetWindowLongPtr();

final int Function(int, int, int) _setWindowLongPtr = _lookupSetWindowLongPtr();

final int Function(int, int) _showWindow =
    _user32.lookupFunction<Int32 Function(IntPtr, Int32), int Function(int, int)>(
        'ShowWindow');

final int Function() _getForegroundWindow =
    _user32.lookupFunction<IntPtr Function(), int Function()>(
        'GetForegroundWindow');

final int Function(int) _setForegroundWindow =
    _user32.lookupFunction<Int32 Function(IntPtr), int Function(int)>(
        'SetForegroundWindow');

final int Function(int) _isWindow =
    _user32.lookupFunction<Int32 Function(IntPtr), int Function(int)>('IsWindow');

final int Function(int) _isWindowVisible =
    _user32.lookupFunction<Int32 Function(IntPtr), int Function(int)>(
        'IsWindowVisible');

final int Function(int, Pointer<Uint16>, int) _getClassName =
    _user32.lookupFunction<
        Int32 Function(IntPtr, Pointer<Uint16>, Int32),
        int Function(int, Pointer<Uint16>, int)>('GetClassNameW');

final int Function(int, Pointer<Uint32>) _getWindowThreadProcessId =
    _user32.lookupFunction<
        Uint32 Function(IntPtr, Pointer<Uint32>),
        int Function(int, Pointer<Uint32>)>('GetWindowThreadProcessId');

final int Function(
    Pointer<NativeFunction<_EnumWindowsProcNative>>, int) _enumWindows =
    _user32.lookupFunction<
        Int32 Function(Pointer<NativeFunction<_EnumWindowsProcNative>>, IntPtr),
        int Function(Pointer<NativeFunction<_EnumWindowsProcNative>>,
            int)>('EnumWindows');

final int Function(int, int, int, int) _postMessage =
    _user32.lookupFunction<
        Int32 Function(IntPtr, Uint32, IntPtr, IntPtr),
        int Function(int, int, int, int)>('PostMessageW');

final int Function(int, Pointer<Utf16>) _setWindowText =
    _user32.lookupFunction<
        Int32 Function(IntPtr, Pointer<Utf16>),
        int Function(int, Pointer<Utf16>)>('SetWindowTextW');

final int Function(Pointer<_Point>) _getCursorPos =
    _user32.lookupFunction<
        Int32 Function(Pointer<_Point>),
        int Function(Pointer<_Point>)>('GetCursorPos');

final DynamicLibrary _kernel32 = DynamicLibrary.open('kernel32.dll');

final int Function() _getCurrentProcessId =
    _kernel32.lookupFunction<Uint32 Function(), int Function()>(
        'GetCurrentProcessId');

final int Function(int) _isIconic =
    _user32.lookupFunction<Int32 Function(IntPtr), int Function(int)>('IsIconic');

final int Function(int) _getDpiForWindow = _lookupGetDpiForWindow();

final int Function(
    int, Pointer<_Rect>, Pointer<NativeFunction<_MonitorEnumProcNative>>,
    int) _enumDisplayMonitors = _user32.lookupFunction<
        Int32 Function(
            IntPtr,
            Pointer<_Rect>,
            Pointer<NativeFunction<_MonitorEnumProcNative>>,
            IntPtr),
        int Function(int, Pointer<_Rect>,
            Pointer<NativeFunction<_MonitorEnumProcNative>>, int)>(
    'EnumDisplayMonitors');

final DynamicLibrary? _shcore = _openShcore();

final int Function(int, int, Pointer<Uint32>, Pointer<Uint32>) _getDpiForMonitor =
    _lookupGetDpiForMonitor();

int Function(int, int) _lookupGetWindowLongPtr() {
  try {
    return _user32.lookupFunction<IntPtr Function(IntPtr, Int32),
        int Function(int, int)>('GetWindowLongPtrW');
  } catch (_) {
    try {
      final legacy = _user32.lookupFunction<Int32 Function(IntPtr, Int32),
          int Function(int, int)>('GetWindowLongW');
      return legacy;
    } catch (_) {
      return (_, _) => 0;
    }
  }
}

int Function(int, int, int) _lookupSetWindowLongPtr() {
  try {
    return _user32.lookupFunction<
        IntPtr Function(IntPtr, Int32, IntPtr),
        int Function(int, int, int)>('SetWindowLongPtrW');
  } catch (_) {
    try {
      return _user32.lookupFunction<
          Int32 Function(IntPtr, Int32, Int32),
          int Function(int, int, int)>('SetWindowLongW');
    } catch (_) {
      return (_, _, _) => 0;
    }
  }
}

int Function(int) _lookupGetDpiForWindow() {
  try {
    return _user32.lookupFunction<Uint32 Function(IntPtr), int Function(int)>(
        'GetDpiForWindow');
  } catch (_) {
    return (_) => 0;
  }
}

DynamicLibrary? _openShcore() {
  try {
    return DynamicLibrary.open('shcore.dll');
  } catch (_) {
    return null;
  }
}

int Function(int, int, Pointer<Uint32>, Pointer<Uint32>) _lookupGetDpiForMonitor() {
  final library = _shcore;
  if (library == null) return (_, _, _, _) => -1;
  try {
    return library.lookupFunction<
        Int32 Function(IntPtr, Int32, Pointer<Uint32>, Pointer<Uint32>),
        int Function(int, int, Pointer<Uint32>, Pointer<Uint32>)>(
      'GetDpiForMonitor',
    );
  } catch (_) {
    return (_, _, _, _) => -1;
  }
}
