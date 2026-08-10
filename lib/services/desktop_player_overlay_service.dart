import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../models/player_overlay_data.dart';
import 'bilibili_auth_service.dart';
import 'player_overlay_service.dart';

/// 保存一次受限桌面网络请求的状态码与响应字节，便于测试替换真实网络。
class DesktopOverlayHttpResponse {
  /// 创建不包含请求地址、请求头或 Cookie 的网络响应。
  const DesktopOverlayHttpResponse({
    required this.statusCode,
    required this.bodyBytes,
  });

  final int statusCode;
  final Uint8List bodyBytes;
}

/// 定义 Windows 字幕与弹幕服务使用的受限 GET 请求函数。
typedef DesktopOverlayRequest =
    Future<DesktopOverlayHttpResponse> Function(
      Uri endpoint,
      Map<String, String> headers,
      int maximumBytes,
    );

/// 在 Windows 上直接读取官方字幕与弹幕接口，同时维持与 Android 相同的安全边界。
class DesktopPlayerOverlayService implements PlayerOverlayService {
  /// 创建桌面叠加数据服务；测试可注入内存请求函数和内存 Cookie 容器。
  DesktopPlayerOverlayService({
    BilibiliAuthService? authService,
    DesktopOverlayRequest? request,
  }) : _authService = authService ?? BilibiliAuthService(),
       _request = request ?? _performLimitedGet;

  static const int _maximumSubtitleMetadataBytes = 1024 * 1024;
  static const int _maximumSubtitleDocumentBytes = 4 * 1024 * 1024;
  static const int _maximumDanmakuSegmentBytes = 6 * 1024 * 1024;
  static const int _maximumSubtitleTracks = 20;
  static const int _maximumSubtitleCues = 10000;
  static const int _maximumSubtitleTrackIdLength = 32;
  static const int _maximumSubtitleDurationMilliseconds = 48 * 60 * 60 * 1000;
  static const int _defaultDanmakuColor = 0xFFFFFF;
  static const int _defaultDanmakuMode = 1;
  static final RegExp _bvidPattern = RegExp(
    r'^BV[0-9A-Za-z]{10}$',
    caseSensitive: false,
  );
  static final RegExp _subtitleTrackIdPattern = RegExp(r'^[0-9]+$');

  final BilibiliAuthService _authService;
  final DesktopOverlayRequest _request;
  String? _subtitleSessionBvid;
  int? _subtitleSessionCid;
  Map<String, Uri> _readableSubtitleUrls = const <String, Uri>{};

  /// 校验视频编号后读取官方播放器元数据，并仅向页面返回无敏感信息的轨道描述。
  @override
  Future<SubtitleTrackLoadResult> loadSubtitleTracks({
    required String bvid,
    required int cid,
  }) async {
    final String normalizedBvid = bvid.trim();
    if (!_isValidVideo(normalizedBvid, cid)) {
      return const SubtitleTrackLoadResult.unavailable(message: '字幕请求参数无效。');
    }
    try {
      final Uri endpoint = Uri.https(
        'api.bilibili.com',
        '/x/player/v2',
        <String, String>{'bvid': normalizedBvid, 'cid': cid.toString()},
      );
      final DesktopOverlayHttpResponse response = await _request(
        endpoint,
        await _buildHeaders(
          bvid: normalizedBvid,
          accept: 'application/json',
          includeCookie: true,
        ),
        _maximumSubtitleMetadataBytes,
      );
      if (response.statusCode < 200 || response.statusCode > 299) {
        return const SubtitleTrackLoadResult.unavailable();
      }
      final Map<String, Object?> root = _decodeJsonObject(response.bodyBytes);
      final int code = _readInt(root['code'], fallback: -1);
      if (code == -101) {
        _clearSubtitleSession();
        return const SubtitleTrackLoadResult.loginRequired();
      }
      if (code != 0 || root['data'] is! Map) {
        _clearSubtitleSession();
        return const SubtitleTrackLoadResult.unavailable();
      }
      return _parseSubtitleTracks(
        bvid: normalizedBvid,
        cid: cid,
        rawData: Map<Object?, Object?>.from(root['data']! as Map),
      );
    } catch (_) {
      _clearSubtitleSession();
      return const SubtitleTrackLoadResult.unavailable();
    }
  }

