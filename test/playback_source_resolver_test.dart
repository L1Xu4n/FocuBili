import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/services/playback_source_resolver.dart';
import 'package:focubili/services/playback_preferences_service.dart';
import 'package:focubili/services/offline_video_service.dart';
import 'review_pr24_regression_test.dart' show ReviewOfflineLibrary;

/// Covers source defaults, exact identity and missing-file behavior.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('source defaults online and persists local priority', () async {
    const preferences = PlaybackPreferencesService();
    expect((await preferences.load()).preferOfflineCache, isFalse);
    await preferences.savePreferOfflineCache(true);
    expect((await preferences.load()).preferOfflineCache, isTrue);
  });

  test(
    'cache is matched by BV and CID and explicit offline overrides online priority',
    () async {
      final resolver = PlaybackSourceResolver(ReviewOfflineLibrary());
      final file = ReviewOfflineLibrary.record;
      expect(
        await resolver.resolve(file.bvid, file.cid, preferLocal: false),
        isNull,
      );
      expect(
        await resolver.resolve(file.bvid, file.cid, preferLocal: true),
        file,
      );
      expect(
        await resolver.resolve(
          file.bvid,
          file.cid,
          preferLocal: false,
          requireLocal: true,
        ),
        file,
      );
      expect(
        await resolver.resolve(file.bvid, file.cid + 1, preferLocal: true),
        isNull,
      );
      await expectLater(
        resolver.resolve(
          file.bvid,
          file.cid + 1,
          preferLocal: true,
          requireLocal: true,
        ),
        throwsA(isA<OfflineVideoException>()),
      );
    },
  );
}
