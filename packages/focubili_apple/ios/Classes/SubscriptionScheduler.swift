#if os(iOS)
import Flutter
import UIKit
import BackgroundTasks

/// BGAppRefresh is opportunistic, never an hourly guarantee. Main-queue owned.
public final class FocuBiliSubscriptionScheduler {
    public static let shared = FocuBiliSubscriptionScheduler()
    private static let taskIdentifier = "com.focubili.app.subscription.refresh"
    private let defaults = UserDefaults.standard
    private let enabledKey = "focubili.subscription.scheduler.enabled"
    private let generationKey = "focubili.subscription.scheduler.generation"
    private let resultKey = "focubili.subscription.scheduler.result"
    private let lastRunKey = "focubili.subscription.scheduler.lastRun"
    private lazy var gate = SubscriptionRunGate(enabled: defaults.bool(forKey: enabledKey), generation: defaults.integer(forKey: generationKey))
    private var registrar: ((FlutterEngine) -> Void)?
    private var registered = false
    private var engine: FlutterEngine?
    private var task: BGAppRefreshTask?
    private var workerChannel: FlutterMethodChannel?
    private var watchdog: DispatchWorkItem?

    /// Must be called in AppDelegate before didFinishLaunching returns.
    public func register(_ registerPlugins: @escaping (FlutterEngine) -> Void) {
        registrar = registerPlugins
        guard !registered else { return }
        registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.taskIdentifier, using: .main) { task in
            guard let refresh = task as? BGAppRefreshTask else { task.setTaskCompleted(success: false); return }
            self.launch(refresh)
        }
    }

    public func attach(messenger: FlutterBinaryMessenger) -> FlutterMethodChannel {
        let channel = FlutterMethodChannel(name: "com.focubili.app/subscription_scheduler", binaryMessenger: messenger)
        channel.setMethodCallHandler { [weak self] call, result in
            guard let self = self else { result(nil); return }
            #if DEBUG && targetEnvironment(simulator)
            if call.method == "probeHeadlessEngine" { self.probeHeadlessEngine(result); return }
            #endif
            if call.method == "getStatus" { result(self.status()); return }
            guard call.method == "configure", let args = call.arguments as? [String: Any],
                let enabled = args["enabled"] as? Bool, let generation = args["generation"] as? Int, generation >= 0 else {
                result(FlutterError(code: "invalid_schedule", message: "Invalid schedule", details: nil)); return
            }
            let cancelled = self.gate.configure(enabled: enabled, generation: generation)
            self.defaults.set(enabled, forKey: self.enabledKey)
            self.defaults.set(generation, forKey: self.generationKey)
            if cancelled != nil { self.terminate(result: "cancelled") }
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskIdentifier)
            var accepted = true
            if enabled { accepted = self.scheduleNext() }
            else { self.defaults.set("stopped", forKey: self.resultKey) }
            result(self.status(accepted: accepted))
        }
        return channel
    }

    private var available: Bool {
        registered && UIApplication.shared.backgroundRefreshStatus == .available
    }
    private func status(accepted: Bool = true) -> [String: Any] {
        ["available": available, "accepted": accepted, "mode": "opportunistic",
         "registered": registered, "status": available ? defaults.string(forKey: resultKey) ?? "ready" : "unavailable",
         "lastRunStatus": defaults.string(forKey: lastRunKey) ?? "none"]
    }
    private func scheduleNext() -> Bool {
        guard gate.enabled, available else { defaults.set("unavailable", forKey: resultKey); return false }
        let request = BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 3600)
        do {
            try BGTaskScheduler.shared.submit(request)
            defaults.set("waiting_system", forKey: resultKey); return true
        } catch {
            defaults.set("schedule_failed", forKey: resultKey); return false
        }
    }

    private func launch(_ refresh: BGAppRefreshTask) {
        guard gate.enabled, registrar != nil, let token = gate.begin() else {
            refresh.setTaskCompleted(success: true); return
        }
        self.task = refresh
        _ = scheduleNext()
        defaults.set("running", forKey: resultKey)
        refresh.expirationHandler = { DispatchQueue.main.async { self.terminate(result: "expired") } }
        let watchdog = DispatchWorkItem { [weak self] in self?.terminate(result: "expired") }
        self.watchdog = watchdog
        DispatchQueue.main.asyncAfter(deadline: .now() + 25, execute: watchdog)
        let started = startEngine(entrypoint: "subscriptionAppleBackgroundMain",
            libraryURI: "package:focubili/services/subscription_background_service.dart") { [weak self] call, result in
            guard let self = self else { result(false); return }
            guard self.gate.run == token else { result(false); return }
            if call.method == "ready" {
                result(["runId": token, "generation": self.gate.generation, "budgetMilliseconds": 20000]); return
            }
            if call.method == "complete", let args = call.arguments as? [String: Any], args["runId"] as? String == token {
                let succeeded = args["success"] as? Bool == true
                result(true)
                self.finish(token, success: succeeded, status: succeeded ? "completed" : "failed")
                return
            }
            result(FlutterMethodNotImplemented)
        }
        if !started { finish(token, success: false, status: "engine_failed") }
    }

    /// Flutter asserts if a native method handler is installed before run().
    /// All setup stays on this main-queue turn, before Dart's ready call arrives.
    private func startEngine(entrypoint: String, libraryURI: String?,
                             handler: @escaping FlutterMethodCallHandler) -> Bool {
        guard let registerPlugins = registrar else { return false }
        let engine = FlutterEngine(name: "focubili.subscription.refresh", project: nil, allowHeadlessExecution: true)
        self.engine = engine
        guard engine.run(withEntrypoint: entrypoint, libraryURI: libraryURI) else { return false }
        let channel = FlutterMethodChannel(name: "com.focubili.app/subscription_worker", binaryMessenger: engine.binaryMessenger)
        workerChannel = channel
        channel.setMethodCallHandler(handler)
        FocuBiliApplePlugin.registeringSubscriptionWorker = true
        registerPlugins(engine)
        FocuBiliApplePlugin.registeringSubscriptionWorker = false
        return true
    }

    #if DEBUG && targetEnvironment(simulator)
    // Simulator CI only; absent from device/release builds. Exercises the real
    // production engine bootstrap with a store-free, network-free Dart probe.
    private func probeHeadlessEngine(_ response: @escaping FlutterResult) {
        guard engine == nil, task == nil else {
            response(FlutterError(code: "worker_busy", message: "Worker busy", details: nil)); return
        }
        let token = UUID().uuidString
        var closed = false
        let finishProbe: (Bool) -> Void = { [weak self] success in
            guard !closed else { return }; closed = true
            self?.cleanup(); response(success)
        }
        let watchdog = DispatchWorkItem { finishProbe(false) }
        self.watchdog = watchdog
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: watchdog)
        let started = startEngine(entrypoint: "nativeSubscriptionHeadlessProbe", libraryURI: nil) { call, result in
            if call.method == "ready" { result(["probe": true, "runId": token]); return }
            if call.method == "complete", let args = call.arguments as? [String: Any], args["runId"] as? String == token {
                result(true); finishProbe(args["success"] as? Bool == true); return
            }
            result(FlutterMethodNotImplemented)
        }
        if !started { finishProbe(false) }
    }
    #endif

    private func terminate(result: String) {
        // configure() may already invalidate the gate; task identity still owns completion.
        guard task != nil else { return }
        workerChannel?.invokeMethod("expire", arguments: nil)
        if let token = gate.run { _ = gate.finish(token) }
        defaults.set(result, forKey: resultKey)
        defaults.set(result, forKey: lastRunKey)
        task?.setTaskCompleted(success: false); task = nil
        cleanup()
    }
    private func finish(_ token: String, success: Bool, status: String) {
        guard gate.finish(token) else { return }
        defaults.set(status, forKey: resultKey)
        defaults.set(status, forKey: lastRunKey)
        task?.setTaskCompleted(success: success); task = nil
        cleanup()
    }
    private func cleanup() {
        watchdog?.cancel(); watchdog = nil
        let oldEngine = engine; engine = nil
        workerChannel?.setMethodCallHandler(nil); workerChannel = nil
        // Give the completion/expiration channel reply a main-loop turn, then end
        // the headless engine. OS locks recover even if expiration kills it first.
        DispatchQueue.main.async { oldEngine?.destroyContext() }
    }
    var currentRunToken: String? { gate.run }
    func canNotify(generation: Int, runToken: String?) -> Bool {
        guard let runToken = runToken else { return false }
        if Thread.isMainThread { return gate.permits(generation, runToken: runToken) }
        return DispatchQueue.main.sync { gate.permits(generation, runToken: runToken) }
    }
}
#endif

