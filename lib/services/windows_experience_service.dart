import 'dart:ui' as ui;
import 'package:flutter/services.dart';

/// Wraps runner-owned Windows operations with a testable typed method channel.
class WindowsExperienceService {
  /// Uses the shared runner channel unless a test supplies an isolated channel.
  const WindowsExperienceService({
    this.channel = const MethodChannel('com.focubili.app/windows_experience'),
  });
  final MethodChannel channel;

  /// Copies actual image pixels in both PNG and widely supported Windows DIB formats.
  Future<void> copyImage({
    required Uint8List png,
    required Uint8List rgba,
    required int width,
    required int height,
  }) => channel.invokeMethod<void>('copyImage', {
    'png': png,
    'rgba': rgba,
    'width': width,
    'height': height,
  });

  /// Converts a rendered image to the same PNG/DIB clipboard contract for every share entry.
  Future<void> copyRenderedImage(
    ui.Image image, {
    required Uint8List png,
  }) async {
    final raw = await image.toByteData(
      format: ui.ImageByteFormat.rawStraightRgba,
    );
    if (raw == null) throw StateError('无法读取图片像素。');
    await copyImage(
      png: png,
      rgba: raw.buffer.asUint8List(raw.offsetInBytes, raw.lengthInBytes),
      width: image.width,
      height: image.height,
    );
  }

  /// Marks fullscreen and skips bottom taskbar trigger pixels while retaining monitor exits.
  Future<void> setFullscreenProtection(bool enabled) async {
    await channel.invokeMethod<bool>('setFullscreenProtection', {
      'enabled': enabled,
    });
  }
}
