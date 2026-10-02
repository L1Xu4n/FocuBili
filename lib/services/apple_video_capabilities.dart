import 'package:flutter/services.dart';
import 'package:media_kit_video/media_kit_video.dart';
import '../platform/app_platform.dart';

/// Probe before creating a macOS video texture. Upstream's OpenGL path force
/// unwraps the pixel format, which is absent on some virtual/headless Macs.
abstract final class AppleVideoCapabilities {
  static bool _hardware = true;
  static Future<void>? _initialization;
  static Future<void> initialize() => _initialization ??= _probe();

  static Future<void> _probe() async {
    if (AppPlatformDetector.current != AppPlatform.macos) return;
    try {
      _hardware =
          await const MethodChannel(
            'com.focubili.app/apple_media',
          ).invokeMethod<bool>('supportsHardwareVideo') ??
          false;
    } on PlatformException {
      _hardware = false;
    } on MissingPluginException {
      _hardware = false;
    }
  }

  static VideoControllerConfiguration get configuration =>
      VideoControllerConfiguration(enableHardwareAcceleration: _hardware);
}
