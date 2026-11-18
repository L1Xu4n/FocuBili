import 'dart:convert';
import 'dart:io';

import '../models/video_preview.dart';
import 'bilibili_auth_service.dart';
import 'bilibili_course_service.dart';
import 'cache_lifecycle.dart';
import 'media_url_policy.dart';
import 'course_cache_validity.dart';
import 'offline_media_plan.dart';

/// A safe error for UI; never holds responses, cookies, or temporary URLs.
class CourseCacheAccessException implements Exception {
  const CourseCacheAccessException(
    this.message, {
    this.revokesReceipt = true,
    this.knownUntil,
  });
  final String message;
  final bool revokesReceipt;

  /// An explicit earlier restriction already observed before a transient error.
  final DateTime? knownUntil;

  @override
  String toString() => message;
}

/// An in-memory authorization for exactly one checked lesson.
class CourseCacheGrant {
  const CourseCacheGrant({
    required this.mid,
    required this.media,
    required this.checkedAt,
    required this.validUntil,
    this.expiryKind = CourseCacheExpiryKind.serverDeadline,
    required this.checkSession,
    required this.mediaHeaders,
    this.checkTransport,
  });

  final int mid;
  final OfflineMediaPlan media;
  final DateTime checkedAt;
  final DateTime? validUntil;
  final CourseCacheExpiryKind expiryKind;
  final Future<void> Function() checkSession;
  final Map<String, String> mediaHeaders;

  /// A CDN signature authenticates only a request, never the offline receipt.
  final void Function(Uri, DateTime)? checkTransport;

  /// A successful response without a date does not erase a previously
  /// observed server deadline. Legacy app-only limits are not passed here.
  CourseCacheGrant retainingServerDeadline(DateTime? observed) =>
      observed == null || validUntil != null
      ? this
      : CourseCacheGrant(
          mid: mid,
          media: media,
          checkedAt: checkedAt,
          validUntil: observed,
          expiryKind: CourseCacheExpiryKind.serverDeadline,
          checkSession: checkSession,
          mediaHeaders: mediaHeaders,
          checkTransport: checkTransport,
        );
}

class CourseCacheAccess {
  CourseCacheAccess({
    CourseJsonRequest? requestJson,
    Future<String> Function()? readCookies,
    DateTime Function()? clock,
    BilibiliAuthService? authService,
  }) : _requestJson = requestJson ?? _requestOfficial,
       _readCookies = readCookies,
       _clock = clock ?? DateTime.now,
       _auth = authService ?? BilibiliAuthService();

  static const _nav = '/x/web-interface/nav';
  static const _paid = '/pugv/pay/web/my/paid';
  static const _season = '/pugv/view/web/season';
  static const _episodeList = '/pugv/view/web/ep/list';
  static const _play = '/pugv/player/web/playurl';
  static const _agent = BilibiliHttpAuthApi.desktopUserAgent;
  static const _sessionChanged = CourseCacheAccessException(
    '登录会话不完整或已变化，请重新登录购买课程的账号。',
  );
  static const _unavailable = CourseCacheAccessException(
    '当前账号无法确认本节课的有效购买或完整播放权限。',
  );
  static const _protected = CourseCacheAccessException(
    '课程含播放保护、试看或缓存限制，请使用 B 站官方课堂。',
  );
  static const _unsupported = CourseCacheAccessException(
    '当前课程未返回可确认的完整媒体格式，无法缓存。',
  );
  static const _expiry = CourseCacheAccessException('无法确认有效期限，课程缓存不可用。');
  static const _network = CourseCacheAccessException(
    '暂时无法联网核验课程，请检查网络后重试。',
    revokesReceipt: false,
  );

  static const _transportUnavailable = CourseCacheAccessException(
    '课程下载地址已到期或无法确认，请重新联网确认。',
    revokesReceipt: false,
  );

  final CourseJsonRequest _requestJson;
  final Future<String> Function()? _readCookies;
  final DateTime Function() _clock;
  final BilibiliAuthService _auth;

