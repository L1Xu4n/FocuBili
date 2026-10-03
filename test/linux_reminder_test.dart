import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/services/linux_focus_notification_service.dart';

class _Client extends LinuxNotificationClient {
  _Client(Future<bool> Function(String) save)
    : super(saveDeadlines: save, cancelNotification: (_) async {});
  final List<int> shown = [];
  @override
  Future<void> show({
    required int id,
    required String title,
    required String body,
  }) async {
    shown.add(id);
  }
}

void main() {
  testWidgets(
    'cancel while deadline persistence is pending cannot show old reminder',
    (tester) async {
      var writes = 0;
      final gate = Completer<bool>();
      final client = _Client((_) {
        writes++;
        return writes == 2 ? gate.future : Future.value(true);
      });
      await client.schedule(
        id: 1,
        title: 'test',
        body: 'test',
        scheduledAt: DateTime.now().add(const Duration(milliseconds: 100)),
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(writes, 2);
      final cancelled = client.cancel(1);
      gate.complete(true);
      await cancelled;
      await tester.pump();
      expect(client.shown, isEmpty);
    },
  );
  testWidgets('failed durable schedule cancels its timer', (tester) async {
    final client = _Client((_) async => false);
    await expectLater(
      client.schedule(
        id: 2,
        title: 'test',
        body: 'test',
        scheduledAt: DateTime.now().add(const Duration(milliseconds: 100)),
      ),
      throwsStateError,
    );
    await tester.pump(const Duration(milliseconds: 200));
    expect(client.shown, isEmpty);
  });
  testWidgets(
    'expired reminder still delivers when cleanup persistence fails',
    (tester) async {
      var writes = 0;
      final client = _Client((_) async => ++writes == 1);
      await client.schedule(
        id: 3,
        title: 'test',
        body: 'test',
        scheduledAt: DateTime.now().add(const Duration(milliseconds: 100)),
      );
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump();
      expect(client.shown, [3]);
    },
  );
}
