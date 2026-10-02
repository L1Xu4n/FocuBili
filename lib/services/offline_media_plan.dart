import 'dart:convert';

import 'media_url_policy.dart';

/// 表示离线播放数据不能组成完整媒体，只携带可展示的说明。
class OfflineMediaPlanException implements Exception {
  /// 创建不会包含临时地址或 Cookie 的解析错误。
  const OfflineMediaPlanException(this.message);
  final String message;

  /// 只返回安全说明，避免外部日志意外包含接口正文。
  @override
  String toString() => message;
}

/// 一条可缓存的音频或视频轨，保留同一轨道的主备地址。
class OfflineMediaTrack {
  /// 接收已校验的轨道编号、地址与可选字节数。
  const OfflineMediaTrack({
    required this.id,
    required this.urls,
    this.codec = '',
    this.bandwidth = 0,
    this.expectedBytes,
  });
  final int id;
  final List<String> urls;
  final String codec;
  final int bandwidth;
  final int? expectedBytes;

  /// 刷新签名时识别是否仍为同一媒体文件，省去已完整下载轨道的重复传输。
  String get identity => '$id:$codec:$bandwidth:${Uri.parse(urls.first).path}';
}

/// 将播放接口转换为单个合并文件或一组完整的 DASH 音视频文件。
class OfflineMediaPlan {
  /// 创建一组可以原子发布到本机缓存的媒体。
  const OfflineMediaPlan({required this.video, this.audio});
  final OfflineMediaTrack video;
  final OfflineMediaTrack? audio;

  /// 下载记录使用实际选中视频轨的档位，而非接口的默认播放档位。
  int get quality => video.id;

  /// 读取成功的播放数据，拒绝错误码和不完整响应。
  static Map<Object?, Object?> decodeData(String text) {
    final Object? root;
    try {
      root = jsonDecode(text);
    } catch (_) {
      throw const OfflineMediaPlanException('下载播放数据格式不正确，请重试。');
    }
    if (root is! Map || root['code'] != 0 || root['data'] is! Map) {
      throw const OfflineMediaPlanException('无法取得下载地址，请检查登录状态或稍后重试。');
    }
    return Map<Object?, Object?>.from(root['data'] as Map);
  }

  /// 只列出实际返回下载地址的 DASH 档位；旧单文件响应继续按其实际上限处理。
  static Set<int> availableQualityIds(Map<Object?, Object?> data) {
    final dash = data['dash'];
    if (dash is Map) {
      final video = _dashTracks(dash['video'], video: true);
      final audio = _dashTracks(dash['audio'], video: false);
      if (video.isNotEmpty && audio.isNotEmpty) {
        return video.map((track) => track.id).toSet();
      }
    }
    final durl = data['durl'];
    if (durl is! List ||
        durl.length != 1 ||
        durl.single is! Map ||
        _urls(durl.single as Map, progressive: true).isEmpty) {
      return {};
    }
    final actual = _int(data['quality']);
    final accepted = data['accept_quality'];
    return accepted is List
        ? accepted.map(_int).where((id) => id > 0 && id <= actual).toSet()
        : (actual > 0 ? {actual} : {});
  }

