import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/models/player_overlay_data.dart';
import 'package:focubili/services/subtitle_export_service.dart';

void main() {
  const cues = [
    SubtitleCue(
      from: Duration(hours: 1, milliseconds: 25),
      to: Duration(hours: 1, seconds: 2),
      content: '第二行\r\n换行',
    ),
    SubtitleCue(
      from: Duration(milliseconds: 1250),
      to: Duration(milliseconds: 2750),
      content: '已有中文字幕',
    ),
  ];
  test('SRT keeps millisecond timing and chronological order', () {
    final package = const SubtitleExportService().buildPackage(
      cues: cues,
      format: SubtitleExportFormat.srt,
    );
    expect(package.extension, 'srt');
    expect(package.cueCount, 2);
    expect(
      utf8.decode(package.bytes),
      '1\n00:00:01,250 --> 00:00:02,750\n已有中文字幕\n\n2\n01:00:00,025 --> 01:00:02,000\n第二行\n换行\n\n',
    );
  });
  test('text export includes source labels and both timeline endpoints', () {
    final package = const SubtitleExportService().buildPackage(
      cues: cues,
      format: SubtitleExportFormat.text,
      videoLabel: 'P2 · 测试视频',
      trackLabel: '中文',
    );
    final text = utf8.decode(package.bytes);
    expect(package.extension, 'txt');
    expect(text, contains('P2 · 测试视频'));
    expect(text, contains('字幕：中文'));
    expect(text, contains('[00:00:01.250 – 00:00:02.750]'));
  });
  test(
    'empty or invalid supplied cues never create synthetic subtitle content',
    () {
      for (final input in [
        <SubtitleCue>[],
        [
          const SubtitleCue(
            from: Duration(seconds: 2),
            to: Duration(seconds: 1),
            content: 'invalid',
          ),
        ],
      ]) {
        expect(
          () => const SubtitleExportService().buildPackage(
            cues: input,
            format: SubtitleExportFormat.srt,
          ),
          throwsArgumentError,
        );
      }
    },
  );
}
