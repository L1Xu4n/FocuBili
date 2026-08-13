//
// Created by yangbin on 2021/11/12.
//

#ifndef WEBVIEW_WINDOW_WINDOWS_WEB_VIEW_H_
#define WEBVIEW_WINDOW_WINDOWS_WEB_VIEW_H_

#include <windows.h>

#include <string>
#include <vector>

#include <flutter/method_channel.h>
#include <flutter/encodable_value.h>

#include "wil/resource.h"
#include "wil/com.h"

#include "WebView2.h"

namespace webview_window {

class WebView {

 public:

  WebView(std::shared_ptr<flutter::MethodChannel<flutter::EncodableValue>> method_channel,
          int64_t web_view_id,
          std::wstring userDataFolder,
          std::function<void(HRESULT)> on_web_view_created_callback
  );

  virtual ~WebView();

  [[nodiscard]] const wil::unique_hwnd &NativeWindow() const { return view_window_; }

  void UpdateBounds();

  void Navigate(const std::wstring &url);

  // Registers a document-start script and completes only after WebView2 confirms it.
  void AddScriptToExecuteOnDocumentCreated(
      const std::wstring &javaScript,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> completer);

  void SetApplicationNameForUserAgent(const std::wstring &application_name);

  // Replaces the complete WebView2 user agent before navigation.
  HRESULT SetUserAgent(const std::wstring &user_agent);

  void GoBack();

  void GoForward();

  void Reload();

  void Stop();

  void GetAllCookies(std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> completer);

  // Reads only Cookies that WebView2 would send to the specified URL.
  void GetCookiesForUrl(
      const std::wstring &url,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> completer);

  void openDevToolsWindow();

  void ExecuteJavaScript(const std::wstring &javaScript,
                         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> completer);

  void PostWebMessageAsString(const std::wstring &webmessage,
          std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> completer);

  void PostWebMessageAsJson(const std::wstring &webmessage,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> completer);

  void setTriggerOnUrlRequestedEvent(const bool value);

  // Store exact trusted HTTPS hosts for synchronous WebView2 navigation checks.
  void SetAllowedNavigationHosts(const std::vector<std::wstring> &hosts);

 private:
  wil::unique_hwnd view_window_;

  // Pointer to WebViewController
  wil::com_ptr<ICoreWebView2Controller> webview_controller_;

  // Pointer to WebView
  wil::com_ptr<ICoreWebView2> webview_;

  std::wstring default_user_agent_;

  std::shared_ptr<flutter::MethodChannel<flutter::EncodableValue>> method_channel_;

  int64_t web_view_id_;

  std::function<void(HRESULT)> on_web_view_created_callback_;

  std::wstring user_data_folder_;

  bool triggerOnUrlRequestedEvent{true};

  std::vector<std::wstring> allowed_navigation_hosts_;

  // Reject malformed, non-HTTPS and non-allowlisted top-level navigation URLs.
  [[nodiscard]] bool IsAllowedNavigationUri(const std::wstring &url) const;

  // Finish WebView2 setup and report whether the browser is ready for commands.
  [[nodiscard]] HRESULT OnWebviewControllerCreated();

  // Runs the shared WebView2 Cookie query for either all Cookies or one URL.
  void GetCookies(
      const std::wstring &url,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> completer);

  [[nodiscard]] bool CanGoBack() const;

  [[nodiscard]] bool CanGoForward() const;

};

}

#endif //WEBVIEW_WINDOW_WINDOWS_WEB_VIEW_H_
