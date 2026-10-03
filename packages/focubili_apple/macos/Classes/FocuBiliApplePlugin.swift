#if os(iOS)
import Flutter
import UIKit
#else
import FlutterMacOS
import AppKit
import OpenGL.GL
import OpenGL.GL3
#endif
import WebKit
import UserNotifications
import AVFoundation
import MediaPlayer
import Network

/// Only app-owned data is exposed; no device identifiers or credentials are logged.
public class FocuBiliApplePlugin: NSObject, FlutterPlugin, UNUserNotificationCenterDelegate {
    private var channels: [FlutterMethodChannel] = []
    private var mediaChannel: FlutterMethodChannel?
    private var pictureInPicture: FocuBiliAppleVideoWindow?
    private var initialLink: String?
    private var networkType = "other"
    private let monitor = NWPathMonitor()
    private var commands: [(MPRemoteCommand, Any)] = []
    private var observers: [NSObjectProtocol] = []

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = FocuBiliApplePlugin()
        #if os(iOS)
        let messenger = registrar.messenger()
        registrar.addApplicationDelegate(instance)
        #else
        let messenger = registrar.messenger
        #endif
        for name in ["auth", "focus_notifications", "device_status", "apple_media"] {
            let channel = FlutterMethodChannel(name: "com.focubili.app/" + name, binaryMessenger: messenger)
            channel.setMethodCallHandler { call, result in instance.handle(name, call, result) }
            instance.channels.append(channel)
            if name == "apple_media" { instance.mediaChannel = channel }
        }
        let deep = FlutterMethodChannel(name: "focubili/deep_links", binaryMessenger: messenger)
        deep.setMethodCallHandler { call, result in
            if call.method == "getInitialLink" {
                result(instance.initialLink); instance.initialLink = nil
            } else { result(FlutterMethodNotImplemented) }
        }
        instance.channels.append(deep)
        instance.monitor.pathUpdateHandler = { [weak instance] path in
            let value = path.status != .satisfied ? "offline" : path.usesInterfaceType(.wifi) ? "wifi" : path.usesInterfaceType(.cellular) ? "mobile" : path.usesInterfaceType(.wiredEthernet) ? "ethernet" : "other"
            DispatchQueue.main.async { instance?.networkType = value }
        }
        instance.monitor.start(queue: DispatchQueue(label: "focubili.network"))
        UNUserNotificationCenter.current().delegate = instance
        instance.installRemoteCommands()
    }

    private func complete(_ result: @escaping FlutterResult, _ value: Any?) {
        DispatchQueue.main.async { result(value) }
    }

    private func handle(_ name: String, _ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        switch name {
        case "auth": auth(call, result)
        case "focus_notifications": notifications(call, result)
        case "apple_media": media(call, result)
        case "device_status":
            switch call.method {
            case "getNetworkType": result(networkType)
            case "getBatteryPercent":
                #if os(iOS)
                UIDevice.current.isBatteryMonitoringEnabled = true
                let level = UIDevice.current.batteryLevel
                result(level < 0 ? nil : Int(level * 100))
                #else
                result(nil)
                #endif
            case "getWebViewInfo": result(["providerAvailable": true, "packageName": "Apple WKWebView", "manufacturer": "Apple", "version": ProcessInfo.processInfo.operatingSystemVersionString])
            default: result(FlutterMethodNotImplemented)
            }
        default: result(FlutterMethodNotImplemented)
        }
    }

    private func isBilibili(_ cookie: HTTPCookie) -> Bool {
        let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return domain == "bilibili.com" || domain.hasSuffix(".bilibili.com")
    }

    private func auth(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        let store = WKWebsiteDataStore.default().httpCookieStore
        guard ["readCookies", "replaceCookies", "clearBilibiliCookies"].contains(call.method) else { result(FlutterMethodNotImplemented); return }
        let header = (call.arguments as? [String: Any])?["cookie"] as? String ?? ""
        if call.method == "replaceCookies" && (header.isEmpty || header.contains("\n") || header.contains("\r")) {
            result(FlutterError(code: "invalid_cookie", message: "Cookie 格式无效", details: nil)); return
        }
        store.getAllCookies { cookies in
            let owned = cookies.filter { self.isBilibili($0) }
            if call.method == "readCookies" {
                // Prefer the root-domain cookie when same-name subdomain cookies exist.
                var values: [String: String] = [:]
                for cookie in owned.sorted(by: { $0.domain.count > $1.domain.count }) {
                    values[cookie.name] = cookie.value
                }
                self.complete(result, values.keys.sorted().map { "\($0)=\(values[$0]!)" }.joined(separator: "; ")); return
            }
            let group = DispatchGroup()
            for cookie in owned { group.enter(); store.delete(cookie) { group.leave() } }
            group.notify(queue: .main) {
                if call.method == "clearBilibiliCookies" { result(nil); return }
                let writes = DispatchGroup()
                for item in header.split(separator: ";") {
                    let pair = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                    guard pair.count == 2 else { continue }
                    let name = pair[0].trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty, let cookie = HTTPCookie(properties: [
                        .domain: ".bilibili.com", .path: "/", .name: name,
                        .value: String(pair[1]).trimmingCharacters(in: .whitespaces),
                        .secure: "TRUE", .expires: Date(timeIntervalSinceNow: 86400 * 180)
                    ]) else { continue }
                    writes.enter(); store.setCookie(cookie) { writes.leave() }
                }
                writes.notify(queue: .main) { result(nil) }
            }
        }
    }

    private func notifications(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        let center = UNUserNotificationCenter.current()
        let args = call.arguments as? [String: Any] ?? [:]
        switch call.method {
        case "hasPermission", "hasExactAlarmPermission":
            center.getNotificationSettings { settings in self.complete(result, settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional) }
        case "requestPermission":
            center.requestAuthorization(options: [.alert, .sound, .badge]) { allowed, _ in self.complete(result, allowed) }
        case "scheduleReminder", "showFocusCompleted":
            guard let id = args["sessionId"] as? String, !id.isEmpty else { result(false); return }
            let content = UNMutableNotificationContent()
            content.title = call.method == "scheduleReminder" ? "继续你的专注" : "专注已完成，做得好！"
            content.body = String((args["goal"] as? String ?? "焦点哔哩").prefix(160))
            content.sound = .default
            var trigger: UNNotificationTrigger? = nil
            if call.method == "scheduleReminder" {
                guard let ms = args["triggerAtMs"] as? NSNumber else { result(false); return }
                trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, ms.doubleValue / 1000 - Date().timeIntervalSince1970), repeats: false)
            }
            let prefix = call.method == "scheduleReminder" ? "reminder:" : "completed:"
            center.add(UNNotificationRequest(identifier: prefix + id, content: content, trigger: trigger)) { error in
                self.complete(result, call.method == "scheduleReminder" ? error == nil : nil)
            }
        case "cancelReminder":
            let id = "reminder:" + (args["sessionId"] as? String ?? "")
            center.removePendingNotificationRequests(withIdentifiers: [id]); center.removeDeliveredNotifications(withIdentifiers: [id]); result(nil)
        case "getReminderDiagnostics":
            center.getPendingNotificationRequests { requests in self.complete(result, ["pendingCount": requests.filter { $0.identifier.hasPrefix("reminder:") }.count]) }
        case "clearReminderDiagnostics", "playCelebrationSound": result(nil)
        case "hasDoNotDisturbAccess", "setDoNotDisturb": result(false)
        case "openSettings", "openExactAlarmSettings", "openDoNotDisturbSettings", "openBatterySettings", "openBackgroundAutostartSettings":
            #if os(iOS)
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            #else
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") { NSWorkspace.shared.open(url) }
            #endif
            result(nil)
        case "getPermissionOverview": result([:])
        default: result(FlutterMethodNotImplemented)
        }
    }

    private func installRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        for (command, method) in [(center.playCommand, "play"), (center.pauseCommand, "pause")] {
            let token = command.addTarget { [weak self] _ in
                DispatchQueue.main.async { self?.mediaChannel?.invokeMethod(method, arguments: nil) }
                return .success
            }
            commands.append((command, token))
        }
        let token = center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let position = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            DispatchQueue.main.async { self?.mediaChannel?.invokeMethod("seek", arguments: position.positionTime) }
            return .success
        }
        commands.append((center.changePlaybackPositionCommand, token))
        #if os(iOS)
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
            let kind = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            if kind == AVAudioSession.InterruptionType.began.rawValue { self?.mediaChannel?.invokeMethod("pause", arguments: nil) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] notification in
            if notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
                self?.mediaChannel?.invokeMethod("pause", arguments: nil)
            }
        })
        #endif
    }

    private func media(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        if pictureInPicture == nil, let channel = mediaChannel {
            #if os(macOS)
            if #available(macOS 26.0, *) {
                pictureInPicture = FocuBiliAppleVideoWindowRouter(channel: channel)
            } else {
                pictureInPicture = FocuBiliAppleFloatingVideoWindow(channel: channel)
            }
            #else
            if #available(iOS 15.0, *) {
                pictureInPicture = FocuBiliApplePictureInPicture(channel: channel)
            }
            #endif
        }
        switch call.method {
        case "pipStatus":
            if let pip = pictureInPicture {
                result(pip.status())
            } else { result(["supported": false, "active": false, "frames": 0]) }
        case "startPiP":
            guard let args = call.arguments as? [String: Any],
                  let x = args["x"] as? Double, let y = args["y"] as? Double,
                  let width = args["width"] as? Double, let height = args["height"] as? Double else { result(false); return }
            #if os(macOS)
            if #available(macOS 26.0, *), args["preferFloating"] as? Bool == true,
               let router = pictureInPicture as? FocuBiliAppleVideoWindowRouter {
                router.startFloating(rect: CGRect(x: x, y: y, width: width, height: height), result: result)
                return
            }
            #endif
            if let pip = pictureInPicture {
                pip.start(rect: CGRect(x: x, y: y, width: width, height: height), result: result)
            } else { result(false) }
        case "stopPiP":
            if let pip = pictureInPicture { pip.stop() }
            result(nil)
        case "supportsHardwareVideo":
            #if os(macOS)
            let attributes: [CGLPixelFormatAttribute] = [
                kCGLPFAOpenGLProfile,
                CGLPixelFormatAttribute(kCGLOGLPVersion_3_2_Core.rawValue),
                kCGLPFAAccelerated, kCGLPFADoubleBuffer,
                kCGLPFAColorSize, CGLPixelFormatAttribute(rawValue: 64),
                kCGLPFAColorFloat, kCGLPFABackingStore,
                kCGLPFAAllowOfflineRenderers, kCGLPFASupportsAutomaticGraphicsSwitching,
                CGLPixelFormatAttribute(rawValue: 0)
            ]
            var pixel: CGLPixelFormatObj?
            var count: GLint = 0
            let error = CGLChoosePixelFormat(attributes, &pixel, &count)
            let available = error == kCGLNoError && pixel != nil && count > 0
            if let pixel = pixel { CGLDestroyPixelFormat(pixel) }
            NSLog("FocuBili hardware video available: %d", available)
            result(available)
            #else
            result(true)
            #endif
        case "activate":
            if let pip = pictureInPicture,
               let args = call.arguments as? [String: Any], let handle = args["handle"] as? NSNumber {
                pip.activate(handle: handle.int64Value)
            }
            #if os(iOS)
            do {
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
                try AVAudioSession.sharedInstance().setActive(true)
            } catch { result(FlutterError(code: "audio_session", message: "无法启动系统音频会话", details: nil)); return }
            #endif
            result(nil)
        case "update":
            let args = call.arguments as? [String: Any] ?? [:]
            if let pip = pictureInPicture {
                pip.update(position: args["position"] as? Double ?? 0, duration: args["duration"] as? Double ?? 0, rate: args["rate"] as? Double ?? 0)
            }
            MPNowPlayingInfoCenter.default().nowPlayingInfo = [
                MPMediaItemPropertyTitle: args["title"] as? String ?? "焦点哔哩",
                MPMediaItemPropertyPlaybackDuration: args["duration"] as? Double ?? 0,
                MPNowPlayingInfoPropertyElapsedPlaybackTime: args["position"] as? Double ?? 0,
                MPNowPlayingInfoPropertyPlaybackRate: args["rate"] as? Double ?? 0
            ]
            #if os(macOS)
            MPNowPlayingInfoCenter.default().playbackState = (args["rate"] as? Double ?? 0) > 0 ? .playing : .paused
            #endif
            result(nil)
        case "deactivate":
            if let pip = pictureInPicture { pip.stop() }
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            #if os(iOS)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            #endif
            result(nil)
        default: result(FlutterMethodNotImplemented)
        }
    }

    #if os(iOS)
    public func application(_ application: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        guard url.scheme == "focubili" else { return false }
        initialLink = url.absoluteString
        channels.last?.invokeMethod("onDeepLink", arguments: url.absoluteString)
        return true
    }
    #endif

    public func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.alert, .sound])
    }
}