  /// 优先解析音视频分离源；没有 DASH 时兼容原有单段合并媒体。
  factory OfflineMediaPlan.fromData(
    Map<Object?, Object?> data,
    int requestedQuality,
  ) {
    final dash = data['dash'];
    if (dash is Map) {
      final videos = _dashTracks(dash['video'], video: true);
      final audio = _dashTracks(dash['audio'], video: false);
      if (videos.isNotEmpty) {
        if (audio.isEmpty) {
          throw const OfflineMediaPlanException('没有取得完整音轨，请稍后重试缓存。');
        }
        final ids = videos.map((track) => track.id).toSet().toList()..sort();
        final below = ids.where((id) => id <= requestedQuality).toList();
        final selectedId = below.isEmpty ? ids.first : below.last;
        final candidates =
            videos.where((track) => track.id == selectedId).toList()
              ..sort(_compareTracks);
        audio.sort(_compareTracks);
        return OfflineMediaPlan(video: candidates.first, audio: audio.first);
      }
    }
    final durl = data['durl'];
    if (durl is! List || durl.isEmpty) {
      throw const OfflineMediaPlanException('当前视频没有可用的缓存地址。');
    }
    if (durl.length != 1) {
      throw const OfflineMediaPlanException('当前返回的是多段合并媒体，暂不能缓存，请稍后重试。');
    }
    if (durl.single is! Map) {
      throw const OfflineMediaPlanException('缓存地址数据不完整。');
    }
    final entry = durl.single as Map;
    final urls = _urls(entry, progressive: true);
    final quality = _int(data['quality']);
    if (urls.isEmpty) {
      throw const OfflineMediaPlanException('播放数据返回了不可用的下载地址。');
    }
    if (quality <= 0) {
      throw const OfflineMediaPlanException('播放数据没有返回有效的缓存清晰度。');
    }
    final size = _int(entry['size']);
    return OfflineMediaPlan(
      video: OfflineMediaTrack(
        id: quality,
        urls: urls,
        expectedBytes: size > 0 ? size : null,
      ),
    );
  }

  /// 解析官方音视频列表，忽略缺少可用地址或媒体类型不符的条目。
  static List<OfflineMediaTrack> _dashTracks(
    Object? raw, {
    required bool video,
  }) {
    if (raw is! List) return [];
    final tracks = <OfflineMediaTrack>[];
    for (final value in raw) {
      if (value is! Map) continue;
      final mime = (value['mimeType'] ?? value['mime_type'] ?? '').toString();
      if (mime.isNotEmpty && !mime.startsWith(video ? 'video/' : 'audio/')) {
        continue;
      }
      final urls = _urls(value);
      final id = _int(value['id']);
      if (urls.isEmpty || id <= 0) continue;
      final rawCodec = (value['codecs'] ?? '').toString();
      final codec = rawCodec.isNotEmpty
          ? rawCodec
          : switch (_int(value['codecid'])) {
              7 => 'avc1',
              12 => 'hev1',
              _ => '',
            };
      final size = _int(value['size']);
      tracks.add(
        OfflineMediaTrack(
          id: id,
          urls: urls,
          codec: codec,
          bandwidth: _int(value['bandwidth']),
          expectedBytes: size > 0 ? size : null,
        ),
      );
    }
    return tracks;
  }

  /// 同档位优先 AVC 视频和 AAC 音频，再选择较高码率以兼顾兼容性和音质。
  static int _compareTracks(OfflineMediaTrack a, OfflineMediaTrack b) {
    final codec = _codecScore(b.codec).compareTo(_codecScore(a.codec));
    return codec != 0 ? codec : b.bandwidth.compareTo(a.bandwidth);
  }

  /// 给常见且兼容的编码更高优先级，不依赖接口数组的顺序。
  static int _codecScore(String codec) =>
      codec.startsWith('avc') || codec.startsWith('mp4a')
      ? 3
      : codec.startsWith('hev') || codec.startsWith('hvc')
      ? 2
      : 1;

  /// 规范化并去重主备媒体地址，继续执行现有 CDN 域名限制。
  static List<String> _urls(Map values, {bool progressive = false}) {
    final result = <String>[];
    final backups = values['backupUrl'] ?? values['backup_url'];
    for (final raw in [
      progressive ? values['url'] : (values['baseUrl'] ?? values['base_url']),
      if (backups is List) ...backups,
    ]) {
      if (raw is! String) continue;
      final url = MediaUrlPolicy.normalize(raw.trim());
      if (url != null && !result.contains(url)) result.add(url);
    }
    return List.unmodifiable(result);
  }

  /// 容错读取接口整数，格式异常时返回零并由调用方拒绝该条数据。
  static int _int(Object? value) =>
      value is num ? value.toInt() : int.tryParse('$value') ?? 0;
}