  /// 读取当前会话中已确认安全的字幕地址，并把 JSON 内容转换为有限字幕条目。
  @override
  Future<SubtitleCueLoadResult> loadSubtitleCues({
    required String bvid,
    required int cid,
    required String trackId,
  }) async {
    final String normalizedBvid = bvid.trim();
    final String normalizedTrackId = trackId.trim();
    if (!_isValidVideo(normalizedBvid, cid) ||
        !_isValidSubtitleTrackId(normalizedTrackId)) {
      return const SubtitleCueLoadResult.unavailable(message: '字幕请求参数无效。');
    }
    if (_subtitleSessionBvid != normalizedBvid || _subtitleSessionCid != cid) {
      return const SubtitleCueLoadResult.locked(message: '请先读取当前视频的字幕轨道。');
    }
    final Uri? endpoint = _readableSubtitleUrls[normalizedTrackId];
    if (endpoint == null) {
      return const SubtitleCueLoadResult.locked();
    }
    try {
      final DesktopOverlayHttpResponse response = await _request(
        endpoint,
        await _buildHeaders(
          bvid: normalizedBvid,
          accept: 'application/json',
          includeCookie: false,
        ),
        _maximumSubtitleDocumentBytes,
      );
      if (response.statusCode < 200 || response.statusCode > 299) {
        return const SubtitleCueLoadResult.unavailable();
      }
      return _parseSubtitleCues(_decodeJsonObject(response.bodyBytes));
    } catch (_) {
      return const SubtitleCueLoadResult.unavailable();
    }
  }

  /// 从固定官方接口读取一个六分钟弹幕段，并用最小 Protobuf 解析器生成安全条目。
  @override
  Future<DanmakuSegmentLoadResult> loadDanmakuSegment({
    required String bvid,
    required int cid,
    required int segmentIndex,
  }) async {
    final String normalizedBvid = bvid.trim();
    if (!_isValidVideo(normalizedBvid, cid) ||
        segmentIndex < 1 ||
        segmentIndex > DanmakuSegmentLoadResult.maximumSegmentIndex) {
      return DanmakuSegmentLoadResult.unavailable(
        segmentIndex: segmentIndex.clamp(
          1,
          DanmakuSegmentLoadResult.maximumSegmentIndex,
        ),
        message: '弹幕请求参数无效。',
      );
    }
    try {
      final Uri endpoint = Uri.https(
        'api.bilibili.com',
        '/x/v2/dm/web/seg.so',
        <String, String>{
          'type': '1',
          'oid': cid.toString(),
          'segment_index': segmentIndex.toString(),
        },
      );
      final DesktopOverlayHttpResponse response = await _request(
        endpoint,
        await _buildHeaders(
          bvid: normalizedBvid,
          accept: 'application/octet-stream',
          includeCookie: true,
        ),
        _maximumDanmakuSegmentBytes,
      );
      if (response.statusCode < 200 || response.statusCode > 299) {
        return DanmakuSegmentLoadResult.unavailable(segmentIndex: segmentIndex);
      }
      return _parseDanmakuSegment(response.bodyBytes, segmentIndex);
    } catch (_) {
      return DanmakuSegmentLoadResult.unavailable(segmentIndex: segmentIndex);
    }
  }

