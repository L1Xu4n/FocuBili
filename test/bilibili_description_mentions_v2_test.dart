import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:focubili/models/video_preview.dart';
import 'package:focubili/services/bilibili_service.dart';

/// 模拟 BV1mE421w7Vg 的公开视频接口，确保回归测试不依赖实时网络。
class _Bv1mDescriptionJsonRequest {
  /// 根据接口路径返回视频详情或空标签列表，其余请求会明确失败以暴露意外调用。
  Future<String> call(Uri uri) async {
    if (uri.path == '/x/web-interface/view') {
      const String description =
          '中轴线申遗办、@新华社  、腾讯ssv、@腾讯游戏  ，共创。'
          '资料：https://example.com/course。';
      return jsonEncode(<String, Object?>{
        'code': 0,
        'data': <String, Object?>{
          'aid': 1906150238,
          'bvid': 'BV1mE421w7Vg',
          'cid': 1614878436,
          'title': '北京中轴线申遗成功',
          'duration': 120,
          'desc': description,
          'desc_v2': <Object?>[
            <String, Object?>{
              'raw_text': '新华社',
              'type': 2,
              'biz_id': 473837611,
            },
            <String, Object?>{
              'raw_text': '腾讯游戏',
              'type': 2,
              'biz_id': 25876049,
            },
          ],
          'owner': <String, Object?>{'name': '测试 UP', 'mid': 100},
          'pages': <Object?>[
            <String, Object?>{
              'page': 1,
              'cid': 1614878436,
              'part': '正片',
              'duration': 120,
            },
          ],
        },
      });
    }
    if (uri.path == '/x/tag/archive/tags') {
      return jsonEncode(<String, Object?>{'code': 0, 'data': <Object?>[]});
    }
    throw StateError('测试没有配置接口：${uri.path}');
  }
}

/// 验证 B 站新版 desc_v2 的 type=2 提及能够正确变成可点击简介片段。
void main() {
  /// 回归 BV1mE421w7Vg：@、原始空格、用户 mid 与同段 URL 都必须完整保留。
  test('BV1mE421w7Vg 的 type=2 简介提及保留 @ 并可点击', () async {
    const String expectedDescription =
        '中轴线申遗办、@新华社  、腾讯ssv、@腾讯游戏  ，共创。'
        '资料：https://example.com/course。';
    final BilibiliVideoInfoService service = BilibiliVideoInfoService(
      requestJson: _Bv1mDescriptionJsonRequest().call,
    );

    final VideoPreview video = await service.lookupVideo('BV1mE421w7Vg');
    final List<VideoDescriptionSegment> mentions = video.descriptionSegments
        .where((VideoDescriptionSegment segment) => segment.isMention)
        .toList(growable: false);
    final VideoDescriptionSegment link = video.descriptionSegments.singleWhere(
      (VideoDescriptionSegment segment) => segment.isLink,
    );

    expect(video.description, expectedDescription);
    expect(
      video.descriptionSegments
          .map((VideoDescriptionSegment segment) => segment.text)
          .join(),
      expectedDescription,
    );
    expect(
      mentions.map((VideoDescriptionSegment segment) => segment.text),
      <String>['@新华社', '@腾讯游戏'],
    );
    expect(
      mentions.map((VideoDescriptionSegment segment) => segment.mentionedMid),
      <int?>[473837611, 25876049],
    );
    expect(link.text, 'https://example.com/course');
    expect(link.linkUri, Uri.parse('https://example.com/course'));
  });
}
