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
import 'course_cache_validity.dart';
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
    this.expiryKind = CourseCacheExpiryKind.legacyReceipt,
    DateTime? retainedServerDeadline,
    this.videoHash,
    this.audioHash,
    this.videoVersion,
    this.audioVersion,
  }) : _retainedServerDeadline = retainedServerDeadline;
  final int mid, season, ep, aid, cid, quality, videoBytes, audioBytes;
  final String courseTitle, chapterTitle;
  final Duration duration;
  final DateTime? checkedAt, until, _retainedServerDeadline;
  final CourseCacheExpiryKind expiryKind;
  final String? videoHash, audioHash, videoVersion, audioVersion;
  String get id => '$season-$ep-$aid-$cid';
  bool get hasMedia => videoBytes > 0;
  DateTime? get _knownServerDeadline =>
      expiryKind == CourseCacheExpiryKind.serverDeadline
      ? until
      : _retainedServerDeadline;
  bool get complete => hasMedia && expiryKind.accepts(checkedAt, until);
  bool usableAt(DateTime now) =>
      hasMedia && expiryKind.usableAt(now, checkedAt, until);
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
    ..._receiptFields(checkedAt, until, expiryKind),
    if (_retainedServerDeadline != null)
      'retainedServerDeadline': _retainedServerDeadline.millisecondsSinceEpoch,
    'videoHash': ?videoHash,
    'audioHash': ?audioHash,
    'videoVersion': ?videoVersion,
    'audioVersion': ?audioVersion,
  };
  // New receipts explicitly say why a deadline exists or is absent. A
  // legacy 'until' cannot be combined with these server-derived fields.
  static Map<String, Object?> _receiptFields(
    DateTime? checkedAt,
    DateTime? until,
    CourseCacheExpiryKind kind,
  ) => {
    'checked': checkedAt?.millisecondsSinceEpoch,
    if (kind == CourseCacheExpiryKind.legacyReceipt)
      'until': until?.millisecondsSinceEpoch
    else
      'authorization': {
        'kind': kind.name,
        if (until != null) 'serverUntil': until.millisecondsSinceEpoch,
      },
  };

  CourseCacheEntry _withReceipt(
    DateTime? checkedAt,
    DateTime? until,
    CourseCacheExpiryKind kind, {
    DateTime? retainedServerDeadline,
  }) {
    final data = toJson()
      ..remove('until')
      ..remove('authorization')
      ..remove('retainedServerDeadline');
    return CourseCacheEntry.fromJson(mid, {
      ...data,
      ..._receiptFields(checkedAt, until, kind),
      if (retainedServerDeadline != null)
        'retainedServerDeadline': retainedServerDeadline.millisecondsSinceEpoch,
    });
  }

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

    String? digest(String key) {
      final value = j[key];
      if (value == null) return null;
      if (value is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(value)) {
        throw const FormatException();
      }
      return value;
    }

    DateTime? date(Object? value) {
      if (value == null) return null;
      if (value is! int || value <= 0) throw const FormatException();
      return DateTime.fromMillisecondsSinceEpoch(value, isUtc: true);
    }

    final checked = date(j['checked']);
    final authorization = j['authorization'];
    var kind = CourseCacheExpiryKind.legacyReceipt;
    DateTime? end;
    if (j.containsKey('authorization')) {
      if (authorization is! Map ||
          j.containsKey('until') ||
          j.containsKey('retainedServerDeadline')) {
        throw const FormatException();
      }
      final name = authorization['kind'];
      final serverKind = CourseCacheExpiryKind.values
          .where((value) => value.name == name)
          .firstOrNull;
      if (serverKind == null ||
          serverKind == CourseCacheExpiryKind.legacyReceipt) {
        throw const FormatException();
      }
      kind = serverKind;
      end = date(authorization['serverUntil']);
      if (!kind.accepts(checked, end)) throw const FormatException();
    } else {
      end = date(j['until']);
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
      videoHash: digest('videoHash'),
      audioHash: digest('audioHash'),
      videoVersion: digest('videoVersion'),
      audioVersion: digest('audioVersion'),
      checkedAt: checked,
      until: end,
      expiryKind: kind,
      retainedServerDeadline: date(j['retainedServerDeadline']),
    );
  }
}

class CourseCacheFailure implements Exception {
  const CourseCacheFailure(this.message, {this.recheckNeeded = false});
  final String message;
  final bool recheckNeeded;
  @override
  String toString() => message;
}

