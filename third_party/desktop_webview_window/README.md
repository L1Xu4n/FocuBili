
### FocuBili Linux restoration

Linux native sources restored from the official desktop_webview_window 0.3.0 pub.dev archive (MIT). The Linux implementation requires WebKitGTK 4.1/libsoup 3. FocuBili patches use ephemeral contexts, asynchronous URL-scoped cookies, Unix cookie expiry/session flags, a fixed HTTPS Bilibili/QQ navigation policy, and close-callback lifetime fixes. TLS errors are never ignored. Upstream files are maintained here with the existing Dart bridge additions; preserve Windows behavior when changing shared Dart APIs.
