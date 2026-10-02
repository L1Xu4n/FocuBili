import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/models/player_overlay_data.dart';
import 'package:focubili/services/bilibili_auth_service.dart';
import 'package:focubili/services/desktop_player_overlay_service.dart';

/// 用内存保存测试 Cookie，验证桌面叠加服务只在需要时把会话放进请求头。
class _MemoryCookieStore implements BilibiliCookieStore {
  /// 创建带有指定初始 Cookie 的内存容器。
  _MemoryCookieStore(this.cookie);

  String cookie;

  /// 返回当前测试 Cookie，不访问系统安全存储。
  @override
  Future<String> readCookies() async => cookie;

  /// 清空测试 Cookie，模拟用户退出登录。
  @override
  Future<void> clearBilibiliCookies() async {
    cookie = '';
  }

  /// 替换测试 Cookie，模拟保存已验证登录会话。
  @override
  Future<void> replaceCookies(String cookieHeader) async {
    cookie = cookieHeader;
  }
}

/// 保存一次测试请求，供断言固定主机、路径、请求头和响应上限。
class _RecordedRequest {
  /// 创建一条不包含真实账号资料的内存请求记录。
  const _RecordedRequest({
    required this.endpoint,
    required this.headers,
    required this.maximumBytes,
  });

  final Uri endpoint;
  final Map<String, String> headers;
  final int maximumBytes;
}

/// 用预设响应替代真实 B 站网络，并记录服务实际尝试访问的端点。
class _FakeOverlayServer {
  final Map<String, DesktopOverlayHttpResponse> responses =
      <String, DesktopOverlayHttpResponse>{};
  final List<_RecordedRequest> requests = <_RecordedRequest>[];

  /// 按 URI 路径返回预设响应；缺失响应时返回 404，避免测试意外联网。
  Future<DesktopOverlayHttpResponse> call(
    Uri endpoint,
    Map<String, String> headers,
    int maximumBytes,
  ) async {
    requests.add(
      _RecordedRequest(
        endpoint: endpoint,
        headers: Map<String, String>.from(headers),
        maximumBytes: maximumBytes,
      ),
    );
    return responses[endpoint.path] ??
        DesktopOverlayHttpResponse(statusCode: 404, bodyBytes: Uint8List(0));
  }
}

/// 把 JSON 测试资料编码为与 HttpClient 相同的 UTF-8 字节响应。
DesktopOverlayHttpResponse _jsonResponse(Object? body) {
  return DesktopOverlayHttpResponse(
    statusCode: 200,
    bodyBytes: Uint8List.fromList(utf8.encode(jsonEncode(body))),
  );
}

/// 把非负整数编码为 Protobuf varint，供弹幕协议测试构造最小合法包。
List<int> _encodeVarint(int value) {
  final List<int> bytes = <int>[];
  int remaining = value;
  do {
    int current = remaining & 0x7F;
    remaining >>= 7;
    if (remaining != 0) {
      current |= 0x80;
    }
    bytes.add(current);
  } while (remaining != 0);
  return bytes;
}

/// 编码一个 varint 字段的标签和值。
List<int> _encodeVarintField(int fieldNumber, int value) {
  return <int>[..._encodeVarint(fieldNumber << 3), ..._encodeVarint(value)];
}

/// 编码一个长度分隔字段，供字符串和嵌套弹幕消息复用。
List<int> _encodeBytesField(int fieldNumber, List<int> value) {
  return <int>[
    ..._encodeVarint((fieldNumber << 3) | 2),
    ..._encodeVarint(value.length),
    ...value,
  ];
}

/// 构造只含播放器所需四项字段的一条 DanmakuElem。
List<int> _encodeDanmakuElement({
  required int progressMilliseconds,
  required int mode,
  required int color,
  required String content,
}) {
  return <int>[
    ..._encodeVarintField(2, progressMilliseconds),
    ..._encodeVarintField(3, mode),
    ..._encodeVarintField(5, color),
    ..._encodeBytesField(7, utf8.encode(content)),
  ];
}

/// 创建带有内存 Cookie 和假网络的桌面叠加服务。
DesktopPlayerOverlayService _createService(
  _FakeOverlayServer server, {
  String cookie = 'SESSDATA=test-session',
}) {
  return DesktopPlayerOverlayService(
    authService: BilibiliAuthService(cookieStore: _MemoryCookieStore(cookie)),
    request: server.call,
  );
}

