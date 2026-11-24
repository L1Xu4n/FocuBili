import 'dart:async';

import 'package:flutter/material.dart';
import '../../../models/video_preview.dart';
import '../../../services/bilibili_service.dart';
import '../../../services/video_tag_preferences.dart';

/// Scope is the open PlayerPage, not a scroll child or the preference store.
class PlayerTagSession extends ChangeNotifier {
  BilibiliVideoTagSource? source;
  VideoPreview? _video;
  VideoTagMode? mode;
  bool expanded = false,
      busy = false,
      failed = false,
      _fetched = false,
      _closed = false;
  bool _sourceOnline = false;
  List<String> tags = const [];
  int _rev = 0, _pref = 0;

  void initialize(BilibiliService service) {
    source = service is BilibiliVideoTagSource
        ? service as BilibiliVideoTagSource
        : null;
    VideoTagPreferences.changes.addListener(_preference);
    _preference();
  }

  /// 只应用最近一次读取的标签显示偏好。
  Future<void> _preference() async {
    final revision = ++_pref;
    final next = await VideoTagPreferences.load();
    if (_closed || revision != _pref || mode == next) return;
    mode = next;
    _resetPresentation();
  }

  /// 当前稿件和实际播放源都允许时才请求在线标签。
  bool get _online =>
      _video != null && !_video!.isCourse && _sourceOnline && source != null;
  bool get visible =>
      mode != null &&
      mode != VideoTagMode.hidden &&
      _video?.isCourse == false &&
      (tags.isNotEmpty || _online);

  /// 新稿件使用自己的标签，播放器可等实际来源确认后再允许联网。
  void bind(VideoPreview video, {bool? online}) {
    final changed = _video?.bvid != video.bvid;
    _video = video;
    if (changed) {
      _sourceOnline = online ?? !video.fromOfflineCache;
      tags = video.tags;
      _fetched = tags.isNotEmpty;
      _resetPresentation();
    } else if (online != null) {
      setOnline(online);
    }
  }

  /// 切本地时丢弃在途结果，恢复在线后继续已展开且未完成的加载。
  void setOnline(bool online) {
    if (_sourceOnline == online) return;
    _sourceOnline = online;
    _rev++;
    busy = false;
    failed = false;
    if (expanded && visible) unawaited(_load());
    notifyListeners();
  }

  /// 根据偏好重置展开状态并撤销旧请求，保留当前稿件已读取的标签。
  void _resetPresentation() {
    _rev++;
    expanded = mode == VideoTagMode.expanded;
    busy = false;
    failed = false;
    if (visible && expanded) unawaited(_load());
    notifyListeners();
  }

  Future<void> reveal() async {
    if (!visible) return;
    expanded = true;
    notifyListeners();
    await _load();
  }

  Future<void> _load() async {
    if (!_online || !visible || _fetched || busy) return;
    final revision = _rev;
    busy = true;
    failed = false;
    notifyListeners();
    try {
      final values = await source!.loadVideoTags(_video!.bvid);
      if (_closed || revision != _rev) return;
      tags = values;
      _fetched = true;
    } catch (_) {
      if (_closed || revision != _rev) return;
      failed = true;
    } finally {
      if (!_closed && revision == _rev) {
        busy = false;
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _closed = true;
    VideoTagPreferences.changes.removeListener(_preference);
    super.dispose();
  }
}

class PlayerVideoTags extends StatelessWidget {
  const PlayerVideoTags({super.key, required this.session});
  final PlayerTagSession session;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: session,
    builder: (context, _) {
      if (!session.visible) return const SizedBox.shrink();
      final theme = Theme.of(context);
      final Widget child;
      if (!session.expanded) {
        child = Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton(
            key: const Key('reveal-video-tags'),
            onPressed: session.reveal,
            style: TextButton.styleFrom(
              foregroundColor: theme.colorScheme.onSurfaceVariant,
              backgroundColor: Colors.transparent,
              minimumSize: const Size(48, 48),
              visualDensity: VisualDensity.standard,
              padding: const EdgeInsetsDirectional.only(end: 8),
              textStyle: theme.textTheme.labelMedium,
            ).copyWith(side: const WidgetStatePropertyAll(BorderSide.none)),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(child: Text('展开标签')),
                SizedBox(width: 2),
                Icon(Icons.keyboard_arrow_down_rounded, size: 16),
              ],
            ),
          ),
        );
      } else if (session.busy) {
        child = Semantics(liveRegion: true, child: const Text('正在读取视频标签…'));
      } else if (session.failed) {
        child = Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton.icon(
            onPressed: session.reveal,
            icon: const Icon(Icons.refresh),
            label: const Text('标签读取失败，重试'),
          ),
        );
      } else if (session.tags.isEmpty) {
        child = Text('暂无视频标签', style: theme.textTheme.bodySmall);
      } else {
        child = Wrap(
          key: const Key('video-tags'),
          spacing: 8,
          runSpacing: 6,
          children: [
            for (final tag in session.tags)
              Chip(visualDensity: VisualDensity.compact, label: Text(tag)),
          ],
        );
      }
      return Padding(
        padding: EdgeInsets.only(top: session.expanded ? 12 : 4),
        child: child,
      );
    },
  );
}
