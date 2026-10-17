import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/models/subscription.dart';
import 'package:focubili/platform/app_platform.dart';
import 'package:focubili/services/image_resource_cache.dart';
import 'package:focubili/services/native_subscription_scheduler.dart';
import 'package:focubili/services/settings_runtime_adapter.dart';
import 'package:focubili/services/settings_transfer_service.dart';
import 'package:focubili/services/subscription_service.dart';

import 'native_subscription_background_test.dart' show nativeCall;
import 'subscription_background_test.dart' show AtomicSnapshots;

/// Exercise the real settings/service/native-channel path with synthetic data.
/// The atomic fixture models shared mobile storage; it is not a native SQL test.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  for (final platform in [AppPlatform.windows, AppPlatform.ios]) {
    test('${platform.name} 设置导入及重置同步原生代次并保留权威订阅源', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final directory = await Directory.systemTemp.createTemp(
        'focubili-native-settings-',
      );
      final channel = MethodChannel('test/settings-native-${platform.name}');
      final configurations = <Map<Object?, Object?>>[];
      var available = true;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'configure') {
          configurations.add(Map<Object?, Object?>.from(call.arguments as Map));
        }
        return {
          'available': available,
          'accepted': true,
          'mode': 'process',
          'status': 'ready',
        };
      });
      final native = NativeSubscriptionScheduler(
        platform: platform,
        channel: channel,
      );
      final store = AtomicSnapshots();
      final subscriptions = SubscriptionService(
        preferencesLoader: () async => prefs,
        snapshotStore: store,
        platform: platform,
        nativeScheduler: native,
      );
      final images = ImageResourceCache(
        directory: () async =>
            Directory('${directory.path}/focubili_images_v1'),
      );
      addTearDown(() async {
        await native.dispose();
        subscriptions.dispose();
        images.dispose();
        messenger.setMockMethodCallHandler(channel, null);
        await directory.delete(recursive: true);
      });
      await subscriptions.initialize();
      // Retained pre-migration preferences must not override the atomic store.
      final legacy = store.value!;
      await prefs.setString(SubscriptionService.storageKey, legacy);
      await subscriptions.addSource(
        const SubscriptionSource(
          kind: SubscriptionKind.creator,
          mid: 7,
          name: 'Synthetic source',
          token: 'synthetic-only',
        ),
      );
      final transfer = SettingsTransferService(
        preferencesLoader: () async => prefs,
        runtimeAdapter: DeviceSettingsRuntimeAdapter(
          subscriptions: subscriptions,
          imageCache: images,
        ),
      );
      await transfer.importSettings({
        DeviceSettingsRuntimeAdapter.enabledKey: true,
        DeviceSettingsRuntimeAdapter.notificationsKey: true,
        DeviceSettingsRuntimeAdapter.backgroundKey: true,
      });
      expect(configurations.last['enabled'], isTrue);
      expect(configurations.last['generation'], store.generation);
      final beforeReset = store.generation;
      final exported = await transfer.exportSettings();
      expect(
        transfer.parseSettings(
          exported,
        )[DeviceSettingsRuntimeAdapter.enabledKey],
        isTrue,
      );
      expect(exported, isNot(contains('synthetic-only')));
      expect(prefs.getString(SubscriptionService.storageKey), legacy);
      await transfer.resetSettings();
      expect(configurations.last['enabled'], isFalse);
      expect(configurations.last['generation'], store.generation);
      expect(store.generation, greaterThan(beforeReset));
      expect(subscriptions.sources.single.key, 'creator:7');
      expect((jsonDecode(store.value!) as Map)['enabled'], isFalse);
      expect(
        await nativeCall(channel, 'check', {'generation': beforeReset}),
        isFalse,
      );
      await transfer.importSettings(transfer.parseSettings(exported));
      expect(configurations.last['enabled'], isTrue);
      expect(configurations.last['generation'], store.generation);
      expect(subscriptions.sources.single.key, 'creator:7');
      // Losing system support must not prevent reset or leave a native request on.
      available = false;
      await transfer.resetSettings();
      expect(configurations.last['enabled'], isFalse);
      expect(subscriptions.backgroundRefreshEnabled, isFalse);
      expect(subscriptions.sources.single.key, 'creator:7');
      expect(prefs.getString(SubscriptionService.storageKey), legacy);
    });
  }
}