  /// Offline identity is valid only with a live local secure-session snapshot
  /// matching the app's already verified account scope. A remembered MID alone
  /// is never sufficient and no network request is made here.
  Future<int?> currentLocalMid() async {
    try {
      return (await _captureSession()).mid;
    } catch (_) {
      return null;
    }
  }

  /// Confirm purchase and exact metadata before requesting the official media
  /// plan. Never request UGC or try alternate modes to get around a restriction.
  Future<CourseCacheGrant> authorize(
    VideoPreview video,
    VideoPart part,
    int quality,
  ) async {
    DateTime? authorizationExpiry;
    void cap(DateTime? expires) {
      if (expires != null &&
          (authorizationExpiry == null ||
              expires.isBefore(authorizationExpiry!))) {
        authorizationExpiry = expires;
      }
    }

    CourseCacheAccessException withObservedLimit(
      CourseCacheAccessException error,
    ) {
      final observed = authorizationExpiry;
      final alreadyKnown = error.knownUntil;
      if (observed == null ||
          (alreadyKnown != null && !observed.isBefore(alreadyKnown))) {
        return error;
      }
      return CourseCacheAccessException(
        error.message,
        revokesReceipt: error.revokesReceipt,
        knownUntil: observed,
      );
    }

    try {
      final season = video.courseSeasonId;
      final ep = part.courseEpisodeId;
      final aid = part.courseAid;
      final cid = part.cid;
      if (season == null ||
          season <= 0 ||
          video.bvid != 'cheese:ss$season' ||
          ep == null ||
          ep <= 0 ||
          aid == null ||
          aid <= 0 ||
          cid <= 0 ||
          quality <= 0 ||
          !video.parts.any(
            (item) =>
                item.courseEpisodeId == ep &&
                item.courseAid == aid &&
                item.cid == cid,
          )) {
        throw _unavailable;
      }

      final account = await _captureSession();
      final checkedAt = _clock().toUtc();
      void restrictOfflineExpiry(Object? data) => cap(_offlineExpiry(data));

      Future<String> request(Uri uri, String cookie) async {
        if (cookie != account.header || !_isOfficial(uri)) {
          throw _sessionChanged;
        }
        await account.validate();
        final String response;
        try {
          response = await _requestJson(
            uri,
            cookie,
          ).timeout(const Duration(seconds: 30));
        } on CourseCacheAccessException {
          rethrow;
        } catch (_) {
          throw _network;
        }
        await account.validate();
        final envelope = jsonDecode(response);
        if (envelope is Map) {
          restrictOfflineExpiry(Map.of(envelope)..remove('data'));
        }
        if (uri.path == _paid) {
          final batch = _data(response)['data'];
          if (batch is List) {
            for (final row in batch) {
              if (row is Map && _integer(row['id']) == season) {
                if (_negativeStatus(row['status']) ||
                    (row.containsKey('is_expired') &&
                        _switch(row['is_expired']) != false)) {
                  throw _unavailable;
                }
                _checkRestrictions(row);
                restrictOfflineExpiry(row);
                if (row.containsKey('expire_at')) {
                  final raw = _integer(row['expire_at']);
                  if (raw != 0) {
                    final end = _epoch(raw);
                    if (end == null) throw _expiry;
                    cap(end);
                  }
                }
              }
            }
          }
        }
        return response;
      }

      // Cookies alone do not prove who the server authenticated. Check its
      // live identity before reading purchases or creating a downloadable plan.
      final identity = _data(
        await request(Uri.https('api.bilibili.com', _nav), account.header),
      );
      if (identity['isLogin'] != true ||
          _integer(identity['mid']) != account.mid) {
        throw _sessionChanged;
      }
      final courses = BilibiliCourseService(
        readCookies: () async {
          await account.validate();
          return account.header;
        },
        requestJson: request,
      );
      try {
        await courses.requirePurchasedCourse(season, account.header);
      } on CourseLookupException {
        // The existing lookup maps failures to display messages, but its
        // parser is not the authority on this captured account's lifetime.
        await account.validate();
        throw _unavailable;
      }
      final meta = _data(
        await request(
          Uri.https('api.bilibili.com', _season, {'ep_id': '$ep'}),
          account.header,
        ),
      );
      if (_integer(meta['season_id']) != season) throw _unavailable;
      final status = meta['user_status'];
      if (status is! Map ||
          _switch(status['payed']) != true ||
          _switch(status['is_expired']) != false ||
          _negativeStatus(meta['status'])) {
        throw _unavailable;
      }
      // Do not allow restrictions on another episode/recommended course to
      // stand in for this episode's own metadata; check the target below.
      final relevantMeta = Map.of(meta)
        ..remove('episodes')
        ..remove('recommend_seasons');
      _checkRestrictions(relevantMeta);
      restrictOfflineExpiry(relevantMeta);
      if (authorizationExpiry case final end? when !checkedAt.isBefore(end)) {
        throw _expiry;
      }
      if (_switch(meta['show_watermark']) != false) throw _protected;
      final purchaseWindow = _purchaseExpiry(meta, status);
      cap(purchaseWindow.end);
      if (authorizationExpiry case final end? when !checkedAt.isBefore(end)) {
        throw _expiry;
      }
      final episode = await _findEpisode(meta, season, ep, account, request);
      if (_integer(episode['aid']) != aid ||
          _integer(episode['cid']) != cid ||
          _switch(episode['episode_can_view']) != true ||
          _switch(episode['playable']) != true ||
          _negativeStatus(episode['status']) ||
          _negativeStatus(episode['ep_status'])) {
        throw _unavailable;
      }
      _checkRestrictions(episode);
      restrictOfflineExpiry(episode);
      if (authorizationExpiry case final end? when !checkedAt.isBefore(end)) {
        throw _expiry;
      }

      final mediaData = _data(
        await request(
          Uri.https('api.bilibili.com', _play, {
            'avid': '$aid',
            'ep_id': '$ep',
            'cid': '$cid',
            'qn': '$quality',
            'fnver': '0',
            'fnval': '16',
            'fourk': '1',
          }),
          account.header,
        ),
      );
      if ((mediaData.containsKey('code') && _integer(mediaData['code']) != 0) ||
          !_matchesIfPresent(mediaData, 'season_id', season) ||
          !_matchesIfPresent(mediaData, 'ep_id', ep) ||
          !_matchesIfPresent(mediaData, 'episode_id', ep) ||
          !_matchesIfPresent(mediaData, 'cid', cid) ||
          !_matchesIfPresent(mediaData, 'aid', aid) ||
          !_matchesIfPresent(mediaData, 'avid', aid)) {
        throw _unavailable;
      }
      _checkRestrictions(mediaData);
      restrictOfflineExpiry(mediaData);
      // A purchased course can still be served a preview or a protected
      // rendition. Missing evidence of a full, unprotected response is not
      // evidence that a cached copy would be equivalent.
      if (_switch(mediaData['is_preview']) != false ||
          !(_switch(mediaData['is_drm']) == false ||
              _switch(mediaData['drm_tech_type']) == false)) {
        throw _protected;
      }
      final media = _media(mediaData, quality);
      // Validate the address metadata, but do not fold URL expiry into
      // the offline receipt. Each network request checks its own URL again.
      for (final track in [media.video, ?media.audio]) {
        var usable = false;
        for (final raw in track.urls) {
          final end = _mediaExpiry(Uri.parse(raw));
          if (end == null || _clock().isBefore(end)) usable = true;
        }
        if (!usable) throw _transportUnavailable;
      }
      final expiry = authorizationExpiry;
      final expiryKind = expiry == null
          ? purchaseWindow.kind
          : CourseCacheExpiryKind.serverDeadline;
      void checkClock() {
        if (!expiryKind.usableAt(_clock().toUtc(), checkedAt, expiry)) {
          throw _expiry;
        }
      }

      Future<void> checkSession() async {
        checkClock();
        await account.validate();
        checkClock();
      }

      await checkSession();
      return CourseCacheGrant(
        mid: account.mid,
        media: media,
        checkedAt: checkedAt,
        validUntil: expiry,
        expiryKind: expiryKind,
        checkSession: checkSession,
        checkTransport: (uri, now) {
          if (uri.port != 443 || !MediaUrlPolicy.isSafe(uri.toString())) {
            throw _unsupported;
          }
          final end = _mediaExpiry(uri);
          if (end != null && !now.isBefore(end)) {
            throw _transportUnavailable;
          }
        },
        mediaHeaders: Map.unmodifiable({
          'Accept': '*/*',
          'Accept-Encoding': 'identity',
          'Origin': 'https://www.bilibili.com',
          'Referer': 'https://www.bilibili.com/cheese/play/ep$ep',
          'User-Agent': _agent,
        }),
      );
    } on CourseCacheAccessException catch (error) {
      throw withObservedLimit(error);
    } catch (_) {
      throw withObservedLimit(_network);
    }
  }

