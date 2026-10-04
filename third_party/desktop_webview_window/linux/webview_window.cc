//
// Created by boyan on 10/21/21.
//

#include "webview_window.h"
#include <utility>
#include "message_channel_plugin.h"
#include <unordered_map>
#include <string>

#if WEBKIT_MAJOR_VERSION < 2 || \
    (WEBKIT_MAJOR_VERSION == 2 && WEBKIT_MINOR_VERSION < 40)
#define WEBKIT_OLD_USED
#endif

struct WebKitRequest {
  FlMethodCall* call;
  WebviewWindow* window;
  WebKitWebContext* context;
};

static void release_request_later(WebKitRequest* request) {
  g_idle_add_full(G_PRIORITY_DEFAULT_IDLE, [](gpointer data) -> gboolean {
    auto* request = static_cast<WebKitRequest*>(data);
    request->window->AsyncOperationCompleted();
    g_object_unref(request->call);
    g_object_unref(request->context);
    delete request;
    return G_SOURCE_REMOVE;
  }, request, nullptr);
}

namespace {

gboolean on_load_failed_with_tls_errors(WebKitWebView *web_view,
                                        char *failing_uri,
                                        GTlsCertificate *certificate,
                                        GTlsCertificateFlags errors,
                                        gpointer user_data) {
  static_cast<WebviewWindow *>(user_data)->OnLoadFailed();
  // Let WebKit reject the certificate. Never bypass TLS failures.
  return false;
}

GtkWidget *on_create(WebKitWebView *web_view,
                     WebKitNavigationAction *navigation_action,
                     gpointer user_data) {
  return nullptr;  // Never create untracked popup windows.
}

void on_load_changed(WebKitWebView *web_view, WebKitLoadEvent load_event,
                     gpointer user_data) {
  auto *window = static_cast<WebviewWindow *>(user_data);
  window->OnLoadChanged(load_event);
}

gboolean decide_policy_cb(WebKitWebView *web_view,
                          WebKitPolicyDecision *decision,
                          WebKitPolicyDecisionType type, gpointer user_data) {
  auto *window = static_cast<WebviewWindow *>(user_data);
  return window->DecidePolicy(decision, type);
}

}  // namespace