/// 验证 Windows 字幕和弹幕服务只访问官方端点并返回经过限制的数据。
void main() {
  /// 构造包含视频归属和独立正文地址的轨道响应，用于模拟并发元数据请求。
  DesktopOverlayHttpResponse metadata(String bvid, int cid, String path) {
    return _jsonResponse({
      'code': 0,
      'data': {
        'bvid': bvid,
        'cid': cid,
        'subtitle': {
          'subtitles': [
            {
              'id_str': '11',
              'lan': 'zh-CN',
              'subtitle_url': 'https://aisubtitle.hdslb.com/$path',
            },
          ],
        },
      },
    });
  }

  /// 两个视频使用同一轨道编号，旧请求晚到仍须保留各自的正文地址。
  test('字幕并发反序返回按 BV/CID 隔离', () async {
    final oldMetadata = Completer<DesktopOverlayHttpResponse>();
    final newMetadata = Completer<DesktopOverlayHttpResponse>();
    final requestsStarted = Completer<void>();
    int requests = 0;
    final service = DesktopPlayerOverlayService(
      authService: BilibiliAuthService(cookieStore: _MemoryCookieStore('')),
      request: (endpoint, headers, maximumBytes) async {
        if (endpoint.path == '/x/player/v2') {
          requests++;
          if (requests == 2) requestsStarted.complete();
          return endpoint.queryParameters['cid'] == '123'
              ? oldMetadata.future
              : newMetadata.future;
        }
        return _jsonResponse({
          'body': [
            {'from': 0, 'to': 2, 'content': endpoint.path},
          ],
        });
      },
    );
    final oldRequest = service.loadSubtitleTracks(
      bvid: 'BV1xx411c7mD',
      cid: 123,
    );
    final newRequest = service.loadSubtitleTracks(
      bvid: 'BV1GJ411x7h7',
      cid: 456,
    );
    await requestsStarted.future;
    newMetadata.complete(metadata('BV1GJ411x7h7', 456, 'new.json'));
    await newRequest;
    oldMetadata.complete(metadata('BV1xx411c7mD', 123, 'old.json'));
    await oldRequest;
    final newCues = await service.loadSubtitleCues(
      bvid: 'BV1GJ411x7h7',
      cid: 456,
      trackId: '11',
    );
    final oldCues = await service.loadSubtitleCues(
      bvid: 'BV1xx411c7mD',
      cid: 123,
      trackId: '11',
    );
    expect(newCues.cues.single.content, '/new.json');
    expect(oldCues.cues.single.content, '/old.json');
  });

  /// 同一视频刷新后旧请求晚到，不能使已刷新地址退回旧地址。
  test('同视频旧字幕请求晚到不能覆盖刷新结果', () async {
    final stale = Completer<DesktopOverlayHttpResponse>();
    final started = Completer<void>();
    int reads = 0;
    final service = DesktopPlayerOverlayService(
      authService: BilibiliAuthService(cookieStore: _MemoryCookieStore('')),
      request: (endpoint, headers, maximumBytes) async {
        if (endpoint.path == '/x/player/v2') {
          if (++reads == 1) {
            started.complete();
            return stale.future;
          }
          return metadata('BV1xx411c7mD', 123, 'fresh.json');
        }
        return _jsonResponse({
          'body': [
            {'from': 0, 'to': 2, 'content': endpoint.path},
          ],
        });
      },
    );
    final pending = service.loadSubtitleTracks(bvid: 'BV1xx411c7mD', cid: 123);
    await started.future;
    await service.loadSubtitleTracks(bvid: 'BV1xx411c7mD', cid: 123);
    stale.complete(metadata('BV1xx411c7mD', 123, 'stale.json'));
    expect((await pending).status, SubtitleLoadStatus.unavailable);
    final cues = await service.loadSubtitleCues(
      bvid: 'BV1xx411c7mD',
      cid: 123,
      trackId: '11',
    );
    expect(cues.cues.single.content, '/fresh.json');
  });

  /// 响应中的 BV 或 CID 与请求不一致时，禁止读取其中的字幕正文。
  test('字幕接口返回其他视频或分 P 时拒绝使用', () async {
    final server = _FakeOverlayServer();
    final service = _createService(server);
    for (final response in [
      metadata('BV1GJ411x7h7', 123, 'wrong.json'),
      metadata('BV1xx411c7mD', 456, 'wrong.json'),
    ]) {
      server.responses['/x/player/v2'] = response;
      expect(
        (await service.loadSubtitleTracks(
          bvid: 'BV1xx411c7mD',
          cid: 123,
        )).status,
        SubtitleLoadStatus.unavailable,
      );
      expect(
        (await service.loadSubtitleCues(
          bvid: 'BV1xx411c7mD',
          cid: 123,
          trackId: '11',
        )).status,
        SubtitleLoadStatus.locked,
      );
    }
    expect(server.requests, hasLength(2));
  });

  /// 失败的刷新不能抹掉同一视频原本可读的正文地址。
  test('字幕列表刷新失败仍可使用之前成功的轨道', () async {
    final server = _FakeOverlayServer();
    final service = _createService(server);
    server.responses['/x/player/v2'] = metadata(
      'BV1xx411c7mD',
      123,
      'kept.json',
    );
    server.responses['/kept.json'] = _jsonResponse({
      'body': [
        {'from': 0, 'to': 2, 'content': '已读取的视频字幕'},
      ],
    });
    await service.loadSubtitleTracks(bvid: 'BV1xx411c7mD', cid: 123);
    server.responses['/x/player/v2'] = DesktopOverlayHttpResponse(
      statusCode: 503,
      bodyBytes: Uint8List(0),
    );
    expect(
      (await service.loadSubtitleTracks(bvid: 'BV1xx411c7mD', cid: 123)).status,
      SubtitleLoadStatus.unavailable,
    );
    final cues = await service.loadSubtitleCues(
      bvid: 'BV1xx411c7mD',
      cid: 123,
      trackId: '11',
    );
    expect(cues.cues.single.content, '已读取的视频字幕');
  });

  /// 正文地址过期时重新获取同一 BV/CID 的地址，并且不对 CDN 携带 Cookie。
  test('字幕临时地址过期自动更新并重试一次', () async {
    var metadataReads = 0;
    final documents = <String>[];
    final service = DesktopPlayerOverlayService(
      authService: BilibiliAuthService(
        cookieStore: _MemoryCookieStore('SESSDATA=test'),
      ),
      request: (endpoint, headers, maximumBytes) async {
        if (endpoint.path == '/x/player/v2') {
          expect(endpoint.queryParameters['cid'], '123');
          return metadata(
            'BV1xx411c7mD',
            123,
            ++metadataReads == 1 ? 'expired.json' : 'fresh.json',
          );
        }
        expect(headers.containsKey('cookie'), isFalse);
        documents.add(endpoint.path);
        if (endpoint.path == '/expired.json') {
          return DesktopOverlayHttpResponse(
            statusCode: 403,
            bodyBytes: Uint8List(0),
          );
        }
        return _jsonResponse({
          'body': [
            {'from': 0, 'to': 1, 'content': '当前视频的新地址'},
          ],
        });
      },
    );
    await service.loadSubtitleTracks(bvid: 'BV1xx411c7mD', cid: 123);
    final cues = await service.loadSubtitleCues(
      bvid: 'BV1xx411c7mD',
      cid: 123,
      trackId: '11',
    );
    expect(cues.cues.single.content, '当前视频的新地址');
    expect(metadataReads, 2);
    expect(documents, ['/expired.json', '/fresh.json']);
  });

  /// 没有归属字段的响应不能被默认当作当前视频。
  test('字幕元数据缺少视频身份时拒绝使用', () async {
    final server = _FakeOverlayServer();
    server.responses['/x/player/v2'] = _jsonResponse({
      'code': 0,
      'data': {
        'subtitle': {
          'subtitles': [
            {
              'id': 11,
              'lan': 'zh',
              'subtitle_url': 'https://aisubtitle.hdslb.com/unknown.json',
            },
          ],
        },
      },
    });
    final service = _createService(server);
    expect(
      (await service.loadSubtitleTracks(bvid: 'BV1xx411c7mD', cid: 123)).status,
      SubtitleLoadStatus.unavailable,
    );
    expect(
      (await service.loadSubtitleCues(
        bvid: 'BV1xx411c7mD',
        cid: 123,
        trackId: '11',
      )).status,
      SubtitleLoadStatus.locked,
    );
    expect(server.requests, hasLength(1));
  });

  test('字幕轨道临时地址留在服务内存且字幕条目按时间排序', () async {
    final _FakeOverlayServer server = _FakeOverlayServer();
    server.responses['/x/player/v2'] = _jsonResponse(<String, Object?>{
      'code': 0,
      'data': <String, Object?>{
        'bvid': 'BV1xx411c7mD',
        'cid': 123,
        'subtitle': <String, Object?>{
          'subtitles': <Object?>[
            <String, Object?>{
              'id_str': '11',
              'lan': 'zh-CN',
              'lan_doc': '中文（自动生成）',
              'is_lock': false,
              'subtitle_url': '//aisubtitle.hdslb.com/bfs/subtitle/safe.json',
            },
            <String, Object?>{
              'id_str': '12',
              'lan': 'en-US',
              'lan_doc': 'English',
              'is_lock': false,
              'subtitle_url': 'https://example.com/unsafe.json',
            },
          ],
        },
      },
    });
    server.responses['/bfs/subtitle/safe.json'] = _jsonResponse(
      <String, Object?>{
        'body': <Object?>[
          <String, Object?>{'from': 2.5, 'to': 3.2, 'content': '第二句'},
          <String, Object?>{'from': 0.4, 'to': 1.1, 'content': '第一句'},
        ],
      },
    );
    final DesktopPlayerOverlayService service = _createService(server);

    final SubtitleTrackLoadResult tracks = await service.loadSubtitleTracks(
      bvid: 'BV1xx411c7mD',
      cid: 123,
    );
    final SubtitleCueLoadResult cues = await service.loadSubtitleCues(
      bvid: 'BV1xx411c7mD',
      cid: 123,
      trackId: '11',
    );

    expect(tracks.status, SubtitleLoadStatus.available);
    expect(tracks.tracks, hasLength(2));
    expect(tracks.tracks.first.isLocked, isFalse);
    expect(tracks.tracks.last.isLocked, isTrue);
    expect(cues.status, SubtitleLoadStatus.available);
    expect(cues.cues.map((SubtitleCue cue) => cue.content), <String>[
      '第一句',
      '第二句',
    ]);
    expect(server.requests.first.endpoint.host, 'api.bilibili.com');
    expect(server.requests.first.endpoint.path, '/x/player/v2');
    expect(server.requests.first.headers['cookie'], 'SESSDATA=test-session');
    expect(server.requests.last.endpoint.host, 'aisubtitle.hdslb.com');
    expect(server.requests.last.headers.containsKey('cookie'), isFalse);
    expect(server.requests.last.maximumBytes, 4 * 1024 * 1024);
  });

  test('没有安全 CDN 地址的字幕被标记为锁定且不会发起第二次请求', () async {
    final _FakeOverlayServer server = _FakeOverlayServer();
    server.responses['/x/player/v2'] = _jsonResponse(<String, Object?>{
      'code': 0,
      'data': <String, Object?>{
        'bvid': 'BV1xx411c7mD',
        'cid': 123,
        'subtitle': <String, Object?>{
          'subtitles': <Object?>[
            <String, Object?>{
              'id': 99,
              'lan': 'zh-CN',
              'subtitle_url': 'http://aisubtitle.hdslb.com/unsafe.json',
            },
          ],
        },
      },
    });
    final DesktopPlayerOverlayService service = _createService(server);

    final SubtitleTrackLoadResult tracks = await service.loadSubtitleTracks(
      bvid: 'BV1xx411c7mD',
      cid: 123,
    );
    final SubtitleCueLoadResult cues = await service.loadSubtitleCues(
      bvid: 'BV1xx411c7mD',
      cid: 123,
      trackId: '99',
    );

    expect(tracks.status, SubtitleLoadStatus.locked);
    expect(tracks.tracks.single.isLocked, isTrue);
    expect(cues.status, SubtitleLoadStatus.locked);
    expect(server.requests, hasLength(1));
  });

  test('弹幕 Protobuf 只提取合法字段并使用固定六分钟接口', () async {
    final List<int> firstElement = _encodeDanmakuElement(
      progressMilliseconds: 1250,
      mode: 1,
      color: 0x66CCFF,
      content: 'Windows 弹幕',
    );
    final List<int> invalidElement = _encodeDanmakuElement(
      progressMilliseconds: 2250,
      mode: 1,
      color: 0xFFFFFF,
      content: '   ',
    );
    final _FakeOverlayServer server = _FakeOverlayServer();
    server.responses['/x/v2/dm/web/seg.so'] = DesktopOverlayHttpResponse(
      statusCode: 200,
      bodyBytes: Uint8List.fromList(<int>[
        ..._encodeBytesField(1, firstElement),
        ..._encodeBytesField(1, invalidElement),
      ]),
    );
    final DesktopPlayerOverlayService service = _createService(server);

    final DanmakuSegmentLoadResult result = await service.loadDanmakuSegment(
      bvid: 'BV1xx411c7mD',
      cid: 456,
      segmentIndex: 2,
    );

    expect(result.status, DanmakuLoadStatus.available);
    expect(result.segmentIndex, 2);
    expect(result.entries, hasLength(1));
    expect(result.entries.single.position, const Duration(milliseconds: 1250));
    expect(result.entries.single.content, 'Windows 弹幕');
    expect(result.entries.single.color, 0x66CCFF);
    expect(server.requests.single.endpoint.host, 'api.bilibili.com');
    expect(server.requests.single.endpoint.path, '/x/v2/dm/web/seg.so');
    expect(server.requests.single.endpoint.queryParameters, <String, String>{
      'type': '1',
      'oid': '456',
      'segment_index': '2',
    });
    expect(server.requests.single.maximumBytes, 6 * 1024 * 1024);
  });
}
