import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/models/video_preview.dart';
import 'package:focubili/services/cache_lifecycle.dart';
import 'package:focubili/services/course_cache_library.dart';
import 'package:focubili/services/course_cache_playback_guard.dart';
import 'package:focubili/services/offline_media_plan.dart';
import 'package:focubili/services/windows_playback_service.dart';
import 'windows_local_source_resume_test.dart' show DelayedLocalPlayer;
import 'course_cache_library_test.dart'
    show Access, FixtureTransfer, video, part;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'verified private route opens its muxed lesson and stops on account change',
    () async {
      SharedPreferences.setMockInitialValues({});
      final root = await Directory.systemTemp.createTemp('private-route-owned');
      addTearDown(() => root.delete(recursive: true));
      final transfer = FixtureTransfer();
      final access = Access()
        ..now = DateTime.now()
        ..media = OfflineMediaPlan(
          video: OfflineMediaTrack(
            id: 64,
            urls: ['https://cdn.bilivideo.com/v'],
            expectedBytes: transfer.payload.length,
          ),
        );
      final store = CourseCacheLibrary(
        access: access,
        root: () async => root,
        downloader: transfer,
        clock: () => access.now,
      );
      addTearDown(store.dispose);
      await store.start(video, part);
      final e = (await store.entries()).single;
      final media = await store.open(e);
      final fake = DelayedLocalPlayer();
      final service = WindowsPlaybackService(
        player: fake,
        courseCacheGuard: CourseCachePlaybackGuard(store, e),
      );
      addTearDown(service.dispose);
      final opening = service.openLocalFile(
        filePath: media.video,
        video: video,
        part: part,
      );
      await fake.opened.future.timeout(const Duration(seconds: 3));
      fake.finishLoading(Duration.zero);
      await opening;
      expect(fake.playCalls, 1);
      expect(fake.state.playing, isTrue);
      access.mid = 75;
      CacheLifecycle.accountChanged();
      await Future<void>.delayed(Duration.zero);
      expect(fake.state.playing, isFalse);
      expect(await store.entries(), isEmpty);
    },
  );
  test(
    'ordinary desktop route cannot pass private file as unlabelled, UGC or lesson media',
    () async {
      SharedPreferences.setMockInitialValues({});
      final root = await Directory.systemTemp.createTemp('private-route');
      addTearDown(() => root.delete(recursive: true));
      final dir = await Directory.fromUri(
        root.uri.resolve('private_course_v1/51/11-21-55-31/'),
      ).create(recursive: true);
      final file = await File.fromUri(
        dir.uri.resolve('video.bin'),
      ).writeAsBytes([11]);
      final fake = DelayedLocalPlayer(),
          service = WindowsPlaybackService(player: fake);
      addTearDown(service.dispose);
      for (final v in <VideoPreview?>[
        null,
        VideoPreview.placeholder(),
        video,
      ]) {
        await expectLater(
          service.openLocalFile(
            filePath: file.path,
            video: v,
            part: v?.initialPart,
          ),
          throwsStateError,
        );
      }
      final ordinary = await File.fromUri(
        root.uri.resolve('ordinary.mp4'),
      ).writeAsBytes([12]);
      await expectLater(
        service.openLocalTracks(
          videoFilePath: ordinary.path,
          audioFilePath: file.path,
        ),
        throwsStateError,
      );
      if (!Platform.isWindows) {
        final alias = Link.fromUri(root.uri.resolve('alias.mp4'));
        await alias.create(file.path);
        await expectLater(
          service.openLocalFile(filePath: alias.path),
          throwsStateError,
        );
      }
      await expectLater(
        service.openLocalFile(
          filePath: ordinary.path,
          video: video,
          part: part,
        ),
        throwsStateError,
      );
      expect(fake.opened.isCompleted, isFalse);
    },
  );
}
