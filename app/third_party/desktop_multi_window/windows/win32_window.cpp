#include "win32_window.h"

#include <dwmapi.h>
#include <flutter_windows.h>

namespace {

/// Window attribute that enables dark mode window decorations.
///
/// Redefined in case the developer's machine has a Windows SDK older than
/// version 10.0.22000.0.
/// See:
/// https://docs.microsoft.com/windows/win32/api/dwmapi/ne-dwmapi-dwmwindowattribute
#ifndef DWMWA_USE_IMMERSIVE_DARK_MODE
#define DWMWA_USE_IMMERSIVE_DARK_MODE 20
#endif

constexpr const wchar_t kWindowClassName[] =
    L"FLUTTER_MULTI_WINDOW_WIN32_WINDOW";

constexpr UINT kResizeChildContentMessage = WM_APP + 0x3D1;

/// Registry key for app theme preference.
///
/// A value of 0 indicates apps should use dark mode. A non-zero or missing
/// value indicates apps should use light mode.
constexpr const wchar_t kGetPreferredBrightnessRegKey[] =
    L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize";
constexpr const wchar_t kGetPreferredBrightnessRegValue[] =
    L"AppsUseLightTheme";

// The number of Win32Window objects that currently exist.
static int g_active_window_count = 0;

using EnableNonClientDpiScaling = BOOL __stdcall(HWND hwnd);

// Scale helper to convert logical scaler values to physical using passed in
// scale factor
int Scale(int source, double scale_factor) {
  return static_cast<int>(source * scale_factor);
}

// Dynamically loads the |EnableNonClientDpiScaling| from the User32 module.
// This API is only needed for PerMonitor V1 awareness mode.
void EnableFullDpiSupportIfAvailable(HWND hwnd) {
  HMODULE user32_module = LoadLibraryA("User32.dll");
  if (!user32_module) {
    return;
  }
  auto enable_non_client_dpi_scaling =
      reinterpret_cast<EnableNonClientDpiScaling*>(
          GetProcAddress(user32_module, "EnableNonClientDpiScaling"));
  if (enable_non_client_dpi_scaling != nullptr) {
    enable_non_client_dpi_scaling(hwnd);
  }
  FreeLibrary(user32_module);
}

// Clip the popup window itself to the same rounded shape as the Flutter
// AnswerPanel. Without this, pixels outside the panel's ClipRRect are painted
// with the engine's black surface, producing dark wedges at the corners.
void ApplyRoundedWindowRegion(HWND window) {
  // SetWindowRgn can synchronously deliver WM_SIZE/WM_WINDOWPOSCHANGED.
  // Guard against re-entrancy and skip no-op updates; otherwise the region
  // handler can drive an endless message loop and freeze the whole process.
  static bool applying = false;
  static HWND last_window = nullptr;
  static int last_width = 0;
  static int last_height = 0;
  static int last_ellipse = 0;
  if (applying) {
    return;
  }

  RECT rect;
  if (!GetWindowRect(window, &rect)) {
    return;
  }
  const int width = rect.right - rect.left;
  const int height = rect.bottom - rect.top;
  if (width <= 0 || height <= 0) {
    return;
  }

  UINT dpi = 96;
  using GetDpiForWindowFn = UINT(WINAPI*)(HWND);
  HMODULE user32 = GetModuleHandleW(L"user32.dll");
  if (user32 != nullptr) {
    auto get_dpi = reinterpret_cast<GetDpiForWindowFn>(
        GetProcAddress(user32, "GetDpiForWindow"));
    if (get_dpi != nullptr) {
      const UINT window_dpi = get_dpi(window);
      if (window_dpi != 0) {
        dpi = window_dpi;
      }
    }
  }

  // Keep in sync with answerRadius in lib/desktop/window_mode.dart.
  const int ellipse = MulDiv(14, static_cast<int>(dpi), 96) * 2;
  if (window == last_window && width == last_width &&
      height == last_height && ellipse == last_ellipse) {
    return;
  }

  HRGN region =
      CreateRoundRectRgn(0, 0, width + 1, height + 1, ellipse, ellipse);
  if (region == nullptr) {
    return;
  }
  applying = true;
  if (SetWindowRgn(window, region, TRUE) != 0) {
    last_window = window;
    last_width = width;
    last_height = height;
    last_ellipse = ellipse;
  } else {
    DeleteObject(region);
  }
  applying = false;
}

}  // namespace

