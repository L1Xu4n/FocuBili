import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:focubili/features/subscriptions/subscription_updates_page.dart';
import 'package:focubili/models/subscription.dart';
import 'package:focubili/services/subscription_service.dart';
import 'package:focubili/services/cache_lifecycle.dart';
import 'package:focubili/services/subscription_source_visits.dart';
import 'subscription_service_test.dart' show Content;
import 'subscription_performance_probe_test.dart'
    show CountingSnapshots, feedFixture;
import 'package:focubili/features/subscriptions/subscription_source_rail.dart';

class RejectOnce extends InMemorySharedPreferencesStore {
  RejectOnce() : super.withData({});
  bool refuse = true;
  @override
  Future<bool> setValue(String type, String key, Object value) async {
    if (key.contains('source_visits') && refuse) {
      refuse = false;
      return false;
    }
    return super.setValue(type, key, value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await CacheLifecycle.setAccount(null);
  });
  test(
    'a rejected source acknowledgement cannot appear in the next read or get committed by an unrelated successful source tap',
    () async {
      final disk = RejectOnce();
      SharedPreferencesStorePlatform.instance = disk;
      final scope = CacheLifecycle.accountScope,
          r = CacheLifecycle.account.value;
      Future<void> ack(String s) => SubscriptionSourceVisits.acknowledge(
        scope: scope,
        revision: r,
        source: s,
        presented: {'event-$s'},
        liveSources: {'A', 'B'},
        retainedEvents: {'event-A', 'event-B'},
        stillVisible: () => true,
      );
      await expectLater(ack('A'), throwsA(isA<StateError>()));
      final afterFailed = await SubscriptionSourceVisits.load(scope);
      await ack('B');
      final afterB = await disk.getAll();
      final visits =
          jsonDecode(
                afterB['flutter.subscription_source_visits_v1/$scope']!
                    as String,
              )
              as Map;
      expect(afterFailed, isNot(contains('A')));
      expect(visits, isNot(contains('A')));
      expect(visits['B'], ['event-B']);
    },
  );
  for (final filter in ['仅未读', '今日发布']) {
    testWidgets(
      'source tap acknowledges only rows shown by the active $filter filter',
      (t) async {
        final data = jsonDecode(feedFixture(count: 2, sourceCount: 1)) as Map;
        final now = DateTime.now(), y = now.subtract(const Duration(days: 1));
        for (final (i, raw) in (data['feed'] as List).indexed) {
          final r = raw as Map;
          r['coverUrl'] = '';
          r['title'] = i == 0 ? 'visible title' : 'hidden title';
          r['discoveredAt'] = now
              .subtract(Duration(minutes: i))
              .toIso8601String();
          r['publishedAt'] = (i == 1 ? y : now).toIso8601String();
          r['readAt'] = i == 1 ? now.toIso8601String() : null;
        }
        final s = SubscriptionService(
          snapshotStore: CountingSnapshots()..value = jsonEncode(data),
          contentService: Content(),
        );
        addTearDown(s.dispose);
        await s.initialize();
        expect(s.feed, hasLength(2));
        await t.pumpWidget(
          MaterialApp(
            builder: (ctx, child) => MediaQuery(
              data: MediaQuery.of(ctx).copyWith(disableAnimations: true),
              child: child!,
            ),
            home: SubscriptionUpdatesPage(service: s),
          ),
        );
        await t.pumpAndSettle();
        expect(find.text('hidden title'), findsOneWidget);
        await t.tap(find.text(filter));
        await t.pumpAndSettle();
        expect(find.text('hidden title'), findsNothing);
        expect(find.text('visible title'), findsOneWidget);
        final chip = find.byKey(
          ValueKey('source-filter-${s.sources.single.key}'),
        );
        await t.tap(chip);
        await t.pumpAndSettle();
        final seen = await SubscriptionSourceVisits.load(
          CacheLifecycle.accountScope,
        );
        final confirmed =
            seen[SubscriptionSourceVisits.identity(s.sources.single)] ??
            <String>{};
        expect(confirmed, {
          SubscriptionSourceVisits.event(
            s.feed.singleWhere((i) => i.title == 'visible title'),
          ),
        });
        await t.tap(find.text(filter));
        await t.pumpAndSettle();
        expect(
          find.descendant(
            of: chip,
            matching: find.byKey(const Key('source-new-dot')),
          ),
          findsOneWidget,
        );
        await t.pumpWidget(const SizedBox());
      },
    );
  }
  testWidgets(
    'mouse drag across many sources changes only horizontal offset, no acknowledgement',
    (t) async {
      final sources = List.generate(
        28,
        (i) => SubscriptionSource(
          kind: SubscriptionKind.creator,
          mid: i + 1,
          name: 'Long creator ${i + 1}',
          token: 'gen$i',
        ),
      );
      final feed = [
        SubscriptionFeedItem(
          bvid: 'test',
          title: 'title',
          coverUrl: '',
          discoveredAt: DateTime.now(),
          sources: {sources[14].key: sources[14].name},
        ),
      ];
      String? selected;
      int taps = 0;
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MediaQuery(
              data: const MediaQueryData(
                size: Size(300, 600),
                accessibleNavigation: true,
              ),
              child: SizedBox(
                height: 90,
                width: 300,
                child: SubscriptionSourceRail(
                  sources: sources,
                  visibleFeed: feed,
                  retainedFeed: feed,
                  actionsReady: true,
                  selected: selected,
                  onSelect: (k) {
                    taps++;
                    selected = k;
                  },
                ),
              ),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      final rail = find.byKey(const Key('subscription-source-filters'));
      final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
      final o = t.getTopLeft(rail) + const Offset(230, 40);
      await mouse.addPointer(location: o);
      await mouse.down(o);
      await mouse.moveBy(const Offset(-160, 0));
      await mouse.moveBy(const Offset(-45, 0));
      await mouse.up();
      await mouse.removePointer();
      await t.pumpAndSettle();
      expect(
        t
            .state<ScrollableState>(
              find.descendant(of: rail, matching: find.byType(Scrollable)),
            )
            .position
            .pixels,
        greaterThan(0),
      );
      expect(taps, 0);
      expect(
        await SubscriptionSourceVisits.load(CacheLifecycle.accountScope),
        isEmpty,
      );
      expect(t.binding.transientCallbackCount, 0);
      await t.pumpWidget(const SizedBox());
    },
  );
}
