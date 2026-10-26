#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <cstring>
#include <cwchar>

#include "flutter_window.h"
#include "utils.h"

namespace {

constexpr wchar_t kLoopWindowClass[] = L"FLUTTER_RUNNER_WIN32_WINDOW";
constexpr wchar_t kLoopMutexName[] = L"Local\\LoopDesktopApp.SingleInstance";

bool IsLoopProcess(DWORD process_id) {
  HANDLE process = ::OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE,
                                 process_id);
  if (!process) {
    return false;
  }
  wchar_t path[MAX_PATH] = {};
  DWORD size = MAX_PATH;
  const BOOL ok = ::QueryFullProcessImageNameW(process, 0, path, &size);
  ::CloseHandle(process);
  if (!ok) {
    return false;
  }
  const wchar_t* name = std::wcsrchr(path, L'\\');
  name = name ? name + 1 : path;
  return _wcsicmp(name, L"Loop.exe") == 0;
}

BOOL CALLBACK FindLoopWindowProc(HWND hwnd, LPARAM lparam) {
  wchar_t class_name[128] = {};
  if (::GetClassNameW(hwnd, class_name, 128) == 0 ||
      _wcsicmp(class_name, kLoopWindowClass) != 0) {
    return TRUE;
  }
  DWORD process_id = 0;
  ::GetWindowThreadProcessId(hwnd, &process_id);
  if (!IsLoopProcess(process_id)) {
    return TRUE;
  }
  *reinterpret_cast<HWND*>(lparam) = hwnd;
  return FALSE;
}

HWND FindExistingLoopWindow() {
  HWND hwnd = nullptr;
  ::EnumWindows(FindLoopWindowProc, reinterpret_cast<LPARAM>(&hwnd));
  return hwnd;
}

void ActivateExistingLoop() {
  // The mutex may exist a few milliseconds before the first instance creates
  // its window; wait briefly instead of silently losing the second launch.
  HWND hwnd = nullptr;
  for (int attempt = 0; attempt < 30 && hwnd == nullptr; ++attempt) {
    hwnd = FindExistingLoopWindow();
    if (hwnd == nullptr) {
      ::Sleep(100);
    }
  }
  if (hwnd == nullptr) {
    return;
  }
  if (::IsIconic(hwnd)) {
    ::ShowWindow(hwnd, SW_RESTORE);
  } else {
    ::ShowWindow(hwnd, SW_SHOW);
  }
  ::SetWindowPos(hwnd, HWND_TOP, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW);
  // Raise the existing window even when the launcher keeps the foreground.
  ::SetWindowPos(hwnd, HWND_TOPMOST, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW);
  ::SetWindowPos(hwnd, HWND_NOTOPMOST, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW);

  // Ask the already-running instance to activate itself; this works even when
  // the launcher keeps the foreground lock.
  DWORD existing_pid = 0;
  ::GetWindowThreadProcessId(hwnd, &existing_pid);
  if (existing_pid != 0) {
    ::AllowSetForegroundWindow(existing_pid);
    ::PostMessage(hwnd, Win32Window::kLoopActivateMessage, 0, 0);
    ::Sleep(120);
  }

  // Newly started launchers may not own the foreground lock. Attach to the
  // foreground thread briefly, then fall back to SwitchToThisWindow.
  if (!::SetForegroundWindow(hwnd)) {
    const HWND foreground = ::GetForegroundWindow();
    DWORD foreground_thread = 0;
    if (foreground != nullptr) {
      foreground_thread = ::GetWindowThreadProcessId(foreground, nullptr);
    }
    const DWORD current_thread = ::GetCurrentThreadId();
    if (foreground_thread != 0 && foreground_thread != current_thread) {
      ::AttachThreadInput(current_thread, foreground_thread, TRUE);
      ::SetForegroundWindow(hwnd);
      ::AttachThreadInput(current_thread, foreground_thread, FALSE);
    }
    if (!::SetForegroundWindow(hwnd)) {
      ::SwitchToThisWindow(hwnd, TRUE);
    }
    if (!::SetForegroundWindow(hwnd)) {
      FLASHWINFO flash{};
      flash.cbSize = sizeof(flash);
      flash.hwnd = hwnd;
      flash.dwFlags = FLASHW_ALL;
      flash.uCount = 3;
      ::FlashWindowEx(&flash);
    }
  }
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Single-instance guard: the second launch focuses the existing window
  // instead of starting another database/backend process.
  ::SetLastError(ERROR_SUCCESS);
  HANDLE instance_mutex =
      ::CreateMutexW(nullptr, FALSE, kLoopMutexName);
  const bool already_running =
      instance_mutex != nullptr && ::GetLastError() == ERROR_ALREADY_EXISTS;
  if (already_running) {
    ActivateExistingLoop();
    ::CloseHandle(instance_mutex);
    return EXIT_SUCCESS;
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1440, 900);
  if (!window.Create(L"\u56DE\u8DEF Loop", origin, size)) {
    if (instance_mutex != nullptr) {
      ::CloseHandle(instance_mutex);
    }
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  if (instance_mutex != nullptr) {
    ::CloseHandle(instance_mutex);
  }
  return EXIT_SUCCESS;
}
