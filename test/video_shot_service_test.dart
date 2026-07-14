import 'package:flutter_test/flutter_test.dart';

import 'package:focubili/models/video_shot_preview.dart';
import 'package:focubili/services/video_shot_service.dart';

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
    final VideoShotFrame? firstSheetFrame =
        preview?.frameFor(const Duration(seconds: 35));
    final VideoShotFrame? secondSheetFrame =
        preview?.frameFor(const Duration(seconds: 60));

    expect(preview, isNotNull);
    expect(firstSheetFrame?.imageUrl, 'https://i0.hdslb.com/first.jpg');
    expect(firstSheetFrame?.column, 1);
    expect(firstSheetFrame?.row, 1);
    expect(secondSheetFrame?.imageUrl, 'https://i0.hdslb.com/second.jpg');
    expect(secondSheetFrame?.column, 0);
    expect(secondSheetFrame?.row, 0);
  });
}