  Future<_CourseCacheSession> _captureSession() async {
    final revision = CacheLifecycle.account.value;
    final scope = CacheLifecycle.accountScope;
    final expected = RegExp(r'^mid:([1-9][0-9]*)$').firstMatch(scope)?.group(1);
    if (expected == null) throw _sessionChanged;
    try {
      final Future<String> Function() read;
      if (_readCookies case final injected?) {
        read = injected;
      } else {
        // The Apple secure store additionally checks its native generation;
        // other platforms still fence account writes and re-read the header.
        final native = await _auth
            .capturePlaybackSession(_play)
            .timeout(const Duration(seconds: 10));
        read = () async {
          await native.validate();
          // Non-Apple snapshots fence Dart account writes but can otherwise
          // retain the old header after an external/system cookie change.
          final current = await _auth.capturePlaybackSession(_play);
          await native.validate();
          return current.headerFor(_play);
        };
      }
      final header = await read().timeout(const Duration(seconds: 10));
      final mid = _cookieMid(header);
      if (mid == null ||
          '$mid' != expected ||
          scope != CacheLifecycle.accountScope ||
          revision != CacheLifecycle.account.value) {
        throw _sessionChanged;
      }
      return _CourseCacheSession(mid, header, read, scope, revision);
    } catch (_) {
      throw _sessionChanged;
    }
  }

