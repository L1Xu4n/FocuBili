import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/features/player/widgets/player_subtitle_sheet.dart';
import 'package:focubili/models/player_overlay_data.dart';
import 'package:focubili/services/bilibili_auth_service.dart';
import 'package:focubili/services/desktop_player_overlay_service.dart';
import 'package:focubili/services/player_overlay_service.dart';
import 'fixtures/subtitle_wbi_navigation.dart';

class _Cookies implements BilibiliCookieStore {
  @override
  Future<String> readCookies() async => '';
  @override
  Future<void> replaceCookies(String value) async {}
  @override
  Future<void> clearBilibiliCookies() async {}
}

class _SourceChannel implements PlayerOverlayPlatformChannel {
  @override
  Future<Object?> invokeMethod(
    String method, [
    Map<String, Object?>? arguments,
  ]) async => {
    'status': 'available',
    'tracks': [
      {'id': '1', 'language': 'zh', 'label': '中文', 'sourceType': 1},
      {'id': '2', 'language': 'ai-zh', 'label': 'AI 名称不作判断依据'},
    ],
  };
}

void main() {
  test(
    'shared HTTP carries the API type instead of guessing from labels or languages',
    () async {
      final service = DesktopPlayerOverlayService(
        authService: BilibiliAuthService(cookieStore: _Cookies()),
        request: (uri, headers, limit) async {
          if (uri.path == '/x/web-interface/nav') {
            return subtitleWbiNavigation();
          }
          return DesktopOverlayHttpResponse(
            statusCode: 200,
            bodyBytes: Uint8List.fromList(
              utf8.encode(
                jsonEncode({
                  'code': 0,
                  'data': {
                    'bvid': 'BV1GJ411x7h7',
                    'cid': 1,
                    'subtitle': {
                      'subtitles': [
                        for (final (i, type) in <(int, Object?)>[
                          (1, 1),
                          (2, 0),
                          (3, null),
                          (4, 99),
                          (5, 1.5),
                          (6, '1'),
                        ])
                          {
                            'id': i,
                            'lan': i == 1 ? 'zh-CN' : 'ai-zh',
                            'lan_doc': i == 1 ? '中文' : '中文（AI）',
                            'type': type,
                            'subtitle_url':
                                '//i0.hdslb.com/bfs/subtitle/$i.json',
                          },
                      ],
                    },
                  },
                }),
              ),
            ),
          );
        },
      );
      final result = await service.loadSubtitleTracks(
        bvid: 'BV1GJ411x7h7',
        cid: 1,
      );
      expect(result.tracks.map((t) => t.sourceType), [
        1,
        0,
        null,
        99,
        null,
        null,
      ]);
      expect(result.tracks.map((t) => t.isAi), [
        true,
        false,
        false,
        false,
        false,
        false,
      ]);
    },
  );

  test('Android bridge preserves explicit source type', () async {
    final result = await NativePlayerOverlayService(
      platformChannel: _SourceChannel(),
    ).loadSubtitleTracks(bvid: 'BV1GJ411x7h7', cid: 1);
    expect(result.tracks.map((t) => t.isAi), [true, false]);
  });

  testWidgets(
    'subtitle menu badges only explicit AI sources at large text sizes',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      const result = SubtitleTrackLoadResult(
        status: SubtitleLoadStatus.available,
        message: '',
        tracks: [
          SubtitleTrack(
            id: '1',
            language: 'zh',
            label: '中文',
            isLocked: false,
            sourceType: 1,
          ),
          SubtitleTrack(
            id: '2',
            language: 'zh',
            label: '视频字幕',
            isLocked: false,
            sourceType: 0,
          ),
          SubtitleTrack(
            id: '3',
            language: 'ai-zh',
            label: '未知来源（AI名称）',
            isLocked: false,
          ),
        ],
      );
      final font = FontLoader('SubtitleSource');
      if (File('C:/Windows/Fonts/msyh.ttc').existsSync()) {
        font.addFont(
          Future.value(
            ByteData.sublistView(
              File('C:/Windows/Fonts/msyh.ttc').readAsBytesSync(),
            ),
          ),
        );
        await font.load();
      }
      await tester.pumpWidget(
        RepaintBoundary(
          key: const Key('source-menu-capture'),
          child: MaterialApp(
            theme: ThemeData(fontFamily: 'SubtitleSource'),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
            home: Scaffold(
              body: PlayerSubtitleSheet(
                videoLabel: 'fixture',
                offValue: 'off',
                fontSize: 16,
                isCurrentVideo: () => true,
                reloadTracks: () async => result,
                initialResult: result,
                onPreviewFontSize: (_) {},
                onCommitFontSize: (v) async => v,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('subtitle-ai-1')), findsOneWidget);
      expect(find.byKey(const ValueKey('subtitle-ai-2')), findsNothing);
      expect(find.byKey(const ValueKey('subtitle-ai-3')), findsNothing);
      if (Platform.environment['FOCUBILI_LAYOUT_CAPTURE'] == '1') {
        await tester.runAsync(() async {
          final image = await tester
              .renderObject<RenderRepaintBoundary>(
                find.byKey(const Key('source-menu-capture')),
              )
              .toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final f = File('evidence/subtitle-layout/ai-source-menu-large.png');
          await f.parent.create(recursive: true);
          await f.writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      expect(tester.takeException(), isNull);
    },
  );
}
