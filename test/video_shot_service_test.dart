import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

import 'package:focubili/models/video_shot_preview.dart';
import 'package:focubili/services/video_shot_service.dart';

/// 生成左红右蓝的 2x1 测试雪碧图，用于核对服务真正裁出了目标格子。
Future<Uint8List> _buildSpritePng() async {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final ui.Canvas canvas = ui.Canvas(recorder);
  canvas.drawRect(
    const ui.Rect.fromLTWH(0, 0, 2, 1),
    ui.Paint()..color = const ui.Color(0xFFFF0000),
  );
  canvas.drawRect(
    const ui.Rect.fromLTWH(2, 0, 2, 1),
    ui.Paint()..color = const ui.Color(0xFF0000FF),
  );
  final ui.Picture picture = recorder.endRecording();
  final ui.Image image = await picture.toImage(4, 1);
  final ByteData? data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  return data!.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}

/// 解码 PNG 并返回首个像素的 RGBA 数值，避免测试只验证文件非空。
Future<List<int>> _readFirstPixel(Uint8List pngBytes) async {
  final ui.Codec codec = await ui.instantiateImageCodec(pngBytes);
  final ui.FrameInfo frame = await codec.getNextFrame();
  final ByteData? data = await frame.image.toByteData(
    format: ui.ImageByteFormat.rawRgba,
  );
  final List<int> pixel = data!.buffer.asUint8List(0, 4).toList();
  frame.image.dispose();
  codec.dispose();
  return pixel;
}

/// 验证进度预览接口解析和雪碧图行列换算。
void main() {
  /// 验证截图元数据会转换成可信 HTTPS 图片与正确的目标格子。
  test('解析进度预览雪碧图并定位目标画面', () async {
    final BilibiliVideoShotService service = BilibiliVideoShotService(
      // 固定请求函数返回两张 2x2 雪碧图，不连接真实网络。
      requestJson: (Uri endpoint) async {
        expect(endpoint.path, '/x/player/videoshot');
        expect(endpoint.queryParameters['bvid'], 'BV1GJ411x7h7');
        expect(endpoint.queryParameters['cid'], '137649199');
        return '''
          {
            "code": 0,
            "data": {
              "img_x_len": 2,
              "img_y_len": 2,
              "img_x_size": 160,
              "img_y_size": 90,
              "image": [
                "//i0.hdslb.com/first.jpg",
                "https://i0.hdslb.com/second.jpg"
              ],
              "index": [0, 5, 10, 30, 60]
            }
          }
        ''';
      },
    );

    final VideoShotPreview? preview = await service.loadPreview(
      bvid: 'BV1GJ411x7h7',
      cid: 137649199,
    );
    final VideoShotFrame? firstSheetFrame = preview?.frameFor(
      const Duration(seconds: 35),
    );
    final VideoShotFrame? secondSheetFrame = preview?.frameFor(
      const Duration(seconds: 60),
    );

    expect(preview, isNotNull);
    expect(firstSheetFrame?.imageUrl, 'https://i0.hdslb.com/first.jpg');
    expect(firstSheetFrame?.column, 1);
    expect(firstSheetFrame?.row, 1);
    expect(secondSheetFrame?.imageUrl, 'https://i0.hdslb.com/second.jpg');
    expect(secondSheetFrame?.column, 0);
    expect(secondSheetFrame?.row, 0);
  });

  /// 验证时间点保存会下载对应雪碧图并裁出第二格蓝色画面。
  test('裁切时间点雪碧图为独立 PNG', () async {
    final Uint8List spriteBytes = await _buildSpritePng();
    final BilibiliVideoShotService service = BilibiliVideoShotService(
      requestJson: (Uri endpoint) async => '''
        {
          "code": 0,
          "data": {
            "img_x_len": 2,
            "img_y_len": 1,
            "img_x_size": 2,
            "img_y_size": 1,
            "image": ["https://i0.hdslb.com/sprite.png"],
            "index": [0, 30]
          }
        }
      ''',
      requestImage: (Uri endpoint) async {
        expect(endpoint.host, 'i0.hdslb.com');
        return spriteBytes;
      },
    );

    final Uint8List? frameBytes = await service.captureFramePngBytes(
      bvid: 'BV1GJ411x7h7',
      cid: 137649199,
      position: const Duration(seconds: 45),
    );

    expect(frameBytes, isNotNull);
    expect(await _readFirstPixel(frameBytes!), <int>[0, 0, 255, 255]);
  });
}
