import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/models/video_preview.dart';
import 'package:focubili/services/cache_lifecycle.dart';
import 'package:focubili/services/desktop_playback_source_service.dart';
import 'package:focubili/services/windows_playback_service.dart';
import 'classroom_access_test.dart' show course;
import 'listening_playback_test.dart' show ListeningPlayer;

class SyntheticCourseSources extends BilibiliDesktopPlaybackSourceService {
  @override
  Future<DesktopPlaybackSources> loadCourse({
    required VideoPreview video,
    required VideoPart part,
    required int quality,
  }) async => load(bvid: video.bvid, cid: part.cid, quality: quality);
  @override
  Future<DesktopPlaybackSources> load({
    required String bvid,
    required int cid,
    required int quality,
  }) async => const DesktopPlaybackSources(
    videoUrls: [
      'https://synthetic.bilivideo.com/primary.mp4',
      'https://synthetic.bilivideo.com/backup.mp4',
    ],
    audioUrls: [],
    referer: '',
    cookieHeader: '',
    actualQuality: 64,
    qualities: [],
    videoCodec: 'muxed',
    audioCodec: '',
  );
}

class AccountRacePlayer extends ListeningPlayer {
  Completer<void>? pausedAfterSources;
  Completer<void>? releasePause;
  bool changeAccountOnFirstOpen = false;
  int pauses = 0;
  int stops = 0;
  Completer<void>? stopEntered;
  Completer<void>? releaseStop;
  Completer<void>? openEntered;
  Completer<void>? releaseOpen;
  @override
  Future<void> pause() async {
    await super.pause();
    if (++pauses == 2 && pausedAfterSources != null) {
      pausedAfterSources!.complete();
      await releasePause!.future;
    }
  }

  @override
  Future<void> stop() async {
    stops++;
    await super.stop();
    if (stops == 1 && stopEntered != null) {
      stopEntered!.complete();
      await releaseStop!.future;
    }
  }

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    if (openEntered != null && !openEntered!.isCompleted) {
      openEntered!.complete();
      await releaseOpen!.future;
    }
    await super.open(playable, play: play);
    if (changeAccountOnFirstOpen && opened.length == 1) {
      CacheLifecycle.accountChanged();
      throw StateError('Synthetic first-source failure after account change');
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'account stop follows an already in-flight media open so late commands cannot leave old media running',
    () async {
      final player = AccountRacePlayer()
        ..openEntered = Completer<void>()
        ..releaseOpen = Completer<void>();
      final service = WindowsPlaybackService(
        player: player,
        sourceService: SyntheticCourseSources(),
      );
      try {
        final opening = service.openVideo(course);
        await player.openEntered!.future;
        CacheLifecycle.accountChanged();
        await Future<void>.delayed(Duration.zero);
        expect(
          player.stops,
          0,
          reason: 'The stop must occur after the delayed open, never before it',
        );
        player.releaseOpen!.complete();
        await opening;
        await Future<void>.delayed(Duration.zero);
        expect(player.opened, hasLength(1));
        expect(player.stops, 1);
        expect(player.state.playing, isFalse);
        expect(player.state.duration, Duration.zero);
      } finally {
        if (!player.releaseOpen!.isCompleted) player.releaseOpen!.complete();
        await service.dispose();
      }
    },
  );

