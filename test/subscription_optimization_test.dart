import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/services/subscription_service.dart';
import 'subscription_performance_probe_test.dart'
    show CountingSnapshots, feedFixture;
import 'subscription_service_test.dart' show Content, item;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
    'cached feed survives unchanged reload; changes and rollback invalidate it',
    () async {
      final store = CountingSnapshots()..value = feedFixture(count: 5);
      final ui = SubscriptionService(snapshotStore: store);
      final worker = SubscriptionService(snapshotStore: store);
      addTearDown(ui.dispose);
      addTearDown(worker.dispose);
      await ui.initialize();
      await worker.initialize();
      var changes = 0;
      ui.addListener(() => changes++);
      final cached = ui.feed;
      for (var i = 0; i < 10; i++) {
        await ui.reload();
      }
      expect(identical(ui.feed, cached), isTrue);
      expect(changes, 0);
      await worker.markRead('fixture0');
      await ui.reload();
      expect(ui.unreadCount, 4);
      expect(ui.feed.first.readAt, isNotNull);
      expect(changes, 1);
      final readAt = ui.feed.first.readAt;
      store.resetCounts();
      await ui.markRead('fixture0');
      expect(store.saves, 0);
      expect(ui.feed.first.readAt, readAt);
      store.failCommit = true;
      await expectLater(
        ui.markAllRead(),
        throwsA(isA<SubscriptionStorageException>()),
      );
      expect(ui.unreadCount, 4);
      expect(ui.feed.first.readAt, readAt);
      store.failCommit = false;
      // Corrupt only a late field to exercise partial restore rollback.
      final valid = store.value!;
      final corrupt = jsonDecode(valid) as Map<String, dynamic>;
      corrupt['feed'] = [];
      corrupt['announced'] = null;
      store.value = jsonEncode(corrupt);
      await expectLater(
        ui.reload(),
        throwsA(isA<SubscriptionStorageException>()),
      );
      expect(ui.feed.length, 5);
      expect(ui.unreadCount, 4);
      store.value = valid;
      await ui.reload();
      expect(ui.storageError, isNull);
    },
  );
  test('checkpoint-only scans preserve the sorted feed view', () async {
    final store = CountingSnapshots()
      ..value = feedFixture(count: 5, sourceCount: 2);
    final content = Content()
      ..pages[1] = [
        [item('old1')],
      ]
      ..pages[2] = [
        [item('old2')],
      ];
    final service = SubscriptionService(
      snapshotStore: store,
      contentService: content,
    );
    addTearDown(service.dispose);
    await service.initialize();
    final before = service.feed;
    service.setForeground(true);
    await service.refresh(manual: true);
    expect(content.calls.length, 2);
    expect(identical(service.feed, before), isTrue);
  });
}