  /// 使用 Dart HttpClient 执行受限 GET，请求过大、超时或重定向都会安全失败。
  static Future<DesktopOverlayHttpResponse> _performLimitedGet(
    Uri endpoint,
    Map<String, String> headers,
    int maximumBytes,
  ) async {
    final HttpClient client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final HttpClientRequest request = await client
          .getUrl(endpoint)
          .timeout(const Duration(seconds: 15));
      request.followRedirects = false;
      headers.forEach(request.headers.set);
      final HttpClientResponse response = await request.close().timeout(
        const Duration(seconds: 15),
      );
      final int declaredLength = response.contentLength;
      if (declaredLength > maximumBytes) {
        throw const _DesktopOverlayException();
      }
      final BytesBuilder output = BytesBuilder(copy: false);
      int receivedBytes = 0;
      await for (final List<int> chunk in response.timeout(
        const Duration(seconds: 15),
      )) {
        receivedBytes += chunk.length;
        if (receivedBytes > maximumBytes) {
          throw const _DesktopOverlayException();
        }
        output.add(chunk);
      }
      return DesktopOverlayHttpResponse(
        statusCode: response.statusCode,
        bodyBytes: output.takeBytes(),
      );
    } finally {
      client.close(force: true);
    }
  }

  /// 创建固定来源和桌面浏览器标识的请求头，Cookie 读取失败时仍允许匿名请求。
  Future<Map<String, String>> _buildHeaders({
    required String bvid,
    required String accept,
    required bool includeCookie,
  }) async {
    final Map<String, String> headers = <String, String>{
      HttpHeaders.acceptHeader: accept,
      HttpHeaders.acceptEncodingHeader: 'identity',
      HttpHeaders.refererHeader: 'https://www.bilibili.com/video/$bvid',
      HttpHeaders.userAgentHeader: BilibiliHttpAuthApi.desktopUserAgent,
    };
    if (includeCookie) {
      try {
        final String cookie = (await _authService.readCookieHeader()).trim();
        if (cookie.isNotEmpty) {
          headers[HttpHeaders.cookieHeader] = cookie;
        }
      } catch (_) {
        // 安全存储暂时不可用时按匿名请求继续，禁止把 Cookie 读取异常写入结果或日志。
      }
    }
    return headers;
  }

  /// 解析字幕轨道、锁定状态和安全 CDN 地址，并建立仅限当前视频的临时会话。
  SubtitleTrackLoadResult _parseSubtitleTracks({
    required String bvid,
    required int cid,
    required Map<Object?, Object?> rawData,
  }) {
    final Object? rawSubtitle = rawData['subtitle'];
    final Object? rawTracks = rawSubtitle is Map
        ? rawSubtitle['subtitles']
        : null;
    final List<Map<String, Object?>> tracks = <Map<String, Object?>>[];
    final Map<String, Uri> readableUrls = <String, Uri>{};
    if (rawTracks is List) {
      for (final Object? rawTrack in rawTracks) {
        if (tracks.length >= _maximumSubtitleTracks || rawTrack is! Map) {
          break;
        }
        final Map<Object?, Object?> values = Map<Object?, Object?>.from(
          rawTrack,
        );
        final String trackId = _readSubtitleTrackId(values);
        if (trackId.isEmpty ||
            tracks.any(
              (Map<String, Object?> track) => track['id'] == trackId,
            )) {
          continue;
        }
        final String language = values['lan']?.toString().trim() ?? '';
        final String rawLabel = values['lan_doc']?.toString().trim() ?? '';
        final bool serviceLocked = values['is_lock'] == true;
        final Uri? safeUrl = serviceLocked
            ? null
            : _normalizeSafeSubtitleUrl(
                values['subtitle_url']?.toString() ?? '',
              );
        tracks.add(<String, Object?>{
          'id': trackId,
          'language': language,
          'label': rawLabel.isEmpty
              ? (language.isEmpty ? '未知语言' : language)
              : rawLabel,
          'isLocked': serviceLocked || safeUrl == null,
        });
        if (safeUrl != null) {
          readableUrls[trackId] = safeUrl;
        }
      }
    }
    _subtitleSessionBvid = bvid;
    _subtitleSessionCid = cid;
    _readableSubtitleUrls = Map<String, Uri>.unmodifiable(readableUrls);
    final bool needsLogin = rawData['need_login_subtitle'] == true;
    final String status = readableUrls.isNotEmpty
        ? 'available'
        : needsLogin
        ? 'login_required'
        : tracks.isNotEmpty
        ? 'locked'
        : 'none';
    return SubtitleTrackLoadResult.fromPlatformMap(<String, Object?>{
      'status': status,
      'tracks': tracks,
    });
  }

  /// 将官方字幕 JSON 中的秒级时间转换为有界毫秒，并丢弃空白或异常条目。
  SubtitleCueLoadResult _parseSubtitleCues(Map<String, Object?> root) {
    final List<Map<String, Object?>> cues = <Map<String, Object?>>[];
    final Object? rawBody = root['body'];
    if (rawBody is List) {
      for (final Object? rawCue in rawBody) {
        if (cues.length >= _maximumSubtitleCues || rawCue is! Map) {
          break;
        }
        final Map<Object?, Object?> values = Map<Object?, Object?>.from(rawCue);
        final int? fromMilliseconds = _readSubtitleMilliseconds(values['from']);
        final int? toMilliseconds = _readSubtitleMilliseconds(values['to']);
        final String content = values['content']?.toString().trim() ?? '';
        if (fromMilliseconds == null ||
            toMilliseconds == null ||
            toMilliseconds <= fromMilliseconds ||
            content.isEmpty) {
          continue;
        }
        cues.add(<String, Object?>{
          'fromMs': fromMilliseconds,
          'toMs': toMilliseconds,
          'content': content,
        });
      }
    }
    cues.sort(
      (Map<String, Object?> left, Map<String, Object?> right) =>
          (left['fromMs']! as int).compareTo(right['fromMs']! as int),
    );
    return SubtitleCueLoadResult.fromPlatformMap(<String, Object?>{
      'status': cues.isEmpty ? 'none' : 'available',
      'cues': cues,
    });
  }

  /// 解析 DmSegMobileReply 的 repeated elems 字段，并容错跳过损坏的单条弹幕。
  DanmakuSegmentLoadResult _parseDanmakuSegment(
    Uint8List responseBytes,
    int segmentIndex,
  ) {
    final _ProtobufCursor cursor = _ProtobufCursor(responseBytes);
    final List<Map<String, Object?>> entries = <Map<String, Object?>>[];
    while (cursor.hasRemaining) {
      final int tag = cursor.readVarint();
      final int fieldNumber = tag >> 3;
      final int wireType = tag & 0x7;
      if (fieldNumber <= 0) {
        throw const _DesktopOverlayException();
      }
      if (fieldNumber == 1 && wireType == 2) {
        try {
          final Map<String, Object?>? entry = _parseDanmakuElement(
            cursor.readLengthDelimited(),
          );
          if (entry != null &&
              entries.length < DanmakuSegmentLoadResult.maximumEntries) {
            entries.add(entry);
          }
        } catch (_) {
          // 单条弹幕损坏时继续读取后续条目，整个顶层包损坏才会使本段失败。
        }
      } else {
        cursor.skipField(wireType);
      }
    }
    return DanmakuSegmentLoadResult.fromPlatformMap(<String, Object?>{
      'status': entries.isEmpty ? 'none' : 'available',
      'segmentIndex': segmentIndex,
      'entries': entries,
    });
  }

  /// 从 DanmakuElem 中仅提取进度、模式、颜色和 UTF-8 文本四个展示字段。
  Map<String, Object?>? _parseDanmakuElement(Uint8List elementBytes) {
    final _ProtobufCursor cursor = _ProtobufCursor(elementBytes);
    int? progressMilliseconds;
    String? content;
    int color = _defaultDanmakuColor;
    int mode = _defaultDanmakuMode;
    while (cursor.hasRemaining) {
      final int tag = cursor.readVarint();
      final int fieldNumber = tag >> 3;
      final int wireType = tag & 0x7;
      if (fieldNumber <= 0) {
        return null;
      }
      if (fieldNumber == 2 && wireType == 0) {
        progressMilliseconds = cursor.readVarint();
      } else if (fieldNumber == 3 && wireType == 0) {
        final int rawMode = cursor.readVarint();
        if (rawMode >= DanmakuEntry.minimumMode &&
            rawMode <= DanmakuEntry.maximumMode) {
          mode = rawMode;
        }
      } else if (fieldNumber == 5 && wireType == 0) {
        color = cursor.readVarint() & 0xFFFFFF;
      } else if (fieldNumber == 7 && wireType == 2) {
        content = utf8.decode(cursor.readLengthDelimited()).trim();
      } else {
        cursor.skipField(wireType);
      }
    }
    if (progressMilliseconds == null || content == null || content.isEmpty) {
      return null;
    }
    return <String, Object?>{
      'progressMs': progressMilliseconds,
      'content': content,
      'color': color,
      'mode': mode,
    };
  }

  /// 将 UTF-8 响应解析为 JSON 对象，数组、空内容和损坏编码都会被拒绝。
  Map<String, Object?> _decodeJsonObject(Uint8List bytes) {
    final Object? decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map) {
      throw const _DesktopOverlayException();
    }
    return Map<String, Object?>.from(decoded);
  }

  /// 验证 BV 与 CID，阻止页面借叠加服务请求任意资源。
  bool _isValidVideo(String bvid, int cid) {
    return _bvidPattern.hasMatch(bvid) && cid > 0;
  }

  /// 读取仅含数字且长度受限的字幕轨道编号。
  String _readSubtitleTrackId(Map<Object?, Object?> values) {
    final String idString = values['id_str']?.toString().trim() ?? '';
    final String fallbackId = values['id']?.toString().trim() ?? '';
    final String id = idString.isEmpty ? fallbackId : idString;
    return _isValidSubtitleTrackId(id) ? id : '';
  }

  /// 判断轨道编号是否符合 B 站数字编号格式和本地长度上限。
  bool _isValidSubtitleTrackId(String trackId) {
    return trackId.isNotEmpty &&
        trackId.length <= _maximumSubtitleTrackIdLength &&
        _subtitleTrackIdPattern.hasMatch(trackId);
  }

  /// 只接受官方 aisubtitle HTTPS 主机，协议相对地址会先补全为 HTTPS。
  Uri? _normalizeSafeSubtitleUrl(String rawUrl) {
    final String value = rawUrl.trim();
    final String normalized = value.startsWith('//') ? 'https:$value' : value;
    final Uri? uri = Uri.tryParse(normalized);
    if (uri == null ||
        uri.scheme.toLowerCase() != 'https' ||
        uri.host.toLowerCase() != 'aisubtitle.hdslb.com' ||
        uri.userInfo.isNotEmpty ||
        (uri.hasPort && uri.port != 443) ||
        uri.fragment.isNotEmpty) {
      return null;
    }
    return uri;
  }

  /// 将字幕秒数转换为 48 小时以内的非负毫秒，非有限小数会被拒绝。
  int? _readSubtitleMilliseconds(Object? rawValue) {
    final double? seconds = rawValue is num
        ? rawValue.toDouble()
        : double.tryParse(rawValue?.toString() ?? '');
    if (seconds == null || !seconds.isFinite || seconds < 0) {
      return null;
    }
    final int milliseconds = (seconds * 1000).truncate();
    return milliseconds <= _maximumSubtitleDurationMilliseconds
        ? milliseconds
        : null;
  }

  /// 把 JSON 中的整数兼容字段转换为 int，无法读取时使用明确回退值。
  int _readInt(Object? value, {required int fallback}) {
    return value is num
        ? value.toInt()
        : int.tryParse(value?.toString() ?? '') ?? fallback;
  }

  /// 清空临时字幕链接，避免视频切换或接口失败后继续使用上一分P地址。
  void _clearSubtitleSession() {
    _subtitleSessionBvid = null;
    _subtitleSessionCid = null;
    _readableSubtitleUrls = const <String, Uri>{};
  }
}

