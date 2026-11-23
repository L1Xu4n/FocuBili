import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'app_http_client.dart';
import 'bilibili_auth_service.dart';
import 'app_behavior_preferences_service.dart';
import 'bilibili_http_user_agent.dart';
import 'http_user_agent_preferences.dart';
import 'bilibili_wbi_signing_service.dart';
import 'native_playback_service.dart';
import 'media_url_policy.dart';
import 'playback_preferences_service.dart';
import 'playback_route_policy.dart';
import '../models/playback_preferences.dart';
import '../models/video_preview.dart';
import 'bilibili_course_link.dart';
import 'bilibili_course_service.dart';
import '../models/playback_request_diagnostic.dart';
import 'problem_diagnostics_service.dart';

/// 定义桌面播放数据请求函数，测试可直接返回固定 JSON 而不访问网络。
typedef DesktopPlaybackJsonRequest =
    Future<String> Function(Uri endpoint, Map<String, String> headers);

/// 一条 DASH 视频表示及其同编码的主备地址。
class DesktopVideoAlternative {
  /// 保留表示清晰度和码率，供选轨与解码回退使用。
  const DesktopVideoAlternative({
    required this.urls,
    required this.codec,
    required this.actualQuality,
    required this.bandwidth,
  });

  final List<String> urls;
  final String codec;
  final int actualQuality;
  final int bandwidth;

  /// 识别 AVC 表示，兼容不同 CDN 返回的编码拼写。
  bool get isAvc {
    final name = codec.toLowerCase();
    return name.startsWith('avc') || name == 'h264';
  }

  /// 识别可在省流模式下择优尝试的较新编码。
  bool get isEfficient {
    final name = codec.toLowerCase();
    return name.startsWith('hev') ||
        name.startsWith('hvc') ||
        name == 'h265' ||
        name.startsWith('av01') ||
        name == 'av1';
  }
}

/// 保存 Windows 播放器打开一条 B 站 DASH 视频需要的安全地址与界面信息。
class DesktopPlaybackSources {
  /// 创建已经过域名校验的桌面播放源。
  const DesktopPlaybackSources({
    required this.videoUrls,
    required this.audioUrls,
    this.audioCodecByUrl = const <String, String>{},
    required this.referer,
    required this.cookieHeader,
    required this.actualQuality,
    required this.qualities,
    required this.videoCodec,
    required this.audioCodec,
    this.validateSession,
    this.requestedQuality,
    this.returnedQuality,
    this.videoAlternatives = const [],
    this.selectedVideo,
  });

  final List<String> videoUrls;
  final List<String> audioUrls;
  final Map<String, String> audioCodecByUrl;
  final String referer;
  final String cookieHeader;
  final int actualQuality;
  final List<PlaybackQuality> qualities;
  final String videoCodec;
  final String audioCodec;
  final Future<void> Function()? validateSession;
  final int? requestedQuality;
  final int? returnedQuality;
  final List<DesktopVideoAlternative> videoAlternatives;
  final DesktopVideoAlternative? selectedVideo;

  /// 只复用响应中已解析出安全地址的确切清晰度。
  DesktopPlaybackSources? forQuality(int quality) {
    if (quality == actualQuality) return this;
    final permitted = returnedQuality;
    if (permitted == null || quality > permitted) return null;
    for (final video in videoAlternatives) {
      if (video.actualQuality != quality) continue;
      return DesktopPlaybackSources(
        videoUrls: video.urls,
        audioUrls: audioUrls,
        audioCodecByUrl: audioCodecByUrl,
        referer: referer,
        cookieHeader: cookieHeader,
        actualQuality: quality,
        qualities: qualities,
        videoCodec: video.codec,
        audioCodec: audioCodec,
        validateSession: validateSession,
        requestedQuality: quality,
        returnedQuality: permitted,
        videoAlternatives: videoAlternatives,
        selectedVideo: video,
      );
    }
    return null;
  }

  /// 生成视频与音频 CDN 共同使用的最小请求头，不把 Cookie 写入地址或日志。
  Map<String, String> get mediaHeaders {
    return <String, String>{
      'Accept': '*/*',
      'Accept-Encoding': 'identity',
      'Origin': 'https://www.bilibili.com',
      'Referer': referer,
      'User-Agent': BilibiliDesktopPlaybackSourceService.desktopUserAgent,
    };
  }
}

