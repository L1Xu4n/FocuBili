import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/services/bilibili_auth_service.dart';
import 'package:focubili/services/desktop_playback_source_service.dart';

/// 使用内存字符串模拟平台 Cookie 容器，确保测试不会接触真实账号会话。
class _MemoryCookieStore implements BilibiliCookieStore {
  /// 创建带可选初始 Cookie 的内存容器。
  _MemoryCookieStore([this.value = '']);

  String value;

  /// 返回测试内存中的 Cookie。
  @override
  Future<String> readCookies() async => value;

  /// 使用新值替换测试内存中的 Cookie。
  @override
  Future<void> replaceCookies(String cookieHeader) async {
    value = cookieHeader;
  }

  /// 清空测试内存中的 Cookie。
  @override
  Future<void> clearBilibiliCookies() async {
    value = '';
  }
}

/// 验证 Windows 播放源解析、域名白名单、轨道选择与错误处理。
void main() {
  test('选择目标清晰度 AVC 轨道并保留安全主备地址', () async {
    late Uri requestedEndpoint;
    late Map<String, String> requestedHeaders;
    final BilibiliDesktopPlaybackSourceService service =
        BilibiliDesktopPlaybackSourceService(
          authService: BilibiliAuthService(
            cookieStore: _MemoryCookieStore('SESSDATA=test-session'),
          ),
          // 固定请求函数记录参数，并返回同时含 AVC、HEVC 和恶意地址的测试响应。
          requestJson: (Uri endpoint, Map<String, String> headers) async {
            requestedEndpoint = endpoint;
            requestedHeaders = headers;
            return jsonEncode(<String, Object?>{
              'code': 0,
              'data': <String, Object?>{
                'quality': 64,
                'accept_quality': <int>[80, 64, 32],
                'accept_description': <String>[
                  '高清 1080P',
                  '高清 720P',
                  '清晰 480P',
                ],
                'dash': <String, Object?>{
                  'video': <Map<String, Object?>>[
                    <String, Object?>{
                      'id': 64,
                      'height': 720,
                      'bandwidth': 2000,
                      'codecs': 'hev1.1.6.L120',
                      'base_url': 'https://hevc.example.invalid/video.m4s',
                    },
                    <String, Object?>{
                      'id': 64,
                      'height': 720,
                      'bandwidth': 1500,
                      'codecs': 'avc1.64001F',
                      'base_url': 'https://upos-sz.bilivideo.com/video.m4s',
                      'backup_url': <String>[
                        'https://backup.bilivideo.cn/video.m4s',
                        'https://evil.example.com/video.m4s',
                        'https://backup.bilivideo.cn:8443/video.m4s',
                        'https://backup.bilivideo.cn/video.m4s#unsafe',
                      ],
                    },
                  ],
                  'audio': <Map<String, Object?>>[
                    <String, Object?>{
                      'id': 30280,
                      'bandwidth': 192000,
                      'codecs': 'mp4a.40.2',
                      'base_url': 'https://audio.bilivideo.com/audio.m4s',
                    },
                  ],
                },
              },
            });
          },
        );

    final DesktopPlaybackSources sources = await service.load(
      bvid: 'BV1GJ411x7h7',
      cid: 137649199,
      quality: 64,
    );

    expect(requestedEndpoint.host, 'api.bilibili.com');
    expect(requestedEndpoint.path, '/x/player/playurl');
    expect(requestedEndpoint.queryParameters['fnval'], '16');
    expect(requestedHeaders['Cookie'], 'SESSDATA=test-session');
    expect(sources.videoCodec, 'avc1.64001F');
    expect(sources.videoUrls, <String>[
      'https://upos-sz.bilivideo.com/video.m4s',
      'https://backup.bilivideo.cn/video.m4s',
    ]);
    expect(sources.audioUrls.single, contains('audio.bilivideo.com'));
    expect(
      sources.qualities.map((quality) => quality.id),
      orderedEquals(<int>[80, 64, 32]),
    );
    expect(sources.mediaHeaders['Referer'], contains('BV1GJ411x7h7'));
  });

  test('全部媒体地址越过白名单时返回明确错误', () async {
    final BilibiliDesktopPlaybackSourceService service =
        BilibiliDesktopPlaybackSourceService(
          authService: BilibiliAuthService(cookieStore: _MemoryCookieStore()),
          // 固定响应只包含第三方域名，验证其绝不会进入本机播放器。
          requestJson: (Uri _, Map<String, String> _) async {
            return jsonEncode(<String, Object?>{
              'code': 0,
              'data': <String, Object?>{
                'quality': 64,
                'dash': <String, Object?>{
                  'video': <Map<String, Object?>>[
                    <String, Object?>{
                      'id': 64,
                      'base_url': 'https://example.com/video.m4s',
                    },
                  ],
                  'audio': <Object?>[],
                },
              },
            });
          },
        );

    await expectLater(
      service.load(bvid: 'BV1GJ411x7h7', cid: 137649199, quality: 64),
      throwsA(
        isA<DesktopPlaybackSourceException>().having(
          (DesktopPlaybackSourceException error) => error.message,
          'message',
          contains('安全的视频地址'),
        ),
      ),
    );
  });

  test('接口错误码不会泄露响应或会话内容', () async {
    final BilibiliDesktopPlaybackSourceService service =
        BilibiliDesktopPlaybackSourceService(
          authService: BilibiliAuthService(
            cookieStore: _MemoryCookieStore('SESSDATA=secret-value'),
          ),
          // 错误响应包含固定服务端说明，业务异常只允许展示错误码与说明。
          requestJson: (Uri _, Map<String, String> _) async {
            return '{"code":-404,"message":"啥都木有"}';
          },
        );

    await expectLater(
      service.load(bvid: 'BV1GJ411x7h7', cid: 137649199, quality: 64),
      throwsA(
        isA<DesktopPlaybackSourceException>()
            .having(
              (DesktopPlaybackSourceException error) => error.message,
              'message',
              contains('-404'),
            )
            .having(
              (DesktopPlaybackSourceException error) => error.message,
              'secret',
              isNot(contains('secret-value')),
            ),
      ),
    );
  });
}
