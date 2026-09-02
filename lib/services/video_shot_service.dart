import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../models/video_shot_preview.dart';
import 'bilibili_service.dart';

/// 定义可注入的雪碧图二进制请求，测试时无需访问真实图片服务器。
typedef VideoShotImageRequest = Future<Uint8List> Function(Uri endpoint);

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
  BilibiliVideoShotService({
    JsonRequest? requestJson,
    VideoShotImageRequest? requestImage,
  }) : _requestJson = requestJson ?? _requestPublicJson,
       _requestImage = requestImage ?? _requestPublicImage;

  static const String _apiHost = 'api.bilibili.com';
  static const String _path = '/x/player/videoshot';
  static const String _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/126.0 Safari/537.36';
  final JsonRequest _requestJson;
  final VideoShotImageRequest _requestImage;

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
        Uri.https(_apiHost, _path, <String, String>{
          'bvid': bvid,
          'cid': cid.toString(),
          'index': '1',
        }),
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

  /// 下载当前时间点所在雪碧图并裁成独立 PNG，供 Windows 专注卡片安全保存截图。
  Future<Uint8List?> captureFramePngBytes({
    required String bvid,
    required int cid,
    required Duration position,
  }) async {
    try {
      final VideoShotPreview? preview = await loadPreview(bvid: bvid, cid: cid);
      final VideoShotFrame? frame = preview?.frameFor(position);
      final Uri? imageUri = Uri.tryParse(frame?.imageUrl ?? '');
      if (frame == null || imageUri == null) {
        return null;
      }
      final Uint8List imageBytes = await _requestImage(imageUri);
      if (imageBytes.isEmpty) {
        return null;
      }
      return _cropFramePng(imageBytes, frame);
    } catch (_) {
      return null;
    }
  }

  /// 解码雪碧图并按接口给出的行列裁切一格，再编码为可直接写入文件的 PNG。
  Future<Uint8List?> _cropFramePng(
    Uint8List imageBytes,
    VideoShotFrame frame,
  ) async {
    ui.Codec? codec;
    ui.Image? sourceImage;
    ui.Picture? picture;
    ui.Image? outputImage;
    try {
      codec = await ui.instantiateImageCodec(imageBytes);
      final ui.FrameInfo frameInfo = await codec.getNextFrame();
      sourceImage = frameInfo.image;
      final double left = frame.column * frame.frameWidth;
      final double top = frame.row * frame.frameHeight;
      final double right = left + frame.frameWidth;
      final double bottom = top + frame.frameHeight;
      if (left < 0 ||
          top < 0 ||
          right > sourceImage.width ||
          bottom > sourceImage.height) {
        return null;
      }
      final int outputWidth = frame.frameWidth.round();
      final int outputHeight = frame.frameHeight.round();
      if (outputWidth <= 0 || outputHeight <= 0) {
        return null;
      }
      final ui.PictureRecorder recorder = ui.PictureRecorder();
      final ui.Canvas canvas = ui.Canvas(recorder);
      canvas.drawImageRect(
        sourceImage,
        ui.Rect.fromLTRB(left, top, right, bottom),
        ui.Rect.fromLTWH(0, 0, outputWidth.toDouble(), outputHeight.toDouble()),
        ui.Paint()..filterQuality = ui.FilterQuality.none,
      );
      picture = recorder.endRecording();
      outputImage = await picture.toImage(outputWidth, outputHeight);
      final ByteData? data = await outputImage.toByteData(
        format: ui.ImageByteFormat.png,
      );
      return data?.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } catch (_) {
      return null;
    } finally {
      outputImage?.dispose();
      picture?.dispose();
      sourceImage?.dispose();
      codec?.dispose();
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
    final int? number = value is num
        ? value.toInt()
        : int.tryParse(value?.toString() ?? '');
    return number == null || number <= 0 ? 0 : number;
  }

  /// 读取并升序整理截图时间点，负数和损坏项会被忽略。
  List<int> _readIndexes(Object? value) {
    if (value is! List) {
      return const <int>[];
    }
    final List<int> indexes =
        value
            .map(
              (Object? item) => item is num
                  ? item.toInt()
                  : int.tryParse(item?.toString() ?? ''),
            )
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

  /// 下载可信 B 站雪碧图原始字节，非成功响应返回空数组供调用方安全降级。
  static Future<Uint8List> _requestPublicImage(Uri endpoint) async {
    final HttpClient client = HttpClient();
    try {
      final HttpClientRequest request = await client.getUrl(endpoint);
      request.headers.set(HttpHeaders.acceptHeader, 'image/*');
      request.headers.set(HttpHeaders.userAgentHeader, _userAgent);
      request.headers.set(
        HttpHeaders.refererHeader,
        'https://www.bilibili.com/',
      );
      final HttpClientResponse response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        return Uint8List(0);
      }
      final BytesBuilder bytes = BytesBuilder(copy: false);
      await for (final List<int> chunk in response) {
        bytes.add(chunk);
      }
      return bytes.takeBytes();
    } finally {
      client.close(force: true);
    }
  }
}
