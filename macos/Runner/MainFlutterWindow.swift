import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var cacheDirectoryScopes: [String: URL] = [:]
  private var cacheDirectoryPaths: [String: String] = [:]
  private var cacheDirectoryChannel: FlutterMethodChannel?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    registerCacheDirectoryChannel(flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }

  private func registerCacheDirectoryChannel(_ messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "focubili/offline_cache_directory",
      binaryMessenger: messenger
    )
    cacheDirectoryChannel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(FlutterError(code: "window_unavailable", message: nil, details: nil))
        return
      }
      switch call.method {
      case "pick":
        self.pickCacheDirectory(result)
      case "restore":
        guard let bookmark = call.arguments as? String else {
          result(nil)
          return
        }
        result(self.restoreCacheDirectory(bookmark))
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func pickCacheDirectory(_ result: @escaping FlutterResult) {
    guard attachedSheet == nil else {
      result(FlutterError(code: "picker_busy", message: nil, details: nil))
      return
    }
    let panel = NSOpenPanel()
    panel.title = "选择离线缓存目录"
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    panel.beginSheetModal(for: self) { [weak self] response in
      guard response == .OK, let url = panel.url, let self = self else {
        result(nil)
        return
      }
      do {
        let data = try url.bookmarkData(
          options: [.withSecurityScope],
          includingResourceValuesForKeys: nil,
          relativeTo: nil
        )
        let bookmark = data.base64EncodedString()
        guard let path = self.restoreCacheDirectory(bookmark) else {
          throw CocoaError(.fileReadNoPermission)
        }
        result(["path": path, "bookmark": bookmark])
      } catch {
        result(FlutterError(code: "directory_access_denied", message: nil, details: nil))
      }
    }
  }

  private func restoreCacheDirectory(_ bookmark: String) -> String? {
    if let path = cacheDirectoryPaths[bookmark] { return path }
    guard let data = Data(base64Encoded: bookmark) else { return nil }
    do {
      var stale = false
      let url = try URL(
        resolvingBookmarkData: data,
        options: [.withSecurityScope, .withoutUI, .withoutMounting],
        relativeTo: nil,
        bookmarkDataIsStale: &stale
      )
      let acquired = url.startAccessingSecurityScopedResource()
      let path = url.resolvingSymlinksInPath().path
      // Keep scopes for old locations open for playback and queue recovery.
      // The process releases them on exit; reselection doesn't acquire duplicates.
      if cacheDirectoryScopes[path] != nil {
        if acquired { url.stopAccessingSecurityScopedResource() }
      } else {
        guard acquired else { return nil }
        cacheDirectoryScopes[path] = url
      }
      cacheDirectoryPaths[bookmark] = path
      return path
    } catch {
      return nil
    }
  }
}
