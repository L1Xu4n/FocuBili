#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
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
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // 向 Flutter 提供 Windows 笔记本电量查询，窗口销毁时随引擎一并释放。
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      device_status_channel_;

  // 让 Flutter 专注控制器在 Windows 11 开启勿扰，并在结束时恢复进入前状态。
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      do_not_disturb_channel_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
