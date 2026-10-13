import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/models/playback_request_diagnostic.dart';
import 'package:focubili/services/native_playback_service.dart';
import 'package:focubili/services/problem_diagnostics_service.dart';

Map<String, Object?> request({int id = 1}) => {
  'request_id': id,
  'wbi_enabled': true,
  'wbi_signed': true,
  'wbi_fallback': false,
  'playurl_attempted': true,
  'session_read': 'ok',
  'auth_state': 'session_present_unverified',
  'requested_quality': 80,
  'returned_quality': 16,
  'selected_quality': 16,
  'stage': 'complete',
  'outcome': 'quality_downgrade',
  'api_code': 0,
  'http_status': 200,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.focubili.app/playback');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    messenger.setMockMethodCallHandler(channel, (_) async => null);
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  Future<ProblemDiagnosticsService> service() async {
    final prefs = await SharedPreferences.getInstance();
    return ProblemDiagnosticsService(
      preferencesLoader: () async => prefs,
      appVersionLoader: () async => '1.7.0+20',
      deviceInfoLoader: () async => const DiagnosticDeviceInfo(
        platformName: 'Android',
        systemVersion: 'test',
        apiLevel: 35,
        model: 'synthetic',
      ),
      reminderDiagnosticsLoader: () async =>
          ReminderDiagnosticsSnapshot.unavailable(),
    );
  }

  Future<void> send(Map<String, Object?> values) async {
    final completed = Completer<void>();
    messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('playbackRequestDiagnostic', values),
      ),
      (_) => completed.complete(),
    );
    await completed.future;
  }

  test(
    'native request event survives storage and export with all safe fields',
    () async {
      final diagnostics = await service();
      final player = NativePlaybackService(diagnosticsService: diagnostics);
      await send(request());
      final entry = (await diagnostics.loadRecentErrors()).single;
      expect(entry.categoryLabel, '播放请求');
      expect(entry.additionalInfo.length, 14);
      expect(entry.additionalInfo['requested_quality'], '80');
      expect(entry.additionalInfo['returned_quality'], '16');
      expect(entry.additionalInfo['selected_quality'], '16');
      final exported = await diagnostics.buildCopyText();
      expect(exported, contains('wbi_enabled: true'));
      expect(exported, contains('wbi_signed: true'));
      expect(exported, contains('wbi_fallback: false'));
      expect(exported, contains('auth_state: session_present_unverified'));
      expect(exported, contains('outcome: quality_downgrade'));
      await player.dispose();
    },
  );

  test(
    'enabled WBI with signing failure never claims a signed or sent request',
    () async {
      final diagnostics = await service();
      final player = NativePlaybackService(diagnosticsService: diagnostics);
      await send(
        request()..addAll({
          'wbi_signed': false,
          'playurl_attempted': false,
          'returned_quality': null,
          'selected_quality': null,
          'stage': 'signing',
          'outcome': 'error',
        }),
      );
      final fields =
          (await diagnostics.loadRecentErrors()).single.additionalInfo;
      expect(fields['wbi_enabled'], 'true');
      expect(fields['wbi_signed'], 'false');
      expect(fields['wbi_fallback'], 'false');
      expect(fields['playurl_attempted'], 'false');
      expect(fields['stage'], 'signing');
      expect(fields.containsKey('returned_quality'), isFalse);
      await player.dispose();
    },
  );

  test(
    'diagnosis uses captured request settings rather than later preferences',
    () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('app_behavior_preferences.wbi_signing_enabled', true);
      final diagnostics = await service();
      final player = NativePlaybackService(diagnosticsService: diagnostics);
      await send(
        request()..addAll({'wbi_enabled': false, 'wbi_signed': false}),
      );
      final fields =
          (await diagnostics.loadRecentErrors()).single.additionalInfo;
      expect(fields['wbi_enabled'], 'false');
      expect(fields['wbi_signed'], 'false');
      await player.dispose();
    },
  );

  test(
    'malformed native values and unknown fields cannot leak into exported text',
    () async {
      const secret = 'synthetic-private-value';
      final malicious = request()
        ..addAll({
          'Cookie': secret,
          'SESSDATA': secret,
          'token': secret,
          'url': 'https://example.invalid/video?w_rid=$secret',
          'auth_state': secret,
          'wbi_signed': secret,
          'requested_quality': secret,
          'stage': secret,
        });
      final diagnostics = await service();
      final player = NativePlaybackService(diagnosticsService: diagnostics);
      await send(malicious);
      final exported = await diagnostics.buildCopyText();
      expect(exported.contains(secret), isFalse);
      expect(exported.contains('example.invalid'), isFalse);
      expect(exported.contains('w_rid'), isFalse);
      expect(exported, contains('auth_state: unknown'));
      expect(
        PlaybackRequestDiagnostic.fromPlatformMap({'request_id': secret}),
        isNull,
      );
      await player.dispose();
    },
  );

  test(
    'concurrent request and playback failure writes keep both records',
    () async {
      final first = await service();
      final second = await service();
      await Future.wait([
        first.recordPlaybackRequest(
          PlaybackRequestDiagnostic.fromPlatformMap(request())!,
        ),
        second.recordPlaybackFailure(
          message: 'HTTP 403',
          playerState: 'preparing',
          multiPart: false,
        ),
      ]);
      expect(await first.loadRecentErrors(), hasLength(2));
      final pending = first.recordPlaybackRequest(
        PlaybackRequestDiagnostic.fromPlatformMap(request(id: 2))!,
      );
      await second.clearRecentErrors();
      await pending;
      expect(await first.loadRecentErrors(), isEmpty);
    },
  );
}
