import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/features/subscriptions/subscription_source_rail.dart';
import 'package:focubili/models/subscription.dart';
import 'package:focubili/services/cache_lifecycle.dart';
import 'package:focubili/services/subscription_source_visits.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const a = SubscriptionSource(
    kind: SubscriptionKind.creator,
    mid: 1,
    name: '甲',
    token: 'a',
  );
  const b = SubscriptionSource(
    kind: SubscriptionKind.collection,
    mid: 2,
    seasonId: 3,
    name: '乙',
    token: 'b',
  );
  final time = DateTime(2026, 11, 18, 10);
  SubscriptionFeedItem row(
    String bv,
    int mins,
    List<SubscriptionSource> sources,
  ) => SubscriptionFeedItem(
    bvid: bv,
    title: bv,
    coverUrl: '',
    discoveredAt: time.add(Duration(minutes: mins)),
    sources: {for (final s in sources) s.key: s.name},
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await CacheLifecycle.setAccount(null);
  });
  tearDown(() => CacheLifecycle.setAccount(null));

  testWidgets(
    'source visits survive reopen, isolate accounts and source generations, new events relight without marking videos read',
    (tester) async {
      var feed = [
        row('v1', 0, [a, b]),
        row('v2', 1, [b]),
      ];
      var sources = [a, b];
      var hidden = <String>{};
      var reduced = false;
      var scopeReady = true;
      String? selection;
      Future<void> render() async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: MediaQuery(
                data: MediaQueryData(
                  size: const Size(400, 800),
                  disableAnimations: reduced,
                ),
                child: SizedBox(
                  height: 56,
                  child: SubscriptionSourceRail(
                    sources: sources,
                    retainedFeed: feed,
                    visibleFeed: feed
                        .where((v) => !hidden.contains(v.bvid))
                        .toList(),
                    actionsReady: scopeReady,
                    selected: selection,
                    onSelect: (s) => selection = s,
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      final dot = find.byKey(const Key('source-new-dot'));
      Finder chip(SubscriptionSource s) =>
          find.byKey(ValueKey('source-filter-${s.key}'));
      Finder chipDot(SubscriptionSource s) =>
          find.descendant(of: chip(s), matching: dot);
      await render();
      expect(dot, findsNWidgets(2));
      expect(
        tester.getTopLeft(chip(b)).dx,
        lessThan(tester.getTopLeft(chip(a)).dx),
      );
      await tester.tap(chip(b));
      await tester.pumpAndSettle();
      expect(selection, b.key);
      expect(chipDot(b), findsNothing);
      expect(chipDot(a), findsOneWidget);
      expect(feed.every((v) => v.readAt == null), isTrue);
      await tester.pumpWidget(const SizedBox());
      await render();
      expect(chipDot(b), findsNothing);
      // A renamed item/mark-read is not a new discovery. The same update added
      // to two sources can nevertheless be acknowledged independently.
      feed = [feed.first.copyWith(readAt: time), feed.last];
      await render();
      expect(chipDot(b), findsNothing);
      feed = [
        ...feed,
        row('v3', 2, [b]),
      ];
      hidden = {'v3'};
      await render();
      expect(chipDot(b), findsNothing);
      hidden = {};
      await render();
      expect(chipDot(b), findsOneWidget);
      await CacheLifecycle.setAccount(123);
      await tester.pumpAndSettle();
      expect(selection, isNull);
      expect(chipDot(b), findsOneWidget);
      await tester.tap(chip(b));
      await tester.pumpAndSettle();
      expect(chipDot(b), findsNothing);
      await CacheLifecycle.setAccount(null);
      await tester.pumpAndSettle();
      expect(chipDot(b), findsOneWidget);
      // Pruning the only unvisited update removes the signal.
      feed = feed.take(2).toList();
      await render();
      expect(chipDot(b), findsNothing);
      sources = [
        a,
        const SubscriptionSource(
          kind: SubscriptionKind.collection,
          mid: 2,
          seasonId: 3,
          name: '乙',
          token: 'new-subscription',
        ),
      ];
      await render();
      expect(chipDot(b), findsOneWidget);
      scopeReady = false;
      await render();
      expect(dot, findsNothing);
      reduced = true;
      scopeReady = true;
      await render();
      expect(dot, findsNWidgets(2));
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'horizontally scrolls, long full source names are accessible, tapping all acknowledges nothing',
    (tester) async {
      final sources = List.generate(
        12,
        (i) => SubscriptionSource(
          kind: SubscriptionKind.creator,
          mid: i + 1,
          token: 's$i',
          name: '很长的第 ${i + 1} 个订阅来源',
        ),
      );
      final feed = [
        row('x', 0, [sources.last]),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 300,
              height: 64,
              child: SubscriptionSourceRail(
                sources: sources,
                visibleFeed: feed,
                retainedFeed: feed,
                selected: null,
                actionsReady: true,
                onSelect: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.bySemanticsLabel('${sources.last.name}，有新更新'),
        findsOneWidget,
      );
      await tester.tap(find.text('全部来源'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('source-new-dot')), findsOneWidget);
      final rail = find.byKey(const Key('subscription-source-filters'));
      await tester.drag(rail, const Offset(-640, 0));
      await tester.pumpAndSettle();
      expect(
        tester
            .state<ScrollableState>(
              find.descendant(of: rail, matching: find.byType(Scrollable)),
            )
            .position
            .pixels,
        greaterThan(0),
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  test(
    'a stale account write cannot acknowledge the new account or overwrite the old scope',
    () async {
      final revision = CacheLifecycle.account.value;
      final pending = SubscriptionSourceVisits.acknowledge(
        scope: 'guest',
        revision: revision,
        source: 's',
        presented: {'v'},
        liveSources: {'s'},
        retainedEvents: {'v'},
        stillVisible: () => true,
      );
      await CacheLifecycle.setAccount(42);
      await pending;
      expect(await SubscriptionSourceVisits.load('guest'), isEmpty);
      expect(await SubscriptionSourceVisits.load('mid:42'), isEmpty);
    },
  );
}
