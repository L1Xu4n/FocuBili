import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/features/player/widgets/player_subtitle_sheet.dart';
import 'package:focubili/models/player_overlay_data.dart';
import 'package:focubili/services/bilibili_auth_service.dart';
import 'package:focubili/services/bilibili_wbi_signing_service.dart';
import 'package:focubili/services/desktop_player_overlay_service.dart';
import 'package:focubili/services/subtitle_diagnostic_log.dart';

import 'fixtures/subtitle_wbi_navigation.dart';

const _bvid = 'BV1GJ411x7h7';

class _Cookies implements BilibiliCookieStore {
  @override
  Future<String> readCookies() async => 'synthetic_session=fixture';
  @override
  Future<void> replaceCookies(String value) async {}
  @override
  Future<void> clearBilibiliCookies() async {}
}

DesktopOverlayHttpResponse _json(Object value, {int status = 200}) =>
    DesktopOverlayHttpResponse(
      statusCode: status,
      bodyBytes: Uint8List.fromList(utf8.encode(jsonEncode(value))),
    );

void main() {
  testWidgets('subtitle diagnostics copy only after a user click', (
    tester,
  ) async {
    String? copied;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );
    await tester.binding.setSurfaceSize(const Size(1080, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlayerSubtitleSheet(
            videoLabel: 'fixture',
            offValue: 'off',
            fontSize: 16,
            isCurrentVideo: () => true,
            initialResult: const SubtitleTrackLoadResult.empty(),
            reloadTracks: () async => const SubtitleTrackLoadResult.empty(),
            onPreviewFontSize: (_) {},
            onCommitFontSize: (size) async => size,
            diagnosticReport: () => 'sanitized fixture provenance',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(copied, isNull);
    await tester.tap(find.text('字幕来源诊断'));
    await tester.pumpAndSettle();
    final copy = find.byKey(const Key('copy-subtitle-diagnostics'));
    await tester.ensureVisible(copy);
    await tester.tap(copy);
    await tester.pumpAndSettle();
    expect(copied, 'sanitized fixture provenance');
    expect(tester.takeException(), isNull);
  });

  test(
    'same-CID refresh signs the current identity and never uses legacy v2',
    () async {
      final requests = <Uri>[];
      final service = DesktopPlayerOverlayService(
        authService: BilibiliAuthService(cookieStore: _Cookies()),
        request: (uri, headers, limit) async {
          requests.add(uri);
          expect(headers['referer'], 'https://www.bilibili.com/video/$_bvid');
          expect(headers['cache-control'], 'no-cache');
          if (uri.path == '/x/web-interface/nav') {
            return subtitleWbiNavigation();
          }
          expect(uri.path, '/x/player/wbi/v2');
          final parameters = Map<String, String>.from(uri.queryParameters);
          expect(parameters['bvid'], _bvid);
          expect(parameters['cid'], '137649199');
          expect(parameters.containsKey('aid'), isFalse);
          final timestamp = int.parse(parameters['wts']!);
          final signature = parameters.remove('w_rid');
          parameters.remove('wts');
          final mixin = BilibiliWbiSigningService.deriveMixinKey(
            '7cd084941338484aae1ad9425b84077c',
            '4932caff0ff746eab6f01bf08b70ac45',
          );
          expect(
            signature,
            BilibiliWbiSigningService.sign(
              parameters,
              mixin,
              timestamp,
            )['w_rid'],
          );
          return _json({
            'code': 0,
            'data': {
              'bvid': _bvid,
              'cid': 137649199,
              'aid': 80433022,
              'subtitle': {'subtitles': []},
            },
          });
        },
      );
      for (var i = 0; i < 4; i++) {
        expect(
          (await service.loadSubtitleTracks(
            bvid: _bvid,
            cid: 137649199,
          )).status,
          SubtitleLoadStatus.empty,
        );
      }
      expect(
        requests.where((u) => u.path == '/x/web-interface/nav'),
        hasLength(1),
      );
      expect(requests.where((u) => u.path == '/x/player/wbi/v2'), hasLength(4));
      expect(requests.any((u) => u.path == '/x/player/v2'), isFalse);
      final report = SubtitleDiagnosticLog.instance.report(
        bvid: _bvid,
        cid: 137649199,
      );
      expect(report, contains('"responseAid":80433022'));
      expect(report, contains('"signed":true'));
      expect(report, isNot(contains('synthetic_session')));
      expect(report, isNot(contains('w_rid')));
    },
  );

  for (final failNav in [true, false]) {
    test(
      '${failNav ? 'nav' : 'metadata'} HTTP 412 stops without a legacy request',
      () async {
        final requests = <String>[];
        final service = DesktopPlayerOverlayService(
          authService: BilibiliAuthService(cookieStore: _Cookies()),
          request: (uri, headers, limit) async {
            requests.add(uri.path);
            if (!failNav && uri.path == '/x/web-interface/nav') {
              return subtitleWbiNavigation();
            }
            return _json({'message': 'synthetic rejection'}, status: 412);
          },
        );
        expect(
          (await service.loadSubtitleTracks(bvid: _bvid, cid: 900)).status,
          SubtitleLoadStatus.unavailable,
        );
        expect(
          requests,
          failNav
              ? ['/x/web-interface/nav']
              : ['/x/web-interface/nav', '/x/player/wbi/v2'],
        );
        final report = SubtitleDiagnosticLog.instance.report(
          bvid: _bvid,
          cid: 900,
        );
        expect(report, contains('"httpStatus":412'));
        expect(
          report,
          contains(
            failNav ? 'subtitle_signing_unavailable' : 'subtitle_network',
          ),
        );
      },
    );
  }

  test('diagnostics accept only safe typed facts and stay bounded', () {
    final log = SubtitleDiagnosticLog();
    log.record(
      bvid: _bvid,
      cid: 1,
      stage: 'metadata-response',
      source: 'dart-http',
      facts: {
        'Cookie': 'SECRET-cookie',
        'url': 'https://example.com/body?token=SECRET-token',
        'content': 'SECRET-caption',
        'bodyHash': 'SECRET-invalid-hash',
        'documentId': SubtitleDiagnosticLog.digest('synthetic document'),
        'responseBvid': _bvid,
        'responseCid': 1,
        'language': 'SECRET-invalid-language?token',
        'errorCode': 'SECRET-server-message',
        'endpoint': '/x/player/wbi/v2?token=SECRET-token',
      },
    );
    var report = log.report();
    expect(report, isNot(contains('SECRET')));
    expect(report, contains('documentId'));
    for (var i = 0; i < 100; i++) {
      log.record(
        bvid: _bvid,
        cid: 2,
        stage: 'present',
        source: 'player-ui',
        facts: {'requestId': i},
      );
    }
    report = log.report();
    final events = report
        .split('\n')
        .where((line) => line.startsWith('{'))
        .toList();
    expect(events, hasLength(80));
    expect(jsonDecode(events.first)['requestId'], 20);
    expect(log.report(bvid: _bvid, cid: 1), isNot(contains('documentId')));
  });

  test(
    'resource and normalized cue hashes separate document and display changes',
    () {
      final original = SubtitleDiagnosticLog.resourceId(
        Uri.parse('https://i0.hdslb.com/bfs/subtitle/a.json?auth_key=old'),
        'zh-CN',
      );
      expect(
        original,
        SubtitleDiagnosticLog.resourceId(
          Uri.parse('https://i1.hdslb.com/bfs/subtitle/a.json?auth_key=new'),
          'zh-CN',
        ),
      );
      expect(
        original,
        isNot(
          SubtitleDiagnosticLog.resourceId(
            Uri.parse('https://i0.hdslb.com/bfs/subtitle/b.json'),
            'zh-CN',
          ),
        ),
      );
      expect(
        original,
        isNot(
          SubtitleDiagnosticLog.resourceId(
            Uri.parse('https://i0.hdslb.com/bfs/subtitle/a.json'),
            'en',
          ),
        ),
      );
      String hash(String text) => SubtitleDiagnosticLog.cueHash([
        SubtitleCue(
          from: Duration.zero,
          to: const Duration(seconds: 1),
          content: text,
        ),
      ]);
      expect(hash('fixture A'), isNot(hash('fixture B')));
    },
  );
}