/// 表示桌面端无法取得或解析安全播放源，并只携带可展示的中文说明。
class DesktopPlaybackSourceException
    implements Exception, BilibiliRequestFailure {
  /// 创建不会包含 Cookie、临时地址或响应正文的播放源异常。
  const DesktopPlaybackSourceException(
    this.message, {
    this.httpStatus,
    this.apiCode,
  });

  final String message;
  @override
  final int? httpStatus;
  @override
  final int? apiCode;

  /// 返回可直接展示给普通用户的错误文字。
  @override
  String toString() => message;
}

/// 在 Dart 层请求 B 站 DASH 数据，供 Windows 媒体后端使用。
class BilibiliDesktopPlaybackSourceService {
  /// 创建桌面播放源服务；正式环境使用固定 HTTPS 接口，测试可注入请求函数和 Cookie 服务。
  BilibiliDesktopPlaybackSourceService({
    BilibiliAuthService? authService,
    DesktopPlaybackJsonRequest? requestJson,
    AppBehaviorPreferencesService? behaviorPreferences,
    ProblemDiagnosticsService? diagnosticsService,
  }) : _authService = authService ?? BilibiliAuthService(),
       _requestJson = requestJson,
       _diagnostics = diagnosticsService ?? ProblemDiagnosticsService(),
       _behaviorPreferences =
           behaviorPreferences ?? AppBehaviorPreferencesService();

  static const String desktopUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
      'AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/126.0.0.0 Safari/537.36';
  static final RegExp _bvidPattern = RegExp(
    r'^BV[0-9A-Za-z]{10}$',
    caseSensitive: false,
  );

  final BilibiliAuthService _authService;
  final DesktopPlaybackJsonRequest? _requestJson;
  final ProblemDiagnosticsService _diagnostics;
  final AppBehaviorPreferencesService _behaviorPreferences;
  late final _wbiSigner = _requestJson == null && HttpOverrides.current == null
      ? BilibiliWbiSigningService.shared
      : BilibiliWbiSigningService(requestJson: _readJson);
  static int _requestId = 0;

  /// The regular Windows player alone has current, parsed upload rights.
  /// Other callers of load() keep exactly their original request headers.
  Future<DesktopPlaybackSources> loadForVideo({
    required VideoPreview video,
    required int cid,
    required int quality,
    PlaybackCodecPreference codecPreference =
        PlaybackCodecPreference.compatible,
    bool preferDataSaving = false,
    bool useDesktopUserAgentOverride = true,
  }) async {
    final custom =
        useDesktopUserAgentOverride &&
            BilibiliHttpUserAgent.isKnownOrdinaryUpload(video) &&
            BilibiliHttpUserAgent.allowsPlaybackQuality(quality) &&
            video.parts.any((part) => part.cid == cid)
        ? await const HttpUserAgentPreferences().forRequest()
        : null;
    if (custom == null &&
        codecPreference == PlaybackCodecPreference.compatible &&
        !preferDataSaving) {
      return load(bvid: video.bvid, cid: cid, quality: quality);
    }
    return _load(
      bvid: video.bvid,
      cid: cid,
      quality: quality,
      customUserAgent: custom,
      codecPreference: codecPreference,
      preferDataSaving: preferDataSaving,
    );
  }

  /// 校验视频参数，请求固定播放接口，并挑选不超过目标清晰度的兼容音视频轨。
  Future<DesktopPlaybackSources> load({
    required String bvid,
    required int cid,
    required int quality,
  }) => _load(bvid: bvid, cid: cid, quality: quality);

