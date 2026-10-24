#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"

namespace {

// Alt+Q / Alt+A: ids must not collide with other RegisterHotKey users in this
// process (0x0000-0xBFFF); 0x4C51/0x4C52 are reserved for Loop.
constexpr int kHotkeyToggleId = 0x4C51;
constexpr int kHotkeyScreenshotId = 0x4C52;
constexpr UINT kHotkeyToggleVirtualKey = 'Q';
constexpr UINT kHotkeyScreenshotVirtualKey = 'A';
constexpr UINT kHotkeyModifiers = MOD_ALT | MOD_NOREPEAT;

// Channel protocol ids sent back to Dart.
constexpr int kHotkeyToggleChannelId = 1;
constexpr int kHotkeyScreenshotChannelId = 2;

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  hotkey_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "loop/hotkeys",
          &flutter::StandardMethodCodec::GetInstance());
  hotkey_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        HandleHotkeyMethodCall(call, std::move(result));
      });

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  UnregisterHotkeys();
  hotkey_channel_.reset();

  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
    case WM_HOTKEY: {
      const int id = static_cast<int>(wparam);
      int channel_id = 0;
      if (id == kHotkeyToggleId) {
        channel_id = kHotkeyToggleChannelId;
      } else if (id == kHotkeyScreenshotId) {
        channel_id = kHotkeyScreenshotChannelId;
      }
      if (channel_id != 0) {
        if (hotkey_channel_) {
          hotkey_channel_->InvokeMethod(
              "hotkey",
              std::make_unique<flutter::EncodableValue>(channel_id));
        }
        return 0;
      }
      break;
    }
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

void FlutterWindow::HandleHotkeyMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& method = call.method_name();
  if (method == "register" || method == "retry") {
    int toggle_error = 0;
    int screenshot_error = 0;
    RegisterHotkeys(&toggle_error, &screenshot_error);

    flutter::EncodableMap errors;
    errors[flutter::EncodableValue("toggle")] =
        toggle_hotkey_registered_ ? flutter::EncodableValue()
                                  : flutter::EncodableValue(toggle_error);
    errors[flutter::EncodableValue("screenshot")] =
        screenshot_hotkey_registered_
            ? flutter::EncodableValue()
            : flutter::EncodableValue(screenshot_error);

    flutter::EncodableMap response;
    response[flutter::EncodableValue("toggle")] =
        flutter::EncodableValue(toggle_hotkey_registered_);
    response[flutter::EncodableValue("screenshot")] =
        flutter::EncodableValue(screenshot_hotkey_registered_);
    response[flutter::EncodableValue("errors")] =
        flutter::EncodableValue(errors);
    result->Success(flutter::EncodableValue(response));
    return;
  }
  if (method == "unregister") {
    UnregisterHotkeys();
    result->Success(flutter::EncodableValue(true));
    return;
  }
  result->NotImplemented();
}

void FlutterWindow::RegisterHotkeys(int* toggle_error,
                                    int* screenshot_error) {
  UnregisterHotkeys();
  HWND hwnd = GetHandle();
  if (hwnd == nullptr) {
    *toggle_error = ERROR_INVALID_WINDOW_HANDLE;
    *screenshot_error = ERROR_INVALID_WINDOW_HANDLE;
    return;
  }

  SetLastError(0);
  toggle_hotkey_registered_ =
      RegisterHotKey(hwnd, kHotkeyToggleId, kHotkeyModifiers,
                     kHotkeyToggleVirtualKey) != FALSE;
  *toggle_error =
      toggle_hotkey_registered_ ? 0 : static_cast<int>(GetLastError());

  SetLastError(0);
  screenshot_hotkey_registered_ =
      RegisterHotKey(hwnd, kHotkeyScreenshotId, kHotkeyModifiers,
                     kHotkeyScreenshotVirtualKey) != FALSE;
  *screenshot_error =
      screenshot_hotkey_registered_ ? 0 : static_cast<int>(GetLastError());
}

void FlutterWindow::UnregisterHotkeys() {
  HWND hwnd = GetHandle();
  if (hwnd != nullptr) {
    if (toggle_hotkey_registered_) {
      UnregisterHotKey(hwnd, kHotkeyToggleId);
    }
    if (screenshot_hotkey_registered_) {
      UnregisterHotKey(hwnd, kHotkeyScreenshotId);
    }
  }
  toggle_hotkey_registered_ = false;
  screenshot_hotkey_registered_ = false;
}
