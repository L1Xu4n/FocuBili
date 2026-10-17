import 'package:flutter/services.dart';

import '../platform/app_platform.dart';
import '../models/subscription.dart';
import 'windows_focus_notification_service.dart';
import 'linux_focus_notification_service.dart';
import 'subscription_notification_delivery.dart';

class SubscriptionNotificationService {
  SubscriptionNotificationService({
    MethodChannel? channel,
    AppPlatform? platform,
    WindowsFocusNotificationBackend? desktopBackend,
  }) : _channel =
           channel ??
           const MethodChannel('com.focubili.app/subscription_notifications'),
       _platform = platform,
       _desktopBackend = desktopBackend,
       _injectedChannel = channel != null;
  final MethodChannel _channel;
  final AppPlatform? _platform;
  final WindowsFocusNotificationBackend? _desktopBackend;
  final bool _injectedChannel;
  AppPlatform get platform => _platform ?? AppPlatformDetector.current;
  bool get _available =>
      (platform == AppPlatform.android || platform.isApple) &&
      (_injectedChannel || !AppPlatformDetector.isFlutterTest);
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

  Future<bool> showSummary(
    int count, {
    int? generation,
    bool background = false,
    String? title,
    String? source,
  }) async {
    if (!_available) return false;
    try {
      if (!SubscriptionNotificationDelivery.allows(
        SubscriptionNotificationDelivery.current,
      )) {
        return false;
      }
      return await _channel.invokeMethod<bool>('showSummary', {
            'count': count,
            'generation': ?generation,
            'background': background,
            'title': ?title,
            'source': ?source,
          }) ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<bool> showItems(
    List<SubscriptionFeedItem> items, {
    int? generation,
    bool background = false,
  }) async {
    if (items.isEmpty) return false;
    final item = items.first;
    final title = item.title;
    final source = '来自${item.sources.values.join(' · ')}';
    final allowDelivery = SubscriptionNotificationDelivery.current;
    if (platform == AppPlatform.windows || platform == AppPlatform.linux) {
      final backend =
          _desktopBackend ??
          (platform == AppPlatform.windows
              ? WindowsFocusNotificationBackend.instance
              : LinuxFocusNotificationBackend.instance);
      return backend.showSubscriptionUpdate(
        title: title,
        source: source,
        count: items.length,
        allowDelivery: allowDelivery,
      );
    }
    return showSummary(
      items.length,
      generation: generation,
      background: background,
      title: title,
      source: source,
    );
  }

  void dispose() {
    if (_available) _channel.setMethodCallHandler(null);
  }
}