  /// 请求普通视频播放数据，并将本次编码和网络偏好交给选轨器。
  Future<DesktopPlaybackSources> _load({
    required String bvid,
    required int cid,
    required int quality,
    String? customUserAgent,
    PlaybackCodecPreference codecPreference =
        PlaybackCodecPreference.compatible,
    bool preferDataSaving = false,
  }) async {
    final String normalizedBvid = bvid.trim();
    if (!_bvidPattern.hasMatch(normalizedBvid)) {
      throw const DesktopPlaybackSourceException('请输入有效的 BV 号。');
    }
    if (cid <= 0) {
      throw const DesktopPlaybackSourceException('该视频没有可播放的分P编号。');
    }
    if (quality <= 0) {
      throw const DesktopPlaybackSourceException('清晰度编号无效。');
    }
    final facts = <String, Object?>{
      'request_id': ++_requestId,
      'requested_quality': quality,
      'session_source': _authService.cookieStoreSource,
      'session_read': 'not_attempted',
      'auth_state': 'unknown',
      'wbi_signed': false,
      'wbi_fallback': false,
      'playurl_attempted': false,
      'stage': 'cookie',
      'outcome': 'error',
    };
    try {
      final String referer = 'https://www.bilibili.com/video/$normalizedBvid';
      final bool wbiEnabled = await _behaviorPreferences
          .loadWbiSigningEnabled();
      facts['wbi_enabled'] = wbiEnabled;
      final requestSession = await _authService.capturePlaybackSession(
        wbiEnabled ? '/x/player/wbi/playurl' : '/x/player/playurl',
      );
      final String cookieHeader = requestSession.snapshot.header;
      facts['session_read'] = 'ok';
      bool hasCookie(String name) =>
          RegExp(
            '(?:^|;)\\s*$name=([^;]+)',
          ).firstMatch(cookieHeader)?.group(1)?.trim().isNotEmpty ==
          true;
      facts['auth_state'] = hasCookie('SESSDATA')
          ? 'session_present_unverified'
          : 'anonymous';
      if (!hasCookie('SESSDATA') &&
          (hasCookie('bili_jct') || hasCookie('DedeUserID'))) {
        facts['session_read'] = 'partial';
        facts['auth_state'] = 'unknown';
      }
      for (final name in ['buvid3', 'buvid4', 'bili_ticket']) {
        facts['has_$name'] = hasCookie(name);
      }
      final headers = <String, String>{
        'Accept': 'application/json',
        'Referer': referer,
        'User-Agent': desktopUserAgent,
        if (cookieHeader.isNotEmpty) 'Cookie': cookieHeader,
      };
      var parameters = <String, String>{
        'bvid': normalizedBvid,
        'cid': '$cid',
        'qn': '$quality',
        'fnval': codecPreference == PlaybackCodecPreference.dataSaver
            ? '${16 | 2048}'
            : '16',
        'fourk': '1',
      };
      if (wbiEnabled) {
        facts['stage'] = 'signing';
        facts['endpoint_kind'] = 'nav';
        parameters = await _wbiSigner.signParameters(
          {...parameters, 'fnver': '0', 'web_location': '1315873'},
          headers: headers,
          scopeKey: requestSession.scopeKey,
          requestJson: (uri, headers) =>
              _readJson(uri, headers, facts, requestSession),
        );
        facts['wbi_signed'] = true;
      }
      final Uri endpoint = Uri.https(
        'api.bilibili.com',
        wbiEnabled ? '/x/player/wbi/playurl' : '/x/player/playurl',
      ).replace(query: BilibiliWbiSigningService.encodeQuery(parameters));
      facts['stage'] = 'playurl';
      final responseText = await _readJson(
        endpoint,
        customUserAgent != null &&
                BilibiliHttpUserAgent.allowsPlayback(endpoint)
            ? {...headers, 'User-Agent': customUserAgent}
            : headers,
        facts,
        requestSession,
      );
      facts['stage'] = 'parse';
      final sources = _parseResponse(
        responseText,
        preferences: await const PlaybackPreferencesService()
            .loadRoutePreferences(),
        requestedQuality: quality,
        referer: referer,
        cookieHeader: requestSession.snapshot.header,
        wbiEnabled: wbiEnabled,
        validateSession: requestSession.validate,
        codecPreference: codecPreference,
        preferDataSaving: preferDataSaving,
      );
      await requestSession.validate();
      facts['stage'] = 'complete';
      facts['outcome'] = sources.actualQuality < quality
          ? 'quality_downgrade'
          : 'success';
      return sources;
    } catch (error) {
      if (facts['stage'] == 'cookie') facts['session_read'] = 'error';
      if (error is BilibiliPlaybackSessionException) {
        facts['session_read'] =
            {'partial', 'conflict', 'changing'}.contains(error.state)
            ? error.state
            : 'error';
        facts['auth_state'] = 'unknown';
      }
      if ({'partial', 'conflict', 'changing'}.contains(facts['session_read'])) {
        throw BilibiliPlaybackSessionException(
          facts['session_read']! as String,
        );
      }
      if (error is BilibiliRequestFailure) {
        if (error.httpStatus != null) facts['http_status'] = error.httpStatus;
        if (error.apiCode != null) facts['api_code'] = error.apiCode;
      }
      rethrow;
    } finally {
      // Telemetry storage must never change playback results or error handling.
      try {
        await _diagnostics.recordPlaybackRequest(
          PlaybackRequestDiagnostic.fromPlatformMap(facts)!,
        );
      } catch (_) {}
    }
  }

