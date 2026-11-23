import '../platform/app_platform.dart';
import 'image_resource_cache.dart';
import 'media_cache_service.dart';
import 'subscription_service.dart';

/// Preferences owned by runtime services, without their user content.
abstract interface class SettingsRuntimeAdapter {
  Future<Map<String, Object>> readSettings();

  /// Null restores the service default; omitted keys retain their value.
  Future<void> writeSettings(Map<String, Object?> values);
}

class DeviceSettingsRuntimeAdapter implements SettingsRuntimeAdapter {
  const DeviceSettingsRuntimeAdapter({
    this.subscriptions,
    this.imageCache,
    this.mediaCache,
    this.appPlatform,
  });

  static const enabledKey = 'subscriptions.enabled';
  static const notificationsKey = 'subscriptions.notifications_enabled';
  static const backgroundKey = 'subscriptions.background_refresh_enabled';
  static const wifiOnlyBackgroundKey =
      'subscriptions.wifi_only_background_refresh';
  static const imageCapacityKey = 'resource_cache.image_capacity_bytes';
  static const androidMediaCapacityKey = 'android_media_cache_capacity_bytes';

  static const subscriptionKeys = {
    enabledKey,
    notificationsKey,
    backgroundKey,
    wifiOnlyBackgroundKey,
  };
  static const keys = {...subscriptionKeys, imageCapacityKey};
  static const optionalKeys = {androidMediaCapacityKey};
  static const allKeys = {...keys, ...optionalKeys};

  final SubscriptionService? subscriptions;
  final ImageResourceCache? imageCache;
  final MediaCacheService? mediaCache;
  final AppPlatform? appPlatform;

  SubscriptionService get _subscriptions =>
      subscriptions ?? SubscriptionService.instance;
  ImageResourceCache get _images => imageCache ?? ImageResourceCache.instance;
  bool get _managesAndroidMediaCache =>
      mediaCache != null ||
      (appPlatform ?? AppPlatformDetector.current) == AppPlatform.android;
  MediaCacheService get _androidMediaCache =>
      mediaCache ?? NativeMediaCacheService();

  Future<void> _prepareSubscriptions() async {
    await _subscriptions.initialize();
    if (_subscriptions.storageError != null) {
      throw StateError('Subscription settings are unavailable');
    }
  }

  @override
  Future<Map<String, Object>> readSettings() async {
    final flags = await _subscriptions.exportPreferenceFlags();
    final capacity = await _images.readCapacity();
    final result = <String, Object>{
      enabledKey: flags['enabled']!,
      notificationsKey: flags['notificationsEnabled']!,
      backgroundKey: flags['backgroundRefreshEnabled']!,
      wifiOnlyBackgroundKey: flags['wifiOnlyBackgroundRefresh'] ?? false,
      imageCapacityKey: capacity,
    };
    if (_managesAndroidMediaCache) {
      final status = await _androidMediaCache.loadStatus();
      result[androidMediaCapacityKey] = status.capacityBytes;
    }
    return result;
  }

  /// Disable the main switch first and enable it last, preserving the existing
  /// import transaction order before updating image and Android media capacities.
  @override
  Future<void> writeSettings(Map<String, Object?> values) async {
    if (values.keys.any(subscriptionKeys.contains)) {
      await _prepareSubscriptions();
      final enabled = values.containsKey(enabledKey)
          ? values[enabledKey] as bool? ?? false
          : _subscriptions.enabled;
      if (!enabled && _subscriptions.enabled) {
        await _subscriptions.setEnabled(false);
      }
      if (values.containsKey(notificationsKey)) {
        final value = values[notificationsKey] as bool? ?? false;
        if (value != _subscriptions.notificationsEnabled) {
          await _subscriptions.setNotificationsEnabled(value);
        }
      }
      if (values.containsKey(wifiOnlyBackgroundKey)) {
        final value = values[wifiOnlyBackgroundKey] as bool? ?? false;
        if (value != _subscriptions.wifiOnlyBackgroundRefresh) {
          await _subscriptions.setWifiOnlyBackgroundRefresh(value);
        }
      }
      if (values.containsKey(backgroundKey)) {
        final value = values[backgroundKey] as bool? ?? false;
        if (value != _subscriptions.backgroundRefreshEnabled) {
          await _subscriptions.setBackgroundRefreshEnabled(value);
        }
      }
      if (enabled && !_subscriptions.enabled) {
        await _subscriptions.setEnabled(true);
      }
    }
    if (values.containsKey(imageCapacityKey)) {
      await _images.setCapacity(
        values[imageCapacityKey] as int? ?? _images.defaultCapacity,
      );
    }
    if (values.containsKey(androidMediaCapacityKey) &&
        _managesAndroidMediaCache) {
      final target =
          values[androidMediaCapacityKey] as int? ?? defaultMediaCacheBytes;
      final current = await _androidMediaCache.loadStatus();
      if (current.capacityBytes != target) {
        await _androidMediaCache.setCapacityBytes(target);
      }
    }
  }
}
