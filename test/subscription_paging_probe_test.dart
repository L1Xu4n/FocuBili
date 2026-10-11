import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/models/subscription.dart';
import 'package:focubili/services/bilibili_public_content_service.dart';
import 'package:focubili/services/subscription_service.dart';
import 'subscription_background_test.dart' show AtomicSnapshots;
import 'support/subscription_public_pages.dart';

// Identical fixture, adapter and service entry points run on dev and this branch.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('record complete adapter-to-scanner request counts', () async {
    final report = <String, Object?>{};
    for (final count in [100, 1000, 10000]) {
      SharedPreferences.setMockInitialValues({});
      final api = PublicPages(count);
      final store = AtomicSnapshots();
      final service = SubscriptionService(
        snapshotStore: store,
        contentService: BilibiliHttpPublicContentService(requestJson: api.call),
        clock: () => DateTime.utc(2026, 1, 2),
      );
      await service.initialize();
      final source = SubscriptionSource(
        kind: SubscriptionKind.creator,
        mid: 1,
        name: 'test',
        token: '1',
      );
      await service.addSource(source);
      await service.setEnabled(true);
      service.setForeground(true);
      await service.refresh();
      final firstRequests = api.calls.length;
      final firstPages = api.pages.length;
      final firstInitialized = service.checkpoint(source.key)!.initialized;
      for (var i = 0; i < 3; i++) {
        await service.refresh(manual: true);
      }
      final pages = api.pages;
      report['$count'] = {
        'firstRoundHttp': firstRequests,
        'firstRoundPages': firstPages,
        'firstRoundInitialized': firstInitialized,
        'fourRoundsHttp': api.calls.length,
        'fourRoundsPages': pages.length,
        'navCalls': api.navCalls,
        'uniquePages': pages.toSet().length,
        'highestPage': pages.reduce((a, b) => a > b ? a : b),
        'initialized': service.checkpoint(source.key)!.initialized,
        'seen': service.checkpoint(source.key)!.seen.length,
        'liveFeed': service.feed.length,
      };
      service.dispose();
    }
    const output = String.fromEnvironment('PAGING_OUTPUT');
    if (output.isNotEmpty) {
      File(output).writeAsStringSync(
        '${const JsonEncoder.withIndent('  ').convert(report)}\n',
      );
    }
    // Keep metrics descriptive: both pre-fix and post-fix runs use this file.
    expect(report.length, 3);
  });
}
