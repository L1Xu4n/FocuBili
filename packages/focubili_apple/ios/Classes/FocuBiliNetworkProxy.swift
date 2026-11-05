#if os(iOS)
import Flutter
#else
import FlutterMacOS
#endif
import Foundation
import CFNetwork

/// Read-only, URL-specific system proxy lookup. Dart and media-kit apply the
/// selected app policy; this bridge never changes the device's network settings.
final class FocuBiliNetworkProxy {
    static func attach(messenger: FlutterBinaryMessenger) -> FlutterMethodChannel {
        let channel = FlutterMethodChannel(name: "com.focubili/network_proxy", binaryMessenger: messenger)
        channel.setMethodCallHandler { call, result in
            let args = call.arguments as? [String: Any] ?? [:]
            switch call.method {
            case "configure":
                guard let mode = args["mode"] as? String,
                      ["system", "direct", "manual"].contains(mode) else {
                    result(FlutterError(code: "invalid_proxy", message: "Invalid proxy mode", details: nil))
                    return
                }
                // Playback uses media-kit, not AVPlayer networking. The caller
                // configures its own Dart HTTP clients and mpv HTTP proxy.
                result(nil)
            case "resolve":
                guard let raw = args["url"] as? String,
                      let url = URL(string: raw),
                      ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                      url.host != nil, url.user == nil, url.password == nil else {
                    result(FlutterError(code: "invalid_url", message: "Expected an HTTP(S) URL", details: nil))
                    return
                }
                DispatchQueue.global(qos: .utility).async {
                    let value = resolve(url)
                    DispatchQueue.main.async { result(value) }
                }
            default:
                result(FlutterMethodNotImplemented)
            }
        }
        return channel
    }

    private static func resolve(_ url: URL) -> Any {
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue(),
              let proxies = CFNetworkCopyProxiesForURL(url as CFURL, settings)
                .takeRetainedValue() as? [[String: Any]], !proxies.isEmpty else {
            return FlutterError(code: "system_proxy_failed", message: "Cannot read system proxy settings", details: nil)
        }
        var routes: [String] = []
        for proxy in proxies {
            guard let type = proxy[kCFProxyTypeKey as String] as? String else {
                return unsupported()
            }
            if type == (kCFProxyTypeAutoConfigurationURL as String) ||
                type == (kCFProxyTypeAutoConfigurationJavaScript as String) {
                // Never silently bypass a PAC policy. A future implementation
                // can evaluate PAC with a bounded, cancellable CFNetwork run loop.
                return FlutterError(code: "unsupported_system_proxy", message: "Automatic proxy scripts are not supported; configure an HTTP proxy manually", details: nil)
            }
            if type == (kCFProxyTypeNone as String) {
                routes.append("DIRECT")
                continue
            }
            guard type == (kCFProxyTypeHTTP as String) || type == (kCFProxyTypeHTTPS as String),
                  (proxy[kCFProxyUsernameKey as String] as? String ?? "").isEmpty,
                  (proxy[kCFProxyPasswordKey as String] as? String ?? "").isEmpty,
                  let host = proxy[kCFProxyHostNameKey as String] as? String,
                  !host.isEmpty,
                  host.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
                  host.rangeOfCharacter(from: .controlCharacters) == nil,
                  host.rangeOfCharacter(from: CharacterSet(charactersIn: ";/@\\?#%")) == nil,
                  let number = proxy[kCFProxyPortNumberKey as String] as? NSNumber,
                  (1...65535).contains(number.intValue),
                  number.doubleValue == Double(number.intValue) else {
                return unsupported()
            }
            let formattedHost = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
            routes.append("PROXY \(formattedHost):\(number.intValue)")
        }
        return routes.joined(separator: "; ")
    }

    private static func unsupported() -> FlutterError {
        FlutterError(code: "unsupported_system_proxy", message: "Only HTTP proxies without credentials are supported", details: nil)
    }
}
