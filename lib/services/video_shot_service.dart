import 'dart:convert';
import 'dart:io';

import '../models/video_shot_preview.dart';
import 'bilibili_service.dart';

/// 定义可注入的进度预览图读取能力，组件测试可以使用无网络实现。
abstract interface class VideoShotService {
  /// 读取指定 BV 和分P的雪碧预览图元数据。
  Future<VideoShotPreview?> loadPreview({
    required String bvid,
    required int cid,
  });
}

/// 在测试或接口不可用场景中稳定返回空预览，不影响原有拖动跳转。
class EmptyVideoShotService implements VideoShotService {
  /// 创建不访问网络的空预览服务。
  const EmptyVideoShotService();

  /// 返回空值，让播放器继续显示目标时间文字。
  @override
  Future<VideoShotPreview?> loadPreview({
    required String bvid,
    required int cid,
  }) async {
    return null;
  }
}

/// 通过 B 站公开视频截图接口读取横向拖动所需的雪碧图位置。
class BilibiliVideoShotService implements VideoShotService {
  /// 创建正式预览服务；测试可注入固定 JSON 请求。
  BilibiliVideoShotService({JsonRequest? requestJson})
      : _requestJson = requestJson ?? _requestPublicJson;

  static const String _apiHost = 'api.bilibili.com';
  static const String _path = '/x/player/videoshot';
  static const String _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/126.0 Safari/537.36';
  final JsonRequest _requestJson;

  /// 请求截图元数据并过滤不可信图片地址，任何异常都退回无预览而不打断播放。
  @override
  Future<VideoShotPreview?> loadPreview({
    required String bvid,
    required int cid,
  }) async {
    if (bvid.trim().isEmpty || cid <= 0) {
      return null;
    }
    try {
      final String responseText = await _requestJson(
        Uri.https(
          _apiHost,
          _path,
          <String, String>{
            'bvid': bvid,
            'cid': cid.toString(),
            'index': '1',
          },
        ),
      );
      final Object? decoded = jsonDecode(responseText);
      if (decoded is! Map || (decoded['code'] as num?)?.toInt() != 0) {
        return null;
      }
      final Map<Object?, Object?> data = _readObject(decoded['data']);
      final List<String> imageUrls = _readImageUrls(data['image']);
      final List<int> sampleSeconds = _readIndexes(data['index']);
      final int columns = _readPositiveInt(data['img_x_len']);
      final int rows = _readPositiveInt(data['img_y_len']);
      final int width = _readPositiveInt(data['img_x_size']);
      final int height = _readPositiveInt(data['img_y_size']);
      if (imageUrls.isEmpty ||
          sampleSeconds.isEmpty ||
          columns <= 0 ||
          rows <= 0 ||
          width <= 0 ||
          height <= 0) {
        return null;
      }
      return VideoShotPreview(
        imageUrls: List<String>.unmodifiable(imageUrls),
        sampleSeconds: List<int>.unmodifiable(sampleSeconds),
        columns: columns,
        rows: rows,
        frameWidth: width.toDouble(),
        frameHeight: height.toDouble(),
      );
    } catch (_) {
      return null;
    }
  }

  /// 将未知 JSON 对象安全转换为字典。
  Map<Object?, Object?> _readObject(Object? value) {
    return value is Map
        ? Map<Object?, Object?>.from(value)
        : const <Object?, Object?>{};
  }

  /// 读取大于零的整数，非法字段返回零。
  int _readPositiveInt(Object? value) {
    final int? number =
        value is num ? value.toInt() : int.tryParse(value?.toString() ?? '');
    return number == null || number <= 0 ? 0 : number;
  }

  /// 读取并升序整理截图时间点，负数和损坏项会被忽略。
  List<int> _readIndexes(Object? value) {
    if (value is! List) {
      return const <int>[];
    }
    final List<int> indexes = value
        .map((Object? item) =>
            item is num ? item.toInt() : int.tryParse(item?.toString() ?? ''))
        .whereType<int>()
        .where((int item) => item >= 0)
        .toList(growable: true)
      ..sort();
    return indexes;
  }

  /// 读取可信 B 站图片地址并统一为 HTTPS。
  List<String> _readImageUrls(Object? value) {
    if (value is! List) {
      return const <String>[];
    }
    final List<String> urls = <String>[];
    for (final Object? item in value) {
      final String raw = item?.toString().trim() ?? '';
      final String normalized = raw.startsWith('//') ? 'https:$raw' : raw;
      final Uri? uri = Uri.tryParse(normalized);
      if (uri != null &&
          uri.scheme == 'https' &&
          (uri.host.endsWith('.hdslb.com') ||
              uri.host.endsWith('.biliimg.com'))) {
        urls.add(uri.toString());
      }
    }
    return urls;
  }

  /// 发出不带 Cookie 的只读截图请求。
  static Future<String> _requestPublicJson(Uri endpoint) async {
    final HttpClient client = HttpClient();
    try {
      final HttpClientRequest request = await client.getUrl(endpoint);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      request.headers.set(HttpHeaders.userAgentHeader, _userAgent);
      request.headers.set(
        HttpHeaders.refererHeader,
        'https://www.bilibili.com/',
      );
      final HttpClientResponse response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        return '';
      }
      return response.transform(utf8.decoder).join();
    } finally {
      client.close(force: true);
    }
  }
}
