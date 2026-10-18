import 'image_resource_cache.dart';
import 'subscription_service.dart';

/// Preferences owned by runtime services, without their user content.
abstract interface class SettingsRuntimeAdapter {
  Future<Map<String, Object>> readSettings();

  /// Null restores the service default; omitted keys retain their value.
  Future<void> writeSettings(Map<String, Object?> values);
}

class DeviceSettingsRuntimeAdapter implements SettingsRuntimeAdapter {
  const DeviceSettingsRuntimeAdapter({this.subscriptions, this.imageCache});

  static const enabledKey = 'subscriptions.enabled';
  static const notificationsKey = 'subscriptions.notifications_enabled';
  static const backgroundKey = 'subscriptions.background_refresh_enabled';
  static const imageCapacityKey = 'resource_cache.image_capacity_bytes';
  static const subscriptionKeys = {enabledKey, notificationsKey, backgroundKey};
  static const keys = {...subscriptionKeys, imageCapacityKey};
  final SubscriptionService? subscriptions;
  final ImageResourceCache? imageCache;

  SubscriptionService get _subscriptions =>
      subscriptions ?? SubscriptionService.instance;
  ImageResourceCache get _images => imageCache ?? ImageResourceCache.instance;

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
    return {
      enabledKey: flags['enabled']!,
      notificationsKey: flags['notificationsEnabled']!,
      backgroundKey: flags['backgroundRefreshEnabled']!,
      imageCapacityKey: capacity,
    };
  }

  /// Disable the main switch first and enable it last, preserving the existing
  /// import transaction order before updating the image cache capacity.
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
  }
}