#if os(macOS)
import FlutterMacOS
import Foundation

/// Process-owned native dispatch timer. No login item or launch agent is installed.
final class FocuBiliDesktopSubscriptionScheduler {
    private var timer: DispatchSourceTimer?
    private var generation = 0
    private var channel: FlutterMethodChannel?
    func attach(messenger: FlutterBinaryMessenger) -> FlutterMethodChannel {
        let channel = FlutterMethodChannel(name: "com.focubili.app/subscription_scheduler", binaryMessenger: messenger)
        self.channel = channel
        channel.setMethodCallHandler { [weak self] call, result in
            guard let self = self else { result(nil); return }
            if call.method == "configure" {
                guard let args = call.arguments as? [String: Any], let generation = args["generation"] as? Int, generation >= 0 else {
                    result(FlutterError(code: "invalid_schedule", message: "Invalid schedule", details: nil)); return
                }
                self.timer?.cancel(); self.timer = nil; self.generation = generation
                if args["enabled"] as? Bool == true {
                    let seconds = min(86400, max(1, args["intervalSeconds"] as? Int ?? 3600))
                    let timer = DispatchSource.makeTimerSource(queue: .main)
                    timer.schedule(deadline: .now() + .seconds(seconds), repeating: .seconds(seconds), leeway: .seconds(min(60, seconds / 10)))
                    timer.setEventHandler { [weak self] in
                        guard let self = self else { return }
                        self.channel?.invokeMethod("check", arguments: ["generation": self.generation])
                    }
                    self.timer = timer; timer.resume()
                }
            } else if call.method != "getStatus" { result(FlutterMethodNotImplemented); return }
            result(["available": true, "accepted": true, "mode": "process", "status": self.timer == nil ? "stopped" : "scheduled_process"])
        }
        return channel
    }
    deinit { timer?.cancel() }
}
#endif