  /// 保留真实 HTTP 状态；旧字符串夹具没有状态时不凭空填 200。
  Future<String> _readJson(
    Uri endpoint,
    Map<String, String> headers, [
    Map<String, Object?>? facts,
    BilibiliPlaybackSession? session,
  ]) async {
    facts?.remove('http_status');
    facts?.remove('api_code');
    if (facts != null) {
      facts['endpoint_kind'] = switch (endpoint.path) {
        '/x/web-interface/nav' => 'nav',
        '/x/player/wbi/playurl' => 'playurl_wbi',
        '/x/player/playurl' => 'playurl_legacy',
        _ => 'unknown',
      };
    }
    final requestHeaders = Map<String, String>.of(headers);
    if (session != null) {
      try {
        final cookie = await session.headerFor(endpoint.path);
        requestHeaders.remove('Cookie');
        if (cookie.isNotEmpty) requestHeaders['Cookie'] = cookie;
        for (final name in ['buvid3', 'buvid4', 'bili_ticket']) {
          facts?['has_$name'] = RegExp(
            '(?:^|;)\\s*$name=([^;]+)',
          ).hasMatch(cookie);
        }
      } on BilibiliPlaybackSessionException catch (error) {
        facts?['session_read'] = error.state;
        facts?['auth_state'] = 'unknown';
        rethrow;
      }
    }
    if (endpoint.path.endsWith('/playurl')) facts?['playurl_attempted'] = true;
    final String body;
    if (_requestJson case final request?) {
      body = await request(endpoint, requestHeaders);
    } else {
      final response = await _requestPlaybackJson(endpoint, requestHeaders);
      facts?['http_status'] = response.statusCode;
      body = response.body;
      try {
        var accepted = false;
        try {
          final decoded = jsonDecode(body);
          accepted =
              decoded is Map &&
              (decoded['code'] == 0 ||
                  (endpoint.path == '/x/web-interface/nav' &&
                      decoded['code'] == -101));
        } on FormatException {
          /* The parser below reports malformed data. */
        }
        if (accepted) {
          await session?.mergeResponse(endpoint.path, response.cookies);
        }
      } on BilibiliPlaybackSessionException catch (error) {
        facts?['session_read'] = error.state;
        facts?['auth_state'] = 'unknown';
        rethrow;
      }
    }
    try {
      final root = jsonDecode(body);
      if (root is Map && root['code'] is int) {
        facts?['api_code'] = root['code'];
      }
      final data = root is Map ? root['data'] : null;
      if (endpoint.path.endsWith('/playurl') &&
          data is Map &&
          data['quality'] is int) {
        facts?['returned_quality'] = data['quality'];
      }
    } on FormatException {
      // The existing parser owns the stable, safe format error.
    }
    return body;
  }

  /// 解析播放 JSON，拒绝错误码、缺失 DASH 和不属于 B 站媒体域名的地址。
  Future<DesktopPlaybackSources> loadCourse({
    required VideoPreview video,
    required VideoPart part,
    required int quality,
  }) async {
    if (!video.isCourse ||
        video.bvid != 'cheese:ss${video.courseSeasonId}' ||
        !BilibiliCourseLink.isStorageKey(video.bvid) ||
        (part.courseEpisodeId ?? 0) <= 0 ||
        (part.courseAid ?? 0) <= 0 ||
        part.cid <= 0 ||
        quality <= 0 ||
        !video.parts.any(
          (p) =>
              p.cid == part.cid &&
              p.courseEpisodeId == part.courseEpisodeId &&
              p.courseAid == part.courseAid,
        )) {
      throw const DesktopPlaybackSourceException('课程章节编号不完整，请重新打开课程。');
    }
    final cookie = await _authService.readCookieHeader();
    if (cookie.trim().isEmpty) {
      throw const DesktopPlaybackSourceException('请先登录购买课程的 B 站账号。');
    }
    final referer =
        'https://www.bilibili.com/cheese/play/ep${part.courseEpisodeId}';
    try {
      await BilibiliCourseService(
        readCookies: _authService.readCookieHeader,
        requestJson: (uri, session) => _readJson(uri, {
          'Accept': 'application/json',
          'Referer': referer,
          'User-Agent': desktopUserAgent,
          'Cookie': session,
        }),
      ).requirePurchasedCourse(video.courseSeasonId!, cookie);
    } on CourseLookupException catch (error) {
      throw DesktopPlaybackSourceException(error.message);
    }
    final endpoint = Uri.https('api.bilibili.com', '/pugv/player/web/playurl', {
      'avid': '${part.courseAid}',
      'ep_id': '${part.courseEpisodeId}',
      'cid': '${part.cid}',
      'qn': '$quality',
      'fnver': '0',
      'fnval': '16',
      'fourk': '1',
    });
    final response = await _readJson(endpoint, {
      'Accept': 'application/json',
      'Referer': referer,
      'User-Agent': desktopUserAgent,
      'Cookie': cookie,
    });

    if (cookie != await _authService.readCookieHeader()) {
      throw const DesktopPlaybackSourceException('登录状态已变化，请重新打开课程。');
    }

    /// Ensures a reused classroom URL still belongs to the purchasing account.
    Future<void> validateSession() async {
      if (cookie != await _authService.readCookieHeader()) {
        throw const BilibiliPlaybackSessionException('changing');
      }
    }

    return _parseResponse(
      response,
      preferences: await const PlaybackPreferencesService()
          .loadRoutePreferences(),
      requestedQuality: quality,
      referer: referer,
      cookieHeader: cookie,
      wbiEnabled: false,
      isCourse: true,
      validateSession: validateSession,
    );
  }