// Manages the Win32Window's window class registration.
class WindowClassRegistrar {
 public:
  ~WindowClassRegistrar() = default;

  // Returns the singleton registrar instance.
  static WindowClassRegistrar* GetInstance() {
    if (!instance_) {
      instance_ = new WindowClassRegistrar();
    }
    return instance_;
  }

  // Returns the name of the window class, registering the class if it hasn't
  // previously been registered.
  const wchar_t* GetWindowClass();

  // Unregisters the window class. Should only be called if there are no
  // instances of the window.
  void UnregisterWindowClass();

 private:
  WindowClassRegistrar() = default;

  static WindowClassRegistrar* instance_;

  bool class_registered_ = false;
};

WindowClassRegistrar* WindowClassRegistrar::instance_ = nullptr;

const wchar_t* WindowClassRegistrar::GetWindowClass() {
  if (!class_registered_) {
    WNDCLASS window_class{};
    window_class.hCursor = LoadCursor(nullptr, IDC_ARROW);
    window_class.lpszClassName = kWindowClassName;
    window_class.style = CS_HREDRAW | CS_VREDRAW;
    window_class.cbClsExtra = 0;
    window_class.cbWndExtra = 0;
    window_class.hInstance = GetModuleHandle(nullptr);

    TCHAR exePath[MAX_PATH];
    GetModuleFileName(NULL, exePath, MAX_PATH);
    HICON hIcon = ExtractIcon(GetModuleHandle(NULL), exePath, 0);
    if (hIcon) {
      window_class.hIcon = hIcon;
    } else {
      window_class.hIcon = LoadIcon(window_class.hInstance, IDI_APPLICATION);
    }

    window_class.hbrBackground = 0;
    window_class.lpszMenuName = nullptr;
    window_class.lpfnWndProc = Win32Window::WndProc;
    RegisterClass(&window_class);
    class_registered_ = true;
  }
  return kWindowClassName;
}

void WindowClassRegistrar::UnregisterWindowClass() {
  UnregisterClass(kWindowClassName, nullptr);
  class_registered_ = false;
}

Win32Window::Win32Window() {
  ++g_active_window_count;
}

Win32Window::~Win32Window() {
  --g_active_window_count;
  if (g_active_window_count == 0) {
    WindowClassRegistrar::GetInstance()->UnregisterWindowClass();
  }
}

bool Win32Window::Create(const std::wstring& title,
                         const Point& origin,
                         const Size& size) {
  if (window_handle_) {
    return false;
  }

  const wchar_t* window_class =
      WindowClassRegistrar::GetInstance()->GetWindowClass();

  const POINT target_point = {static_cast<LONG>(origin.x),
                              static_cast<LONG>(origin.y)};
  HMONITOR monitor = MonitorFromPoint(target_point, MONITOR_DEFAULTTONEAREST);
  UINT dpi = FlutterDesktopGetDpiForMonitor(monitor);
  double scale_factor = dpi / 96.0;

  // R1-B (Loop v0.6.0): create the second top-level window as a
  // non-activating tool window so the plugin's native CreateWindow cannot
  // steal foreground (spec 2.4 R1-B / 2.8).
  HWND window = CreateWindowEx(
      WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW, window_class, title.c_str(),
      WS_POPUP, Scale(origin.x, scale_factor), Scale(origin.y, scale_factor),
      Scale(size.width, scale_factor), Scale(size.height, scale_factor),
      nullptr, nullptr, GetModuleHandle(nullptr), this);

  if (!window) {
    return false;
  }

  UpdateTheme(window);
  ApplyRoundedWindowRegion(window);

  return OnCreate();
}

bool Win32Window::Show() {
  return ShowWindow(window_handle_, SW_SHOWNOACTIVATE);
}

// static
LRESULT CALLBACK Win32Window::WndProc(HWND const window,
                                      UINT const message,
                                      WPARAM const wparam,
                                      LPARAM const lparam) noexcept {
  if (message == WM_NCCREATE) {
    auto window_struct = reinterpret_cast<CREATESTRUCT*>(lparam);
    SetWindowLongPtr(window, GWLP_USERDATA,
                     reinterpret_cast<LONG_PTR>(window_struct->lpCreateParams));

    auto that = static_cast<Win32Window*>(window_struct->lpCreateParams);
    EnableFullDpiSupportIfAvailable(window);
    that->window_handle_ = window;
  } else if (Win32Window* that = GetThisFromHandle(window)) {
    return that->MessageHandler(window, message, wparam, lparam);
  }

  return DefWindowProc(window, message, wparam, lparam);
}

