import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/models/ios_decode_preferences.dart';
import 'package:focubili/models/playback_preferences.dart';
import 'package:focubili/models/media_runtime_diagnostic.dart';
import 'package:focubili/platform/app_platform.dart';
import 'package:focubili/services/ios_decode_session.dart';

void main() {
  setUp(IosDecodeSession.clearDiagnostics);

  test(
    'other backends do not load settings or write iOS mpv options',
    () async {
      for (final platform in AppPlatform.values.where(
        (p) => p != AppPlatform.ios,
      )) {
        final session = IosDecodeSession(
          platform: platform,
          loadPreferences: () async => throw StateError('must not read'),
          readProperty: (_) async => throw StateError('must not read'),
          writeProperty: (_, _) async => throw StateError('must not write'),
          canReadVideo: () => true,
        );
        expect(await session.configure(isCurrent: () => true), isTrue);
        await session.dispose();
      }
      expect(await IosDecodeSession.readDiagnostics(), isEmpty);
    },
  );

  test(
    'next media load applies changed mode; requested hardware can actually be software',
    () async {
      var preferences = const PlaybackPreferences();
      final properties = <String, String>{
        'hwdec-current': 'no',
        'video-format': 'h264',
        'video-codec': 'h264 (H.264 / AVC / MPEG-4 AVC / MPEG-4 part 10)',
        'width': '1920',
        'height': '1080',
        'container-fps': '59.94',
        'speed': '1.5',
        'frame-drop-count': '3',
        'video-params/gamma': 'pq',
        'mpv-version': 'mpv 0.36.0',
      };
      final writes = <String>[];
      final session = IosDecodeSession(
        platform: AppPlatform.ios,
        loadPreferences: () async => preferences,
        readProperty: (name) async => properties[name] ?? '',
        writeProperty: (name, value) async {
          writes.add(value);
          properties[name] = value;
        },
        canReadVideo: () => true,
      );
      addTearDown(session.dispose);
      await session.configure(isCurrent: () => true);
      preferences = preferences.copyWith(
        iosDecodeMode: IosDecodeMode.videoToolbox,
      );
      session.beginSource();
      await session.configure(isCurrent: () => true);
      final fields = MediaRuntimeDiagnostic.parse(
        await IosDecodeSession.readDiagnostics(),
      ).last.fields;
      expect(writes, ['auto-copy', 'videotoolbox-copy']);
      expect(fields['hwdec_configured'], 'videotoolbox-copy');
      expect(fields['hwdec_current'], 'no');
      expect(fields['decode_option_status'], 'accepted');
      expect(fields['decoder'], 'h264');
      expect(fields['codec_family'], 'h264');
      expect(fields['fps'], '59.94');
      expect(fields['mpv_version'], 'mpv 0.36.0');
      expect(fields['transfer'], 'pq');
    },
  );

  test(
    'rejected option readback falls back to verified automatic mode',
    () async {
      var actual = 'auto-copy';
      final writes = <String>[];
      final session = IosDecodeSession(
        platform: AppPlatform.ios,
        loadPreferences: () async => const PlaybackPreferences(
          iosDecodeMode: IosDecodeMode.videoToolbox,
        ),
        readProperty: (_) async => actual,
        writeProperty: (_, value) async {
          writes.add(value);
          if (value == 'auto-copy') actual = value;
        },
        canReadVideo: () => false,
      );
      addTearDown(session.dispose);
      expect(await session.configure(isCurrent: () => true), isTrue);
      expect(writes, ['videotoolbox-copy', 'auto-copy']);
      final fields = MediaRuntimeDiagnostic.parse(
        await IosDecodeSession.readDiagnostics(),
      ).last.fields;
      expect(fields['decode_option_status'], 'fallback_auto');
      expect(fields['hwdec_configured'], 'auto-copy');
      expect(fields.containsKey('hwdec_current'), isFalse);
    },
  );

  test(
    'unavailable native options never claim successful configuration',
    () async {
      final session = IosDecodeSession(
        platform: AppPlatform.ios,
        loadPreferences: () async =>
            const PlaybackPreferences(iosDecodeMode: IosDecodeMode.software),
        readProperty: (_) async => '',
        writeProperty: (_, _) async => throw StateError('not supported'),
        canReadVideo: () => false,
      );
      addTearDown(session.dispose);
      expect(await session.configure(isCurrent: () => true), isTrue);
      final fields = MediaRuntimeDiagnostic.parse(
        await IosDecodeSession.readDiagnostics(),
      ).last.fields;
      expect(fields['decode_option_status'], 'unavailable');
      expect(fields.containsKey('hwdec_configured'), isFalse);
      expect(fields.containsKey('hwdec_current'), isFalse);
    },
  );

  test(
    'superseded load cannot write a preference after its asynchronous read',
    () async {
      final gate = Completer<PlaybackPreferences>();
      var current = true;
      var writes = 0;
      final session = IosDecodeSession(
        platform: AppPlatform.ios,
        loadPreferences: () => gate.future,
        readProperty: (_) async => '',
        writeProperty: (_, _) async => writes++,
        canReadVideo: () => false,
      );
      final pending = session.configure(isCurrent: () => current);
      await Future<void>.delayed(Duration.zero);
      current = false;
      gate.complete(
        const PlaybackPreferences(iosDecodeMode: IosDecodeMode.software),
      );
      expect(await pending, isFalse);
      expect(writes, 0);
      await session.dispose();
    },
  );

  test(
    'dispose waits for in-flight reads and no further mpv access is possible',
    () async {
      final gate = Completer<String>();
      final entered = Completer<void>();
      var reads = 0;
      final session = IosDecodeSession(
        platform: AppPlatform.ios,
        loadPreferences: () async => const PlaybackPreferences(),
        readProperty: (_) {
          reads++;
          entered.complete();
          return gate.future;
        },
        writeProperty: (_, _) async {},
        canReadVideo: () => true,
      );
      final sampling = IosDecodeSession.readDiagnostics();
      await entered.future;
      var disposed = false;
      final disposal = session.dispose().then((_) => disposed = true);
      await Future<void>.delayed(Duration.zero);
      expect(disposed, isFalse);
      gate.complete('no');
      expect(await sampling, isEmpty);
      await disposal;
      expect(await session.configure(isCurrent: () => true), isFalse);
      expect(await IosDecodeSession.readDiagnostics(), isEmpty);
      expect(reads, 1);
    },
  );

  test(
    'ready capture survives route disposal, is bounded, sanitized, and clearable',
    () async {
      final session = IosDecodeSession(
        platform: AppPlatform.ios,
        loadPreferences: () async => const PlaybackPreferences(),
        readProperty: (_) async => 'https://private.invalid/?SESSDATA=secret',
        writeProperty: (_, _) async {},
        canReadVideo: () => true,
      );
      session.captureReady();
      // Await the same serial queue without adding a diagnostic poll.
      await session.configure(isCurrent: () => true);
      final first = await IosDecodeSession.readDiagnostics();
      expect(first, hasLength(2));
      expect(first.toString(), isNot(contains('secret')));
      expect(first.last.containsKey('hwdec_current'), isFalse);
      session.captureReady();
      for (var i = 0; i < 70; i++) {
        await IosDecodeSession.readDiagnostics();
      }
      await session.dispose();
      expect(await IosDecodeSession.readDiagnostics(), hasLength(64));
      IosDecodeSession.clearDiagnostics();
      expect(await IosDecodeSession.readDiagnostics(), isEmpty);
    },
  );

  test(
    'source switching while sampling discards the old decoder result',
    () async {
      final gate = Completer<String>();
      final entered = Completer<void>();
      final session = IosDecodeSession(
        platform: AppPlatform.ios,
        loadPreferences: () async => const PlaybackPreferences(),
        readProperty: (_) {
          entered.complete();
          return gate.future;
        },
        writeProperty: (_, _) async {},
        canReadVideo: () => true,
      );
      final sampling = IosDecodeSession.readDiagnostics();
      await entered.future;
      session.beginSource();
      gate.complete('videotoolbox-copy');
      expect(await sampling, isEmpty);
      await session.dispose();
    },
  );
}
