import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/models/ab_repeat_range.dart';
import 'package:focubili/services/native_playback_service.dart';

void main() {
  test(
    'backend play intent preserves false independently of isPlaying and accepts old null snapshots',
    () {
      final paused = PlaybackSnapshot.fromPlatformMap({
        'isPlaying': false,
        'playRequested': false,
      });
      expect(paused.playRequested, isFalse);
      expect(
        paused.copyWith(position: const Duration(seconds: 10)).playRequested,
        isFalse,
      );
      expect(paused.copyWith(playRequested: true).playRequested, isTrue);
      expect(
        PlaybackSnapshot.fromPlatformMap({
          'isPlaying': false,
          'playRequested': true,
        }).playRequested,
        isTrue,
      );
      expect(
        PlaybackSnapshot.fromPlatformMap({'isPlaying': false}).playRequested,
        isNull,
      );
      expect(
        PlaybackSnapshot.fromPlatformMap({
          'playRequested': 'false',
        }).playRequested,
        isNull,
      );
    },
  );
  test(
    'parses and formats second/minute/hour points without ambiguous clocks',
    () {
      for (final entry in {
        '1.250': 1250,
        '01:23.500': 83500,
        '1:02:03': 3723000,
        '120:00': 7200000,
      }.entries) {
        expect(parseAbRepeatTime(entry.key)?.inMilliseconds, entry.value);
        expect(
          parseAbRepeatTime(
            formatAbRepeatTime(Duration(milliseconds: entry.value)),
          )?.inMilliseconds,
          entry.value,
        );
      }
      for (final value in [
        '-1',
        'NaN',
        '1:60',
        '1:60:00',
        '1:00:60',
        '00:01.0001',
        '1:2:3:4',
        '',
        '604801',
        '999999999999999999999999:00:00',
      ]) {
        expect(parseAbRepeatTime(value), isNull, reason: value);
      }
    },
  );
  test('requires a positive chapter-local range of at least one second', () {
    AbRepeatRange range(int a, int b) => AbRepeatRange(
      bvid: 'cheese:ss1',
      cid: 9,
      a: Duration(milliseconds: a),
      b: Duration(milliseconds: b),
    );
    for (final points in [
      (-1, 2000),
      (2000, 1000),
      (1000, 1000),
      (1000, 1999),
      (1000, 3001),
    ]) {
      expect(
        range(points.$1, points.$2).validate(const Duration(seconds: 3)),
        isNotNull,
      );
    }
    final valid = range(1000, 3000);
    expect(valid.validate(const Duration(seconds: 3)), isNull);
    expect(valid.validate(Duration.zero), isNotNull);
    expect(valid.contains(const Duration(seconds: 1)), isTrue);
    expect(valid.contains(const Duration(seconds: 3)), isFalse);
    expect(valid.matches('cheese:ss1', 9), isTrue);
    expect(valid.matches('cheese:ss1', 10), isFalse);
    expect(valid.matches('BV1GJ411x7h7', 9), isFalse);
  });
}
