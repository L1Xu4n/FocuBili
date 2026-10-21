import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:focubili/features/profile/personalization_settings_page.dart';
import 'package:focubili/models/ios_decode_preferences.dart';
import 'package:focubili/platform/app_platform.dart';
import 'package:focubili/services/bilibili_auth_service.dart';
import 'package:focubili/services/desktop_playback_source_service.dart';
import 'package:focubili/services/playback_preferences_service.dart';
import 'package:focubili/services/settings_transfer_service.dart';
import 'package:focubili/services/settings_runtime_adapter.dart';

class _RuntimeSettings implements SettingsRuntimeAdapter {
  @override
  Future<Map<String, Object>> readSettings() async => {};
  @override
  Future<void> writeSettings(Map<String, Object?> updates) async {}
}

class _Cookies implements BilibiliCookieStore {
  @override
  Future<String> readCookies() async => '';
  @override
  Future<void> replaceCookies(String value) async {}
  @override
  Future<void> clearBilibiliCookies() async {}
}

class _RejectStore extends InMemorySharedPreferencesStore {
  _RejectStore() : super.withData({});
  @override
  Future<bool> setValue(String valueType, String key, Object value) async =>
      false;
}

class _RejectPreferences extends PlaybackPreferencesService {
  @override
  Future<void> saveIosDecodeMode(IosDecodeMode mode) async =>
      throw StateError('rejected');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'missing, corrupt, and future values migrate to automatic decoding and AVC',
    () async {
      const service = PlaybackPreferencesService();
      for (final values in [
        <String, Object>{},
        {
          PlaybackPreferencesService.iosDecodeModeKey: 'future_mode',
          PlaybackPreferencesService.iosVideoCodecKey: 12,
        },
      ]) {
        SharedPreferences.setMockInitialValues(values);
        final preferences = await service.load();
        expect(preferences.iosDecodeMode, IosDecodeMode.automatic);
        expect(preferences.iosVideoCodec, IosVideoCodecPreference.avc);
        expect(preferences.wifiDefaultQuality.id, 64);
      }
      await service.saveIosDecodeMode(IosDecodeMode.software);
      await service.saveIosVideoCodec(IosVideoCodecPreference.hevc);
      final restored = (await service.load()).copyWith(
        showNoteTimeMarkers: false,
      );
      expect(restored.iosDecodeMode, IosDecodeMode.software);
      expect(restored.iosVideoCodec, IosVideoCodecPreference.hevc);
    },
  );

  test(
    'failed writes reload the persisted value rather than retaining a failed cache value',
    () async {
      SharedPreferencesStorePlatform.instance = _RejectStore();
      const service = PlaybackPreferencesService();
      await expectLater(
        service.saveIosDecodeMode(IosDecodeMode.software),
        throwsStateError,
      );
      expect((await service.load()).iosDecodeMode, IosDecodeMode.automatic);
      await expectLater(
        service.saveIosVideoCodec(IosVideoCodecPreference.hevc),
        throwsStateError,
      );
      expect((await service.load()).iosVideoCodec, IosVideoCodecPreference.avc);
    },
  );

  test(
    'settings transfer accepts known enums and rejects arbitrary mpv parameters',
    () {
      const service = SettingsTransferService();
      String file(Map<String, Object> values) => jsonEncode({
        'format': 'focubili-settings',
        'schemaVersion': 1,
        'settings': values,
      });
      expect(
        service.parseSettings(
          file({
            PlaybackPreferencesService.iosDecodeModeKey: 'videoToolbox',
            PlaybackPreferencesService.iosVideoCodecKey: 'hevc',
          }),
        ),
        hasLength(2),
      );
      for (final key in [
        PlaybackPreferencesService.iosDecodeModeKey,
        PlaybackPreferencesService.iosVideoCodecKey,
      ]) {
        expect(
          () => service.parseSettings(file({key: 'cuda,all'})),
          throwsFormatException,
        );
      }
    },
  );

  test(
    'export, reset and import preserve decode preferences through actual loaders',
    () async {
      const preferences = PlaybackPreferencesService();
      final transfer = SettingsTransferService(
        runtimeAdapter: _RuntimeSettings(),
      );
      await preferences.saveIosDecodeMode(IosDecodeMode.videoToolbox);
      await preferences.saveIosVideoCodec(IosVideoCodecPreference.hevc);
      final exported = await transfer.exportSettings();
      await transfer.resetSettings();
      expect((await preferences.load()).iosDecodeMode, IosDecodeMode.automatic);
      expect(
        (await preferences.load()).iosVideoCodec,
        IosVideoCodecPreference.avc,
      );
      await transfer.importSettings(transfer.parseSettings(exported));
      expect(
        (await preferences.load()).iosDecodeMode,
        IosDecodeMode.videoToolbox,
      );
      expect(
        (await preferences.load()).iosVideoCodec,
        IosVideoCodecPreference.hevc,
      );
    },
  );

  Map<String, Object> track(
    int quality,
    String codec, {
    int bandwidth = 1000,
  }) => {
    'id': quality,
    'height': quality == 64 ? 720 : 480,
    'bandwidth': bandwidth,
    'codecs': codec,
    'base_url': 'https://video.bilivideo.com/$quality/$codec.m4s',
  };

  Future<DesktopPlaybackSources> load(
    AppPlatform platform,
    List<Map<String, Object>> video,
  ) => BilibiliDesktopPlaybackSourceService(
    platform: platform,
    authService: BilibiliAuthService(cookieStore: _Cookies()),
    requestJson: (_, _) async => jsonEncode({
      'code': 0,
      'data': {
        'quality': 64,
        'dash': {
          'video': video,
          'audio': [
            {
              'id': 30280,
              'codecs': 'mp4a.40.2',
              'base_url': 'https://audio.bilivideo.com/a.m4s',
            },
          ],
        },
      },
    }),
  ).load(bvid: 'BV1GJ411x7h7', cid: 1, quality: 64);

  test(
    'iOS representation preference is reloaded and only breaks ties at the same quality',
    () async {
      final candidates = [
        track(64, 'av01.0.08M.08'),
        track(64, 'hev1.1.6.L120'),
        track(64, 'avc1.64001F'),
      ];
      expect(
        (await load(AppPlatform.ios, candidates)).videoCodec,
        'avc1.64001F',
      );
      await const PlaybackPreferencesService().saveIosVideoCodec(
        IosVideoCodecPreference.hevc,
      );
      expect(
        (await load(AppPlatform.ios, candidates)).videoCodec,
        'hev1.1.6.L120',
      );
      final preferred = await load(AppPlatform.ios, candidates);
      expect(preferred.videoUrls, [
        'https://video.bilivideo.com/64/hev1.1.6.L120.m4s',
        'https://video.bilivideo.com/64/avc1.64001F.m4s',
      ]);
      expect(
        (await load(AppPlatform.windows, candidates)).videoCodec,
        'avc1.64001F',
      );
      expect(
        (await load(AppPlatform.ios, [
          track(32, 'hev1.1.6.L120'),
          track(64, 'avc1.64001F'),
        ])).videoCodec,
        'avc1.64001F',
      );
      expect(
        (await load(AppPlatform.ios, [
          track(64, 'avc1.64001F'),
          track(64, 'av01.0.08M.08', bandwidth: 9000000000),
        ])).videoCodec,
        'avc1.64001F',
      );
      expect(
        (await load(AppPlatform.ios, [track(64, 'av01.0.08M.08')])).videoCodec,
        'av01.0.08M.08',
      );
    },
  );

  for (final platform in AppPlatform.values) {
    testWidgets(
      'decode settings are ${platform == AppPlatform.ios ? 'available' : 'hidden'} on ${platform.name}',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(home: PersonalizationSettingsPage(appPlatform: platform)),
        );
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('settings-search')),
          'iPad',
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('ios-decode-mode-preference')),
          platform == AppPlatform.ios ? findsOneWidget : findsNothing,
        );
        expect(
          find.byKey(const Key('ios-video-codec-preference')),
          platform == AppPlatform.ios ? findsOneWidget : findsNothing,
        );
      },
    );
  }

  for (final fail in [false, true]) {
    testWidgets(
      'software warning is visible and save ${fail ? 'failure keeps automatic mode' : 'persists choice'}',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: PersonalizationSettingsPage(
              appPlatform: AppPlatform.ios,
              preferencesService: fail
                  ? _RejectPreferences()
                  : const PlaybackPreferencesService(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.enterText(find.byKey(const Key('settings-search')), '硬解');
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('ios-decode-mode-preference')));
        await tester.pumpAndSettle();
        expect(find.textContaining('可能明显增加耗电和发热'), findsOneWidget);
        await tester.tap(find.text('软件解码（排查用）'));
        await tester.pumpAndSettle();
        expect(
          (await const PlaybackPreferencesService().load()).iosDecodeMode,
          fail ? IosDecodeMode.automatic : IosDecodeMode.software,
        );
        expect(
          find.text(fail ? '解码偏好保存失败，请重试。' : '已保存，下次加载视频时生效。'),
          findsOneWidget,
        );
      },
    );
  }

  testWidgets('HEVC UI persists an independent streaming preference', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: PersonalizationSettingsPage(appPlatform: AppPlatform.ios),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('settings-search')), 'H265');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('ios-video-codec-preference')));
    await tester.pumpAndSettle();
    expect(find.textContaining('不转换已下载文件'), findsOneWidget);
    await tester.tap(find.text('HEVC / H.265 优先'));
    await tester.pumpAndSettle();
    final preferences = await const PlaybackPreferencesService().load();
    expect(preferences.iosVideoCodec, IosVideoCodecPreference.hevc);
    expect(preferences.iosDecodeMode, IosDecodeMode.automatic);
  });
}