  /// 解析轨道并按本次偏好排列地址，保留编码优先级与会话校验。
  DesktopPlaybackSources _parseResponse(
    String responseText, {
    required int requestedQuality,
    required String referer,
    required String cookieHeader,
    required bool wbiEnabled,
    required PlaybackPreferences preferences,
    bool isCourse = false,
    Future<void> Function()? validateSession,
    PlaybackCodecPreference codecPreference =
        PlaybackCodecPreference.compatible,
    bool preferDataSaving = false,
  }) {
    final Object? decoded;
    try {
      decoded = jsonDecode(responseText);
    } on FormatException {
      throw const DesktopPlaybackSourceException('播放数据格式不正确，请稍后重试。');
    }
    if (decoded is! Map) {
      throw const DesktopPlaybackSourceException('播放数据格式不正确，请稍后重试。');
    }
    final Map<Object?, Object?> root = Map<Object?, Object?>.from(decoded);
    final int code = (root['code'] as num?)?.toInt() ?? -1;
    if (code != 0) {
      if (isCourse) {
        throw DesktopPlaybackSourceException(switch (code) {
          -101 || -401 => '登录已失效，请重新登录购买课程的账号。',
          -403 => '当前账号没有本节课的播放权限，请确认已购买且课程未过期。',
          -404 => '课程不存在或已下架。',
          _ => '课程播放请求失败（错误码：$code），请稍后重试。',
        });
      }
      if (code == -351) {
        throw DesktopPlaybackSourceException(
          wbiEnabled
              ? '播放数据服务拒绝了本次请求（错误码：-351）。WBI 签名已启用，请稍后重试或检查账号与网络状态。'
              : '播放数据服务拒绝了本次请求（错误码：-351）。请到“我的 → 个性化设置 → 播放与专注”开启“启用 WBI 签名”后重试；不保证恢复。',
          apiCode: code,
        );
      }
      throw DesktopPlaybackSourceException(
        '播放数据服务拒绝了本次请求（错误码：$code）。',
        apiCode: code,
      );
    }
    final Object? rawData = root['data'];
    if (rawData is! Map) {
      throw const DesktopPlaybackSourceException('播放数据服务没有返回视频信息。');
    }
    final Map<Object?, Object?> data = Map<Object?, Object?>.from(rawData);
    if (isCourse) {
      bool flagged(Object? value) =>
          value == true || (num.tryParse('$value') ?? 0) != 0;
      if (flagged(data['code'])) {
        throw const DesktopPlaybackSourceException('课程播放请求未获授权，请确认购买账号。');
      }
      if (data.containsKey('paid_access') &&
          data['paid_access'] != true &&
          int.tryParse('${data['paid_access']}') != 1) {
        throw const DesktopPlaybackSourceException('本节课未获得已购播放权限，请确认购买账号。');
      }
      if (flagged(data['is_drm']) || flagged(data['drm_tech_type'])) {
        throw const DesktopPlaybackSourceException(
          '本节课需要受保护的官方播放能力，请使用 B 站官方课堂。',
        );
      }
      if (flagged(data['is_preview'])) {
        throw const DesktopPlaybackSourceException('服务器仅提供试看内容，请确认购买账号和课程有效期。');
      }
    }
    final Object? rawDash = data['dash'];
    if (rawDash is! Map) {
      if (isCourse) {
        final segments = data['durl'];
        if (segments is! List ||
            segments.length != 1 ||
            segments.single is! Map) {
          throw const DesktopPlaybackSourceException(
            '课程未返回支持的单段媒体或 DASH 数据，请使用官方课堂。',
          );
        }
        final segment = Map<Object?, Object?>.from(segments.single as Map);
        final urls = _readMediaUrls({...segment, 'base_url': segment['url']});
        if (urls.isEmpty) {
          throw const DesktopPlaybackSourceException('课程没有返回安全的 HTTPS 媒体地址。');
        }
        final qn = (data['quality'] as num?)?.toInt() ?? requestedQuality;
        return DesktopPlaybackSources(
          validateSession: validateSession,
          videoUrls: PlaybackRoutePolicy.order(
            urls,
            preference: preferences.linePreference,
            preferNonPcdn: preferences.preferNonPcdn,
          ),
          audioUrls: const [],
          referer: referer,
          cookieHeader: cookieHeader,
          actualQuality: qn,
          requestedQuality: requestedQuality,
          returnedQuality: qn,
          qualities: _parseQualities(data, const {}, qn),
          videoCodec: 'muxed',
          audioCodec: '',
        );
      }
      throw const DesktopPlaybackSourceException('该视频没有可用的 DASH 播放数据。');
    }
    final Map<Object?, Object?> dash = Map<Object?, Object?>.from(rawDash);
    final reportedQuality = (data['quality'] as num?)?.toInt() ?? 0;
    final returnedQuality = reportedQuality > 0
        ? reportedQuality
        : requestedQuality;
    final maxQuality = math.min(requestedQuality, returnedQuality);
    final videoAlternatives = _selectVideoTracks(
      dash['video'],
      preferences: preferences,
      dataSaver: codecPreference == PlaybackCodecPreference.dataSaver,
    );
    final videoTrack = videoAlternatives
        .where((track) => track.actualQuality <= maxQuality)
        .firstOrNull;
    final List<_DesktopMediaTrack> audioTracks = _selectAudioTracks(
      dash['audio'],
      dataSaver:
          preferDataSaving ||
          codecPreference == PlaybackCodecPreference.dataSaver,
    );
    if (videoTrack == null) {
      throw const DesktopPlaybackSourceException('播放数据没有返回安全的视频地址。');
    }
    if (audioTracks.isEmpty) {
      throw const DesktopPlaybackSourceException('播放数据没有返回安全的音频地址。');
    }
    final List<String> audioUrls = <String>[
      for (final _DesktopMediaTrack track in audioTracks)
        ...PlaybackRoutePolicy.order(
          track.urls,
          preference: preferences.linePreference,
          preferNonPcdn: preferences.preferNonPcdn,
        ),
    ];
    final Map<String, String> audioCodecByUrl = <String, String>{
      for (final _DesktopMediaTrack track in audioTracks)
        for (final String url in track.urls) url: track.codec,
    };
    return DesktopPlaybackSources(
      validateSession: validateSession,
      videoUrls: videoTrack.urls,
      audioUrls: List<String>.unmodifiable(audioUrls),
      audioCodecByUrl: Map<String, String>.unmodifiable(audioCodecByUrl),
      referer: referer,
      cookieHeader: cookieHeader,
      actualQuality: videoTrack.actualQuality,
      requestedQuality: requestedQuality,
      returnedQuality: returnedQuality,
      qualities: _parseQualities(data, dash, videoTrack.actualQuality),
      videoCodec: videoTrack.codec,
      audioCodec: audioTracks.first.codec,
      selectedVideo: videoTrack,
      videoAlternatives: videoAlternatives,
    );
  }

