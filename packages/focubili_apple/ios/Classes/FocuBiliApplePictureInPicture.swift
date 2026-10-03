#if os(iOS)
import Flutter
import UIKit
#else
import FlutterMacOS
import AppKit
#endif
import AVKit
import AVFoundation

protocol FocuBiliAppleVideoWindow: AnyObject {
    func activate(handle: Int64)
    func update(position: Double, duration: Double, rate: Double)
    func status() -> [String: Any]
    func start(rect: CGRect, result: @escaping FlutterResult)
    func stop()
}

#if os(macOS)
// Native fallback for older macOS and runtimes that reject sample-buffer PiP.
final class FocuBiliAppleFloatingVideoWindow: NSObject, NSWindowDelegate, FocuBiliAppleVideoWindow {
    private let channel: FlutterMethodChannel
    private let layer = AVSampleBufferDisplayLayer()
    private var panel: NSPanel?
    private var observer: NSObjectProtocol?
    private var completion: FlutterResult?
    private var handle: Int64 = 0
    private var generation = 0
    private var frames = 0
    private var position = 0.0
    private var duration = 0.0
    private var rate = 0.0
    private var timebase: CMTimebase?
    init(channel: FlutterMethodChannel) {
        self.channel = channel
        super.init()
        var base: CMTimebase?
        CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &base)
        timebase = base; layer.controlTimebase = base
        layer.videoGravity = .resizeAspect
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        observer = NotificationCenter.default.addObserver(forName: Notification.Name("FocuBili.PiP.Frame"), object: nil, queue: .main) { [weak self] note in
            guard let self = self, self.panel != nil,
                  note.userInfo?["handle"] as? Int64 == self.handle,
                  let value = note.userInfo?["pixelBuffer"] else { return }
            self.enqueue(value as! CVPixelBuffer)
        }
    }
    deinit { if let observer = observer { NotificationCenter.default.removeObserver(observer) } }
    private func capture(_ enabled: Bool) {
        NotificationCenter.default.post(name: Notification.Name("FocuBili.PiP.Capture"), object: nil,
            userInfo: ["handle": handle, "enabled": enabled])
    }
    func activate(handle: Int64) { if self.handle != handle { stop(); self.handle = handle } }
    func update(position: Double, duration: Double, rate: Double) {
        guard position.isFinite, duration.isFinite, rate.isFinite else { return }
        if abs(self.position - position) > 2 { layer.flush() }
        self.position = max(0, position); self.duration = max(0, duration); self.rate = max(0, rate)
        if let timebase = timebase {
            CMTimebaseSetTime(timebase, time: CMTime(seconds: self.position, preferredTimescale: 600))
            CMTimebaseSetRate(timebase, rate: self.rate)
        }
    }
    func status() -> [String: Any] {
        ["supported": true, "mode": "floating", "systemPictureInPicture": false,
         "possible": handle != 0, "active": panel?.isVisible ?? false,
         "frames": frames, "layerStatus": layer.status.rawValue,
         "layerError": layer.error?.localizedDescription ?? ""]
    }
    func start(rect: CGRect, result: @escaping FlutterResult) {
        if panel?.isVisible == true { result(true); return }
        guard panel == nil, completion == nil, handle != 0,
              rect.width > 0, rect.height > 0, rect.width.isFinite, rect.height.isFinite else { result(false); return }
        let ratio = min(max(rect.width / rect.height, 0.5), 3)
        let screen = NSApp.keyWindow?.screen ?? NSScreen.main
        let availableHeight = screen?.visibleFrame.height ?? 720
        let width: CGFloat = min(400, max(200, availableHeight * 0.65 * ratio)), height = width / ratio
        let window = NSPanel(contentRect: CGRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        window.title = "焦点哔哩 · 视频小窗"
        window.isFloatingPanel = true; window.level = .floating
        window.hidesOnDeactivate = false; window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentMinSize = NSSize(width: 200, height: 200 / ratio)
        window.contentAspectRatio = NSSize(width: width, height: height)
        let view = NSView(frame: CGRect(x: 0, y: 0, width: width, height: height))
        view.wantsLayer = true; view.layer?.backgroundColor = NSColor.black.cgColor
        window.contentView = view; window.delegate = self
        layer.frame = view.bounds; view.layer?.addSublayer(layer)
        let controls = NSStackView()
        controls.orientation = .horizontal; controls.spacing = 8
        for (title, action) in [("−15", #selector(back)), ("播放", #selector(play)), ("暂停", #selector(pause)), ("+15", #selector(forward))] {
            let button = NSButton(title: title, target: self, action: action)
            button.bezelStyle = .rounded; controls.addArrangedSubview(button)
        }
        controls.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controls)
        NSLayoutConstraint.activate([controls.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            controls.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8)])
        if let screen = screen {
            let visible = screen.visibleFrame
            window.setFrameOrigin(NSPoint(x: max(visible.minX, visible.maxX - width - 20), y: max(visible.minY, visible.maxY - height - 70)))
        }
        panel = window; completion = result; frames = 0; generation += 1
        layer.flushAndRemoveImage(); capture(true)
        let expected = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self = self, self.generation == expected, self.completion != nil else { return }
            self.stop()
        }
    }
    private func enqueue(_ buffer: CVPixelBuffer) {
        if layer.status == .failed { layer.flush() }
        guard layer.isReadyForMoreMediaData else { return }
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescriptionOut: &format) == noErr,
              let format = format else { return }
        var timing = CMSampleTimingInfo(duration: .invalid,
            presentationTimeStamp: CMTime(seconds: position, preferredTimescale: 600), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample) == noErr,
              let sample = sample else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as? [NSMutableDictionary], let first = attachments.first {
            first[kCMSampleAttachmentKey_DisplayImmediately] = true
        }
        layer.enqueue(sample); frames += 1
        if completion != nil, let panel = panel {
            panel.orderFrontRegardless()
            let callback = completion; completion = nil
            callback?(panel.isVisible)
            channel.invokeMethod("pipStateChanged", arguments: panel.isVisible)
        }
    }
    func stop() {
        generation += 1; capture(false)
        let callback = completion; completion = nil; callback?(false)
        if let window = panel { panel = nil; window.delegate = nil; window.close() }
        layer.flushAndRemoveImage(); layer.removeFromSuperlayer()
        channel.invokeMethod("pipStateChanged", arguments: false)
    }
    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === panel else { return }
        panel = nil; closing.delegate = nil
        stop()
    }
    @objc private func play() { channel.invokeMethod("play", arguments: nil) }
    @objc private func pause() { channel.invokeMethod("pause", arguments: nil) }
    @objc private func back() { seek(-15) }
    @objc private func forward() { seek(15) }
    private func seek(_ interval: Double) {
        guard duration > 0 else { return }
        let target = min(max(0, position + interval), duration)
        let expected = generation, expectedHandle = handle
        channel.invokeMethod("seek", arguments: target) { [weak self] result in
            guard let self = self, self.generation == expected, self.handle == expectedHandle,
                  self.panel != nil, !(result is FlutterError) else { return }
            self.layer.flush(); self.update(position: target, duration: self.duration, rate: self.rate)
        }
    }
}
#endif

