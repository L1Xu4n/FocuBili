import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/services/bilibili_service.dart';
import 'package:focubili/services/playback_preferences_service.dart';
import 'review_pr24_regression_test.dart' show ReviewOfflineLibrary;

/// Online entry keeps complete metadata; cache metadata is only an offline fallback.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'legacy local priority no longer replaces complete online metadata',
    () async {
      await const PlaybackPreferencesService().savePreferOfflineCache(true);
      final service = BilibiliVideoInfoService(
        offlineVideoService: ReviewOfflineLibrary(),
        requestJson: (uri) async => jsonEncode({
          'code': 0,
          'data': uri.path.contains('/tags')
              ? []
              : {
                  'bvid': 'BV1GJ411x7h7',
                  'cid': 137649199,
                  'title': 'Online title',
                  'desc': 'Complete online description',
                  'duration': 120,
                  'owner': {'name': 'Online UP', 'mid': 1},
                  'pages': [
                    {
                      'cid': 137649199,
                      'page': 1,
                      'part': 'Online part',
                      'duration': 120,
                    },
                  ],
                },
        }),
      );
      final video = await service.lookupVideo('BV1GJ411x7h7');
      expect(video.cid, ReviewOfflineLibrary.record.cid);
      expect(video.fromOfflineCache, isFalse);
      expect(video.description, 'Complete online description');
    },
  );

  test(
    'online priority falls back to validated cache metadata when disconnected',
    () async {
      var requested = 0;
      final service = BilibiliVideoInfoService(
        offlineVideoService: ReviewOfflineLibrary(),
        requestJson: (_) async {
          requested++;
          throw StateError('offline');
        },
      );
      final video = await service.lookupVideo('BV1GJ411x7h7');
      expect(requested, 1);
      expect(video.fromOfflineCache, isTrue);
    },
  );
}