  /// 从接口清晰度数组读取菜单；缺少描述时使用稳定中文名称。
  List<PlaybackQuality> _parseQualities(
    Map<Object?, Object?> data,
    Map<Object?, Object?> dash,
    int currentQuality,
  ) {
    final List<PlaybackQuality> result = <PlaybackQuality>[];
    final Object? rawIds = data['accept_quality'];
    final Object? rawDescriptions = data['accept_description'];
    final List<Object?> ids = rawIds is List ? rawIds : const <Object?>[];
    final List<Object?> descriptions = rawDescriptions is List
        ? rawDescriptions
        : const <Object?>[];
    for (int index = 0; index < ids.length; index += 1) {
      final int id = (ids[index] as num?)?.toInt() ?? 0;
      if (id <= 0 || result.any((PlaybackQuality item) => item.id == id)) {
        continue;
      }
      final String description = index < descriptions.length
          ? _readText(descriptions[index])
          : '';
      result.add(
        PlaybackQuality(
          id: id,
          label: description.isEmpty ? _qualityFallbackLabel(id) : description,
        ),
      );
    }
    if (result.isEmpty) {
      final Object? rawVideoTracks = dash['video'];
      if (rawVideoTracks is List) {
        for (final Object? rawTrack in rawVideoTracks) {
          if (rawTrack is! Map) {
            continue;
          }
          final int id = (rawTrack['id'] as num?)?.toInt() ?? 0;
          if (id > 0 && !result.any((PlaybackQuality item) => item.id == id)) {
            result.add(
              PlaybackQuality(id: id, label: _qualityFallbackLabel(id)),
            );
          }
        }
      }
    }
    if (!result.any((PlaybackQuality item) => item.id == currentQuality)) {
      result.add(
        PlaybackQuality(
          id: currentQuality,
          label: _qualityFallbackLabel(currentQuality),
        ),
      );
    }
    result.sort((PlaybackQuality left, PlaybackQuality right) {
      return right.id.compareTo(left.id);
    });
    return List<PlaybackQuality>.unmodifiable(result);
  }