@available(iOS 15.0, macOS 12.0, *)
final class FocuBiliApplePictureInPicture: NSObject, AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate, FocuBiliAppleVideoWindow {
    private let channel: FlutterMethodChannel
    private let layer = AVSampleBufferDisplayLayer()
    private var controller: AVPictureInPictureController?
    #if os(iOS)
    private var host: UIView?
    #else
    private var host: NSView?
    #endif
    private var observer: NSObjectProtocol?
    private var possibleObservation: NSKeyValueObservation?
    private var completion: FlutterResult?
    private var starting = false
    private var handle: Int64 = 0
    private var position = 0.0
    private var duration = 0.0
    private var rate = 0.0
    private var frames = 0
    private var generation = 0
    private var timebase: CMTimebase?
    private var lastAttempt: [String: Any] = [:]

    init(channel: FlutterMethodChannel) {
        self.channel = channel
        super.init()
        var base: CMTimebase?
        CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &base)
        timebase = base
        layer.controlTimebase = base
        layer.videoGravity = .resizeAspect
        observer = NotificationCenter.default.addObserver(forName: Notification.Name("FocuBili.PiP.Frame"), object: nil, queue: .main) { [weak self] notification in
            guard let self = self, self.host != nil,
                  let source = notification.userInfo?["handle"] as? Int64, source == self.handle,
                  let value = notification.userInfo?["pixelBuffer"] else { return }
            self.enqueue(value as! CVPixelBuffer)
        }
    }
    deinit { if let observer = observer { NotificationCenter.default.removeObserver(observer) } }
    func activate(handle: Int64) {
        if self.handle != handle { stop(); self.handle = handle }
    }
    func update(position: Double, duration: Double, rate: Double) {
        guard position.isFinite, duration.isFinite, rate.isFinite else { return }
        if abs(self.position - position) > 2 { layer.flush() }
        self.position = max(0, position); self.duration = max(0, duration); self.rate = max(0, rate)
        if let timebase = timebase {
            CMTimebaseSetTime(timebase, time: CMTime(seconds: self.position, preferredTimescale: 600))
            CMTimebaseSetRate(timebase, rate: self.rate)
        }
        controller?.invalidatePlaybackState()
    }
    private func capture(_ enabled: Bool) {
        NotificationCenter.default.post(name: Notification.Name("FocuBili.PiP.Capture"), object: nil,
            userInfo: ["handle": handle, "enabled": enabled])
    }
    func status() -> [String: Any] {
        ["mode": "system", "systemPictureInPicture": true, "supported": AVPictureInPictureController.isPictureInPictureSupported(),
         "possible": controller?.isPictureInPicturePossible ?? false,
         "active": controller?.isPictureInPictureActive ?? false, "frames": frames, "lastAttempt": lastAttempt]
    }
    func start(rect: CGRect, result: @escaping FlutterResult) {
        guard completion == nil else { result(false); return }
        if controller?.isPictureInPictureActive == true { result(true); return }
        guard host == nil else { result(false); return }
        guard handle != 0, rect.width > 0, rect.height > 0,
              [rect.minX, rect.minY, rect.width, rect.height].allSatisfy({ $0.isFinite }),
              AVPictureInPictureController.isPictureInPictureSupported() else { result(false); return }
        #if os(iOS)
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }.flatMap { $0.windows }
        guard let root = windows.first(where: { $0.isKeyWindow })?.rootViewController?.view else { result(false); return }
        let view = UIView(frame: rect)
        view.isUserInteractionEnabled = false
        root.addSubview(view); view.layer.addSublayer(layer); host = view
        #else
        guard let root = NSApp.keyWindow?.contentView ?? NSApp.windows.first(where: { $0.isVisible })?.contentView else { result(false); return }
        let nativeRect = root.isFlipped ? rect : CGRect(x: rect.minX, y: root.bounds.height - rect.maxY, width: rect.width, height: rect.height)
        let view = NSView(frame: nativeRect)
        view.wantsLayer = true
        root.addSubview(view); view.layer?.addSublayer(layer); host = view
        #endif
        layer.frame = CGRect(origin: .zero, size: rect.size)
        layer.flushAndRemoveImage()
        frames = 0; starting = false; generation += 1
        completion = result
        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: layer, playbackDelegate: self)
        let pip = AVPictureInPictureController(contentSource: source)
        controller = pip; pip.delegate = self
        possibleObservation = pip.observe(\.isPictureInPicturePossible, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.startIfReady() }
        }
        capture(true)
        let expected = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self = self, self.generation == expected, self.completion != nil else { return }
            self.finish(false); self.cleanUp()
        }
    }
    private func enqueue(_ buffer: CVPixelBuffer) {
        if layer.status == .failed { layer.flush() }
        guard layer.isReadyForMoreMediaData else { return }
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescriptionOut: &format) == noErr,
              let format = format else { return }
        var timing = CMSampleTimingInfo(duration: .invalid,
            presentationTimeStamp: CMTime(seconds: position, preferredTimescale: 600), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample) == noErr,
              let sample = sample else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as? [NSMutableDictionary], let first = attachments.first {
            first[kCMSampleAttachmentKey_DisplayImmediately] = true
        }
        layer.enqueue(sample); frames += 1
        startIfReady()
    }
    private func startIfReady() {
        guard completion != nil, !starting, frames > 0, controller?.isPictureInPicturePossible == true else { return }
        starting = true
        controller?.startPictureInPicture()
    }
    private func finish(_ succeeded: Bool) { let callback = completion; completion = nil; callback?(succeeded) }
    private func cleanUp() {
        lastAttempt = ["possible": controller?.isPictureInPicturePossible ?? false,
            "layerStatus": layer.status.rawValue, "layerError": layer.error?.localizedDescription ?? "",
            "hostAttached": host?.window != nil, "position": position, "duration": duration, "rate": rate]
        #if os(macOS)
        lastAttempt["applicationActive"] = NSApp.isActive
        #endif
        generation += 1; capture(false); possibleObservation = nil
        controller?.delegate = nil; controller = nil; starting = false
        layer.flushAndRemoveImage(); layer.removeFromSuperlayer(); host?.removeFromSuperview(); host = nil
    }
    func stop() {
        controller?.stopPictureInPicture()
        finish(false); cleanUp()
        channel.invokeMethod("pipStateChanged", arguments: false)
    }
    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        guard controller === pictureInPictureController else { return }
        finish(true); channel.invokeMethod("pipStateChanged", arguments: true)
    }
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        guard controller === pictureInPictureController else { return }
        finish(false); cleanUp(); channel.invokeMethod("pipStateChanged", arguments: false)
    }
    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        guard controller === pictureInPictureController else { return }
        finish(false); cleanUp(); channel.invokeMethod("pipStateChanged", arguments: false)
    }
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping @Sendable (Bool) -> Void) {
        #if os(macOS)
        NSApp.activate(ignoringOtherApps: true); NSApp.windows.first?.makeKeyAndOrderFront(nil)
        #endif
        completionHandler(host?.window != nil)
    }
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
        channel.invokeMethod(playing ? "play" : "pause", arguments: nil)
    }
    func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        duration > 0 ? CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 600)) : .invalid
    }
    func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool { rate == 0 }
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion completionHandler: @escaping @Sendable () -> Void) {
        let delta = skipInterval.seconds
        guard delta.isFinite else { completionHandler(); return }
        let target = min(max(0, position + delta), max(0, duration))
        let expectedGeneration = generation
        let expectedHandle = handle
        channel.invokeMethod("seek", arguments: target) { [weak self] result in
            if !(result is FlutterError), let self = self,
               self.generation == expectedGeneration, self.handle == expectedHandle,
               self.controller === pictureInPictureController {
                self.layer.flush(); self.update(position: target, duration: self.duration, rate: self.rate)
            }
            completionHandler()
        }
    }
}