  static int? _cookieMid(String header) {
    if (RegExp(r'[\x00-\x1f\x7f]').hasMatch(header)) return null;
    String? session;
    String? uid;
    for (final entry in header.split(';')) {
      final separator = entry.indexOf('=');
      if (separator <= 0) continue;
      final name = entry.substring(0, separator).trim();
      final value = entry.substring(separator + 1).trim();
      if (name == 'SESSDATA') {
        if (session != null ||
            value.isEmpty ||
            value == '""' ||
            value.contains(RegExp(r'\s'))) {
          return null;
        }
        session = value;
      } else if (name == 'DedeUserID') {
        if (uid != null || !RegExp(r'^[1-9][0-9]*$').hasMatch(value)) {
          return null;
        }
        uid = value;
      }
    }
    return session == null ? null : int.tryParse(uid ?? '');
  }

  static Future<Map> _findEpisode(
    Map seasonData,
    int season,
    int ep,
    _CourseCacheSession account,
    CourseJsonRequest request,
  ) async {
    Map? match(Object? rows) {
      if (rows is! List) throw _unavailable;
      Map? result;
      for (final row in rows) {
        if (row is Map && _integer(row['id']) == ep) {
          if (result != null) throw _unavailable;
          result = row;
        }
      }
      return result;
    }

    final initial = match(seasonData['episodes']);
    if (initial != null) return initial;
    final page = seasonData['episode_page'];
    final initialRows = seasonData['episodes'] as List;
    if (page is! Map ||
        !(_switch(page['next']) == true ||
            (_integer(page['total']) ?? 0) > initialRows.length)) {
      throw _unavailable;
    }
    final seen = <int>{};
    for (var pn = 1; pn <= 100; pn++) {
      final batch = _data(
        await request(
          Uri.https('api.bilibili.com', _episodeList, {
            'season_id': '$season',
            'pn': '$pn',
            'ps': '100',
          }),
          account.header,
        ),
      );
      if (!_matchesIfPresent(batch, 'season_id', season)) throw _unavailable;
      final rows = batch['items'];
      final lesson = match(rows);
      if (lesson != null) return lesson;
      final before = seen.length;
      for (final item in rows as List) {
        if (item is! Map || (_integer(item['id']) ?? 0) <= 0) {
          throw _unavailable;
        }
        seen.add(_integer(item['id'])!);
      }
      if (seen.length == before) break;
      final paging = batch['page'];
      if (paging is! Map || _switch(paging['next']) != true) break;
    }
    throw _unavailable;
  }