WebviewWindow::WebviewWindow(FlMethodChannel *method_channel, int64_t window_id,
                             std::function<void()> on_close_callback,
                             const std::string &title, int width, int height,
                             int title_bar_height)
    : method_channel_(method_channel),
      window_id_(window_id),
      on_close_callback_(std::move(on_close_callback)),
      default_user_agent_() {
  g_object_ref(method_channel_);

  cookie_cancellable_ = g_cancellable_new();
  window_ = gtk_window_new(GTK_WINDOW_TOPLEVEL);
  g_signal_connect(window_, "delete-event",
      G_CALLBACK(+[](GtkWidget*, GdkEvent*, gpointer data) -> gboolean {
        static_cast<WebviewWindow*>(data)->Close();
        return TRUE;
      }), this);
  g_signal_connect(G_OBJECT(window_), "destroy",
                   G_CALLBACK(+[](GtkWidget *, gpointer arg) {
                     auto *window = static_cast<WebviewWindow *>(arg);
                     // The owner erases this C++ object. Emit first, then invoke
                     // a copied callback and never access window afterwards.
                     auto callback = window->on_close_callback_;
                     g_autoptr(FlValue) args = fl_value_new_map();
                     fl_value_set_string_take(args, "id", fl_value_new_int(window->window_id_));
                     fl_method_channel_invoke_method(window->method_channel_,
                         "onWindowClose", args, nullptr, nullptr, nullptr);
                     if (callback) callback();
                   }),
                   this);
  gtk_window_set_title(GTK_WINDOW(window_), title.c_str());
  gtk_window_set_default_size(GTK_WINDOW(window_), width, height);
  gtk_window_set_position(GTK_WINDOW(window_), GTK_WIN_POS_CENTER);

  box_ = GTK_BOX(gtk_box_new(GTK_ORIENTATION_VERTICAL, 0));
  gtk_container_add(GTK_CONTAINER(window_), GTK_WIDGET(box_));

  // Use GTK chrome instead of a second Flutter engine. WebKit and the main
  // media texture must not compete with a title-bar engine for a GL context.
  GtkWidget* header = gtk_header_bar_new();
  gtk_header_bar_set_title(GTK_HEADER_BAR(header), title.c_str());
  gtk_header_bar_set_show_close_button(GTK_HEADER_BAR(header), TRUE);
  gtk_window_set_titlebar(GTK_WINDOW(window_), header);
  auto add_button = [this, header](const char* icon, const char* tooltip, GCallback callback) {
    GtkWidget* button = gtk_button_new_from_icon_name(icon, GTK_ICON_SIZE_BUTTON);
    gtk_widget_set_tooltip_text(button, tooltip);
    g_signal_connect(button, "clicked", callback, this);
    gtk_header_bar_pack_start(GTK_HEADER_BAR(header), button);
  };
  add_button("go-previous-symbolic", "返回", G_CALLBACK(+[](GtkButton*, gpointer data) {
    static_cast<WebviewWindow*>(data)->GoBack();
  }));
  add_button("go-next-symbolic", "前进", G_CALLBACK(+[](GtkButton*, gpointer data) {
    static_cast<WebviewWindow*>(data)->GoForward();
  }));
  add_button("view-refresh-symbolic", "重新加载", G_CALLBACK(+[](GtkButton*, gpointer data) {
    static_cast<WebviewWindow*>(data)->Reload();
  }));

  // initial web_view
  g_autoptr(WebKitWebContext) context = webkit_web_context_new_ephemeral();
  webview_ = webkit_web_view_new_with_context(context);
  g_object_ref_sink(webview_);
  g_signal_connect(webview_, "load-failed",
      G_CALLBACK(+[](WebKitWebView*, WebKitLoadEvent, gchar*, GError*, gpointer data) -> gboolean {
        static_cast<WebviewWindow*>(data)->OnLoadFailed();
        return FALSE;
      }), this);
  g_signal_connect(G_OBJECT(webview_), "load-failed-with-tls-errors",
                   G_CALLBACK(on_load_failed_with_tls_errors), this);
  g_signal_connect(G_OBJECT(webview_), "create", G_CALLBACK(on_create), this);
  g_signal_connect(G_OBJECT(webview_), "load-changed",
                   G_CALLBACK(on_load_changed), this);
  g_signal_connect(G_OBJECT(webview_), "decide-policy",
                   G_CALLBACK(decide_policy_cb), this);

  auto settings = webkit_web_view_get_settings(WEBKIT_WEB_VIEW(webview_));
  webkit_settings_set_javascript_can_open_windows_automatically(settings, true);
  default_user_agent_ = webkit_settings_get_user_agent(settings);
  gtk_box_pack_end(box_, webview_, true, true, 0);

  gtk_widget_show_all(GTK_WIDGET(window_));
  gtk_widget_grab_focus(GTK_WIDGET(webview_));


}

WebviewWindow::~WebviewWindow() {
  if (webview_ != nullptr) {
    WebKitUserContentManager *manager = webkit_web_view_get_user_content_manager(WEBKIT_WEB_VIEW(webview_));
    for (auto &entry : js_channel_handler_ids_) {
      g_signal_handler_disconnect(manager, entry.second);
    }
    js_channel_handler_ids_.clear();
  }
  if (webview_ != nullptr) {
    g_signal_handlers_disconnect_by_data(webview_, this);
    g_object_unref(webview_);
  }
  g_clear_object(&cookie_cancellable_);
  g_object_unref(method_channel_);
}

void WebviewWindow::Navigate(const char *url) {
  if (closing_) return;
  if (IsAllowedUrl(url)) webkit_web_view_load_uri(WEBKIT_WEB_VIEW(webview_), url);
}

void WebviewWindow::RunJavaScriptWhenContentReady(const char *java_script) {
  if (closing_) return;
  auto *manager =
      webkit_web_view_get_user_content_manager(WEBKIT_WEB_VIEW(webview_));
  WebKitUserScript* script = webkit_user_script_new(java_script,
      WEBKIT_USER_CONTENT_INJECT_TOP_FRAME, WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START,
      nullptr, nullptr);
  webkit_user_content_manager_add_script(manager, script);
  webkit_user_script_unref(script);
}

void WebviewWindow::SetApplicationNameForUserAgent(
    const std::string &app_name) {
  if (closing_) return;
  auto *setting = webkit_web_view_get_settings(WEBKIT_WEB_VIEW(webview_));
  webkit_settings_set_user_agent(setting,
                                 (default_user_agent_ + app_name).c_str());
}

