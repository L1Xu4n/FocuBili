import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/services/app_http_client.dart';
import 'package:focubili/services/bilibili_deep_link_service.dart';

/// 用固定重定向验证请求次数、跳转方式和最终目标参数。
void main() {
  test('短链在解析相对跳转和视频 Location 后停止请求', () async {
    final transport = _RedirectTransport({
      '/start': '/next',
      '/next': 'https://www.bilibili.com/video/BV1GJ411x7h7?p=2&t=5',
    });
    final resolver = BilibiliIncomingLinkResolver(transport: transport);

    final target = await resolver.resolve('分享 https://b23.tv/start');

    expect(target?.bvid, 'BV1GJ411x7h7');
    expect(target?.partPageNumber, 2);
    expect(target?.initialPosition, const Duration(seconds: 5));
    expect(transport.visited, ['/start', '/next']);
  });

  test('第五跳直接返回用户空间，并拒绝请求额外的第六跳', () async {
    const target = 'https://space.bilibili.com/42/video';
    final transport = _RedirectTransport({
      '/1': '/2',
      '/2': '/3',
      '/3': '/4',
      '/4': '/5',
      '/5': target,
    });
    final resolver = BilibiliIncomingLinkResolver(transport: transport);
    final shortLink = Uri.https('b23.tv', '/1');

    expect(await resolver.expandShortLink(shortLink), Uri.parse(target));
    expect(transport.visited, ['/1', '/2', '/3', '/4', '/5']);
    transport.visited.clear();
    transport.locations['/5'] = '/6';
    expect(await resolver.expandShortLink(shortLink), isNull);
    expect(transport.visited, ['/1', '/2', '/3', '/4', '/5']);
  });
}

class _RedirectTransport implements AppHttpTransport {
  /// 为每个请求提供固定 Location；请求到终点会使测试失败。
  _RedirectTransport(this.locations);

  final Map<String, String> locations;
  final visited = <String>[];

  /// 记录每跳并核对传输层关闭了自动重定向。
  @override
  Future<AppHttpResponse> send({
    required Uri uri,
    String method = 'GET',
    Map<String, String> headers = const {},
    List<int>? bodyBytes,
    Duration timeout = const Duration(seconds: 15),
    int? maxResponseBytes,
    bool followRedirects = true,
    int maxRedirects = 5,
    bool autoUncompress = true,
    AppHttpClientPoolKind pool = AppHttpClientPoolKind.api,
    AppHttpCancelToken? cancelToken,
  }) async {
    expect(uri.host, 'b23.tv');
    expect(followRedirects, isFalse);
    visited.add(uri.path);
    expect(locations, contains(uri.path));
    return AppHttpResponse(
      statusCode: 302,
      bytes: Uint8List(0),
      headers: const {},
      redirectLocation: locations[uri.path],
    );
  }

  /// 替身没有真实连接池。
  @override
  void closePools({bool force = false}) {}
}
