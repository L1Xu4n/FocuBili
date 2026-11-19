import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

import 'package:focubili/models/video_shot_preview.dart';
import 'package:focubili/services/video_shot_service.dart';

String _previewResponse(String image, {int samples = 2}) => jsonEncode({
  'code': 0,
  'data': {
    'img_x_len': 2,
    'img_y_len': 1,
    'img_x_size': 160,
    'img_y_size': 90,
    'image': ['https://i0.hdslb.com/$image'],
    'index': List<int>.generate(samples, (index) => index * 10),
  },
});

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
  const bvid = 'BV1GJ411x7h7';

  test('复用同一 BV/CID，分 P 和不同 BV 独立，五分钟后重新请求', () async {
    var now = DateTime(2026);
    var calls = 0;
    final service = BilibiliVideoShotService(
      clock: () => now,
      requestJson: (uri) async => _previewResponse('${++calls}.jpg'),
    );
    final first = await service.loadPreview(bvid: bvid, cid: 1);
    final secondPart = await service.loadPreview(bvid: bvid, cid: 2);
    final different = await service.loadPreview(bvid: 'BV1GJ411x7H7', cid: 1);
    final reopened = await service.loadPreview(bvid: bvid, cid: 1);
    expect(reopened, same(first));
    expect(secondPart?.imageUrls.single, endsWith('/2.jpg'));
    expect(different?.imageUrls.single, endsWith('/3.jpg'));
    expect(calls, 3);
    now = now.add(const Duration(minutes: 5));
    final refreshed = await service.loadPreview(bvid: bvid, cid: 1);
    expect(refreshed?.imageUrls.single, endsWith('/4.jpg'));
    expect(calls, 4);
  });

  test('合并并发请求，但不跨注入服务共享缓存', () async {
    final response = Completer<String>();
    var calls = 0;
    final service = BilibiliVideoShotService(
      requestJson: (uri) {
        calls++;
        return response.future;
      },
    );
    final alternate = BilibiliVideoShotService(
      requestJson: (uri) async => _previewResponse('alternate.jpg'),
    );
    final waiting = [
      service.loadPreview(bvid: bvid, cid: 1),
      service.loadPreview(bvid: bvid, cid: 1),
    ];
    expect(calls, 1);
    final independent = await alternate.loadPreview(bvid: bvid, cid: 1);
    expect(independent?.imageUrls.single, endsWith('/alternate.jpg'));
    response.complete(_previewResponse('shared.jpg'));
    final values = await Future.wait(waiting);
    expect(values[0], same(values[1]));
    expect(values[0]?.imageUrls.single, endsWith('/shared.jpg'));
    expect(calls, 1);
  });

  test('超时及无预览均可重试，迟到结果不会污染缓存', () async {
    final late = Completer<String>();
    var calls = 0;
    final service = BilibiliVideoShotService(
      requestTimeout: const Duration(milliseconds: 10),
      requestJson: (uri) => switch (++calls) {
        1 => late.future,
        2 => Future.value('{"code": -404}'),
        _ => Future.value(_previewResponse('fresh.jpg')),
      },
    );
    final first = service.loadPreview(bvid: bvid, cid: 1);
    final simultaneous = service.loadPreview(bvid: bvid, cid: 1);
    expect(await first, isNull);
    expect(await simultaneous, isNull);
    expect(calls, 1);
    expect(await service.loadPreview(bvid: bvid, cid: 1), isNull);
    final fresh = await service.loadPreview(bvid: bvid, cid: 1);
    late.complete(_previewResponse('late.jpg'));
    expect(await service.loadPreview(bvid: bvid, cid: 1), same(fresh));
    expect(fresh?.imageUrls.single, endsWith('/fresh.jpg'));
    expect(calls, 3);
  });

  test('访问续保 LRU 顺序，超过 32 项淘汰最久未访问项', () async {
    final calls = <int>[];
    final service = BilibiliVideoShotService(
      requestJson: (uri) async {
        calls.add(int.parse(uri.queryParameters['cid']!));
        return _previewResponse('cached.jpg');
      },
    );
    for (var i = 1; i <= 32; i++) {
      await service.loadPreview(bvid: bvid, cid: i);
    }
    await service.loadPreview(bvid: bvid, cid: 1);
    await service.loadPreview(bvid: bvid, cid: 33);
    await service.loadPreview(bvid: bvid, cid: 1);
    await service.loadPreview(bvid: bvid, cid: 2);
    expect(calls, [...List.generate(33, (i) => i + 1), 2]);
  });

  test('长视频仍可预览，保留缓存受样本大小预算约束', () async {
    final calls = <int>[];
    final service = BilibiliVideoShotService(
      requestJson: (uri) async {
        final cid = int.parse(uri.queryParameters['cid']!);
        calls.add(cid);
        return _previewResponse('long.jpg', samples: cid == 3 ? 33000 : 18000);
      },
    );
    final first = await service.loadPreview(bvid: bvid, cid: 1);
    expect(first?.sampleSeconds.length, 18000);
    expect(await service.loadPreview(bvid: bvid, cid: 1), same(first));
    await service.loadPreview(bvid: bvid, cid: 2);
    expect(await service.loadPreview(bvid: bvid, cid: 1), isNot(same(first)));
    final oversize = await service.loadPreview(bvid: bvid, cid: 3);
    expect(oversize?.sampleSeconds.length, 33000);
    expect(
      await service.loadPreview(bvid: bvid, cid: 3),
      isNot(same(oversize)),
    );
    expect(calls, [1, 2, 1, 3, 3]);
  });

  test('可能包含临时签名的图片地址不留在缓存', () async {
    var calls = 0;
    final service = BilibiliVideoShotService(
      requestJson: (uri) async =>
          _previewResponse('image.jpg?token=${++calls}'),
    );
    final first = await service.loadPreview(bvid: bvid, cid: 1);
    final reopened = await service.loadPreview(bvid: bvid, cid: 1);
    expect(first?.imageUrls.single, endsWith('?token=1'));
    expect(reopened?.imageUrls.single, endsWith('?token=2'));
    expect(calls, 2);
  });

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
