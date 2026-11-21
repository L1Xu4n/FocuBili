import 'dart:convert';
import 'dart:typed_data';

import '../models/player_overlay_data.dart';

enum SubtitleExportFormat { srt, text }

class SubtitleExportPackage {
  const SubtitleExportPackage({
    required this.fileName,
    required this.bytes,
    required this.cueCount,
  });
  final String fileName;
  final Uint8List bytes;
  final int cueCount;
  String get extension => fileName.split('.').last;
}

/// 只导出调用方已从 B 站读取的条目，不翻译、不转写、不补造字幕。
class SubtitleExportService {
  const SubtitleExportService();

  SubtitleExportPackage buildPackage({
    required List<SubtitleCue> cues,
    required SubtitleExportFormat format,
    String videoLabel = '',
    String trackLabel = '',
  }) {
    final indexed =
        cues.indexed
            .where(
              (item) =>
                  item.$2.from >= Duration.zero &&
                  item.$2.to > item.$2.from &&
                  item.$2.content.trim().isNotEmpty,
            )
            .toList()
          ..sort((a, b) {
            final comparison = a.$2.from.compareTo(b.$2.from);
            return comparison == 0 ? a.$1.compareTo(b.$1) : comparison;
          });
    if (indexed.isEmpty) throw ArgumentError('没有可导出的已有字幕。');
    final buffer = StringBuffer();
    if (format == SubtitleExportFormat.text) {
      if (videoLabel.isNotEmpty) buffer.writeln(videoLabel);
      if (trackLabel.isNotEmpty) buffer.writeln('字幕：$trackLabel');
      buffer.writeln();
    }
    for (int index = 0; index < indexed.length; index++) {
      final cue = indexed[index].$2;
      final text = cue.content
          .replaceAll('\r\n', '\n')
          .replaceAll('\r', '\n')
          .trim();
      if (format == SubtitleExportFormat.srt) {
        buffer
          ..writeln(index + 1)
          ..writeln(
            '${formatSubtitleTimestamp(cue.from, srt: true)} --> ${formatSubtitleTimestamp(cue.to, srt: true)}',
          )
          // 空行会结束一个 SRT 条目，压成单次换行以保留同一条的文本。
          ..writeln(text.replaceAll(RegExp(r'\n\s*\n'), '\n'))
          ..writeln();
      } else {
        buffer
          ..writeln(
            '[${formatSubtitleTimestamp(cue.from)} – ${formatSubtitleTimestamp(cue.to)}]',
          )
          ..writeln(text)
          ..writeln();
      }
    }
    final extension = format == SubtitleExportFormat.srt ? 'srt' : 'txt';
    return SubtitleExportPackage(
      fileName: 'focubili_subtitles.$extension',
      bytes: Uint8List.fromList(utf8.encode(buffer.toString())),
      cueCount: indexed.length,
    );
  }
}

String formatSubtitleTimestamp(Duration time, {bool srt = false}) {
  final milliseconds = time.inMilliseconds.clamp(0, 172800000);
  final hours = (milliseconds ~/ 3600000).toString().padLeft(2, '0');
  final minutes = (milliseconds ~/ 60000 % 60).toString().padLeft(2, '0');
  final seconds = (milliseconds ~/ 1000 % 60).toString().padLeft(2, '0');
  final fraction = (milliseconds % 1000).toString().padLeft(3, '0');
  return '$hours:$minutes:$seconds${srt ? ',' : '.'}$fraction';
}
