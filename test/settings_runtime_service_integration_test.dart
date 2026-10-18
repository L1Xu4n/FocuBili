import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/models/subscription.dart';
import 'package:focubili/services/image_resource_cache.dart';
import 'package:focubili/services/settings_runtime_adapter.dart';
import 'package:focubili/services/subscription_service.dart';

/// 用合成订阅及临时缓存验证设置重置走服务入口，保留源与持久化容量。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('运行期设置往返和重置保留订阅源并撤销后台调度', () async {
    SharedPreferences.setMockInitialValues({});
    final directory = await Directory.systemTemp.createTemp(
      'focubili-settings-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final schedules = <bool>[];
    final subscriptions = SubscriptionService(
      preferencesLoader: SharedPreferences.getInstance,
      backgroundScheduler: (enabled, generation) async =>
          schedules.add(enabled),
    );
    addTearDown(subscriptions.dispose);
    final imageDirectory = Directory('${directory.path}/focubili_images_v1');
    final images = ImageResourceCache(directory: () async => imageDirectory);
    addTearDown(images.dispose);
    final adapter = DeviceSettingsRuntimeAdapter(
      subscriptions: subscriptions,
      imageCache: images,
    );
    await subscriptions.initialize();
    await subscriptions.addSource(
      const SubscriptionSource(
        kind: SubscriptionKind.creator,
        mid: 7,
        name: '合成订阅源',
        token: 'synthetic-source',
      ),
    );
    await adapter.writeSettings({
      DeviceSettingsRuntimeAdapter.enabledKey: true,
      DeviceSettingsRuntimeAdapter.notificationsKey: true,
      DeviceSettingsRuntimeAdapter.backgroundKey: true,
      DeviceSettingsRuntimeAdapter.imageCapacityKey: 128 * 1024 * 1024,
    });
    final exported = await adapter.readSettings();
    expect(exported[DeviceSettingsRuntimeAdapter.enabledKey], isTrue);
    expect(exported[DeviceSettingsRuntimeAdapter.backgroundKey], isTrue);
    expect(exported.toString(), isNot(contains('synthetic-source')));
    await adapter.writeSettings({
      for (final key in DeviceSettingsRuntimeAdapter.keys) key: null,
    });
    expect(subscriptions.enabled, isFalse);
    expect(subscriptions.notificationsEnabled, isFalse);
    expect(subscriptions.backgroundRefreshEnabled, isFalse);
    expect(subscriptions.sources.single.key, 'creator:7');
    expect(schedules.last, isFalse);
    expect((await images.status()).capacityBytes, images.defaultCapacity);
    await adapter.writeSettings(exported);
    expect(subscriptions.enabled, isTrue);
    expect(subscriptions.sources.single.key, 'creator:7');
    final reopenedImages = ImageResourceCache(
      directory: () async => imageDirectory,
    );
    addTearDown(reopenedImages.dispose);
    expect((await reopenedImages.status()).capacityBytes, 128 * 1024 * 1024);
  });
}