enum _VersionProbe { matches, incompatible, unavailable }

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
  String? _busyKey, _operationKey;
  bool _closed = false, _deleting = false;
  int _revision = 0, _received = 0, _listVersion = 0;
  int get listVersion => _listVersion;
  int? _total;
  bool _checking = false;
  bool get checking => _checking;
  bool isUsable(CourseCacheEntry entry) => entry.usableAt(_clock());
  Duration? untilExpiry(CourseCacheEntry entry) =>
      entry.until?.difference(_clock());

  // Opening a lesson crosses several player adapters. Reuse the local digest
  // check only while the exact path's size, mtime and change time still match.
  final _verified = <String, ({FileStat stat, String hash})>{};
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
    _verified.clear();
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

  Future<void> _save(
    Directory dir,
    CourseCacheEntry e, {
    Future<void> Function()? validate,
  }) async {
    final temp = await _file(dir, 'entry.tmp'),
        dest = await _file(dir, 'entry.json');
    await temp.writeAsString(jsonEncode(e.toJson()), flush: true);
    try {
      if (validate != null) await validate();
      await temp.rename(dest.path);
    } catch (_) {
      if (await temp.exists()) await temp.delete();
      rethrow;
    }
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
    _checking = true;
    _operationKey = _busyKey =
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
      _busyKey = _operationKey = null;
      _checking = false;
      _control = null;
      _running = null;
      _listVersion++;
      _emit();
    }
  }

  static String _trackVersion(OfflineMediaTrack track, String object) => sha256
      .convert(
        utf8.encode(
          jsonEncode([track.id, track.codec, track.bandwidth, object]),
        ),
      )
      .toString();

  static bool _sameStat(FileStat a, FileStat b) =>
      a.type == b.type &&
      a.size == b.size &&
      a.modified == b.modified &&
      a.changed == b.changed;

  Future<String?> _hashFile(
    File file,
    int size,
    void Function() check, {
    bool useMemo = false,
  }) async {
    check();
    final before = await file.stat();
    if (size <= 0 ||
        before.type != FileSystemEntityType.file ||
        before.size != size) {
      return null;
    }
    final memo = _verified[file.path];
    if (useMemo && memo != null && _sameStat(before, memo.stat)) {
      return memo.hash;
    }
    final Digest digest;
    try {
      digest = await sha256
          .bind(
            file.openRead().map((chunk) {
              check();
              return chunk;
            }),
          )
          .first;
    } on FileSystemException {
      return null;
    }
    check();
    if (!_sameStat(before, await file.stat())) return null;
    final hash = digest.toString();
    if (_verified.length >= 16) _verified.remove(_verified.keys.first);
    _verified[file.path] = (stat: before, hash: hash);
    return hash;
  }

  static CourseCacheEntry _withoutReceipt(
    CourseCacheEntry entry, {
    DateTime? observed,
  }) {
    final retained = entry._knownServerDeadline;
    final earliest =
        observed != null && (retained == null || observed.isBefore(retained))
        ? observed
        : retained;
    return entry._withReceipt(
      null,
      null,
      CourseCacheExpiryKind.legacyReceipt,
      retainedServerDeadline: earliest,
    );
  }

  Future<void> _commitReceipt(
    Directory dir,
    CourseCacheEntry next,
    CourseCacheEntry fallback,
    Future<void> Function() check,
  ) async {
    await _save(dir, next, validate: check);
    try {
      await check();
    } catch (_) {
      // open() fences this chapter until the operation settles, including
      // the narrow interval between atomic rename and the final fence check.
      await _save(dir, fallback);
      rethrow;
    }
  }

  Future<bool> _reuse(
    Directory dir,
    CourseCacheEntry old,
    CourseCacheGrant grant,
    DownloadControl c,
    Future<void> Function() check,
    void Function(Uri) beforeRequest,
  ) async {
    if (old.quality != grant.media.quality ||
        old.videoHash == null ||
        old.videoVersion == null ||
        ((old.audioBytes > 0) != (grant.media.audio != null)) ||
        (old.audioBytes > 0 &&
            (old.audioHash == null || old.audioVersion == null))) {
      return false;
    }
    Future<_VersionProbe> probe(
      OfflineMediaTrack track,
      int size,
      String version,
    ) async {
      if (track.expectedBytes != null && track.expectedBytes != size) {
        return _VersionProbe.incompatible;
      }
      var reached = false;
      for (final url in track.urls) {
        await check();
        try {
          final object = await downloader.probeVersion(
            Uri.parse(url),
            grant.mediaHeaders,
            control: c,
            beforeRequest: beforeRequest,
          );
          reached = true;
          if (object != null && _trackVersion(track, object) == version) {
            return _VersionProbe.matches;
          }
        } catch (_) {
          c.check();
        }
      }
      return reached ? _VersionProbe.incompatible : _VersionProbe.unavailable;
    }

    final vf = await _file(dir, 'video.bin');
    if (await _hashFile(vf, old.videoBytes, c.check) != old.videoHash) {
      return false;
    }
    final videoStat = _verified[vf.path]!.stat;
    final audio = grant.media.audio;
    File? af;
    FileStat? audioStat;
    if (audio != null) {
      af = await _file(dir, 'audio.bin');
      if (await _hashFile(af, old.audioBytes, c.check) != old.audioHash) {
        return false;
      }
      audioStat = _verified[af.path]!.stat;
    }

    Future<bool> matched(
      OfflineMediaTrack track,
      int bytes,
      String version,
    ) async {
      final result = await probe(track, bytes, version);
      await check();
      if (result == _VersionProbe.unavailable) {
        throw const CourseCacheFailure('暂时无法核对媒体版本，请检查网络后重试。');
      }
      return result == _VersionProbe.matches;
    }

    if (!await matched(grant.media.video, old.videoBytes, old.videoVersion!) ||
        (audio != null &&
            !await matched(audio, old.audioBytes, old.audioVersion!))) {
      return false;
    }

    // Detect changes while HEAD was in flight; each track was hashed before
    // probing and both file stats must still refer to the same bytes.
    if (!_sameStat(videoStat, await vf.stat()) ||
        (af != null && !_sameStat(audioStat!, await af.stat()))) {
      return false;
    }
    await _commitReceipt(
      dir,
      old._withReceipt(grant.checkedAt, grant.validUntil, grant.expiryKind),
      old,
      check,
    );
    return true;
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
    CourseCacheEntry? previous;
    try {
      previous = await _read(dir, mid);
    } on FormatException {
      // A new authoritative proof can replace an unreadable legacy receipt.
    } on TypeError {
      // Same as malformed JSON.
    }
    if (previous?.id != pending.id) previous = null;
    c.check();
    CourseCacheEntry? shortened(DateTime? until) {
      final old = previous;
      if (until == null) return null;
      if (old == null) return _withoutReceipt(pending, observed: until);
      final known = old._knownServerDeadline;
      if (known != null && !until.isBefore(known)) return null;
      if (!old.complete ||
          !_clock().isBefore(until) ||
          !until.isAfter(old.checkedAt!)) {
        return _withoutReceipt(old, observed: until);
      }
      if (old.until != null && !until.isBefore(old.until!)) {
        // Preserve the older app-only window and the actual server cap.
        return old._withReceipt(
          old.checkedAt,
          old.until,
          old.expiryKind,
          retainedServerDeadline: until,
        );
      }
      return old._withReceipt(
        old.checkedAt,
        until,
        CourseCacheExpiryKind.serverDeadline,
      );
    }

    Future<void> stillCurrent() async {
      c.check();
      await _same(mid, rev);
      c.check();
    }

    final CourseCacheGrant g;
    try {
      final issued = await c.guard(access.authorize(v, p, q));
      g = issued.retainingServerDeadline(previous?._knownServerDeadline);
    } on CourseCacheAccessException catch (error) {
      final updated = error.revokesReceipt && previous?.complete == true
          ? _withoutReceipt(previous!, observed: error.knownUntil)
          : shortened(error.knownUntil);
      if (updated != null) {
        await _save(dir, updated, validate: stillCurrent);
      }
      rethrow;
    }
    if (g.mid != mid) throw _inactive;
    Future<void> check() async {
      c.check();
      await _same(mid, rev);
      await g.checkSession();
      c.check();
      final now = _clock();
      if (!g.expiryKind.usableAt(now, g.checkedAt, g.validUntil)) {
        throw const CourseCacheFailure('本次课程校验已到期，请重新联网确认。');
      }
    }

    void beforeRequest(Uri url) {
      c.check();
      if (rev != _revision) throw _inactive;
      g.checkTransport?.call(url, _clock());
    }

    await stillCurrent();
    // Even if the HEAD request fails later, never keep a longer offline
    // window than the purchase or explicit authorization we just observed.
    final shorter = shortened(g.validUntil);
    if (shorter != null) {
      await _save(dir, shorter, validate: stillCurrent);
      previous = shorter;
    }
    await check();
    final current = previous;
    if (current != null &&
        current.hasMedia &&
        await _reuse(dir, current, g, c, check, beforeRequest)) {
      return;
    }
    // Fresh authorization but no proof that old bytes are equivalent. Hide
    // them before touching any files; the replacement only commits atomically.
    _checking = false;
    // An interrupted replacement is not a playback receipt. It still has to
    // remember the effective server deadline even before the first media byte.
    final transferPending = _withoutReceipt(pending, observed: g.validUntil);
    await _save(dir, transferPending, validate: check);
    _listVersion++;
    _emit();
    final expiry = g.validUntil;
    final deadline = expiry == null
        ? null
        : Timer(expiry.difference(_clock()), () {
            if (!c.isInterrupted && rev == _revision && !_closed) {
              _error = '本次课程校验已到期，请重新联网确认。';
              c.interrupt();
            }
          });
    final paint = Stopwatch()..start();
    try {
      var offset = 0;
      Future<({int bytes, String? version})> track(
        OfflineMediaTrack t,
        String name,
      ) async {
        final output = await _file(dir, '$name.part');
        await _file(dir, '$name.part.resume');
        for (final url in t.urls) {
          await check();
          try {
            String? objectVersion;
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
              beforeRequest: beforeRequest,
              onCompleteVersion: (value) => objectVersion = value,
              mediaIdentity: sha256
                  .convert(utf8.encode('${pending.id}:${t.identity}'))
                  .toString(),
            );
            if (t.expectedBytes != null && n != t.expectedBytes) {
              throw const CourseCacheFailure('课程媒体接收不完整。');
            }
            offset += n;
            return (
              bytes: n,
              version: objectVersion == null
                  ? null
                  : _trackVersion(t, objectVersion!),
            );
          } catch (_) {
            c.check();
          }
        }
        throw const CourseCacheFailure('课程媒体接收不完整，请重试。');
      }

      final video = await track(g.media.video, 'video');
      final audio = g.media.audio == null
          ? null
          : await track(g.media.audio!, 'audio');
      final nv = video.bytes, na = audio?.bytes ?? 0;
      await check();
      for (final name in ['video', if (na > 0) 'audio']) {
        if (!await CourseCacheContainer.clearMp4(
          await _file(dir, '$name.part'),
          c.check,
          video: name == 'video',
          audio: name == 'audio' || g.media.audio == null,
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
          throw const CourseCacheFailure('实际媒体缺少所需音画轨、含保护标记或格式不受支持，未创建可播放缓存。');
        }
      }
      final videoHash = await _hashFile(
        await _file(dir, 'video.part'),
        nv,
        c.check,
      );
      final audioHash = na == 0
          ? null
          : await _hashFile(await _file(dir, 'audio.part'), na, c.check);
      if (videoHash == null || (na > 0 && audioHash == null)) {
        throw const CourseCacheFailure('课程媒体在校验期间发生变化，请重新缓存。');
      }
      await check();
      final vf = await _file(dir, 'video.bin');
      _verified.remove(vf.path);
      await (await _file(dir, 'video.part')).rename(vf.path);
      final af = await _file(dir, 'audio.bin');
      _verified.remove(af.path);
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
      await _commitReceipt(
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
          expiryKind: g.expiryKind,
          videoHash: videoHash,
          audioHash: audioHash,
          videoVersion: video.version,
          audioVersion: audio?.version,
        ),
        transferPending,
        check,
      );
    } finally {
      deadline?.cancel();
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
    final version = _listVersion;
    if (_operationKey == e.id || _deleting) {
      throw const CourseCacheFailure('正在检查课程缓存，请稍后再播放。');
    }
    await _same(e.mid, rev);
    final dir = await _dirs(e.mid, e.id);
    final CourseCacheEntry? fresh;
    try {
      fresh = await _read(dir, e.mid);
    } on FormatException {
      throw const CourseCacheFailure('无法确认课程缓存记录，请联网复核。', recheckNeeded: true);
    } on TypeError {
      throw const CourseCacheFailure('无法确认课程缓存记录，请联网复核。', recheckNeeded: true);
    }
    if (fresh == null || fresh.id != e.id || !fresh.usableAt(_clock())) {
      throw const CourseCacheFailure('缓存不完整或校验已到期，请联网复核。', recheckNeeded: true);
    }
    final v = await _file(dir, 'video.bin'), a = await _file(dir, 'audio.bin');
    if (!await v.exists() ||
        await v.length() != fresh.videoBytes ||
        (fresh.videoHash != null &&
            await _hashFile(v, fresh.videoBytes, () {}, useMemo: true) !=
                fresh.videoHash) ||
        (fresh.audioBytes > 0 &&
            (!await a.exists() ||
                await a.length() != fresh.audioBytes ||
                (fresh.audioHash != null &&
                    await _hashFile(
                          a,
                          fresh.audioBytes,
                          () {},
                          useMemo: true,
                        ) !=
                        fresh.audioHash)))) {
      throw const CourseCacheFailure(
        '课程缓存已被清理或损坏，联网复核时会重新缓存。',
        recheckNeeded: true,
      );
    }
    await _same(e.mid, rev);
    if (_operationKey == e.id || _deleting || _listVersion != version) {
      throw const CourseCacheFailure('课程缓存已变化，请重新打开。');
    }
    if (!fresh.usableAt(_clock())) {
      throw const CourseCacheFailure('本次课程校验已到期，请联网复核。', recheckNeeded: true);
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
