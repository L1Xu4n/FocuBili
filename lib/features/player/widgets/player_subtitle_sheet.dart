import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../models/playback_preferences.dart';
import '../../../models/player_overlay_data.dart';
import '../../../core/theme/app_text_scale.dart';
import '../../../services/local_export_service.dart';
import '../../../services/subtitle_export_service.dart';

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
    this.diagnosticReport,
    this.selectedTrackId,
    this.loadCues,
    this.onSeek,
    this.exportService = const LocalExportService(),
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
  final Future<SubtitleCueLoadResult> Function(SubtitleTrack)? loadCues;
  final Future<void> Function(Duration)? onSeek;
  final LocalExportService exportService;
  final String Function()? diagnosticReport;

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
  final _searchController = TextEditingController();
  SubtitleTrack? _browsingTrack;
  SubtitleCueLoadResult? _cueResult;
  bool _cuesLoading = false;
  bool _exporting = false;
  int _cueRevision = 0;
  String _query = '';

  @override
  void dispose() {
    _cueRevision++;
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _browseTrack(SubtitleTrack track) async {
    if (track.isLocked || widget.loadCues == null || !widget.isCurrentVideo()) {
      return;
    }
    final revision = ++_cueRevision;
    setState(() {
      _browsingTrack = track;
      _cueResult = null;
      _cuesLoading = true;
      _query = '';
      _searchController.clear();
    });
    SubtitleCueLoadResult result;
    try {
      result = await widget.loadCues!(track);
    } catch (_) {
      result = const SubtitleCueLoadResult.unavailable();
    }
    if (!mounted || revision != _cueRevision) return;
    if (result.status == SubtitleLoadStatus.available) {
      final ordered = result.cues.indexed.toList()
        ..sort((a, b) {
          final time = a.$2.from.compareTo(b.$2.from);
          return time == 0 ? a.$1.compareTo(b.$1) : time;
        });
      result = SubtitleCueLoadResult(
        status: result.status,
        message: result.message,
        cues: List<SubtitleCue>.unmodifiable(ordered.map((entry) => entry.$2)),
      );
    }
    setState(() {
      _cuesLoading = false;
      _cueResult = widget.isCurrentVideo()
          ? result
          : const SubtitleCueLoadResult.unavailable(
              message: '视频已切换，请重新打开字幕设置。',
            );
    });
  }

  Future<void> _seekToCue(SubtitleCue cue) async {
    if (!widget.isCurrentVideo() || widget.onSeek == null) return;
    try {
      await widget.onSeek!(cue.from);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('暂时无法跳转到此字幕。')));
      }
    }
  }

  Future<void> _exportCues(SubtitleExportFormat format) async {
    final result = _cueResult;
    if (_exporting ||
        !widget.isCurrentVideo() ||
        result?.status != SubtitleLoadStatus.available ||
        result!.cues.isEmpty) {
      return;
    }
    setState(() => _exporting = true);
    try {
      final package = const SubtitleExportService().buildPackage(
        cues: result.cues,
        format: format,
        videoLabel: widget.videoLabel,
        trackLabel: _browsingTrack?.label ?? '',
      );
      final path = await widget.exportService.save(
        fileName: package.fileName,
        bytes: package.bytes,
        dialogTitle: '保存已有字幕',
      );
      if (mounted && path != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已导出 ${package.cueCount} 条字幕（完整时间轴）。')),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              error is LocalExportException ? error.message : '字幕文件生成失败，请稍后重试。',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Widget _buildCueBrowser() {
    final result = widget.isCurrentVideo()
        ? _cueResult
        : const SubtitleCueLoadResult.unavailable(message: '视频已切换，请重新打开字幕设置。');
    final cues = result?.status == SubtitleLoadStatus.available
        ? result!.cues
        : const <SubtitleCue>[];
    final visible = cues
        .where(
          (cue) =>
              _query.isEmpty ||
              cue.content.toLowerCase().contains(_query.toLowerCase()),
        )
        .toList();
    return SizedBox(
      height:
          (MediaQuery.sizeOf(context).height -
                  MediaQuery.viewInsetsOf(context).bottom)
              .clamp(0.0, double.infinity) *
          .58,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              key: const Key('subtitle-search'),
              controller: _searchController,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search_rounded),
                hintText: '搜索已有字幕',
              ),
              onChanged: (value) => setState(() => _query = value.trim()),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 16, right: 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '${_browsingTrack!.label} · ${visible.length}/${cues.length} 条',
                  ),
                ),
                PopupMenuButton<SubtitleExportFormat>(
                  key: const Key('export-subtitle-timeline'),
                  tooltip: '导出完整字幕时间轴',
                  enabled:
                      !_exporting &&
                      !_cuesLoading &&
                      cues.isNotEmpty &&
                      widget.isCurrentVideo(),
                  onSelected: _exportCues,
                  itemBuilder: (context) => const [
                    PopupMenuItem(
                      value: SubtitleExportFormat.srt,
                      child: Text('导出 SRT'),
                    ),
                    PopupMenuItem(
                      value: SubtitleExportFormat.text,
                      child: Text('导出文本（含时间轴）'),
                    ),
                  ],
                  icon: _exporting
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.download_rounded),
                ),
              ],
            ),
          ),
          if (_cuesLoading) const LinearProgressIndicator(),
          Expanded(
            child: _cuesLoading
                ? const SizedBox.shrink()
                : cues.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(result?.message ?? '暂无可用字幕。'),
                          TextButton(
                            onPressed: () => _browseTrack(_browsingTrack!),
                            child: const Text('重试'),
                          ),
                        ],
                      ),
                    ),
                  )
                : visible.isEmpty
                ? const Center(child: Text('没有匹配的字幕'))
                : ListView.builder(
                    key: const Key('subtitle-cue-list'),
                    itemCount: visible.length,
                    itemBuilder: (context, index) {
                      final cue = visible[index];
                      return ListTile(
                        key: ValueKey('subtitle-cue-$index'),
                        title: Text(cue.content),
                        subtitle: Text(
                          '${formatSubtitleTimestamp(cue.from)} – ${formatSubtitleTimestamp(cue.to)}',
                        ),
                        leading: const Icon(Icons.play_arrow_rounded),
                        onTap: widget.onSeek == null || !widget.isCurrentVideo()
                            ? null
                            : () => _seekToCue(cue),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildDiagnostics() => ExpansionTile(
    title: const Text('字幕来源诊断'),
    subtitle: const Text('仅标识与哈希，不含正文或登录信息'),
    children: [
      Padding(
        padding: const EdgeInsets.all(16),
        child: SelectableText(
          widget.diagnosticReport!(),
          style: const TextStyle(fontSize: 11),
        ),
      ),
      TextButton.icon(
        key: const Key('copy-subtitle-diagnostics'),
        icon: const Icon(Icons.copy_rounded),
        label: const Text('复制字幕诊断'),
        onPressed: () =>
            Clipboard.setData(ClipboardData(text: widget.diagnosticReport!())),
      ),
    ],
  );

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
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight:
                (MediaQuery.sizeOf(context).height -
                        MediaQuery.viewInsetsOf(context).bottom)
                    .clamp(0.0, double.infinity) *
                .8,
          ),
          child: Column(
            key: const Key('subtitle-settings-sheet'),
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.only(left: 16, right: 4),
                child: Row(
                  children: [
                    if (_browsingTrack != null)
                      IconButton(
                        key: const Key('back-to-subtitle-tracks'),
                        tooltip: '返回字幕轨道',
                        onPressed: () => setState(() {
                          _cueRevision++;
                          _browsingTrack = null;
                          _cueResult = null;
                          _cuesLoading = false;
                        }),
                        icon: const Icon(Icons.arrow_back_rounded),
                      ),
                    Expanded(
                      child: Text(
                        _browsingTrack == null ? '字幕' : '字幕列表',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    IconButton(
                      key: const Key('refresh-subtitle-tracks'),
                      tooltip: '刷新字幕列表',
                      onPressed: _loading || _cuesLoading
                          ? null
                          : _browsingTrack == null
                          ? _refresh
                          : () => _browseTrack(_browsingTrack!),
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
                child: _browsingTrack != null
                    ? _buildCueBrowser()
                    : SingleChildScrollView(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                              ),
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
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                              ),
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
                                textScaler: AppTextScaleScope.subtitleScalerOf(
                                  context,
                                ),
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
                                    result.status !=
                                        SubtitleLoadStatus.available))
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
                            if (widget.diagnosticReport != null)
                              _buildDiagnostics(),
                            for (final track
                                in result?.tracks ?? const <SubtitleTrack>[])
                              ListTile(
                                enabled: !track.isLocked,
                                leading: Icon(
                                  track.isLocked
                                      ? Icons.lock_outline_rounded
                                      : Icons.subtitles_rounded,
                                ),
                                title: Wrap(
                                  spacing: 8,
                                  runSpacing: 4,
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  children: [
                                    Text(track.label),
                                    if (track.isAi)
                                      Semantics(
                                        label: 'AI 自动字幕',
                                        excludeSemantics: true,
                                        child: Container(
                                          key: ValueKey(
                                            'subtitle-ai-${track.id}',
                                          ),
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 6,
                                            vertical: 2,
                                          ),
                                          decoration: BoxDecoration(
                                            color: Theme.of(
                                              context,
                                            ).colorScheme.secondaryContainer,
                                            borderRadius: BorderRadius.circular(
                                              5,
                                            ),
                                          ),
                                          child: Text(
                                            'AI',
                                            style: TextStyle(
                                              fontSize: 11,
                                              fontWeight: FontWeight.w600,
                                              color: Theme.of(context)
                                                  .colorScheme
                                                  .onSecondaryContainer,
                                            ),
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                                subtitle: track.language.isEmpty
                                    ? null
                                    : Text(track.language),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (widget.selectedTrackId == track.id)
                                      const Icon(Icons.check_rounded),
                                    if (widget.loadCues != null &&
                                        !track.isLocked)
                                      IconButton(
                                        key: ValueKey(
                                          'browse-subtitle-${track.id}',
                                        ),
                                        tooltip: '查看字幕列表',
                                        onPressed: () => _browseTrack(track),
                                        icon: const Icon(
                                          Icons.list_alt_rounded,
                                        ),
                                      ),
                                  ],
                                ),
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
      ),
    );
  }
}
