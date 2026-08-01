import 'package:flutter_test/flutter_test.dart';

import 'package:focubili/models/player_enhancement.dart';
import 'package:focubili/services/bilibili_player_enhancement_service.dart';

/// 记录播放器增强接口地址，并返回与真实接口结构一致的固定 JSON。
class _PlayerEnhancementJsonFixture {
  final List<Uri> requestedUris = <Uri>[];

  /// 根据请求路径返回章节或互动节点数据，测试不会访问真实网络。
  Future<String> call(Uri uri) async {
    requestedUris.add(uri);
    if (uri.path == '/x/player/wbi/v2') {
      return '''
      {
        "code": 0,
        "message": "0",
        "data": {
          "view_points": [
            {"type": 1, "from": 0, "to": 68, "content": "什么是北京中轴线", "img_url": "http://i0.hdslb.com/bfs/vchapter/1629781561_0.jpg"},
            {"type": 1, "from": 68, "to": 292, "content": "王朝的接力", "imgUrl": "//i0.hdslb.com/bfs/vchapter/1629781561_68.jpg"},
            {"type": 1, "from": 292, "to": 508, "content": "巨匠的思索", "img_url": "https://i0.hdslb.com/bfs/vchapter/1629781561_2.jpg"},
            {"type": 1, "from": 508, "to": 690, "content": "人间的烟火", "img_url": "https://i0.hdslb.com/bfs/vchapter/1629781561_3.jpg"}
          ],
          "interaction": null
        }
      }
      ''';
    }
    return '''
    {
      "code": 0,
      "message": "0",
      "data": {
        "title": "初始界面",
        "edge_id": 1,
        "is_leaf": 0,
        "edges": {
          "questions": [
            {
              "start_time_r": 300,
              "pause_video": 1,
              "choices": [
                {"id": 46910898, "cid": 40178418329, "option": "A 开始游戏"},
                {"id": 46910899, "cid": 40178877072, "option": "B 离开游戏"}
              ]
            }
          ]
        }
      }
    }
    ''';
  }
}

/// 验证指定视频的四个章节以及互动剧情节点都能转换为稳定本地模型。
void main() {
  /// 验证 BV1mE421w7Vg 当前 CID 返回的四段标题、时间与 HTTPS 图片。
  test('解析 BV1mE421w7Vg 的四个真实视频分段', () async {
    final _PlayerEnhancementJsonFixture fixture =
        _PlayerEnhancementJsonFixture();
    final BilibiliPublicPlayerEnhancementService service =
        BilibiliPublicPlayerEnhancementService(requestJson: fixture.call);

    final PlayerEnhancementMetadata metadata = await service.loadMetadata(
      bvid: 'BV1mE421w7Vg',
      cid: 1629781561,
    );

    expect(fixture.requestedUris.single.path, '/x/player/wbi/v2');
    expect(
      fixture.requestedUris.single.queryParameters,
      containsPair('cid', '1629781561'),
    );
    expect(
      metadata.chapters.map((VideoChapter chapter) => chapter.title),
      <String>['什么是北京中轴线', '王朝的接力', '巨匠的思索', '人间的烟火'],
    );
    expect(metadata.chapters[1].start, const Duration(seconds: 68));
    expect(metadata.chapters.last.end, const Duration(seconds: 690));
    expect(metadata.chapters.first.imageUrl, startsWith('https://'));
    expect(metadata.chapters[1].imageUrl, endsWith('1629781561_68.jpg'));
    expect(metadata.interaction, isNull);
  });

  /// 验证互动接口使用剧情图版本与目标 edge_id，并解析两个目标 CID。
  test('解析互动视频剧情选项并携带用户选择的 edge_id', () async {
    final _PlayerEnhancementJsonFixture fixture =
        _PlayerEnhancementJsonFixture();
    final BilibiliPublicPlayerEnhancementService service =
        BilibiliPublicPlayerEnhancementService(requestJson: fixture.call);

    final InteractiveVideoNode node = await service.loadInteractiveNode(
      bvid: 'BV18ug66REzE',
      graphVersion: 1619916,
      edgeId: 46910898,
    );

    final Uri endpoint = fixture.requestedUris.single;
    expect(endpoint.path, '/x/stein/edgeinfo_v2');
    expect(endpoint.queryParameters['graph_version'], '1619916');
    expect(endpoint.queryParameters['edge_id'], '46910898');
    expect(node.title, '初始界面');
    expect(node.isLeaf, isFalse);
    expect(node.choices, hasLength(2));
    expect(node.choices.first.cid, 40178418329);
    expect(node.choices.first.label, 'A 开始游戏');
    expect(node.choicePromptLeadTime, const Duration(milliseconds: 300));
    expect(node.pauseVideoForChoice, isTrue);
  });
}
