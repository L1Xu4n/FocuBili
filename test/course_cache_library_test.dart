import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/models/video_preview.dart';
import 'package:focubili/services/cache_lifecycle.dart';
import 'package:focubili/services/course_cache_access.dart';
import 'package:focubili/services/course_cache_library.dart';
import 'package:focubili/services/download_control.dart';
import 'package:focubili/services/offline_media_plan.dart';
import 'package:focubili/services/resumable_media_download.dart';

const part = VideoPart(
  pageNumber: 1,
  cid: 31,
  title: '力与运动',
  duration: Duration(minutes: 4),
  courseEpisodeId: 21,
  courseAid: 55,
);
const video = VideoPreview(
  bvid: 'cheese:ss11',
  cid: 31,
  title: '合成物理课堂',
  ownerName: '测试',
  parts: [part],
  courseSeasonId: 11,
);

class Access extends CourseCacheAccess {
  int? mid = 51;
  int calls = 0;
  bool denied = false;
  late DateTime now;
  Duration window = const Duration(hours: 1);
  late OfflineMediaPlan media;
  @override
  Future<int?> currentLocalMid() async => mid;
  @override
  Future<CourseCacheGrant> authorize(
    VideoPreview video,
    VideoPart part,
    int quality,
  ) async {
    calls++;
    if (denied) throw const CourseCacheAccessException('无法验证购买。');
    final uid = mid!;
    return CourseCacheGrant(
      mid: uid,
      checkedAt: now,
      validUntil: now.add(window),
      media: media,
      checkSession: () async {
        if (uid != mid) throw const CourseCacheAccessException('账号变化。');
      },
      mediaHeaders: const {'Accept': '*/*'},
    );
  }
}