  test(
    'an older local open waiting on account stop cannot cancel a newer online request',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'classroom_stop_fixture_',
      );
      final file = await File(
        '${directory.path}/synthetic.mp4',
      ).writeAsBytes([1]);
      final player = AccountRacePlayer()
        ..stopEntered = Completer<void>()
        ..releaseStop = Completer<void>();
      final service = WindowsPlaybackService(
        player: player,
        sourceService: SyntheticCourseSources(),
      );
      try {
        await service.openVideo(course);
        CacheLifecycle.accountChanged();
        await player.stopEntered!.future;
        final oldLocal = service.openLocalFile(
          filePath: file.path,
          video: VideoPreview.placeholder(),
        );
        final newerOnline = service.openVideo(VideoPreview.placeholder());
        player.releaseStop!.complete();
        await Future.wait([oldLocal, newerOnline]);
        expect(
          player.opened.any((media) => media.uri.contains('synthetic.mp4')),
          isFalse,
        );
        expect(player.opened.last.uri, contains('primary.mp4'));
        expect(player.state.playing, isTrue);
      } finally {
        if (!player.releaseStop!.isCompleted) player.releaseStop!.complete();
        await service.dispose();
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'account changes after playurl returns and before media open cancel captured classroom URLs',
    () async {
      final player = AccountRacePlayer()
        ..pausedAfterSources = Completer<void>()
        ..releasePause = Completer<void>();
      final service = WindowsPlaybackService(
        player: player,
        sourceService: SyntheticCourseSources(),
      );
      try {
        final opening = service.openVideo(course);
        await player.pausedAfterSources!.future;
        CacheLifecycle.accountChanged();
        await Future<void>.delayed(Duration.zero);
        player.releasePause!.complete();
        await opening;
        expect(player.opened, isEmpty);
        expect(player.stops, greaterThan(0));
        await expectLater(service.play(), throwsStateError);
      } finally {
        if (!player.releasePause!.isCompleted) player.releasePause!.complete();
        await service.dispose();
      }
    },
  );

  test(
    'account changes before failed primary source retry cannot open a captured backup URL',
    () async {
      final player = AccountRacePlayer()..changeAccountOnFirstOpen = true;
      final service = WindowsPlaybackService(
        player: player,
        sourceService: SyntheticCourseSources(),
      );
      try {
        await service.openVideo(course);
        await Future<void>.delayed(Duration.zero);
        expect(player.opened, hasLength(1));
        expect(player.opened.single.uri, contains('primary'));
        expect(player.stops, greaterThan(0));
        expect(player.state.playing, isFalse);
      } finally {
        await service.dispose();
      }
    },
  );

  test(
    'already playing classroom stops on account change; UGC keeps its prior behavior',
    () async {
      final player = AccountRacePlayer();
      final service = WindowsPlaybackService(
        player: player,
        sourceService: SyntheticCourseSources(),
      );
      try {
        await service.openVideo(course);
        expect(player.state.playing, isTrue);
        CacheLifecycle.accountChanged();
        await Future<void>.delayed(Duration.zero);
        expect(player.state.playing, isFalse);
        final oldOpens = player.opened.length;
        await expectLater(service.play(), throwsStateError);
        expect(player.opened.length, oldOpens);
        await service.openVideo(VideoPreview.placeholder());
        expect(player.state.playing, isTrue);
        final stops = player.stops;
        CacheLifecycle.accountChanged();
        await Future<void>.delayed(Duration.zero);
        expect(player.state.playing, isTrue);
        expect(player.stops, stops);
      } finally {
        await service.dispose();
      }
    },
  );

  for (final changeBeforeLocal in [true, false]) {
    test(
      'course to local UGC isolates account scope; change before local=$changeBeforeLocal',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'classroom_local_fixture_',
        );
        final file = await File(
          '${directory.path}/synthetic.mp4',
        ).writeAsBytes([1]);
        final player = AccountRacePlayer();
        final service = WindowsPlaybackService(
          player: player,
          sourceService: SyntheticCourseSources(),
        );
        try {
          await service.openVideo(course);
          if (changeBeforeLocal) CacheLifecycle.accountChanged();
          await service.openLocalFile(
            filePath: file.path,
            video: VideoPreview.placeholder(),
          );
          expect(player.opened.last.uri, contains('synthetic.mp4'));
          expect(player.state.playing, isTrue);
          final stops = player.stops;
          CacheLifecycle.accountChanged();
          await Future<void>.delayed(Duration.zero);
          expect(player.state.playing, isTrue);
          expect(player.stops, stops);
        } finally {
          await service.dispose();
          await directory.delete(recursive: true);
        }
      },
    );
  }
}
