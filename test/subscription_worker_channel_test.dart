import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:workmanager/workmanager.dart';

import 'package:focubili/services/subscription_background_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'worker installs its callback before notifying Android and returns retry decisions',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const hostChannel = BasicMessageChannel<Object?>(
        'dev.flutter.pigeon.workmanager_platform_interface.WorkmanagerHostApi.notifyBackgroundChannelInitialized',
        WorkmanagerHostApi.pigeonChannelCodec,
      );
      const taskChannel =
          'dev.flutter.pigeon.workmanager_platform_interface.WorkmanagerFlutterApi.executeTask';
      const codec = WorkmanagerFlutterApi.pigeonChannelCodec;
      final received = <(String, Map<String, dynamic>?)>[];
      final firstReply = Completer<Object?>();

      Future<Object?> deliverTask(int generation) async {
        final reply = await messenger.handlePlatformMessage(
          taskChannel,
          codec.encodeMessage(<Object?>[
            SubscriptionBackgroundScheduler.taskName,
            <String, Object?>{'generation': generation},
          ]),
          null,
        );
        return codec.decodeMessage(reply);
      }

      addTearDown(() {
        messenger.setMockDecodedMessageHandler(hostChannel, null);
        WorkmanagerFlutterApi.setUp(null);
      });
      messenger.setMockDecodedMessageHandler<Object?>(hostChannel, (_) async {
        // The native worker can send work immediately after the readiness signal.
        firstReply.complete(await deliverTask(17));
        return <Object?>[null];
      });

      Workmanager().executeTask((task, data) async {
        received.add((task, data));
        return data?['generation'] == 17;
      });

      expect(await firstReply.future.timeout(const Duration(seconds: 5)), [
        true,
      ]);
      expect(await deliverTask(18), [false]);
      expect(received.map((call) => call.$1), [
        SubscriptionBackgroundScheduler.taskName,
        SubscriptionBackgroundScheduler.taskName,
      ]);
      expect(received.map((call) => call.$2), [
        {'generation': 17},
        {'generation': 18},
      ]);
    },
  );
}
