import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/video_preview.dart';
import 'cache_lifecycle.dart';
import 'course_cache_access.dart';
import 'course_cache_container.dart';
import 'download_control.dart';
import 'offline_media_plan.dart';
import 'resumable_media_download.dart';

/// Private chapter cache. It never adds paid media to the device-wide BV
/// download index, its export UI, or its foreground notifications.
class CourseCacheEntry {
  const CourseCacheEntry({
    required this.mid,
    required this.season,
    required this.ep,
    required this.aid,
    required this.cid,
    required this.courseTitle,
    required this.chapterTitle,
    required this.duration,
    required this.quality,
    this.videoBytes = 0,
    this.audioBytes = 0,
    this.checkedAt,
    this.until,
  });
  final int mid, season, ep, aid, cid, quality, videoBytes, audioBytes;
  final String courseTitle, chapterTitle;
  final Duration duration;
  final DateTime? checkedAt, until;
  String get id => '$season-$ep-$aid-$cid';
  bool get complete => videoBytes > 0 && until != null && checkedAt != null;
  bool usableAt(DateTime now) =>
      complete &&
      !now.isBefore(checkedAt!) &&
      now.isBefore(until!) &&
      until!.difference(checkedAt!) <= const Duration(hours: 24);
  VideoPart get part => VideoPart(
    pageNumber: 1,
    cid: cid,
    title: chapterTitle,
    duration: duration,
    courseEpisodeId: ep,
    courseAid: aid,
  );
  VideoPreview get video => VideoPreview(
    bvid: 'cheese:ss$season',
    courseSeasonId: season,
    requestedCourseEpisodeId: ep,
    cid: cid,
    title: courseTitle,
    ownerName: 'B站课堂',
    duration: duration,
    parts: [part],
    fromOfflineCache: true,
  );
  Map<String, Object?> toJson() => {
    'season': season,
    'ep': ep,
    'aid': aid,
    'cid': cid,
    'course': courseTitle,
    'chapter': chapterTitle,
    'ms': duration.inMilliseconds,
    'quality': quality,
    'v': videoBytes,
    'a': audioBytes,
    'checked': checkedAt?.millisecondsSinceEpoch,
    'until': until?.millisecondsSinceEpoch,
  };
  factory CourseCacheEntry.fromJson(int mid, Map j) {
    int positive(String k) {
      final n = j[k];
      if (n is! int || n <= 0) throw const FormatException();
      return n;
    }

    int nonnegative(String k) {
      final n = j[k];
      if (n is! int || n < 0) throw const FormatException();
      return n;
    }

    return CourseCacheEntry(
      mid: mid,
      season: positive('season'),
      ep: positive('ep'),
      aid: positive('aid'),
      cid: positive('cid'),
      courseTitle: j['course'] as String,
      chapterTitle: j['chapter'] as String,
      duration: Duration(milliseconds: nonnegative('ms')),
      quality: positive('quality'),
      videoBytes: nonnegative('v'),
      audioBytes: nonnegative('a'),
      checkedAt: j['checked'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(positive('checked')),
      until: j['until'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(positive('until')),
    );
  }
}

class CourseCacheFailure implements Exception {
  const CourseCacheFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

class CourseCacheLibrary extends ChangeNotifier {
  CourseCacheLibrary({
    CourseCacheAccess? access,
    Future<Directory> Function()? root,
    this.downloader = const ResumableMediaDownload(),
    DateTime Function()? clock,
  }) : access = access ?? CourseCacheAccess(),
       _root = root ?? getApplicationCacheDirectory,
       _clock = clock ?? DateTime.now {
    CacheLifecycle.account.addListener(_accountChanged);
  }
  static final instance = CourseCacheLibrary();
  final CourseCacheAccess access;
  final Future<Directory> Function() _root;
  final ResumableMediaDownload downloader;
  final DateTime Function() _clock;
  Future<void>? _running;
  DownloadControl? _control;
  String? _busyKey;
  bool _closed = false, _deleting = false;
  int _revision = 0, _received = 0, _listVersion = 0;
  int get listVersion => _listVersion;
  int? _total;
  String? _error;
  String? get activeId => _busyKey;
  int get received => _received;
  int? get total => _total;
  String? get error => _error;
  bool get busy => _running != null || _deleting;
  Future<void> get settled => _running ?? Future.value();
  static const _inactive = CourseCacheFailure('请登录缓存该课程的账号，再打开离线课堂。');
  void _emit() {
    if (!_closed) notifyListeners();
  }

  void _accountChanged() {
    _revision++;
    _listVersion++;
    _control?.interrupt();
    _busyKey = null;
    _error = null;
    _received = 0;
    _total = null;
    _emit();
  }

  Future<int> _mid() async {
    final mid = await access.currentLocalMid();
    if (mid == null || mid <= 0) throw _inactive;
    return mid;
  }

  Future<void> _same(int mid, int revision) async {
    if (_closed ||
        _revision != revision ||
        await _mid() != mid ||
        _revision != revision) {
      throw _inactive;
    }
  }

  // Only generated positive numeric path components. Refuse links, including
  // parent directories and partial-file sidecars, before touching bytes.
  Future<Directory> _dirs(int mid, [String? key]) async {
    if (mid <= 0 ||
        key != null &&
            !RegExp(r'^[1-9][0-9]*(?:-[1-9][0-9]*){3}$').hasMatch(key)) {
      throw const FormatException();
    }
    var d = await _root();
    if (!await d.exists()) await d.create(recursive: true);
    for (final name in ['private_course_v1', '$mid', ?key]) {
      d = Directory.fromUri(d.absolute.uri.resolve('$name/'));
      final type = await FileSystemEntity.type(d.path, followLinks: false);
      if (type == FileSystemEntityType.notFound) {
        await d.create();
      } else if (type != FileSystemEntityType.directory) {
        throw const CourseCacheFailure('课程缓存目录不可用。');
      }
    }
    return d;
  }

  Future<File> _file(Directory d, String basename) async {
    final file = File.fromUri(d.absolute.uri.resolve(basename));
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type != FileSystemEntityType.file &&
        type != FileSystemEntityType.notFound) {
      throw const CourseCacheFailure('课程缓存文件不可用。');
    }
    return file;
  }

  Future<void> _save(Directory dir, CourseCacheEntry e) async {
    final temp = await _file(dir, 'entry.tmp'),
        dest = await _file(dir, 'entry.json');
    await temp.writeAsString(jsonEncode(e.toJson()), flush: true);
    await temp.rename(dest.path);
  }

  Future<CourseCacheEntry?> _read(Directory d, int mid) async {
    final f = await _file(d, 'entry.json');
    if (!await f.exists()) return null;
    if (await f.length() > 65536) throw const FormatException();
    return CourseCacheEntry.fromJson(
      mid,
      jsonDecode(await f.readAsString()) as Map,
    );
  }

  Future<List<CourseCacheEntry>> entries() async {
    final revision = _revision;
    final mid = await _mid(), root = await _dirs(mid);
    final list = <CourseCacheEntry>[];
    await for (final d in root.list(followLinks: false)) {
      if (d is! Directory) continue;
      final CourseCacheEntry? entry;
      try {
        entry = await _read(d, mid);
      } on FormatException {
        continue; // A broken receipt cannot authorize media or hide other lessons.
      } on TypeError {
        continue;
      }
      if (entry != null &&
          d.absolute.uri.pathSegments.where((s) => s.isNotEmpty).last ==
              entry.id) {
        list.add(entry);
      }
    }
    await _same(mid, revision);
    return list..sort(
      (a, b) => a.courseTitle.compareTo(b.courseTitle) != 0
          ? a.courseTitle.compareTo(b.courseTitle)
          : a.ep.compareTo(b.ep),
    );
  }

  Future<void> start(VideoPreview v, VideoPart p, {int quality = 64}) async {
    if (busy) throw const CourseCacheFailure('已有章节正在缓存，请先暂停或等它完成。');
    if (v.courseSeasonId == null ||
        v.bvid != 'cheese:ss${v.courseSeasonId}' ||
        (p.courseEpisodeId ?? 0) <= 0 ||
        (p.courseAid ?? 0) <= 0 ||
        p.cid <= 0 ||
        quality <= 0 ||
        !v.parts.any(
          (e) =>
              e.cid == p.cid &&
              e.courseEpisodeId == p.courseEpisodeId &&
              e.courseAid == p.courseAid,
        )) {
      throw const CourseCacheFailure('课程章节无效，请重新打开。');
    }
    final revision = _revision, c = DownloadControl();
    _control = c;
    _received = 0;
    _total = null;
    _error = null;
    _busyKey =
        '${v.courseSeasonId}-${p.courseEpisodeId}-${p.courseAid}-${p.cid}';
    final run = _transfer(v, p, quality, c, revision);
    _running = run;
    _emit();
    try {
      await run;
    } on DownloadInterrupted {
      // No completion is published. A partial can be resumed after a fresh check.
    } catch (e) {
      if (revision == _revision && !c.isInterrupted) {
        _error = e is CourseCacheFailure
            ? e.message
            : e is CourseCacheAccessException
            ? e.message
            : '课程缓存失败，请检查网络、购买状态和剩余空间。';
      }
    } finally {
      _busyKey = null;
      _control = null;
      _running = null;
      _listVersion++;
      _emit();
    }
  }

  Future<void> _transfer(
    VideoPreview v,
    VideoPart p,
    int q,
    DownloadControl c,
    int rev,
  ) async {
    final mid = await c.guard(_mid());
    final pending = CourseCacheEntry(
      mid: mid,
      season: v.courseSeasonId!,
      ep: p.courseEpisodeId!,
      aid: p.courseAid!,
      cid: p.cid,
      courseTitle: v.title,
      chapterTitle: p.title,
      duration: p.duration,
      quality: q,
    );
    final dir = await _dirs(mid, pending.id);
    await _same(mid, rev);
    c.check();
    // An interrupted renewal cannot keep using a now-denied/stale proof.
    final previous = await _read(dir, mid);
    if (previous != null) {
      final revoked = Map<String, Object?>.of(previous.toJson())
        ..['checked'] = null
        ..['until'] = null;
      await _save(dir, CourseCacheEntry.fromJson(mid, revoked));
      _listVersion++;
      _emit();
    }
    final g = await c.guard(access.authorize(v, p, q));
    if (g.mid != mid) throw _inactive;
    Future<void> check() async {
      c.check();
      await _same(mid, rev);
      await g.checkSession();
      c.check();
      if (_clock().isBefore(g.checkedAt) || !_clock().isBefore(g.validUntil)) {
        throw const CourseCacheFailure('本次课程校验已到期，请重新联网确认。');
      }
    }

    await check();
    await _save(dir, pending);
    _listVersion++;
    _emit();
    final ttl = g.validUntil.difference(_clock());
    final deadline = Timer(ttl, () {
      if (!c.isInterrupted && rev == _revision && !_closed) {
        _error = '本次课程校验已到期，请重新联网确认。';
        c.interrupt();
      }
    });
    final paint = Stopwatch()..start();
    try {
      var offset = 0;
      Future<int> track(OfflineMediaTrack t, String name) async {
        final output = await _file(dir, '$name.part');
        await _file(dir, '$name.part.resume');
        for (final url in t.urls) {
          await check();
          try {
            final n = await downloader.download(
              Uri.parse(url),
              g.mediaHeaders,
              output,
              (bytes, total) {
                if (c.isInterrupted || rev != _revision) return;
                _received = offset + bytes;
                _total =
                    g.media.video.expectedBytes == null ||
                        g.media.audio != null &&
                            g.media.audio!.expectedBytes == null
                    ? null
                    : (g.media.video.expectedBytes ?? 0) +
                          (g.media.audio?.expectedBytes ?? 0);
                if (bytes == total || paint.elapsedMilliseconds >= 160) {
                  paint.reset();
                  _emit();
                }
              },
              control: c,
              mediaIdentity: sha256
                  .convert(utf8.encode('${pending.id}:${t.identity}'))
                  .toString(),
            );
            if (t.expectedBytes != null && n != t.expectedBytes) {
              throw const CourseCacheFailure('课程媒体接收不完整。');
            }
            offset += n;
            return n;
          } catch (_) {
            c.check();
          }
        }
        throw const CourseCacheFailure('课程媒体接收不完整，请重试。');
      }

      final nv = await track(g.media.video, 'video'),
          na = g.media.audio == null ? 0 : await track(g.media.audio!, 'audio');
      await check();
      for (final name in ['video', if (na > 0) 'audio']) {
        if (!await CourseCacheContainer.clearMp4(
          await _file(dir, '$name.part'),
          c.check,
        )) {
          // Never retain an apparently protected or unrecognized source for resume.
          for (final rejected in [
            'video.part',
            'audio.part',
            'video.part.resume',
            'audio.part.resume',
          ]) {
            final f = await _file(dir, rejected);
            if (await f.exists()) await f.delete();
          }
          throw const CourseCacheFailure('实际媒体含保护标记或不是支持的完整 MP4，未创建可播放缓存。');
        }
      }
      await check();
      final vf = await _file(dir, 'video.bin');
      await (await _file(dir, 'video.part')).rename(vf.path);
      final af = await _file(dir, 'audio.bin');
      if (na > 0) {
        await (await _file(dir, 'audio.part')).rename(af.path);
      } else if (await af.exists()) {
        await af.delete();
      }
      for (final name in ['audio.part.resume', 'video.part.resume']) {
        final f = await _file(dir, name);
        if (await f.exists()) await f.delete();
      }
      await check();
      await _save(
        dir,
        CourseCacheEntry(
          mid: mid,
          season: pending.season,
          ep: pending.ep,
          aid: pending.aid,
          cid: pending.cid,
          courseTitle: pending.courseTitle,
          chapterTitle: pending.chapterTitle,
          duration: pending.duration,
          quality: g.media.quality,
          videoBytes: nv,
          audioBytes: na,
          checkedAt: g.checkedAt,
          until: g.validUntil,
        ),
      );
    } finally {
      deadline.cancel();
    }
  }

  Future<void> pause() async {
    final r = _running;
    _control?.interrupt();
    try {
      await r;
    } catch (_) {}
  }

  Future<void> remove(CourseCacheEntry e) async {
    if (busy) throw const CourseCacheFailure('请先暂停进行中的缓存，再删除章节。');
    _deleting = true;
    try {
      final rev = _revision;
      await _same(e.mid, rev);
      final dir = await _dirs(e.mid, e.id);
      await _same(e.mid, rev);
      await dir.delete(recursive: true);
    } finally {
      _deleting = false;
      _listVersion++;
      _emit();
    }
  }

  Future<({CourseCacheEntry entry, String video, String? audio})> open(
    CourseCacheEntry e,
  ) async {
    final rev = _revision;
    await _same(e.mid, rev);
    final dir = await _dirs(e.mid, e.id), fresh = await _read(dir, e.mid);
    if (fresh == null || fresh.id != e.id || !fresh.usableAt(_clock())) {
      throw const CourseCacheFailure('缓存不完整或校验已到期，请联网重新确认。');
    }
    final v = await _file(dir, 'video.bin'), a = await _file(dir, 'audio.bin');
    if (!await v.exists() ||
        await v.length() != fresh.videoBytes ||
        fresh.audioBytes > 0 &&
            (!await a.exists() || await a.length() != fresh.audioBytes)) {
      throw const CourseCacheFailure('课程缓存已被清理或损坏，请重新缓存。');
    }
    await _same(e.mid, rev);
    if (!fresh.usableAt(_clock())) {
      throw const CourseCacheFailure('本次课程校验已到期，请重新联网确认。');
    }
    return (
      entry: fresh,
      video: v.path,
      audio: fresh.audioBytes > 0 ? a.path : null,
    );
  }

  @override
  void dispose() {
    _closed = true;
    _control?.interrupt();
    CacheLifecycle.account.removeListener(_accountChanged);
    super.dispose();
  }
}