  static Map _data(String response) {
    final value = jsonDecode(response);
    if (value is! Map) throw _network;
    final code = _integer(value['code']);
    if (code == -101 || code == -401) throw _sessionChanged;
    if (code == -403 || code == -404) throw _unavailable;
    if (code != 0 || value['data'] is! Map) throw _network;
    _checkRestrictions(Map.of(value)..remove('data'));
    return value['data'] as Map;
  }

  static int? _integer(Object? value) => switch (value) {
    int n => n,
    String text when RegExp(r'^-?[0-9]+$').hasMatch(text) => int.tryParse(text),
    _ => null,
  };

  static bool? _switch(Object? value) => switch (value) {
    true || 1 || '1' || 'true' => true,
    false || 0 || '0' || 'false' => false,
    _ => null,
  };

  static bool _negativeStatus(Object? value) =>
      value != null && (_integer(value) ?? -1) < 0;

  static bool _matchesIfPresent(Map value, String key, int expected) =>
      !value.containsKey(key) || _integer(value[key]) == expected;

  static DateTime? _epoch(int? timestamp) {
    if (timestamp == null) return null;
    final millis = switch (timestamp) {
      >= 1000000000 && <= 9999999999 => timestamp * 1000,
      >= 1000000000000 && <= 9999999999999 => timestamp,
      _ => null,
    };
    return millis == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true);
  }

  static ({DateTime? end, CourseCacheExpiryKind kind}) _purchaseExpiry(
    Map metadata,
    Map user,
  ) {
    final raw = _integer(user['expire_at']);
    final expiry = _epoch(raw);
    if (expiry != null) {
      return (end: expiry, kind: CourseCacheExpiryKind.serverDeadline);
    }
    if (user.containsKey('expire_at') && raw != 0) throw _expiry;
    final days = _integer(metadata['expiry_day']);
    if (metadata.containsKey('expiry_day') && days != 0) throw _expiry;

    // A zero timestamp also appears for anonymous, unpurchased courses. It
    // is not proof by itself. Purchase and complete playback are independent
    // checks, and only recognized provider text can disambiguate zero.
    final notes = [
      user['user_expiry_content'],
      metadata['expiry_info_content'],
    ].where((value) => value != null && value != '').toList();
    if (notes.any((value) => value is! String || value.trim() != '长期有效')) {
      throw _expiry;
    }
    if (notes.isNotEmpty) {
      return (end: null, kind: CourseCacheExpiryKind.explicitLongTerm);
    }
    if (user.containsKey('expire_at') || metadata.containsKey('expiry_day')) {
      throw _expiry;
    }
    // Some successful purchased responses supply no duration metadata. This
    // is not a promise of permanent rights. Rechecks can still revoke or cap.
    return (end: null, kind: CourseCacheExpiryKind.noDeclaredDeadline);
  }

  static String _canonical(String key) =>
      key.toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '');

  static const _offlineExpiryFields = {
    'offlineexpiresat',
    'offlineexpireat',
    'offlinevaliduntil',
    'cacheexpiresat',
    'cacheexpireat',
    'cachevaliduntil',
    'offlineauthorizationexpiresat',
    'offlineauthorizationexpireat',
  };

  static DateTime? _offlineExpiry(Object? value) {
    DateTime? earliest;
    final pending = <Object?>[value];
    while (pending.isNotEmpty) {
      final node = pending.removeLast();
      if (node is List) {
        pending.addAll(node);
      } else if (node is Map) {
        for (final item in node.entries) {
          if (_offlineExpiryFields.contains(_canonical('${item.key}'))) {
            final end = _epoch(_integer(item.value));
            if (end == null) throw _expiry;
            if (earliest == null || end.isBefore(earliest)) earliest = end;
          } else if (item.value is List || item.value is Map) {
            pending.add(item.value);
          }
        }
      }
    }
    return earliest;
  }

  static void _checkRestrictions(Object? value) {
    final pending = <Object?>[value];
    while (pending.isNotEmpty) {
      final node = pending.removeLast();
      if (node is List) {
        pending.addAll(node);
      } else if (node is Map) {
        for (final item in node.entries) {
          final key = _canonical('${item.key}');
          final raw = item.value;
          if (const {
            'allowdownload',
            'candownload',
            'downloadable',
            'isdownloadable',
            'downloadallowed',
            'allowofflinecache',
            'offlinecacheallowed',
            'allowoffline',
            'canoffline',
            'offlineallowed',
            'allowcache',
            'cancache',
            'cacheallowed',
            'paidaccess',
          }.contains(key)) {
            if (_switch(raw) != true) throw _protected;
          } else if (const {
                'ispreview',
                'preview',
                'previewonly',
                'ispaypreview',
                'downloadforbidden',
                'forbiddownload',
                'disabledownload',
                'nodownload',
                'disableoffline',
                'nooffline',
                'offlineforbidden',
                'forbidoffline',
                'disablecache',
                'nocache',
                'cacheforbidden',
                'forbidcache',
              }.contains(key) ||
              key.contains('drm') ||
              key.contains('encrypt') ||
              key.contains('protect') ||
              key.contains('license') ||
              ((key.contains('download') ||
                      key.contains('offline') ||
                      key.contains('cache')) &&
                  const [
                    'forbid',
                    'prohibit',
                    'disabl',
                    'deny',
                    'restrict',
                  ].any(key.contains)) ||
              (key.contains('watermark') &&
                  (key != 'watermarkinterval' ||
                      _switch(node['show_watermark']) != false))) {
            // Unknown values (including nested configurations) are not false.
            if (_switch(raw) != false) throw _protected;
          }
          if (raw is Map || raw is List) pending.add(raw);
        }
      }
    }
  }

  static OfflineMediaPlan _media(Map data, int quality) {
    final durl = data['durl'];
    final dash = data['dash'];
    final split = dash != null;
    if (split) {
      if (dash is! Map ||
          dash['video'] is! List ||
          dash['audio'] is! List ||
          (durl != null && (durl is! List || durl.isNotEmpty))) {
        throw _unsupported;
      }
    } else {
      if (durl is! List || durl.length != 1 || durl.single is! Map) {
        throw _unsupported;
      }
      final format = data['format'];
      if (format != null &&
          (format is! String ||
              !RegExp(r'^(?:mp4|hdmp4)(?:[0-9]+)?$').hasMatch(format))) {
        throw _unsupported;
      }
    }
    try {
      final candidates = Map<Object?, Object?>.from(data);
      if (dash is Map) {
        List<Map> mp4(Object? raw, String type) => (raw as List)
            .whereType<Map>()
            .where((row) {
              final mime = row['mimeType'] ?? row['mime_type'];
              return mime == null || mime == '$type/mp4';
            })
            .toList(growable: false);
        candidates['dash'] = {
          'video': mp4(dash['video'], 'video'),
          'audio': mp4(dash['audio'], 'audio'),
        };
      }
      final result = OfflineMediaPlan.fromData(candidates, quality);
      if (result.quality > quality) throw _unsupported;
      final audio = result.audio;
      if (split &&
          (audio == null ||
              !RegExp(
                r'^(?:avc[13]|hev1|hvc1)(?:\.|$)',
              ).hasMatch(result.video.codec) ||
              !RegExp(r'^mp4a(?:\.|$)').hasMatch(audio.codec))) {
        throw _unsupported;
      }
      for (final track in [result.video, ?audio]) {
        for (final address in track.urls) {
          final uri = Uri.parse(address);
          final path = uri.path.toLowerCase();
          if (uri.port != 443 ||
              !MediaUrlPolicy.isSafe(address) ||
              !(path.endsWith('.mp4') || (split && path.endsWith('.m4s')))) {
            throw _unsupported;
          }
        }
      }
      return result;
    } on OfflineMediaPlanException {
      throw _unsupported;
    }
  }

  static DateTime? _mediaExpiry(Uri url) {
    final all = url.queryParametersAll;
    DateTime? expiry;
    var signed = false;
    for (final parameter in all.entries) {
      final key = _canonical(parameter.key);
      final values = parameter.value;
      final known = const {
        'deadline',
        'expires',
        'expire',
        'expiresat',
        'expireat',
        'wstime',
        'authkey',
      }.contains(key);
      if (const {
        'sign',
        'signature',
        'upsig',
        'token',
        'accesskey',
        'wssecret',
        'authkey',
      }.contains(key)) {
        signed = true;
      }
      if (!known) continue;
      if (values.length != 1) throw _transportUnavailable;
      final raw = values.single;
      final timestamp = switch (key) {
        'wstime' => int.tryParse(raw, radix: 16),
        'authkey' => _integer(raw.split('-').first),
        _ => _integer(raw),
      };
      final next = _epoch(timestamp);
      if (next == null) throw _transportUnavailable;
      if (expiry == null || next.isBefore(expiry)) expiry = next;
    }
    if (signed && expiry == null) throw _transportUnavailable;
    return expiry;
  }

  static bool _isOfficial(Uri uri) =>
      uri.scheme == 'https' &&
      uri.host == 'api.bilibili.com' &&
      uri.port == 443 &&
      uri.userInfo.isEmpty &&
      !uri.hasFragment &&
      const {_nav, _paid, _season, _episodeList, _play}.contains(uri.path);

  static Future<String> _requestOfficial(Uri uri, String cookie) async {
    if (!_isOfficial(uri)) throw _network;
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 12);
    try {
      final request = await client
          .getUrl(uri)
          .timeout(const Duration(seconds: 15));
      request.followRedirects = false;
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      request.headers.set(
        HttpHeaders.refererHeader,
        'https://www.bilibili.com/',
      );
      request.headers.set(HttpHeaders.userAgentHeader, _agent);
      request.headers.set(HttpHeaders.cookieHeader, cookie);
      final response = await request.close().timeout(
        const Duration(seconds: 15),
      );
      if (response.statusCode == HttpStatus.unauthorized) throw _sessionChanged;
      if (response.statusCode == HttpStatus.forbidden ||
          response.statusCode == HttpStatus.notFound) {
        throw _unavailable;
      }
      if (response.statusCode != HttpStatus.ok) throw _network;
      return await response
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 15));
    } finally {
      client.close(force: true);
    }
  }
}

class _CourseCacheSession {
  const _CourseCacheSession(
    this.mid,
    this.header,
    this._read,
    this._scope,
    this._revision,
  );

  final int mid;
  final String header;
  final Future<String> Function() _read;
  final String _scope;
  final int _revision;

  bool get _current =>
      _revision == CacheLifecycle.account.value &&
      _scope == CacheLifecycle.accountScope;

  Future<void> validate() async {
    if (!_current) throw CourseCacheAccess._sessionChanged;
    final String current;
    try {
      current = await _read().timeout(const Duration(seconds: 10));
    } catch (_) {
      throw CourseCacheAccess._sessionChanged;
    }
    if (!_current || current != header) throw CourseCacheAccess._sessionChanged;
  }
}
