import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/services/native_playback_service.dart';
import 'package:focubili/features/player/widgets/player_timeline.dart';

void main() {
  test('mpv ranges preserve seek gaps, clamp bounds and merge overlaps', () {
    final ranges = playbackBufferRangesFromMpv(
      '{"seekable-ranges":[{"start":80,"end":120},{"start":-1,"end":5},{"start":3,"end":10},{"start":42,"end":41}]}',
      duration: const Duration(seconds: 100),
    );
    expect(ranges.map((r) => [r.start.inSeconds, r.end.inSeconds]), [
      [0, 10],
      [80, 100],
    ]);
    final rects = playbackBufferRects(
      ranges,
      const Duration(seconds: 100),
      const Rect.fromLTWH(8, 0, 100, 2),
      TextDirection.ltr,
    );
    expect(rects, [
      const Rect.fromLTWH(8, 0, 10, 2),
      const Rect.fromLTWH(88, 0, 20, 2),
    ]);
    expect(
      playbackBufferRects(
        ranges,
        const Duration(seconds: 100),
        const Rect.fromLTWH(8, 0, 100, 2),
        TextDirection.rtl,
      ).last.left,
      closeTo(8, .001),
    );
  });
  test(
    'missing or malformed native buffering never fabricates a cached prefix',
    () {
      for (final value in [
        '',
        'null',
        '{"seekable-ranges":null}',
        '{"seekable-ranges":[{"start":"5","end":9}]}',
      ]) {
        expect(
          playbackBufferRangesFromMpv(
            value,
            duration: const Duration(minutes: 10),
          ),
          isEmpty,
        );
      }
      final snapshot = PlaybackSnapshot.fromPlatformMap({
        'durationMs': 100000,
        'positionMs': 60000,
        'bufferedRanges': [
          {'startMs': 60000, 'endMs': 70000},
        ],
      });
      expect(snapshot.bufferedRanges.single.start, const Duration(seconds: 60));
      expect(
        snapshot.copyWith(isPlaying: true).bufferedRanges.single.end,
        const Duration(seconds: 70),
      );
      expect(
        PlaybackSnapshot.fromPlatformMap({'durationMs': 100000}).bufferedRanges,
        isEmpty,
      );
    },
  );
}
