import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/services/image_resource_cache.dart';
import 'package:focubili/services/settings_runtime_adapter.dart';
import 'package:focubili/services/subscription_service.dart';

class _Subscriptions extends SubscriptionService {
  _Subscriptions(this.events);
  final List<String> events;
  @override
  Future<void> initialize() async => events.add('initialize');
  @override
  Future<void> setEnabled(bool value) async {
    events.add('enabled:$value');
    enabled = value;
  }

  @override
  Future<void> setNotificationsEnabled(bool value) async {
    events.add('notifications:$value');
    notificationsEnabled = value;
  }

  @override
  Future<void> setBackgroundRefreshEnabled(bool value) async {
    events.add('background:$value');
    backgroundRefreshEnabled = value;
  }
}

class _Images extends ImageResourceCache {
  _Images(this.events);
  final List<String> events;
  @override
  Future<ImageCacheUsage> setCapacity(int bytes) async {
    events.add('capacity:$bytes');
    return ImageCacheUsage(0, bytes, 0);
  }
}

void main() {
  for (final enable in [false, true]) {
    test(
      'write preserves ${enable ? 'enable-last' : 'disable-first'} transaction order',
      () async {
        final events = <String>[];
        final subscriptions = _Subscriptions(events)..enabled = !enable;
        final images = _Images(events);
        addTearDown(subscriptions.dispose);
        addTearDown(images.dispose);
        await DeviceSettingsRuntimeAdapter(
          subscriptions: subscriptions,
          imageCache: images,
        ).writeSettings({
          DeviceSettingsRuntimeAdapter.enabledKey: enable,
          DeviceSettingsRuntimeAdapter.notificationsKey: true,
          DeviceSettingsRuntimeAdapter.backgroundKey: true,
          DeviceSettingsRuntimeAdapter.imageCapacityKey: 123,
        });
        expect(events, [
          'initialize',
          if (!enable) 'enabled:false',
          'notifications:true',
          'background:true',
          if (enable) 'enabled:true',
          'capacity:123',
        ]);
      },
    );
  }

  test('capacity-only write does not initialize subscriptions', () async {
    final events = <String>[];
    final subscriptions = _Subscriptions(events);
    final images = _Images(events);
    addTearDown(subscriptions.dispose);
    addTearDown(images.dispose);
    await DeviceSettingsRuntimeAdapter(
      subscriptions: subscriptions,
      imageCache: images,
    ).writeSettings({DeviceSettingsRuntimeAdapter.imageCapacityKey: null});
    expect(events, ['capacity:${images.defaultCapacity}']);
  });
}
