#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <memory>

#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // Handles 'loop/hotkeys' method calls (register/unregister/retry).
  void HandleHotkeyMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  // Registers Alt+Q / Alt+A (idempotent: unregisters first). On failure the
  // corresponding error code is stored (1409 = conflict).
  void RegisterHotkeys(int* toggle_error, int* screenshot_error);

  // Releases both hotkeys (safe to call when not registered).
  void UnregisterHotkeys();

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // Native global hotkeys -> Dart ('hotkey' method, id 1/2).
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      hotkey_channel_;
  bool toggle_hotkey_registered_ = false;
  bool screenshot_hotkey_registered_ = false;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