LRESULT
Win32Window::MessageHandler(HWND hwnd,
                            UINT const message,
                            WPARAM const wparam,
                            LPARAM const lparam) noexcept {
  switch (message) {
    // R1-B: click/drag/wheel on the answer window must never activate it.
    case WM_MOUSEACTIVATE:
      return MA_NOACTIVATE;

    case WM_DESTROY:
      window_handle_ = nullptr;
      Destroy();
      if (quit_on_close_) {
        PostQuitMessage(0);
      }
      return 0;

    case WM_DPICHANGED: {
      // R1-B (t12): the answer window's physical geometry is owned by the main
      // engine (Win32 SetWindowPos) and by the user drag FFI. Applying the OS
      // suggested rect here double-scales the window when it crosses monitors
      // with different DPI (e.g. 125% -> 150%: 1075x1120 becomes 1290x1344).
      // Only re-layout the Flutter child view; the host re-applies the final
      // physical rect after DPI settles.
      QueueChildContentResize();
      ApplyRoundedWindowRegion(hwnd);
      return 0;
    }
    case WM_SIZE: {
      ResizeChildContent();
      ApplyRoundedWindowRegion(hwnd);
      return 0;
    }
    case WM_WINDOWPOSCHANGED:
      QueueChildContentResize();
      break;
    case kResizeChildContentMessage:
      child_resize_pending_ = false;
      ResizeChildContent();
      ApplyRoundedWindowRegion(hwnd);
      return 0;

    case WM_ACTIVATE:
      // R1-B: the answer window is read-only; never move keyboard focus away
      // from the main window even if some path still activates it.
      return 0;

    case WM_DWMCOLORIZATIONCOLORCHANGED:
      UpdateTheme(hwnd);
      return 0;
  }

  return DefWindowProc(window_handle_, message, wparam, lparam);
}

void Win32Window::Destroy() {
  OnDestroy();

  if (window_handle_) {
    DestroyWindow(window_handle_);
    window_handle_ = nullptr;
  }
  if (g_active_window_count == 0) {
    WindowClassRegistrar::GetInstance()->UnregisterWindowClass();
  }
}

Win32Window* Win32Window::GetThisFromHandle(HWND const window) noexcept {
  return reinterpret_cast<Win32Window*>(
      GetWindowLongPtr(window, GWLP_USERDATA));
}

void Win32Window::SetChildContent(HWND content) {
  child_content_ = content;
  SetParent(content, window_handle_);
  ResizeChildContent();

  SetFocus(child_content_);
}

RECT Win32Window::GetClientArea() {
  RECT frame;
  GetClientRect(window_handle_, &frame);
  return frame;
}

HWND Win32Window::GetHandle() {
  return window_handle_;
}

void Win32Window::SetQuitOnClose(bool quit_on_close) {
  quit_on_close_ = quit_on_close;
}

void Win32Window::QueueChildContentResize() {
  if (window_handle_ == nullptr || child_content_ == nullptr ||
      child_resize_pending_) {
    return;
  }
  child_resize_pending_ = true;
  if (!PostMessage(window_handle_, kResizeChildContentMessage, 0, 0)) {
    child_resize_pending_ = false;
  }
}

void Win32Window::ResizeChildContent() {
  if (child_content_ == nullptr) {
    return;
  }
  RECT frame = GetClientArea();
  MoveWindow(child_content_, frame.left, frame.top, frame.right - frame.left,
             frame.bottom - frame.top, TRUE);
}

bool Win32Window::OnCreate() {
  // No-op; provided for subclasses.
  return true;
}

void Win32Window::OnDestroy() {
  // No-op; provided for subclasses.
}

void Win32Window::UpdateTheme(HWND const window) {
  DWORD light_mode;
  DWORD light_mode_size = sizeof(light_mode);
  LSTATUS result =
      RegGetValue(HKEY_CURRENT_USER, kGetPreferredBrightnessRegKey,
                  kGetPreferredBrightnessRegValue, RRF_RT_REG_DWORD, nullptr,
                  &light_mode, &light_mode_size);

  if (result == ERROR_SUCCESS) {
    BOOL enable_dark_mode = light_mode == 0;
    DwmSetWindowAttribute(window, DWMWA_USE_IMMERSIVE_DARK_MODE,
                          &enable_dark_mode, sizeof(enable_dark_mode));
  }
}