  /// 按清晰度保留表示，只有同档 AVC 可回退时才优先尝试更省流的新编码。
  List<DesktopVideoAlternative> _selectVideoTracks(
    Object? rawTracks, {
    required PlaybackPreferences preferences,
    required bool dataSaver,
  }) {
    if (rawTracks is! List) return const [];
    final byQuality = <int, List<DesktopVideoAlternative>>{};
    for (final rawTrack in rawTracks.whereType<Map>()) {
      final Map<Object?, Object?> track = Map<Object?, Object?>.from(rawTrack);
      final quality = (track['id'] as num?)?.toInt() ?? 0;
      final List<String> urls = _readMediaUrls(track);
      if (quality <= 0 || urls.isEmpty) continue;
      (byQuality[quality] ??= []).add(
        DesktopVideoAlternative(
          urls: PlaybackRoutePolicy.order(
            urls,
            preference: preferences.linePreference,
            preferNonPcdn: preferences.preferNonPcdn,
          ),
          codec: _readText(track['codecs']),
          actualQuality: quality,
          bandwidth: (track['bandwidth'] as num?)?.toInt() ?? 0,
        ),
      );
    }
    final qualities = byQuality.keys.toList()..sort((a, b) => b.compareTo(a));
    final result = <DesktopVideoAlternative>[];
    for (final quality in qualities) {
      final tracks = byQuality[quality]!;
      tracks.sort((a, b) {
        if (a.isAvc != b.isAvc) return a.isAvc ? -1 : 1;
        return b.bandwidth.compareTo(a.bandwidth);
      });
      final baseline = tracks.first;
      if (dataSaver && baseline.isAvc && baseline.bandwidth > 0) {
        final efficient =
            tracks
                .where(
                  (track) =>
                      track.isEfficient &&
                      track.bandwidth > 0 &&
                      track.bandwidth < baseline.bandwidth,
                )
                .toList()
              ..sort((a, b) => a.bandwidth.compareTo(b.bandwidth));
        if (efficient.isNotEmpty) {
          tracks.remove(efficient.first);
          tracks.insert(0, efficient.first);
        }
      }
      result.addAll(tracks);
    }
    return List.unmodifiable(result);
  }

  /// 按 Windows 兼容性排列全部安全音频表示；通用 AAC 优先，其余编码保留为失败后的后备。
  List<_DesktopMediaTrack> _selectAudioTracks(
    Object? rawTracks, {
    required bool dataSaver,
  }) {
    if (rawTracks is! List) {
      return const <_DesktopMediaTrack>[];
    }
    final List<({int order, _DesktopMediaTrack track, int score})> candidates =
        <({int order, _DesktopMediaTrack track, int score})>[];
    for (int index = 0; index < rawTracks.length; index += 1) {
      final Object? rawTrack = rawTracks[index];
      if (rawTrack is! Map) {
        continue;
      }
      final Map<Object?, Object?> track = Map<Object?, Object?>.from(rawTrack);
      final List<String> urls = _readMediaUrls(track);
      if (urls.isEmpty) {
        continue;
      }
      final String codec = _readText(track['codecs']);
      final int bandwidth = (track['bandwidth'] as num?)?.toInt() ?? 0;
      candidates.add((
        order: index,
        track: _DesktopMediaTrack(urls: urls, codec: codec),
        score: _audioCompatibilityScore(codec, bandwidth, dataSaver: dataSaver),
      ));
    }
    candidates.sort((left, right) {
      final int scoreOrder = right.score.compareTo(left.score);
      return scoreOrder != 0 ? scoreOrder : left.order.compareTo(right.order);
    });
    return List<_DesktopMediaTrack>.unmodifiable(
      candidates.map((candidate) => candidate.track),
    );
  }