void WebviewWindow::Close() {
  if (destroying_) return;
  closing_ = true;
  webkit_web_view_stop_loading(WEBKIT_WEB_VIEW(webview_));
  gtk_widget_hide(window_);
  if (pending_operations_ > 0) {
    // WebKit's cookie GTask can outlive its owning ephemeral context. Keep the
    // widget/context alive until every completion callback has fully unwound.
    g_cancellable_cancel(cookie_cancellable_);
    return;
  }
  destroying_ = true;
  gtk_widget_destroy(window_);
}

void WebviewWindow::AsyncOperationCompleted() {
  --pending_operations_;
  if (closing_ && pending_operations_ == 0) Close();
}

void WebviewWindow::OnLoadChanged(WebKitLoadEvent load_event) {
  if (closing_) return;
  // notify history changed event.
  {
    auto can_go_back = webkit_web_view_can_go_back(WEBKIT_WEB_VIEW(webview_));
    auto can_go_forward =
        webkit_web_view_can_go_forward(WEBKIT_WEB_VIEW(webview_));
    g_autoptr(FlValue) args = fl_value_new_map();
    fl_value_set_take(args, fl_value_new_string("id"), fl_value_new_int(window_id_));
    fl_value_set_take(args, fl_value_new_string("canGoBack"),
                 fl_value_new_bool(can_go_back));
    fl_value_set_take(args, fl_value_new_string("canGoForward"),
                 fl_value_new_bool(can_go_forward));
    fl_method_channel_invoke_method(FL_METHOD_CHANNEL(method_channel_),
                                    "onHistoryChanged", args, nullptr, nullptr,
                                    nullptr);
  }

  // notify load start/finished event.
  switch (load_event) {
    case WEBKIT_LOAD_STARTED: {
      load_failed_ = false;
      g_autoptr(FlValue) args = fl_value_new_map();
      fl_value_set_take(args, fl_value_new_string("id"),
                   fl_value_new_int(window_id_));
      fl_method_channel_invoke_method(FL_METHOD_CHANNEL(method_channel_),
                                      "onNavigationStarted", args, nullptr,
                                      nullptr, nullptr);
      break;
    }
    case WEBKIT_LOAD_FINISHED: {
      g_autoptr(FlValue) args = fl_value_new_map();
      fl_value_set_take(args, fl_value_new_string("id"),
                   fl_value_new_int(window_id_));
      const char* uri = webkit_web_view_get_uri(WEBKIT_WEB_VIEW(webview_));
      fl_value_set_string_take(args, "url", fl_value_new_string(uri ? uri : ""));
      fl_value_set_string_take(args, "isSuccess", fl_value_new_bool(!load_failed_));
      fl_method_channel_invoke_method(FL_METHOD_CHANNEL(method_channel_),
                                      "onNavigationCompleted", args, nullptr,
                                      nullptr, nullptr);
      break;
    }
    default:
      break;
  }
}

void WebviewWindow::GoForward() {
  if (closing_) return;
  webkit_web_view_go_forward(WEBKIT_WEB_VIEW(webview_));
}

void WebviewWindow::GoBack() {
  if (closing_) return;
  webkit_web_view_go_back(WEBKIT_WEB_VIEW(webview_));
}

void WebviewWindow::Reload() {
  if (closing_) return;
  webkit_web_view_reload(WEBKIT_WEB_VIEW(webview_));
}

void WebviewWindow::StopLoading() {
  webkit_web_view_stop_loading(WEBKIT_WEB_VIEW(webview_));
}

bool WebviewWindow::IsAllowedUrl(const char* url) {
  if (!url) return false;
  g_autoptr(GUri) uri = g_uri_parse(url, G_URI_FLAGS_NONE, nullptr);
  if (!uri || g_strcmp0(g_uri_get_scheme(uri), "https") != 0 ||
      g_uri_get_userinfo(uri) != nullptr) return false;
  const char* raw_host = g_uri_get_host(uri);
  if (!raw_host) return false;
  g_autofree gchar* host = g_ascii_strdown(raw_host, -1);
  return g_strcmp0(host, "bilibili.com") == 0 ||
      g_str_has_suffix(host, ".bilibili.com") ||
      g_strcmp0(host, "graph.qq.com") == 0 ||
      g_strcmp0(host, "xui.ptlogin2.qq.com") == 0;
}

void WebviewWindow::SetUserAgent(const char* user_agent) {
  if (closing_) return;
  webkit_settings_set_user_agent(
      webkit_web_view_get_settings(WEBKIT_WEB_VIEW(webview_)), user_agent);
}

