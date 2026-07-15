import 'package:flutter/material.dart';

import '../../models/watch_history_entry.dart';

/// 在视频封面上显示本机最近看过的标记和可选播放位置。
class WatchHistoryBadge extends StatelessWidget {
  /// 创建紧凑的“上次看过”封面标记；传入位置后同时显示进度时间。
  const WatchHistoryBadge({
    super.key,
    required this.entry,
    this.showPosition = true,
  });

  final WatchHistoryEntry entry;
  final bool showPosition;

  /// 组合历史文字，并使用深色半透明背景保证各种封面上都能看清。
  @override
  Widget build(BuildContext context) {
    final String position = _formatPosition(entry.lastPosition);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black87,
        borderRadius: BorderRadius.circular(5),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        child: Text(
          showPosition && position.isNotEmpty ? '上次看过 $position' : '上次看过',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 10,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  /// 将最近播放位置格式化为分秒或时分秒，零秒时不显示无意义的 0:00。
  String _formatPosition(Duration value) {
    final int seconds = value.inSeconds;
    if (seconds <= 0) {
      return '';
    }
    final int hours = seconds ~/ 3600;
    final int minutes = (seconds % 3600) ~/ 60;
    final int rest = seconds % 60;
    return hours > 0
        ? '$hours:${minutes.toString().padLeft(2, '0')}:${rest.toString().padLeft(2, '0')}'
        : '$minutes:${rest.toString().padLeft(2, '0')}';
  }
}