  /// 给桌面音频编码计算稳定优先级：AAC-LC 最通用，其他 AAC 次之，未知增强编码最后尝试。
  int _audioCompatibilityScore(
    String codec,
    int bandwidth, {
    required bool dataSaver,
  }) {
    final String normalized = codec.trim().toLowerCase();
    final int compatibility = normalized.contains('mp4a.40.2')
        ? 3
        : normalized.contains('mp4a') || normalized.contains('aac')
        ? 2
        : 1;
    final bitrate = bandwidth.clamp(0, 999999999);
    final score = !dataSaver
        ? bitrate
        : switch (bitrate) {
            0 => 0,
            <= 140000 => 1000000000 + bitrate,
            _ => 1000000000 - bitrate,
          };
    return compatibility * 2000000000 + score;
  }

  /// 从主地址与备用地址中去重，只保留 B 站媒体 CDN 的 HTTPS 地址。
  List<String> _readMediaUrls(Map<Object?, Object?> media) {
    final Set<String> urls = <String>{};
    final String primary = _readText(media['base_url']).isNotEmpty
        ? _readText(media['base_url'])
        : _readText(media['baseUrl']);
    if (_isSafeMediaUrl(primary)) {
      urls.add(primary);
    }
    final Object? rawBackups = media['backup_url'] ?? media['backupUrl'];
    if (rawBackups is List) {
      for (final Object? rawUrl in rawBackups) {
        final String url = _readText(rawUrl);
        if (_isSafeMediaUrl(url)) {
          urls.add(url);
        }
      }
    }
    return List<String>.unmodifiable(urls);
  }

  /// Applies the shared trusted-CDN policy before handing media to mpv.
  bool _isSafeMediaUrl(String value) => MediaUrlPolicy.isSafe(value);

  /// 为常见 B 站清晰度编号生成稳定中文名称。
  String _qualityFallbackLabel(int quality) {
    return switch (quality) {
      127 => '超高清 8K',
      120 => '超清 4K',
      116 => '高清 1080P60',
      112 => '高清 1080P+',
      80 => '高清 1080P',
      64 => '高清 720P',
      32 => '清晰 480P',
      16 => '流畅 360P',
      _ => '清晰度 $quality',
    };
  }

  /// 把未知 JSON 字段安全转换为去除首尾空白的文字。
  String _readText(Object? value) => value is String ? value.trim() : '';

  /// 使用共享连接池读取固定播放接口，保留真实状态和多条 Set-Cookie。
  static Future<({int statusCode, String body, List<String> cookies})>
  _requestPlaybackJson(Uri endpoint, Map<String, String> headers) async {
    try {
      final response = await AppHttpTransport.shared.send(
        uri: endpoint,
        headers: headers,
        followRedirects: false,
        timeout: const Duration(seconds: 20),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw DesktopPlaybackSourceException(
          '播放数据服务暂时不可用（HTTP ${response.statusCode}）。',
          httpStatus: response.statusCode,
        );
      }
      final String body = response.bodyUtf8;
      if (body.trim().isEmpty) {
        throw const DesktopPlaybackSourceException('播放数据服务返回了空内容。');
      }
      return (
        statusCode: response.statusCode,
        body: body,
        cookies: response.headerValues(HttpHeaders.setCookieHeader),
      );
    } on TimeoutException {
      throw const DesktopPlaybackSourceException('请求播放数据超时，请检查网络。');
    } on SocketException {
      throw const DesktopPlaybackSourceException('无法连接播放数据服务，请检查网络。');
    }
  }
}

/// 保存一次内部轨道挑选结果，不向界面暴露临时地址解析细节。
class _DesktopMediaTrack {
  /// 创建包含安全主备地址与编码名称的内部轨道。
  const _DesktopMediaTrack({this.urls = const <String>[], this.codec = ''});

  final List<String> urls;
  final String codec;
}