void WebviewWindow::GetCookies(const char* url, FlMethodCall* call) {
  if (closing_) {
    fl_method_call_respond_error(call, "closed", "WebView is closing", nullptr, nullptr);
    return;
  }
  const char* target = url ? url : webkit_web_view_get_uri(WEBKIT_WEB_VIEW(webview_));
  if (!IsAllowedUrl(target)) {
    fl_method_call_respond_error(call, "invalid_url", "Cookie URL is not allowed", nullptr, nullptr);
    return;
  }
  auto* manager = webkit_web_context_get_cookie_manager(
      webkit_web_view_get_context(WEBKIT_WEB_VIEW(webview_)));
  ++pending_operations_;
  auto* request = new WebKitRequest{
      FL_METHOD_CALL(g_object_ref(call)), this,
      WEBKIT_WEB_CONTEXT(g_object_ref(webkit_web_view_get_context(WEBKIT_WEB_VIEW(webview_))))};
  webkit_cookie_manager_get_cookies(manager, target, cookie_cancellable_,
      [](GObject* object, GAsyncResult* result, gpointer data) {
        auto* request = static_cast<WebKitRequest*>(data);
        auto* call = request->call;
        g_autoptr(GError) error = nullptr;
        GList* cookies = webkit_cookie_manager_get_cookies_finish(
            WEBKIT_COOKIE_MANAGER(object), result, &error);
        if (error) {
          fl_method_call_respond_error(call, "cookie_read_failed", "Unable to read browser session", nullptr, nullptr);
        } else {
          g_autoptr(FlValue) values = fl_value_new_list();
          for (GList* item = cookies; item; item = item->next) {
            auto* cookie = static_cast<SoupCookie*>(item->data);
            g_autoptr(FlValue) value = fl_value_new_map();
            fl_value_set_string_take(value, "name", fl_value_new_string(soup_cookie_get_name(cookie)));
            fl_value_set_string_take(value, "value", fl_value_new_string(soup_cookie_get_value(cookie)));
            fl_value_set_string_take(value, "domain", fl_value_new_string(soup_cookie_get_domain(cookie)));
            fl_value_set_string_take(value, "path", fl_value_new_string(soup_cookie_get_path(cookie)));
            GDateTime* expires = soup_cookie_get_expires(cookie);
            fl_value_set_string_take(value, "expires", expires
                ? fl_value_new_float(static_cast<double>(g_date_time_to_unix(expires))) : fl_value_new_null());
            fl_value_set_string_take(value, "sessionOnly", fl_value_new_bool(expires == nullptr));
            fl_value_set_string_take(value, "httpOnly", fl_value_new_bool(soup_cookie_get_http_only(cookie)));
            fl_value_set_string_take(value, "secure", fl_value_new_bool(soup_cookie_get_secure(cookie)));
            fl_value_append(values, value);
          }
          fl_method_call_respond_success(call, values, nullptr);
        }
        g_list_free_full(cookies, reinterpret_cast<GDestroyNotify>(soup_cookie_free));
        // The next main-loop turn is after WebKit has released its GTask and
        // cookie-manager references. Only then may Close destroy the context.
        release_request_later(request);
      }, request);
}

gboolean WebviewWindow::DecidePolicy(WebKitPolicyDecision* decision,
                                    WebKitPolicyDecisionType type) {
  if (closing_) {
    webkit_policy_decision_ignore(decision);
    return TRUE;
  }
  if (type == WEBKIT_POLICY_DECISION_TYPE_NAVIGATION_ACTION ||
      type == WEBKIT_POLICY_DECISION_TYPE_NEW_WINDOW_ACTION) {
    auto* action = webkit_navigation_policy_decision_get_navigation_action(
        WEBKIT_NAVIGATION_POLICY_DECISION(decision));
    const char* uri = webkit_uri_request_get_uri(webkit_navigation_action_get_request(action));
    if (!IsAllowedUrl(uri) || type == WEBKIT_POLICY_DECISION_TYPE_NEW_WINDOW_ACTION) {
      webkit_policy_decision_ignore(decision);
      return TRUE;
    }
  }
  // WebKit continues the original request, preserving POST bodies and redirects.
  return FALSE;
}