class FixtureTransfer extends ResumableMediaDownload {
  final starts = <String>[];
  static List<int> box(String kind, List<int> data) => [
    0,
    0,
    0,
    8 + data.length,
    ...ascii.encode(kind),
    ...data,
  ];
  List<int> payload = [
    ...box('ftyp', [105, 115, 111, 109, 0, 0, 0, 1]),
    ...box('moov', box('trak', [])),
    ...box('mdat', utf8.encode('synthetic-media-for-testing')),
  ];
  String? fail;
  Completer<void>? pausePoint;
  Completer<void>? allow;
  @override
  Future<int> download(
    Uri uri,
    Map<String, String> headers,
    File output,
    void Function(int, int?) onProgress, {
    DownloadControl? control,
    String? mediaIdentity,
  }) async {
    expect(headers.keys.map((x) => x.toLowerCase()), isNot(contains('cookie')));
    starts.add(uri.path);
    if (uri.path == fail) throw const HttpException('synthetic error');
    if (pausePoint != null) {
      await output.writeAsBytes(payload.sublist(0, 4));
      await File('${output.path}.resume').writeAsString('tag');
      if (!pausePoint!.isCompleted) pausePoint!.complete();
      await control!.guard(allow!.future);
    }
    await output.writeAsBytes(payload);
    onProgress(payload.length, payload.length);
    return payload.length;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;
  late Access a;
  late FixtureTransfer d;
  late CourseCacheLibrary lib;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('course_cache_unit');
    d = FixtureTransfer();
    a = Access()..now = DateTime.now();
    a.media = OfflineMediaPlan(
      video: OfflineMediaTrack(
        id: 64,
        urls: ['https://cdn.bilivideo.com/v'],
        expectedBytes: d.payload.length,
      ),
      audio: OfflineMediaTrack(
        id: 10,
        urls: ['https://cdn.bilivideo.com/a'],
        expectedBytes: d.payload.length,
      ),
    );
    lib = CourseCacheLibrary(
      access: a,
      root: () async => tmp,
      downloader: d,
      clock: () => a.now,
    );
  });
  tearDown(() async {
    lib.dispose();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });
  test(
    'paired tracks commit together and reopen without any network, then delete',
    () async {
      await lib.start(video, part);
      expect(lib.error, isNull);
      final e = (await lib.entries()).single;
      final local = await lib.open(e);
      expect(await File(local.video).readAsBytes(), d.payload);
      expect(await File(local.audio!).readAsBytes(), d.payload);
      expect(e.video.bvid, video.bvid);
      expect(e.part.courseEpisodeId, 21);
      expect(a.calls, 1);
      expect(d.starts, ['/v', '/a']);
      final manifest = await File.fromUri(
        File(local.video).parent.uri.resolve('entry.json'),
      ).readAsString();
      expect(manifest, isNot(contains('https://')));
      await lib.remove(e);
      expect(await lib.entries(), isEmpty);
      expect(await File(local.video).exists(), isFalse);
    },
  );
  test(
    'new account, guest, and back to previously checked account only see their own files',
    () async {
      await lib.start(video, part);
      final e = (await lib.entries()).single;
      a.mid = 77;
      CacheLifecycle.accountChanged();
      expect(await lib.entries(), isEmpty);
      await expectLater(lib.open(e), throwsA(isA<CourseCacheFailure>()));
      await expectLater(lib.remove(e), throwsA(isA<CourseCacheFailure>()));
      a.mid = null;
      CacheLifecycle.accountChanged();
      await expectLater(lib.entries(), throwsA(isA<CourseCacheFailure>()));
      a.mid = 51;
      CacheLifecycle.accountChanged();
      expect((await lib.open(e)).entry.mid, 51);
    },
  );
  test(
    'expiry and clock rollback do not return paths; a failed renewal revokes previous completion',
    () async {
      await lib.start(video, part);
      final e = (await lib.entries()).single, orig = a.now;
      a.now = e.until!;
      await expectLater(lib.open(e), throwsA(isA<CourseCacheFailure>()));
      a.now = orig.subtract(const Duration(seconds: 1));
      await expectLater(lib.open(e), throwsA(isA<CourseCacheFailure>()));
      a.now = orig;
      a.denied = true;
      await lib.start(video, part);
      expect(lib.error, contains('无法验证'));
      expect((await lib.entries()).single.complete, isFalse);
      await expectLater(lib.open(e), throwsA(isA<CourseCacheFailure>()));
    },
  );
  test(
    'unexpected protection marker on media bytes never becomes a playable file',
    () async {
      final i = d.payload.indexOf(116, 24);
      d.payload.replaceRange(i, i + 4, ascii.encode('encv'));
      await lib.start(video, part);
      expect(lib.error, contains('保护标记'));
      expect((await lib.entries()).single.complete, isFalse);
      final files = await tmp
          .list(recursive: true)
          .where((e) => e is File)
          .map((f) => f.path)
          .toList();
      expect(
        files.where((path) => path.endsWith('.part') || path.endsWith('.bin')),
        isEmpty,
      );
    },
  );
  test(
    'failed audio cannot publish silent video, truncated file cannot play',
    () async {
      d.fail = '/a';
      await lib.start(video, part);
      final partial = (await lib.entries()).single;
      expect(partial.complete, isFalse);
      await expectLater(lib.open(partial), throwsA(isA<CourseCacheFailure>()));
      d.fail = null;
      await lib.start(video, part);
      final e = (await lib.entries()).single,
          f = File((await lib.open(e)).audio!);
      await f.writeAsBytes([1]);
      await expectLater(lib.open(e), throwsA(isA<CourseCacheFailure>()));
    },
  );
  test(
    'pause keeps partial inaccessible and resume requires fresh entitlement',
    () async {
      d.pausePoint = Completer();
      d.allow = Completer();
      final downloading = lib.start(video, part);
      await d.pausePoint!.future;
      await lib.pause();
      await downloading;
      final e = (await lib.entries()).single;
      expect(e.complete, isFalse);
      expect(lib.activeId, isNull);
      d.pausePoint = null;
      await lib.start(video, part);
      expect((await lib.entries()).single.complete, isTrue);
      expect(a.calls, 2);
    },
  );
  test(
    'switch during download aborts; stale transfer cannot finish or name any new account rows',
    () async {
      d.pausePoint = Completer();
      d.allow = Completer();
      final downloading = lib.start(video, part);
      await d.pausePoint!.future;
      a.mid = 73;
      CacheLifecycle.accountChanged();
      await downloading;
      expect(await lib.entries(), isEmpty);
      a.mid = 51;
      CacheLifecycle.accountChanged();
      expect((await lib.entries()).single.complete, isFalse);
    },
  );
  test(
    'a grant timeout interrupts blocked transfer even when no more chunks arrive',
    () async {
      a.window = const Duration(milliseconds: 60);
      d.pausePoint = Completer();
      d.allow = Completer();
      await lib.start(video, part).timeout(const Duration(seconds: 3));
      expect(lib.error, contains('到期'));
      expect((await lib.entries()).single.complete, isFalse);
    },
  );
  test(
    'unentitled first attempt never writes purchased course title or partial media',
    () async {
      a.denied = true;
      await lib.start(video, part);
      expect(await lib.entries(), isEmpty);
      expect(d.starts, isEmpty);
      expect(
        await tmp.list(recursive: true).where((e) => e is File).isEmpty,
        isTrue,
      );
    },
  );
  test(
    'reject forged oversized receipt, symlink and corruption without crossing partition',
    () async {
      await lib.start(video, part);
      final e = (await lib.entries()).single;
      final videoFile = File((await lib.open(e)).video);
      final receipt = File.fromUri(videoFile.parent.uri.resolve('entry.json'));
      final j = jsonDecode(await receipt.readAsString()) as Map;
      j['until'] = e.checkedAt!
          .add(const Duration(days: 2))
          .millisecondsSinceEpoch;
      await receipt.writeAsString(jsonEncode(j));
      await expectLater(lib.open(e), throwsA(isA<CourseCacheFailure>()));
      await receipt.writeAsString(jsonEncode(e.toJson()));
      final outside = File.fromUri(tmp.uri.resolve('outside'))
        ..writeAsBytesSync(d.payload);
      await videoFile.delete();
      await Link(videoFile.path).create(outside.path);
      await expectLater(lib.open(e), throwsA(isA<CourseCacheFailure>()));
      await lib.remove(e);
      expect(await outside.readAsBytes(), d.payload);
    },
    skip: Platform.isWindows
        ? 'Link creation may require developer mode.'
        : false,
  );
}