/// 表示已被转换为稳定用户提示的桌面字幕或弹幕内部异常。
class _DesktopOverlayException implements Exception {
  /// 创建不携带服务端正文、Cookie 或地址详情的内部异常。
  const _DesktopOverlayException();
}

/// 提供只支持 varint、定长字段和长度分隔字段的最小 Protobuf 游标。
class _ProtobufCursor {
  /// 创建从响应字节开头读取的有界游标。
  _ProtobufCursor(this._payload);

  final Uint8List _payload;
  int _position = 0;

  /// 判断缓冲区是否仍有未读取字节。
  bool get hasRemaining => _position < _payload.length;

  /// 读取最多十字节的无符号 varint，截断或超长编码会被拒绝。
  int readVarint() {
    int value = 0;
    int shift = 0;
    for (int index = 0; index < 10; index += 1) {
      if (!hasRemaining) {
        throw const _DesktopOverlayException();
      }
      final int currentByte = _payload[_position];
      _position += 1;
      value |= (currentByte & 0x7F) << shift;
      if ((currentByte & 0x80) == 0) {
        return value;
      }
      shift += 7;
    }
    throw const _DesktopOverlayException();
  }

  /// 读取一个长度分隔字段，并验证声明长度不会越过当前包边界。
  Uint8List readLengthDelimited() {
    final int length = readVarint();
    final int start = _position;
    _skipBytes(length);
    return Uint8List.sublistView(_payload, start, _position);
  }

  /// 按 wire type 跳过未知字段，使协议新增字段不会破坏当前解析。
  void skipField(int wireType) {
    switch (wireType) {
      case 0:
        readVarint();
        return;
      case 1:
        _skipBytes(8);
        return;
      case 2:
        _skipBytes(readVarint());
        return;
      case 5:
        _skipBytes(4);
        return;
      default:
        throw const _DesktopOverlayException();
    }
  }

  /// 向前移动指定字节数，并拒绝负长度与越界读取。
  void _skipBytes(int length) {
    if (length < 0 || length > _payload.length - _position) {
      throw const _DesktopOverlayException();
    }
    _position += length;
  }
}
