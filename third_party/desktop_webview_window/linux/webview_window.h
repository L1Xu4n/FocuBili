//
// Created by boyan on 10/21/21.
//

#ifndef WEBVIEW_WINDOW_LINUX_WEBVIEW_WINDOW_H_
#define WEBVIEW_WINDOW_LINUX_WEBVIEW_WINDOW_H_

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>
#include <libsoup/soup.h>
#include <webkit2/webkit2.h>

#include <functional>
#include <string>
#include <unordered_map>

class WebviewWindow {
 public:
  WebviewWindow(FlMethodChannel *method_channel, int64_t window_id,
                std::function<void()> on_close_callback,
                const std::string &title, int width, int height,
                int title_bar_height);

  virtual ~WebviewWindow();

  void Navigate(const char *url);

  void RunJavaScriptWhenContentReady(const char *java_script);

  void Close();

  void SetApplicationNameForUserAgent(const std::string &app_name);

  void OnLoadChanged(WebKitLoadEvent load_event);

  void GoBack();

  void GoForward();

  void Reload();

  void StopLoading();

  void GetCookies(const char* url, FlMethodCall* call);
  void SetUserAgent(const char* user_agent);
  void OnLoadFailed() { load_failed_ = true; }
  static bool IsAllowedUrl(const char* url);

  gboolean DecidePolicy(WebKitPolicyDecision *decision,
                        WebKitPolicyDecisionType type);

  void EvaluateJavaScript(const char *java_script, FlMethodCall *call);

  void RegisterJavaScriptChannel(const std::string &name);

  void UnregisterJavaScriptChannel(const std::string &name);

 private:
  FlMethodChannel *method_channel_;
  int64_t window_id_;
  std::function<void()> on_close_callback_;

  std::string default_user_agent_;

  bool load_failed_ = false;
  GtkWidget *window_ = nullptr;
  GtkWidget *webview_ = nullptr;
  GtkBox *box_ = nullptr;

  std::unordered_map<std::string, gulong> js_channel_handler_ids_;
};

#endif  // WEBVIEW_WINDOW_LINUX_WEBVIEW_WINDOW_H_
