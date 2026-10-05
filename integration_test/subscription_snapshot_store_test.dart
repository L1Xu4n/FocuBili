import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:focubili/services/subscription_snapshot_store.dart';

/// Run on Android: flutter test integration_test/subscription_snapshot_store_test.dart -d DEVICE.
/// Isolated test database; never reads/writes the user's subscription/learning data.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'SQLite serializes independent service connections and rolls back',
    (_) async {
      final name =
          'subscription_test_${DateTime.now().microsecondsSinceEpoch}.db';
      final first = SqliteSubscriptionSnapshotStore(databaseName: name);
      final second = SqliteSubscriptionSnapshotStore(databaseName: name);
      addTearDown(first.close);
      addTearDown(second.close);
      await first.transact((current, save) => save(jsonEncode({'count': 0})));
      Future<void> increment(SubscriptionSnapshotStore store) =>
          store.transact((current, save) async {
            final value = jsonDecode(current!) as Map<String, dynamic>;
            await Future<void>.delayed(const Duration(milliseconds: 5));
            value['count'] = (value['count'] as int) + 1;
            save(jsonEncode(value));
          });
      await Future.wait(
        List.generate(20, (i) => increment(i.isEven ? first : second)),
      );
      expect((jsonDecode((await first.read())!) as Map)['count'], 20);
      await expectLater(
        first.transact<void>((current, save) {
          save('{"count":999}');
          throw StateError('simulated failure before commit');
        }),
        throwsStateError,
      );
      expect((jsonDecode((await second.read())!) as Map)['count'], 20);
      final restarted = SqliteSubscriptionSnapshotStore(databaseName: name);
      addTearDown(restarted.close);
      expect(await restarted.read(), await second.read());
    },
  );
}
