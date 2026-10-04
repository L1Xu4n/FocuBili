import 'package:flutter/services.dart';

import '../platform/app_platform.dart';

class SubscriptionNotificationService {
  static const _channel = MethodChannel(
    'com.focubili.app/subscription_notifications',
  );
  bool get _available =>
      AppPlatformDetector.current == AppPlatform.android &&
      !AppPlatformDetector.isFlutterTest;
  Future<void> initialize(void Function() onTap) async {
    if (!_available) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'subscriptionTapped') onTap();
    });
    try {
      if (await _channel.invokeMethod<bool>('consumeTap') == true) onTap();
    } on MissingPluginException {
      /* independent UI previews have no platform backend */
    }
  }

  Future<bool> showSummary(int count) async {
    if (!_available) return false;
    try {
      return await _channel.invokeMethod<bool>('showSummary', {
            'count': count,
          }) ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  void dispose() {
    if (_available) _channel.setMethodCallHandler(null);
  }
}
