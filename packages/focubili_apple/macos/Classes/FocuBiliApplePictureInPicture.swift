#if os(iOS)
import Flutter
import UIKit
#else
import FlutterMacOS
import AppKit
#endif
import AVKit
import AVFoundation

@available(iOS 15.0, macOS 12.0, *)
final class FocuBiliApplePictureInPicture: NSObject, AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate {
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
        ["supported": AVPictureInPictureController.isPictureInPictureSupported(),
         "possible": controller?.isPictureInPicturePossible ?? false,
         "active": controller?.isPictureInPictureActive ?? false, "frames": frames]
    }
    func start(rect: CGRect, result: @escaping FlutterResult) {
        guard completion == nil else { result(false); return }
        if controller?.isPictureInPictureActive == true { result(true); return }
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
        finish(true); channel.invokeMethod("pipStateChanged", arguments: true)
    }
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        finish(false); cleanUp(); channel.invokeMethod("pipStateChanged", arguments: false)
    }
    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
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
        channel.invokeMethod("seek", arguments: target) { [weak self] result in
            if !(result is FlutterError), let self = self {
                self.layer.flush(); self.update(position: target, duration: self.duration, rate: self.rate)
            }
            completionHandler()
        }
    }
}
