import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/features/subscriptions/subscription_updates_page.dart';
import 'package:focubili/models/public_profile.dart';
import 'package:focubili/models/subscription.dart';
import 'package:focubili/services/subscription_service.dart';

import 'subscription_service_test.dart' show Content, item, source;
import 'subscription_background_test.dart' show AtomicSnapshots;

class CountingSnapshots extends AtomicSnapshots {
  int reads = 0, transactions = 0, saves = 0;
  @override
  Future<String?> read() {
    reads++;
    return super.read();
  }

  @override
  Future<T> transact<T>(
    FutureOr<T> Function(String?, void Function(String)) action,
  ) {
    transactions++;
    return super.transact(
      (current, save) => action(current, (value) {
        saves++;
        save(value);
      }),
    );
  }

  void resetCounts() {
    reads = transactions = saves = 0;
  }
}

class CountingContent extends Content {
  int active = 0, maximumActive = 0;
  @override
  Future<CreatorContentPage<CreatorVideo>> page(int mid, int index) async {
    active++;
    if (active > maximumActive) maximumActive = active;
    await Future<void>.delayed(Duration.zero);
    try {
      return await super.page(mid, index);
    } finally {
      active--;
    }
  }
}

String feedFixture({int count = 500, int sourceCount = 20}) {
  final now = DateTime(2026, 10, 10, 12);
  return jsonEncode({
    'version': 1,
    'enabled': true,
    'notificationsEnabled': false,
    'backgroundRefreshEnabled': false,
    'generation': 1,
    'sources': [for (var i = 1; i <= sourceCount; i++) source(i).toJson()],
    'checkpoints': {
      for (var i = 1; i <= sourceCount; i++)
        source(i).key: SourceCheckpoint(
          initialized: true,
          seen: {'old$i'},
          lastSuccess: now.subtract(const Duration(hours: 2)),
        ).toJson(),
    },
    'feed': [
      for (var i = 0; i < count; i++)
        SubscriptionFeedItem(
          bvid: 'fixture$i',
          title: '第 $i 课 · 从基础开始理解知识，建立持续学习的方法',
          coverUrl: '',
          sources: const {'creator:1': '学习频道'},
          discoveredAt: now.subtract(Duration(minutes: i)),
          publishedAt: now.subtract(Duration(hours: i)),
        ).toJson(),
    ],
    'announced': [],
    'notificationClaims': [],
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final report = <String, Object?>{};
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDownAll(() {
    const output = String.fromEnvironment('PERF_OUTPUT');
    if (output.isNotEmpty) {
      File(output).writeAsStringSync(
        '${const JsonEncoder.withIndent('  ').convert(report)}\n',
      );
    }
  });
  test('reproducible snapshot, reload and request counters', () async {
    final store = CountingSnapshots()..value = feedFixture();
    final content = CountingContent();
    for (var i = 1; i <= 20; i++) {
      content.pages[i] = [
        [item('old$i')],
      ];
    }
    final service = SubscriptionService(
      snapshotStore: store,
      contentService: content,
      clock: () => DateTime(2026, 10, 10, 12),
    );
    addTearDown(service.dispose);
    await service.initialize();
    final identities = Set<List<SubscriptionFeedItem>>.identity();
    final timer = Stopwatch()..start();
    for (var i = 0; i < 1000; i++) {
      identities.add(service.feed);
      expect(service.unreadCount, 500);
    }
    timer.stop();
    report['1000_feed_reads'] = {
      'distinct_sorted_lists': identities.length,
      'microseconds_including_assertions': timer.elapsedMicroseconds,
    };
    var notifications = 0;
    service.addListener(() => notifications++);
    store.resetCounts();
    for (var i = 0; i < 100; i++) {
      await service.reload();
    }
    report['100_unchanged_reloads'] = {
      'reads': store.reads,
      'transactions': store.transactions,
      'save_callbacks': store.saves,
      'notifications': notifications,
    };
    service.setForeground(true);
    await Future.wait(List.generate(20, (_) => service.refresh(manual: true)));
    expect(content.calls.length, 20);
    expect(content.maximumActive, lessThanOrEqualTo(2));
    report['20_simultaneous_refresh_calls'] = {
      'requests': content.calls.length,
      'max_in_flight': content.maximumActive,
    };
    notifications = 0;
    content.calls.clear();
    for (var i = 0; i < 100; i++) {
      await service.refresh();
    }
    report['100_automatic_refreshes_within_hour'] = {
      'requests': content.calls.length,
      'notifications': notifications,
    };
    expect(content.calls, isEmpty);
  });
  testWidgets('500 item list builds only visible rows', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = CountingSnapshots()..value = feedFixture();
    final service = SubscriptionService(snapshotStore: store);
    addTearDown(service.dispose);
    await service.initialize();
    await tester.pumpWidget(
      MaterialApp(home: SubscriptionUpdatesPage(service: service)),
    );
    await tester.pumpAndSettle();
    final delegate = tester
        .widget<SliverList>(find.byType(SliverList).first)
        .delegate;
    final mountedRows = find.byType(Card).evaluate().length;
    final preconstructed = delegate is SliverChildListDelegate
        ? delegate.children.whereType<Card>().length
        : mountedRows;
    report['500_item_feed_390x844'] = {
      'preconstructed_card_widgets': preconstructed,
      'mounted_rows': mountedRows,
      'delegate': delegate.runtimeType.toString(),
    };
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