#if os(macOS)
@available(macOS 26.0, *)
final class FocuBiliAppleVideoWindowRouter: FocuBiliAppleVideoWindow {
    private let system: FocuBiliApplePictureInPicture
    private let floating: FocuBiliAppleFloatingVideoWindow
    private var current: FocuBiliAppleVideoWindow
    private var generation = 0
    private var starting = false
    init(channel: FlutterMethodChannel) {
        let system = FocuBiliApplePictureInPicture(channel: channel)
        let floating = FocuBiliAppleFloatingVideoWindow(channel: channel)
        self.system = system; self.floating = floating; current = system
    }
    func activate(handle: Int64) {
        generation += 1; starting = false
        system.activate(handle: handle); floating.activate(handle: handle)
    }
    func update(position: Double, duration: Double, rate: Double) {
        system.update(position: position, duration: duration, rate: rate)
        floating.update(position: position, duration: duration, rate: rate)
    }
    func status() -> [String: Any] {
        var value = current.status()
        value["supported"] = true // The native floating-window fallback is available.
        value["systemSupported"] = system.status()["supported"]
        return value
    }
    func start(rect: CGRect, result: @escaping FlutterResult) {
        guard !starting else { result(false); return }
        if current.status()["active"] as? Bool == true { current.start(rect: rect, result: result); return }
        starting = true; current = system
        let expected = generation
        system.start(rect: rect) { [weak self] value in
            guard let self = self, self.generation == expected else { result(false); return }
            if value as? Bool == true { self.starting = false; result(true); return }
            // Let the system source finish cleanup before enabling the same handle
            // for the fallback. Otherwise its capture(false) can cancel our frames.
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.generation == expected else { result(false); return }
                self.current = self.floating
                self.floating.start(rect: rect) { [weak self] value in
                    guard let self = self, self.generation == expected else { result(false); return }
                    self.starting = false; result(value)
                }
            }
        }
    }
    func startFloating(rect: CGRect, result: @escaping FlutterResult) {
        guard !starting, current.status()["active"] as? Bool != true else { result(false); return }
        current = floating; starting = true
        let expected = generation
        floating.start(rect: rect) { [weak self] value in
            guard let self = self, self.generation == expected else { result(false); return }
            self.starting = false; result(value)
        }
    }
    func stop() {
        generation += 1; starting = false
        system.stop(); floating.stop()
    }
}
#endif
