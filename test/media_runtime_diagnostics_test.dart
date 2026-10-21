import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/models/media_runtime_diagnostic.dart';
import 'package:focubili/services/problem_diagnostics_service.dart';

Map<String, Object?> event(String kind, {String track = 'video'}) => {
  'event': kind,
  'session_id': 1,
  'attempt': 1,
  'elapsed_ms': 321,
  'track': track,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.focubili.app/playback');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  ProblemDiagnosticsService service({
    Future<Object?> Function()? loader,
    Future<void> Function()? clearer,
  }) => ProblemDiagnosticsService(
    mediaRuntimeLoader: loader,
    mediaRuntimeClearer: clearer,
    appVersionLoader: () async => '1.8.2+32',
    deviceInfoLoader: () async => const DiagnosticDeviceInfo(
      platformName: 'Android',
      systemVersion: '10',
      apiLevel: 29,
      model: 'fixture',
    ),
    reminderDiagnosticsLoader: () async =>
        ReminderDiagnosticsSnapshot.unavailable(),
    reminderDiagnosticsClearer: () async {},
  );

  test(
    'native runtime snapshots export without persistence or active player service',
    () async {
      var reads = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'getMediaRuntimeDiagnostics') {
          reads++;
          return [
            event('first_frame')
              ..addAll({'first_frame_ms': 321, 'prepare_to_frame_ms': 120}),
            event('load_error', track: 'audio')
              ..addAll({'cause': 'timeout', 'bytes': 123}),
            event('decoder')..addAll({
              'decoder': 'OMX.hisi.video.decoder.avc',
              'codec': 'avc1.64001F',
            }),
            event('summary')..addAll({
              'rebuffer_count': 2,
              'rebuffer_ms': 4000,
              'dropped_frames': 3,
            }),
          ];
        }
        return null;
      });
      final diagnostics = service();
      final copied = await diagnostics.buildCopyText();
      expect(reads, 1);
      expect(copied, contains('first_frame_ms: 321'));
      expect(copied, contains('track: audio'));
      expect(copied, contains('decoder: OMX.hisi.video.decoder.avc'));
      expect(copied, contains('rebuffer_ms: 4000'));
      expect((await SharedPreferences.getInstance()).getKeys(), isEmpty);
    },
  );

  test(
    'platform boundary rejects secrets, invalid types, unsafe codec strings and unbounded events',
    () {
      final secret = event('load_error')
        ..addAll({
          'Cookie': 'secret',
          'url': 'https://private.invalid/v?sign=secret',
          'subtitle': 'private body',
          'message': 'secret',
          'cause': 'secret',
          'decoder': 'OMX.secret?Cookie=secret',
          'codec': 'avc1.secret&sig=secret',
          'bytes': -1,
          'fps': double.infinity,
          'speed': double.nan,
          'http_status': '403',
        });
      final parsed = MediaRuntimeDiagnostic.parse([secret]);
      expect(parsed.single.fields.keys.toSet(), {
        'event',
        'session_id',
        'attempt',
        'elapsed_ms',
        'track',
      });
      expect(parsed.toString(), isNot(contains('secret')));
      expect(
        MediaRuntimeDiagnostic.parse(
          List.generate(1000, (_) => event('state')),
        ),
        hasLength(64),
      );
      expect(
        MediaRuntimeDiagnostic.parse([
          null,
          'secret',
          {'event': 'secret'},
          {'event': 'state'},
        ]),
        isEmpty,
      );
    },
  );

  test(
    'unavailable backend does not prevent existing diagnostics export',
    () async {
      final diagnostics = service(
        loader: () async => throw MissingPluginException(),
      );
      expect((await diagnostics.loadSnapshot()).mediaRuntime, isEmpty);
      expect(await diagnostics.buildCopyText(), contains('暂无记录或此平台不支持'));
    },
  );

  test('clear action also clears native memory', () async {
    var cleared = false;
    final diagnostics = service(
      loader: () async => [],
      clearer: () async => cleared = true,
    );
    await diagnostics.clearRecentErrors();
    expect(cleared, isTrue);
  });
}
