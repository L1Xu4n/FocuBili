import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'bilibili_auth_service.dart';
import 'native_playback_service.dart';

/// 定义桌面播放数据请求函数，测试可直接返回固定 JSON 而不访问网络。
typedef DesktopPlaybackJsonRequest =
    Future<String> Function(Uri endpoint, Map<String, String> headers);

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

  /// 生成视频与音频 CDN 共同使用的最小请求头，不把 Cookie 写入地址或日志。
  Map<String, String> get mediaHeaders {
    return <String, String>{
      'Accept': '*/*',
      'Accept-Encoding': 'identity',
      'Origin': 'https://www.bilibili.com',
      'Referer': referer,
      'User-Agent': BilibiliDesktopPlaybackSourceService.desktopUserAgent,
      if (cookieHeader.isNotEmpty) 'Cookie': cookieHeader,
    };
  }
}

/// 表示桌面端无法取得或解析安全播放源，并只携带可展示的中文说明。
class DesktopPlaybackSourceException implements Exception {
  /// 创建不会包含 Cookie、临时地址或响应正文的播放源异常。
  const DesktopPlaybackSourceException(this.message);

  final String message;

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
  }) : _authService = authService ?? BilibiliAuthService(),
       _requestJson = requestJson ?? _requestPlaybackJson;

  static const String desktopUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
      'AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/126.0.0.0 Safari/537.36';
  static final RegExp _bvidPattern = RegExp(
    r'^BV[0-9A-Za-z]{10}$',
    caseSensitive: false,
  );

  final BilibiliAuthService _authService;
  final DesktopPlaybackJsonRequest _requestJson;

  /// 校验视频参数，请求固定播放接口，并挑选不超过目标清晰度的兼容音视频轨。
  Future<DesktopPlaybackSources> load({
    required String bvid,
    required int cid,
    required int quality,
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
    final String referer = 'https://www.bilibili.com/video/$normalizedBvid';
    final String cookieHeader = await _authService.readCookieHeader();
    final Uri endpoint = Uri.https(
      'api.bilibili.com',
      '/x/player/playurl',
      <String, String>{
        'bvid': normalizedBvid,
        'cid': '$cid',
        'qn': '$quality',
        'fnval': '16',
        'fourk': '1',
      },
    );
    final String responseText = await _requestJson(endpoint, <String, String>{
      'Accept': 'application/json',
      'Referer': referer,
      'User-Agent': desktopUserAgent,
      if (cookieHeader.isNotEmpty) 'Cookie': cookieHeader,
    });
    return _parseResponse(
      responseText,
      requestedQuality: quality,
      referer: referer,
      cookieHeader: cookieHeader,
    );
  }

  /// 解析播放 JSON，拒绝错误码、缺失 DASH 和不属于 B 站媒体域名的地址。
  DesktopPlaybackSources _parseResponse(
    String responseText, {
    required int requestedQuality,
    required String referer,
    required String cookieHeader,
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
      final String serverMessage = _readText(root['message']);
      throw DesktopPlaybackSourceException(
        serverMessage.isEmpty || serverMessage == '0'
            ? '播放数据服务拒绝了本次请求（错误码：$code）。'
            : '无法取得播放数据：$serverMessage（错误码：$code）。',
      );
    }
    final Object? rawData = root['data'];
    if (rawData is! Map) {
      throw const DesktopPlaybackSourceException('播放数据服务没有返回视频信息。');
    }
    final Map<Object?, Object?> data = Map<Object?, Object?>.from(rawData);
    final Object? rawDash = data['dash'];
    if (rawDash is! Map) {
      throw const DesktopPlaybackSourceException('该视频没有可用的 DASH 播放数据。');
    }
    final Map<Object?, Object?> dash = Map<Object?, Object?>.from(rawDash);
    final int actualQuality =
        (data['quality'] as num?)?.toInt() ?? requestedQuality;
    final _DesktopMediaTrack videoTrack = _selectTrack(
      dash['video'],
      preferredQuality: actualQuality,
    );
    final List<_DesktopMediaTrack> audioTracks = _selectAudioTracks(
      dash['audio'],
    );
    if (videoTrack.urls.isEmpty) {
      throw const DesktopPlaybackSourceException('播放数据没有返回安全的视频地址。');
    }
    if (audioTracks.isEmpty) {
      throw const DesktopPlaybackSourceException('播放数据没有返回安全的音频地址。');
    }
    final List<String> audioUrls = <String>[
      for (final _DesktopMediaTrack track in audioTracks) ...track.urls,
    ];
    final Map<String, String> audioCodecByUrl = <String, String>{
      for (final _DesktopMediaTrack track in audioTracks)
        for (final String url in track.urls) url: track.codec,
    };
    return DesktopPlaybackSources(
      videoUrls: videoTrack.urls,
      audioUrls: List<String>.unmodifiable(audioUrls),
      audioCodecByUrl: Map<String, String>.unmodifiable(audioCodecByUrl),
      referer: referer,
      cookieHeader: cookieHeader,
      actualQuality: actualQuality > 0 ? actualQuality : requestedQuality,
      qualities: _parseQualities(
        data,
        dash,
        actualQuality > 0 ? actualQuality : requestedQuality,
      ),
      videoCodec: videoTrack.codec,
      audioCodec: audioTracks.first.codec,
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

  /// 从视频或音频数组选择最合适轨道；视频优先目标质量与 AVC，音频优先高码率。
  _DesktopMediaTrack _selectTrack(Object? rawTracks, {int? preferredQuality}) {
    if (rawTracks is! List) {
      return const _DesktopMediaTrack();
    }
    Map<Object?, Object?>? selected;
    int bestScore = -1;
    for (final Object? rawTrack in rawTracks) {
      if (rawTrack is! Map) {
        continue;
      }
      final Map<Object?, Object?> track = Map<Object?, Object?>.from(rawTrack);
      final int candidateQuality = (track['id'] as num?)?.toInt() ?? 0;
      if (preferredQuality != null && candidateQuality > preferredQuality) {
        continue;
      }
      final List<String> urls = _readMediaUrls(track);
      if (urls.isEmpty) {
        continue;
      }
      final String codec = _readText(track['codecs']).toLowerCase();
      final int exactQualityBonus =
          preferredQuality != null && candidateQuality == preferredQuality
          ? 1000000000
          : 0;
      final int compatibilityBonus = codec.contains('avc') ? 500000000 : 0;
      final int height = (track['height'] as num?)?.toInt() ?? 0;
      final int bandwidth = (track['bandwidth'] as num?)?.toInt() ?? 0;
      final int score =
          exactQualityBonus + compatibilityBonus + height * 100000 + bandwidth;
      if (score > bestScore) {
        selected = track;
        bestScore = score;
      }
    }
    if (selected == null) {
      return const _DesktopMediaTrack();
    }
    return _DesktopMediaTrack(
      urls: _readMediaUrls(selected),
      codec: _readText(selected['codecs']),
    );
  }

  /// 按 Windows 兼容性排列全部安全音频表示；通用 AAC 优先，其余编码保留为失败后的后备。
  List<_DesktopMediaTrack> _selectAudioTracks(Object? rawTracks) {
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
        score: _audioCompatibilityScore(codec, bandwidth),
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
  int _audioCompatibilityScore(String codec, int bandwidth) {
    final String normalized = codec.trim().toLowerCase();
    final int compatibility = normalized.contains('mp4a.40.2')
        ? 3
        : normalized.contains('mp4a') || normalized.contains('aac')
        ? 2
        : 1;
    return compatibility * 1000000000 + bandwidth.clamp(0, 999999999);
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

  /// 判断地址是否属于允许送入本机播放器的 B 站 HTTPS 媒体域名。
  bool _isSafeMediaUrl(String value) {
    final Uri? uri = Uri.tryParse(value);
    if (uri == null ||
        uri.scheme.toLowerCase() != 'https' ||
        uri.userInfo.isNotEmpty ||
        (uri.hasPort && uri.port != 443) ||
        uri.fragment.isNotEmpty) {
      return false;
    }
    final String host = uri.host.toLowerCase();
    return host == 'bilivideo.com' ||
        host.endsWith('.bilivideo.com') ||
        host == 'bilivideo.cn' ||
        host.endsWith('.bilivideo.cn');
  }

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

  /// 使用带超时的 HttpClient 读取固定播放接口，并拒绝非成功状态或空响应。
  static Future<String> _requestPlaybackJson(
    Uri endpoint,
    Map<String, String> headers,
  ) async {
    final HttpClient client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final HttpClientRequest request = await client.getUrl(endpoint);
      headers.forEach(request.headers.set);
      final HttpClientResponse response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      final String body = await response.transform(utf8.decoder).join();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw DesktopPlaybackSourceException(
          '播放数据服务暂时不可用（HTTP ${response.statusCode}）。',
        );
      }
      if (body.trim().isEmpty) {
        throw const DesktopPlaybackSourceException('播放数据服务返回了空内容。');
      }
      return body;
    } on TimeoutException {
      throw const DesktopPlaybackSourceException('请求播放数据超时，请检查网络。');
    } on SocketException {
      throw const DesktopPlaybackSourceException('无法连接播放数据服务，请检查网络。');
    } finally {
      client.close(force: true);
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
