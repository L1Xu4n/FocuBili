import 'dart:async';
import 'package:flutter/foundation.dart';

/// 一条短提示及可选操作，独立于播放控制栏的布局。
class PlayerNoticeEntry {
  /// 保存显示文字和用户明确点击后执行的操作。
  const PlayerNoticeEntry(this.message, {this.actionLabel, this.onAction});
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;
}

/// 管理独立到期的短提示，相同文字只刷新时间，不覆盖其他提示。
class PlayerNoticeController extends ChangeNotifier {
  final Map<String, Timer> _timers = {};
  final Map<String, PlayerNoticeEntry> _entries = {};

  /// 按首次出现的顺序提供当前提示，调用者不能修改内部集合。
  List<String> get messages => List.unmodifiable(_timers.keys);

  /// 提供有序内容和操作信息，保证外部不能改动内部状态。
  List<PlayerNoticeEntry> get entries => List.unmodifiable(_entries.values);

  /// 显示或续期一条提示，到期时只移除这一条。
  void show(
    String message, {
    Duration duration = const Duration(seconds: 3),
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    final text = message.trim();
    if (text.isEmpty) return;
    _timers[text]?.cancel();
    _entries[text] = PlayerNoticeEntry(
      text,
      actionLabel: actionLabel,
      onAction: onAction,
    );
    _timers[text] = Timer(duration, () {
      _timers.remove(text);
      _entries.remove(text);
      notifyListeners();
    });
    notifyListeners();
  }

  /// 取消所有提示及计时器，供明确重置和页面退出使用。
  void clear() {
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
    _entries.clear();
    notifyListeners();
  }

  /// 页面销毁后取消计时，避免迟到的提示刷新。
  @override
  void dispose() {
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
    _entries.clear();
    super.dispose();
  }
}
