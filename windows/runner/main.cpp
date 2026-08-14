#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter_windows.h>
#include <shellapi.h>
#include <windows.h>

#include <algorithm>

#include "flutter_window.h"
#include "utils.h"

namespace {

// 根据主显示器工作区和 DPI 计算逻辑坐标，让首次窗口完整居中且不压住任务栏。
Win32Window::Point CalculateCenteredOrigin(const Win32Window::Size& size) {
  const POINT primary_point = {0, 0};
  HMONITOR monitor =
      ::MonitorFromPoint(primary_point, MONITOR_DEFAULTTOPRIMARY);
  MONITORINFO monitor_info{};
  monitor_info.cbSize = sizeof(monitor_info);
  if (!::GetMonitorInfo(monitor, &monitor_info)) {
    return Win32Window::Point(10, 10);
  }

  const UINT dpi = FlutterDesktopGetDpiForMonitor(monitor);
  const double scale_factor = dpi > 0 ? dpi / 96.0 : 1.0;
  const LONG scaled_width =
      static_cast<LONG>(size.width * scale_factor);
  const LONG scaled_height =
      static_cast<LONG>(size.height * scale_factor);
  const RECT work_area = monitor_info.rcWork;
  const LONG physical_x =
      work_area.left + (work_area.right - work_area.left - scaled_width) / 2;
  const LONG physical_y =
      work_area.top + (work_area.bottom - work_area.top - scaled_height) / 2;

  const auto logical_x = static_cast<unsigned int>(std::max<LONG>(
      0, static_cast<LONG>(physical_x / scale_factor)));
  const auto logical_y = static_cast<unsigned int>(std::max<LONG>(
      0, static_cast<LONG>(physical_y / scale_factor)));
  return Win32Window::Point(logical_x, logical_y);
}

// 判断当前进程是否由桌面 WebView 插件创建，仅此子进程可绕过主应用单实例锁。
bool IsWebViewTitleBarProcess() {
  int argument_count = 0;
  LPWSTR* arguments =
      ::CommandLineToArgvW(::GetCommandLineW(), &argument_count);
  if (arguments == nullptr) {
    return false;
  }
  const bool is_title_bar =
      argument_count > 1 &&
      std::wstring(arguments[1]) == L"web_view_title_bar";
  ::LocalFree(arguments);
  return is_title_bar;
}

}  // namespace

// 激活已经运行的焦点哔哩窗口，避免用户重复启动多个播放器和计时器实例。
void FocusExistingWindow() {
  HWND existing_window =
      ::FindWindow(L"FLUTTER_RUNNER_WIN32_WINDOW", L"焦点哔哩");
  if (existing_window == nullptr) {
    return;
  }
  if (::IsIconic(existing_window)) {
    ::ShowWindow(existing_window, SW_RESTORE);
  }
  ::SetForegroundWindow(existing_window);
}

// 创建进程级唯一互斥锁并启动 Flutter Windows 主消息循环。
int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  const bool is_webview_title_bar = IsWebViewTitleBarProcess();
  HANDLE single_instance_mutex = nullptr;
  if (!is_webview_title_bar) {
    single_instance_mutex =
        ::CreateMutex(nullptr, TRUE, L"Local\\FocuBili.SingleInstance");
    if (single_instance_mutex == nullptr) {
      return EXIT_FAILURE;
    }
    if (::GetLastError() == ERROR_ALREADY_EXISTS) {
      FocusExistingWindow();
      ::CloseHandle(single_instance_mutex);
      return EXIT_SUCCESS;
    }
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
  Win32Window::Size size(1280, 800);
  Win32Window::Point origin = CalculateCenteredOrigin(size);
  if (!window.Create(L"焦点哔哩", origin, size)) {
    if (single_instance_mutex != nullptr) {
      ::CloseHandle(single_instance_mutex);
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
  if (single_instance_mutex != nullptr) {
    ::ReleaseMutex(single_instance_mutex);
    ::CloseHandle(single_instance_mutex);
  }
  return EXIT_SUCCESS;
}
