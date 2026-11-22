import 'package:focubili/models/subscription.dart';
import 'package:focubili/services/subscription_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'subscription_service_test.dart' show Content;

const _bv = 'BV1aa411c7ab';
const _old = 'BV2aa411c7ab';

Map<String, Object?> _source(int mid, {String? name}) => {
  'kind': 'creator',
  'mid': mid,
  'seasonId': null,
  'name': name ?? 'UP $mid',
  'paused': false,
  'imageUrl': 'https://i0.hdslb.com/avatar.png?token=private',
};

Map<String, Object?> _row(String id, DateTime when) => SubscriptionFeedItem(
  bvid: id,
  title: '学习视频',
  coverUrl: 'https://example.org/never-fetch.png',
  sources: const {'creator:42': 'UP 42'},
  discoveredAt: when,
  readAt: when,
).toJson();

Map<String, dynamic> _export(DateTime now) => {
  'format': 'focubili.subscriptions',
  'version': 1,
  'enabled': true,
  'notificationsEnabled': true,
  'backgroundRefreshEnabled': true,
  'sources': [_source(42), _source(7, name: 'backup')],
  'feed': [
    _row(_bv, now.subtract(const Duration(days: 1))),
    _row(_old, now.subtract(const Duration(days: 15))),
  ],
  'history': {
    'creator:42': [_row(_old, now.subtract(const Duration(days: 15)))],
  },
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final now = DateTime.utc(2026, 11, 22);

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'adds sources and recent feed only, preserves local data and flags',
    () async {
      final content = Content();
      final service = SubscriptionService(
        contentService: content,
        preferencesLoader: SharedPreferences.getInstance,
        clock: () => now,
      );
      addTearDown(service.dispose);
      await service.addSource(
        const SubscriptionSource(
          kind: SubscriptionKind.creator,
          mid: 7,
          name: 'local',
          token: 'existing',
        ),
      );

      final portable = SubscriptionService.parseUnifiedRestore(_export(now));
      final result = await service.restoreUnifiedData(portable);
      expect(result.added, 2);
      expect(result.kept, 3);
      expect(service.sources.map((entry) => entry.name), ['local', 'UP 42']);
      expect(service.sources.last.token, isNotEmpty);
      expect(service.sources.last.imageUrl, 'https://i0.hdslb.com/avatar.png');
      expect(service.feed.map((entry) => entry.bvid), [_bv]);
      expect(service.feed.single.readAt, isNotNull);
      expect(service.feed.single.coverUrl, isEmpty);
      expect(service.enabled, isFalse);
      expect(service.notificationsEnabled, isFalse);
      expect(service.backgroundRefreshEnabled, isFalse);
      expect(content.calls, isEmpty);

      final after = await service.exportLocalData();
      final reimport = await service.restoreUnifiedData(portable);
      expect(reimport.added, 0);
      expect(await service.exportLocalData(), after);
    },
  );

  test('rejects source tokens from archives instead of importing them', () {
    final archive = _export(now);
    archive['sources'] = [
      {..._source(42), 'token': 'not-portable'},
    ];
    expect(
      () => SubscriptionService.parseUnifiedRestore(archive),
      throwsFormatException,
    );
  });

  test(
    'respects source capacity without removing the current source',
    () async {
      final service = SubscriptionService(
        preferencesLoader: SharedPreferences.getInstance,
        clock: () => now,
        maxSources: 1,
      );
      addTearDown(service.dispose);
      await service.addSource(
        const SubscriptionSource(
          kind: SubscriptionKind.creator,
          mid: 7,
          name: 'local',
          token: 'existing',
        ),
      );
      final result = await service.restoreUnifiedData(
        SubscriptionService.parseUnifiedRestore(_export(now)),
      );
      expect(result.added, 0);
      expect(service.sources.single.mid, 7);
      expect(service.feed, isEmpty);
    },
  );
}