void WebviewWindow::EvaluateJavaScript(const char *java_script,
                                       FlMethodCall *call) {
  if (closing_) {
    fl_method_call_respond_error(call, "closed", "WebView is closing", nullptr, nullptr);
    return;
  }
  ++pending_operations_;
  auto* request = new WebKitRequest{
      FL_METHOD_CALL(g_object_ref(call)), this,
      WEBKIT_WEB_CONTEXT(g_object_ref(webkit_web_view_get_context(WEBKIT_WEB_VIEW(webview_))))};
#ifdef WEBKIT_OLD_USED
  webkit_web_view_run_javascript(
#else
  webkit_web_view_evaluate_javascript(
#endif
      WEBKIT_WEB_VIEW(webview_), java_script,
#ifndef WEBKIT_OLD_USED
      -1, nullptr, nullptr,
#endif
      cookie_cancellable_,
      [](GObject *object, GAsyncResult *result, gpointer user_data) {
        auto* request = static_cast<WebKitRequest*>(user_data);
        auto* call = request->call;
        GError *error = nullptr;
        auto *js_result =
#ifdef WEBKIT_OLD_USED
            webkit_web_view_run_javascript_finish(
#else
            webkit_web_view_evaluate_javascript_finish(
#endif
                WEBKIT_WEB_VIEW(object), result, &error);
        if (!js_result) {
          fl_method_call_respond_error(call, "failed to evaluate javascript.",
                                       "JavaScript evaluation failed", nullptr, nullptr);
          if (error) g_error_free(error);
        } else {
          auto *js_value = jsc_value_to_json(
#ifdef WEBKIT_OLD_USED
              webkit_javascript_result_get_js_value
#endif
              (js_result),
              0);
          fl_method_call_respond_success(
              call, js_value ? fl_value_new_string(js_value) : nullptr,
              nullptr);
          g_free(js_value);
#ifdef WEBKIT_OLD_USED
          webkit_javascript_result_unref(js_result);
#else
          g_object_unref(js_result);
#endif
        }
        release_request_later(request);
      },
      request);
}

void WebviewWindow::RegisterJavaScriptChannel(const std::string &name) {
    WebKitUserContentManager *manager =
            webkit_web_view_get_user_content_manager(WEBKIT_WEB_VIEW(webview_));

    webkit_user_content_manager_register_script_message_handler(
            manager, name.c_str());

    struct HandlerData {
        WebviewWindow *self;
        std::string name;
    };

    HandlerData *data = new HandlerData{this, name};
    auto it = js_channel_handler_ids_.find(name);
    if (it != js_channel_handler_ids_.end()) {
        g_signal_handler_disconnect(manager, it->second);
        js_channel_handler_ids_.erase(it);
    }

    gulong handler_id = g_signal_connect_data(
            manager,
            ("script-message-received::" + name).c_str(),
            G_CALLBACK(+[](WebKitUserContentManager *manager,
                           WebKitJavascriptResult *result,
                           gpointer user_data) {
                HandlerData *data = static_cast<HandlerData *>(user_data);
                WebviewWindow *self = data->self;
                const std::string &handler_name = data->name;

                JSCValue *value = webkit_javascript_result_get_js_value(result);

                if (jsc_value_is_string(value)) {
                    gchar *str_value = jsc_value_to_string(value);
                    if (str_value != nullptr) {
                        FlValue *args = fl_value_new_map();
                        fl_value_set_string(args, "name",
                                            fl_value_new_string(handler_name.c_str()));
                        fl_value_set_string(args, "body",
                                            fl_value_new_string(str_value));
                        fl_value_set_string(args, "id",
                                            fl_value_new_int(self->window_id_));

                        fl_method_channel_invoke_method(
                                self->method_channel_,
                                "onJavaScriptMessage",
                                args,
                                nullptr,
                                nullptr,
                                nullptr);

                        g_free(str_value);
                    }
                }
            }),
            data,
            +[](gpointer user_data, GClosure *) {
                delete static_cast<HandlerData *>(user_data);
            },
            static_cast<GConnectFlags>(0));

    js_channel_handler_ids_[name] = handler_id;
}


void WebviewWindow::UnregisterJavaScriptChannel(const std::string &name) {
    WebKitUserContentManager *manager =
            webkit_web_view_get_user_content_manager(WEBKIT_WEB_VIEW(webview_));

    auto it = js_channel_handler_ids_.find(name);
    if (it != js_channel_handler_ids_.end()) {
        g_signal_handler_disconnect(manager, it->second);
        js_channel_handler_ids_.erase(it);
    }

    webkit_user_content_manager_unregister_script_message_handler(
            manager, name.c_str());
}
