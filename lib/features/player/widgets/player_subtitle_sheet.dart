import 'dart:async';

import 'package:flutter/material.dart';

import '../../../models/playback_preferences.dart';
import '../../../models/player_overlay_data.dart';

/// 在同一个面板选择字幕、刷新失败请求与预览字号，不把网络失败藏在短提示里。
class PlayerSubtitleSheet extends StatefulWidget {
  /// 只接收当前视频的安全轨道描述及回调，不持有字幕地址或账号资料。
  const PlayerSubtitleSheet({
    super.key,
    required this.videoLabel,
    required this.offValue,
    required this.fontSize,
    required this.isCurrentVideo,
    required this.reloadTracks,
    required this.onPreviewFontSize,
    required this.onCommitFontSize,
    this.initialResult,
    this.selectedTrackId,
  });

  final String videoLabel;
  final String offValue;
  final double fontSize;
  final String? selectedTrackId;
  final SubtitleTrackLoadResult? initialResult;
  final bool Function() isCurrentVideo;
  final Future<SubtitleTrackLoadResult> Function() reloadTracks;
  final ValueChanged<double> onPreviewFontSize;
  final Future<double> Function(double) onCommitFontSize;

  /// 创建管理面板读取状态和实时字号预览的状态对象。
  @override
  State<PlayerSubtitleSheet> createState() => _PlayerSubtitleSheetState();
}

class _PlayerSubtitleSheetState extends State<PlayerSubtitleSheet> {
  SubtitleTrackLoadResult? _result;
  late double _fontSize;
  bool _loading = false;
  String? _warning;
  int _fontRevision = 0;

  /// 优先显示当前分 P 已成功获取的列表，没有有效缓存时才开始读取。
  @override
  void initState() {
    super.initState();
    _fontSize = PlaybackPreferences.normalizeSubtitleFontSize(widget.fontSize);
    _result = widget.initialResult;
    if (_result == null) unawaited(_refresh());
  }

  /// 刷新失败保留当前视频已读取的轨道；视频身份变化时立即撤下旧列表。
  Future<void> _refresh() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _warning = null;
    });
    SubtitleTrackLoadResult next;
    try {
      next = await widget.reloadTracks();
    } catch (_) {
      next = const SubtitleTrackLoadResult.unavailable();
    }
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (!widget.isCurrentVideo()) {
        _result = const SubtitleTrackLoadResult.unavailable(
          message: '视频已切换，请重新打开字幕设置。',
        );
      } else if (next.status == SubtitleLoadStatus.unavailable &&
          _result?.status == SubtitleLoadStatus.available) {
        _warning = '刷新未成功，仍保留已读取的字幕。可稍后重试。';
      } else {
        _result = next;
      }
    });
  }

  /// 每次滑动立即预览，保存仅在松手时执行，避免逐帧写入存储。
  void _previewFontSize(double value) {
    final size = PlaybackPreferences.normalizeSubtitleFontSize(value);
    setState(() {
      _fontSize = size;
      _fontRevision++;
    });
    widget.onPreviewFontSize(size);
  }

  /// 保存完成后同步最终字号，迟到的旧保存不能覆盖新的拖动预览。
  Future<void> _commitFontSize(double value) async {
    final revision = _fontRevision;
    final saved = await widget.onCommitFontSize(value);
    if (mounted && revision == _fontRevision) {
      setState(() => _fontSize = saved);
    }
  }

  /// 恢复原有的 16 号字幕并立即保存。
  void _resetFontSize() {
    _previewFontSize(PlaybackPreferences.defaultSubtitleFontSize);
    unawaited(_commitFontSize(_fontSize));
  }

  /// 只提交仍属于当前视频的选择，防止旧面板操作影响后来打开的视频。
  void _chooseTrack(String id) {
    if (!widget.isCurrentVideo()) {
      setState(() {
        _warning = null;
        _result = const SubtitleTrackLoadResult.unavailable(
          message: '视频已切换，请重新打开字幕设置。',
        );
      });
      return;
    }
    Navigator.of(context).pop(id);
  }

  /// 固定标题、刷新与关闭入口，字号预览和长语言列表在受限区域内滚动。
  @override
  Widget build(BuildContext context) {
    final result = _result;
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * .8,
        ),
        child: Column(
          key: const Key('subtitle-settings-sheet'),
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 16, right: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '字幕',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    key: const Key('refresh-subtitle-tracks'),
                    tooltip: '刷新字幕列表',
                    onPressed: _loading ? null : _refresh,
                    icon: const Icon(Icons.refresh_rounded),
                  ),
                  IconButton(
                    tooltip: '关闭字幕设置',
                    // 关闭面板不改变已选中的字幕或播放器状态。
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          widget.videoLabel,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Row(
                        children: [
                          const Expanded(child: Text('字幕字号')),
                          Text(
                            '${_fontSize.round()}',
                            key: const Key('subtitle-font-size-value'),
                          ),
                          TextButton(
                            onPressed: _resetFontSize,
                            child: const Text('默认'),
                          ),
                        ],
                      ),
                    ),
                    Slider(
                      key: const Key('subtitle-font-size-slider'),
                      value: _fontSize,
                      min: PlaybackPreferences.minSubtitleFontSize,
                      max: PlaybackPreferences.maxSubtitleFontSize,
                      divisions: 24,
                      label: '${_fontSize.round()}',
                      onChanged: _previewFontSize,
                      onChangeEnd: _commitFontSize,
                    ),
                    Container(
                      margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      width: double.infinity,
                      decoration: BoxDecoration(
                        color: Colors.black87,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        '这是字幕预览',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: _fontSize,
                          height: 1.28,
                        ),
                      ),
                    ),
                    if (_loading) const LinearProgressIndicator(),
                    if (_warning != null ||
                        (result != null &&
                            result.status != SubtitleLoadStatus.available))
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        child: Text(_warning ?? result!.message),
                      ),
                    ListTile(
                      leading: const Icon(Icons.subtitles_off_rounded),
                      title: const Text('关闭字幕'),
                      trailing: widget.selectedTrackId == null
                          ? const Icon(Icons.check_rounded)
                          : null,
                      // 关闭只撤销当前视频的字幕显示。
                      onTap: () => _chooseTrack(widget.offValue),
                    ),
                    for (final track
                        in result?.tracks ?? const <SubtitleTrack>[])
                      ListTile(
                        enabled: !track.isLocked,
                        leading: Icon(
                          track.isLocked
                              ? Icons.lock_outline_rounded
                              : Icons.subtitles_rounded,
                        ),
                        title: Text(track.label),
                        subtitle: track.language.isEmpty
                            ? null
                            : Text(track.language),
                        trailing: widget.selectedTrackId == track.id
                            ? const Icon(Icons.check_rounded)
                            : null,
                        // 将稳定轨道编号交回播放器，地址和读取流程仍由服务掌管。
                        onTap: track.isLocked
                            ? null
                            : () => _chooseTrack(track.id),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
