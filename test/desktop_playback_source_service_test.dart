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

/// 验证 Windows 播放源解析、媒体地址安全校验、轨道选择与错误处理。
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
                        'https://192.168.1.5/video.m4s',
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
      // CDN 节点会使用 B 站侧指定的非标准端口，合法主机名应被保留。
      'https://backup.bilivideo.cn:8443/video.m4s',
    ]);
    expect(sources.audioUrls.single, contains('audio.bilivideo.com'));
    expect(
      sources.qualities.map((quality) => quality.id),
      orderedEquals(<int>[80, 64, 32]),
    );
    expect(sources.mediaHeaders['Referer'], contains('BV1GJ411x7h7'));
  });

  test('全部媒体地址均不安全时返回明确错误', () async {
    final BilibiliDesktopPlaybackSourceService service =
        BilibiliDesktopPlaybackSourceService(
          authService: BilibiliAuthService(cookieStore: _MemoryCookieStore()),
          // 固定响应只包含内网字面 IP 与片段地址，验证它们绝不会进入本机播放器。
          requestJson: (Uri _, Map<String, String> _) async {
            return jsonEncode(<String, Object?>{
              'code': 0,
              'data': <String, Object?>{
                'quality': 64,
                'dash': <String, Object?>{
                  'video': <Map<String, Object?>>[
                    <String, Object?>{
                      'id': 64,
                      'base_url': 'https://10.0.0.1/video.m4s',
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

  test('DASH 缺少安全音频地址时拒绝生成无声播放源', () async {
    final BilibiliDesktopPlaybackSourceService service =
        BilibiliDesktopPlaybackSourceService(
          authService: BilibiliAuthService(cookieStore: _MemoryCookieStore()),
          // 固定响应保留安全视频但移除音频，验证 Windows 不会把纯视频误判为播放成功。
          requestJson: (Uri _, Map<String, String> _) async {
            return jsonEncode(<String, Object?>{
              'code': 0,
              'data': <String, Object?>{
                'quality': 64,
                'dash': <String, Object?>{
                  'video': <Map<String, Object?>>[
                    <String, Object?>{
                      'id': 64,
                      'codecs': 'avc1.64001F',
                      'base_url': 'https://video.bilivideo.com/video.m4s',
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
          contains('安全的音频地址'),
        ),
      ),
    );
  });

  test('Windows 优先 AAC 并保留其他音频表示作为后备', () async {
    final BilibiliDesktopPlaybackSourceService service =
        BilibiliDesktopPlaybackSourceService(
          authService: BilibiliAuthService(cookieStore: _MemoryCookieStore()),
          // 固定响应让高带宽增强音频排在 AAC 前，验证兼容性优先而非只看码率。
          requestJson: (Uri _, Map<String, String> _) async {
            return jsonEncode(<String, Object?>{
              'code': 0,
              'data': <String, Object?>{
                'quality': 64,
                'dash': <String, Object?>{
                  'video': <Map<String, Object?>>[
                    <String, Object?>{
                      'id': 64,
                      'codecs': 'avc1.64001F',
                      'base_url': 'https://video.bilivideo.com/video.m4s',
                    },
                  ],
                  'audio': <Map<String, Object?>>[
                    <String, Object?>{
                      'id': 30251,
                      'bandwidth': 1500000,
                      'codecs': 'ec-3',
                      'base_url': 'https://audio.bilivideo.com/enhanced.m4s',
                    },
                    <String, Object?>{
                      'id': 30216,
                      'bandwidth': 900000,
                      'codecs': 'mp4a.40.5',
                      'base_url': 'https://audio.bilivideo.com/he-aac.m4s',
                    },
                    <String, Object?>{
                      'id': 30280,
                      'bandwidth': 192000,
                      'codecs': 'mp4a.40.2',
                      'base_url': 'https://audio.bilivideo.com/aac-main.m4s',
                      'backup_url': <String>[
                        'https://backup.bilivideo.cn/aac-backup.m4s',
                      ],
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

    expect(sources.audioCodec, 'mp4a.40.2');
    expect(sources.audioUrls, <String>[
      'https://audio.bilivideo.com/aac-main.m4s',
      'https://backup.bilivideo.cn/aac-backup.m4s',
      'https://audio.bilivideo.com/he-aac.m4s',
      'https://audio.bilivideo.com/enhanced.m4s',
    ]);
    expect(sources.audioCodecByUrl[sources.audioUrls.last], 'ec-3');
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

  test('B 站未来新增的公开 CDN 域名不再被域名白名单拦截', () async {
    final BilibiliDesktopPlaybackSourceService service =
        BilibiliDesktopPlaybackSourceService(
          authService: BilibiliAuthService(cookieStore: _MemoryCookieStore()),
          // 固定响应使用两个任意公开主机名，验证不再要求命中固定 CDN 白名单。
          requestJson: (Uri _, Map<String, String> _) async {
            return jsonEncode(<String, Object?>{
              'code': 0,
              'data': <String, Object?>{
                'quality': 64,
                'dash': <String, Object?>{
                  'video': <Map<String, Object?>>[
                    <String, Object?>{
                      'id': 64,
                      'codecs': 'avc1.64001F',
                      'base_url': 'https://cdn-01.new-bilibili-cdn.example/video.m4s',
                    },
                  ],
                  'audio': <Map<String, Object?>>[
                    <String, Object?>{
                      'id': 30280,
                      'codecs': 'mp4a.40.2',
                      'base_url': 'https://cdn-02.new-bilibili-cdn.example/audio.m4s',
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

    expect(sources.videoUrls.single, contains('new-bilibili-cdn.example'));
    expect(sources.audioUrls.single, contains('new-bilibili-cdn.example'));
  });

  test('内网字面 IP 与带用户信息地址一律拒绝，公开 http 地址放行', () async {
    final BilibiliDesktopPlaybackSourceService service =
        BilibiliDesktopPlaybackSourceService(
          authService: BilibiliAuthService(cookieStore: _MemoryCookieStore()),
          // 固定响应同时包含内网 IP、明文 http 与带用户信息的地址，验证内网
          // 与带账号信息的地址被拒绝、公开 http 地址被保留。
          requestJson: (Uri _, Map<String, String> _) async {
            return jsonEncode(<String, Object?>{
              'code': 0,
              'data': <String, Object?>{
                'quality': 64,
                'dash': <String, Object?>{
                  'video': <Map<String, Object?>>[
                    <String, Object?>{
                      'id': 64,
                      'base_url': 'https://upos-sz.bilivideo.com/video.m4s',
                      'backup_url': <String>[
                        'https://172.16.3.9/video.m4s',
                        'http://upos-sz.bilivideo.com/video.m4s',
                        'https://user:pass@upos-sz.bilivideo.com/video.m4s',
                      ],
                    },
                  ],
                  'audio': <Map<String, Object?>>[
                    <String, Object?>{
                      'id': 30280,
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

    // 内网字面 IP 与带账号信息的地址被拒绝；公开域名即使使用 http 也放行。
    expect(sources.videoUrls, <String>[
      'https://upos-sz.bilivideo.com/video.m4s',
      'http://upos-sz.bilivideo.com/video.m4s',
    ]);
  });
}
