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
    #if os(iOS)
    static var registeringSubscriptionWorker = false
    private var subscriptionWorkerToken: String?
    private var subscriptionWorkerFocusEpoch: Int?
    private var isSubscriptionWorker = false
    #else
    private let subscriptionScheduler = FocuBiliDesktopSubscriptionScheduler()
    #endif
    private var channels: [FlutterMethodChannel] = []
    private var mediaChannel: FlutterMethodChannel?
    private var subscriptionChannel: FlutterMethodChannel?
    private let subscriptionDeliveryGate = SubscriptionNotificationGate()
    private var subscriptionTapPending = false
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
        if !registeringSubscriptionWorker { registrar.addApplicationDelegate(instance) }
        #else
        let messenger = registrar.messenger
        #endif
        #if os(iOS)
        let worker = registeringSubscriptionWorker
        instance.isSubscriptionWorker = worker
        if worker {
            instance.subscriptionWorkerToken = FocuBiliSubscriptionScheduler.shared.currentRunToken
            instance.subscriptionWorkerFocusEpoch = SubscriptionFocusGate.shared.capture()
        }
        let names = worker ? ["auth", "subscription_notifications"] : ["auth", "focus_notifications", "subscription_notifications", "device_status", "apple_media"]
        #else
        let names = ["auth", "focus_notifications", "subscription_notifications", "device_status", "apple_media"]
        #endif
        for name in names {
            let channel = FlutterMethodChannel(name: "com.focubili.app/" + name, binaryMessenger: messenger)
            channel.setMethodCallHandler { call, result in instance.handle(name, call, result) }
            instance.channels.append(channel)
            if name == "apple_media" { instance.mediaChannel = channel }
            if name == "subscription_notifications" { instance.subscriptionChannel = channel }
        }
        #if os(iOS)
        if worker { registrar.publish(instance); return }
        instance.channels.append(FocuBiliSubscriptionScheduler.shared.attach(messenger: messenger))
        #else
        instance.channels.append(instance.subscriptionScheduler.attach(messenger: messenger))
        #endif
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
        case "subscription_notifications": subscriptionNotifications(call, result)
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

    private static let playbackCookies = BilibiliPlaybackSessionCoordinator(store: WebKitBilibiliCookieContainer())

    private func auth(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        let path = args["path"] as? String ?? "/x/web-interface/nav"
        switch call.method {
        case "readPlaybackSession":
            Self.playbackCookies.read(path: path) { self.complete(result, $0.payload) }
        case "validatePlaybackSession":
            guard let generation = args["generation"] as? Int else {
                result(FlutterError(code: "session_unknown", message: "无法确认播放会话", details: nil)); return
            }
            Self.playbackCookies.validate(generation: generation, path: path) { self.complete(result, $0) }
        case "mergePlaybackResponseCookies":
            guard let generation = args["generation"] as? Int,
                  let headers = args["cookies"] as? [String] else {
                result(FlutterError(code: "session_unknown", message: "无法确认播放会话", details: nil)); return
            }
            Self.playbackCookies.merge(generation: generation, path: path, headers: headers) { self.complete(result, $0.payload) }
        case "readCookies":
            Self.playbackCookies.read(path: "/x/web-interface/nav") { snapshot in
                self.complete(result, snapshot.usable ? snapshot.header : FlutterError(code: "session_" + snapshot.state, message: "登录会话不完整或存在冲突，请重新登录", details: nil))
            }
        case "replaceCookies", "clearBilibiliCookies":
            if call.method == "replaceCookies" && args["cookie"] as? String == nil {
                result(FlutterError(code: "invalid_cookie", message: "Cookie 格式无效", details: nil)); return
            }
            Self.playbackCookies.replace(header: call.method == "replaceCookies" ? args["cookie"] as? String : nil) { accepted in
                self.complete(result, accepted ? nil : FlutterError(code: "invalid_cookie", message: "Cookie 格式无效", details: nil))
            }
        default: result(FlutterMethodNotImplemented)
        }
    }

    // Scheduling is separate; this posts only an already checked update.
    private func subscriptionNotifications(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        if call.method == "consumeTap" {
            result(subscriptionTapPending); subscriptionTapPending = false; return
        }
        let args = call.arguments as? [String: Any] ?? [:]
        if call.method == "setFocusActive" {
            #if os(iOS)
            guard !isSubscriptionWorker else { result(false); return }
            #endif
            guard let active = args["active"] as? Bool else {
                result(FlutterError(code: "invalid_focus", message: "Invalid focus state", details: nil)); return
            }
            SubscriptionFocusGate.shared.update(active: active)
            result(nil); return
        }
        if call.method == "cancelWorkerSummary" {
            #if os(iOS)
            guard isSubscriptionWorker else { result(false); return }
            subscriptionDeliveryGate.cancelWorker()
            result(nil)
            #else
            result(false)
            #endif
            return
        }
        if call.method == "cancelSummary" {
            if let request = args["requestId"] as? String { subscriptionDeliveryGate.finish(request) }
            result(nil); return
        }
        guard call.method == "showSummary" else { result(FlutterMethodNotImplemented); return }
        guard let count = args["count"] as? Int, count > 0 else { result(false); return }
        let center = UNUserNotificationCenter.current()
        #if os(iOS)
        let isBackground = args["background"] as? Bool == true
        let generation = args["generation"] as? Int ?? -1
        // Bind background delivery to engine registration, not the later show
        // call: focus may start and end before that queued call reaches native.
        let focusEpoch = isBackground ? subscriptionWorkerFocusEpoch : SubscriptionFocusGate.shared.capture()
        #else
        let isBackground = false
        let focusEpoch = SubscriptionFocusGate.shared.capture()
        #endif
        let canDeliver = { () -> Bool in
            guard SubscriptionFocusGate.shared.permits(focusEpoch) else { return false }
            #if os(iOS)
            if isBackground {
                guard !self.subscriptionDeliveryGate.workerCancelled else { return false }
                return FocuBiliSubscriptionScheduler.shared.canNotify(generation: generation, runToken: self.subscriptionWorkerToken)
            }
            #endif
            return true
        }
        guard canDeliver() else { result(false); return }
        let requestId = args["requestId"] as? String
        if !isBackground {
            guard let request = requestId, subscriptionDeliveryGate.begin(request) else { result(false); return }
        }
        let reject = {
            if let request = requestId { self.subscriptionDeliveryGate.finish(request) }
            result(false)
        }
        center.getNotificationSettings { settings in
            DispatchQueue.main.async {
                // Serialize delivery against native opt-out, generation changes
                // and expiration, even if UN settings replied on another queue.
                guard canDeliver() else { reject(); return }
                guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
                    reject(); return
                }
                let deliver = {
                    // Latest UI-owned focus state, serialized with center.add.
                    // Never ask the headless Dart engine for a cached snapshot.
                    guard canDeliver() else { reject(); return }
                    // Cancellation may arrive while the Dart guard reply is in
                    // flight. Consume on this same main-queue turn as center.add.
                    if !isBackground {
                        guard let request = requestId, self.subscriptionDeliveryGate.finish(request) else { result(false); return }
                    }
                    let content = UNMutableNotificationContent()
                    content.title = String((args["title"] as? String ?? "焦点订阅").prefix(240))
                    content.subtitle = String((args["source"] as? String ?? "").prefix(240))
                    content.body = count > 1 ? "另有 \(count - 1) 条更新，打开焦点订阅查看" : "点击查看订阅更新"
                    content.threadIdentifier = "focubili.subscriptions"
                    center.add(UNNotificationRequest(identifier: "focubili.subscriptions", content: content, trigger: nil)) { error in
                        self.complete(result, error == nil)
                    }
                }
                if isBackground { deliver(); return }
                guard let request = requestId, self.subscriptionDeliveryGate.contains(request),
                      let channel = self.subscriptionChannel else { reject(); return }
                // The Dart guard includes source changes, opt-out, focus and
                // disposal, including when background refresh is disabled.
                channel.invokeMethod("canDeliver", arguments: ["requestId": request]) { allowed in
                    DispatchQueue.main.async {
                        guard SubscriptionNotificationGate.allows(allowed) else { reject(); return }
                        deliver()
                    }
                }
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
            // The system sample-buffer path reported success but cropped frames
            // in visual QA. Use the fully verified native window on Mac.
            pictureInPicture = FocuBiliAppleFloatingVideoWindow(channel: channel)
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

    public func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.notification.request.identifier == "focubili.subscriptions" {
            DispatchQueue.main.async {
                self.subscriptionTapPending = true
                self.subscriptionChannel?.invokeMethod("subscriptionTapped", arguments: nil)
            }
        }
        completionHandler()
    }

    public func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.alert, .sound])
    }
}
