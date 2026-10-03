import Foundation
import CoreVideo

// All capture() calls run on one VideoOutput worker. Delivery is bounded to one
// independent frame; the source's recyclable buffer never escapes that worker.
final class FocuBiliFrameBridge {
  private static let lock = NSLock()
  private static var enabledHandles = Set<Int64>()
  private static let observer: NSObjectProtocol = NotificationCenter.default.addObserver(
    forName: Notification.Name("FocuBili.PiP.Capture"), object: nil, queue: nil
  ) { note in
    guard let handle = note.userInfo?["handle"] as? Int64,
          let enabled = note.userInfo?["enabled"] as? Bool else { return }
    lock.lock(); defer { lock.unlock() }
    if enabled { enabledHandles.insert(handle) } else { enabledHandles.remove(handle) }
  }
  static func enabled(_ handle: Int64) -> Bool {
    _ = observer
    lock.lock(); defer { lock.unlock() }
    return enabledHandles.contains(handle)
  }
  // Ensure the control notification observer exists before first request.
  static func initialize() { _ = observer }
  private let handle: Int64
  private let deliveryLock = NSLock()
  private var pending = false
  private var pool: CVPixelBufferPool?
  private var dimensions = (0, 0)
  init(handle: Int64) { self.handle = handle; Self.initialize() }
  deinit {
    Self.lock.lock(); Self.enabledHandles.remove(handle); Self.lock.unlock()
  }
  func capture(_ source: CVPixelBuffer) {
    guard Self.enabled(handle) else { return }
    deliveryLock.lock()
    if pending { deliveryLock.unlock(); return }
    pending = true; deliveryLock.unlock()
    var delivered = false
    defer { if !delivered { deliveryLock.lock(); pending = false; deliveryLock.unlock() } }
    guard CVPixelBufferGetPixelFormatType(source) == kCVPixelFormatType_32BGRA else { return }
    let width = CVPixelBufferGetWidth(source), height = CVPixelBufferGetHeight(source)
    if dimensions != (width, height) {
      dimensions = (width, height)
      pool = nil
      let attrs: [CFString: Any] = [kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
        kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
        kCVPixelBufferIOSurfacePropertiesKey: [:]]
      guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &pool) == kCVReturnSuccess else { return }
    }
    guard let pool = pool else { return }
    var copy: CVPixelBuffer?
    let limits = [kCVPixelBufferPoolAllocationThresholdKey: 4] as CFDictionary
    guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool, limits, &copy) == kCVReturnSuccess,
          let copy = copy else { return }
    guard CVPixelBufferLockBaseAddress(source, .readOnly) == kCVReturnSuccess else { return }
    defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
    guard CVPixelBufferLockBaseAddress(copy, []) == kCVReturnSuccess else { return }
    defer { CVPixelBufferUnlockBaseAddress(copy, []) }
    guard let src = CVPixelBufferGetBaseAddress(source), let dst = CVPixelBufferGetBaseAddress(copy) else { return }
    let srcStride = CVPixelBufferGetBytesPerRow(source), dstStride = CVPixelBufferGetBytesPerRow(copy)
    for row in 0..<height { memcpy(dst.advanced(by: row * dstStride), src.advanced(by: row * srcStride), width * 4) }
    delivered = true
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      defer { self.deliveryLock.lock(); self.pending = false; self.deliveryLock.unlock() }
      guard Self.enabled(self.handle) else { return }
      NotificationCenter.default.post(name: Notification.Name("FocuBili.PiP.Frame"), object: nil,
        userInfo: ["handle": self.handle, "pixelBuffer": copy])
    }
  }
}
