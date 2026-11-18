import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../models/playback_preferences.dart';
import '../../../models/player_overlay_data.dart';
import '../../../services/local_export_service.dart';
import '../../../services/subtitle_export_service.dart';
import 'player_subtitle_caption.dart';

/// 在播放器内选择字幕、浏览正文和调整字幕外观。
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
    this.position = PlaybackPreferences.defaultSubtitlePosition,
    this.opacity = PlaybackPreferences.defaultSubtitleOpacity,
    this.onPreviewPosition,
    this.onPositionChanged,
    this.onPreviewOpacity,
    this.onOpacityChanged,
    this.diagnosticReport,
    this.selectedTrackId,
    this.loadCues,
    this.onSeek,
    this.exportService = const LocalExportService(),
  });

  final String videoLabel;
  final String offValue;
  final double fontSize;
  final double position;
  final double opacity;
  final ValueChanged<double>? onPreviewPosition;
  final Future<double> Function(double)? onPositionChanged;
  final ValueChanged<double>? onPreviewOpacity;
  final Future<double> Function(double)? onOpacityChanged;
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

  @override
  State<PlayerSubtitleSheet> createState() => _PlayerSubtitleSheetState();
}

class _PlayerSubtitleSheetState extends State<PlayerSubtitleSheet> {
  SubtitleTrackLoadResult? _result;
  late PlaybackPreferences _appearance;
  bool _appearanceOpen = false;
  bool _loading = false;
  String? _warning;
  final _appearanceRevisions = <SubtitleAppearanceSetting, int>{};
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
    final changedTrack = _browsingTrack?.id != track.id;
    setState(() {
      _browsingTrack = track;
      _cueResult = null;
      _cuesLoading = true;
      if (changedTrack) {
        _query = '';
        _searchController.clear();
      }
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
    final needle = _query.toLowerCase();
    final visible = needle.isEmpty
        ? cues
        : cues
              .where((cue) => cue.content.toLowerCase().contains(needle))
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
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search_rounded),
                hintText: '搜索已有字幕',
                suffixIcon: _searchController.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: '清除字幕搜索',
                        icon: const Icon(Icons.clear_rounded),
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _query = '');
                        },
                      ),
              ),
              onChanged: (value) => setState(() => _query = value.trim()),
            ),
          ),
          // Keep the search field usable while the track header and body
          // share the remaining scrollable viewport above the keyboard.
          Expanded(
            child: CustomScrollView(
              key: const Key('subtitle-cue-list'),
              slivers: [
                SliverToBoxAdapter(
                  child: Padding(
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
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.download_rounded),
                        ),
                      ],
                    ),
                  ),
                ),
                if (_cuesLoading)
                  const SliverToBoxAdapter(child: LinearProgressIndicator())
                else if (cues.isEmpty)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
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
                else if (visible.isEmpty)
                  const SliverToBoxAdapter(
                    child: Center(child: Text('没有匹配的字幕')),
                  )
                else
                  SliverList.builder(
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
              ],
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
    _appearance = const PlaybackPreferences().copyWith(
      subtitleFontSize: widget.fontSize,
      subtitlePosition: widget.position,
      subtitleOpacity: widget.opacity,
    );
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
  void _previewAppearance(SubtitleAppearanceSetting setting, double value) {
    setState(() {
      _appearance = setting.apply(_appearance, value);
      _appearanceRevisions.update(
        setting,
        (revision) => revision + 1,
        ifAbsent: () => 1,
      );
    });
    final preview = switch (setting) {
      SubtitleAppearanceSetting.fontSize => widget.onPreviewFontSize,
      SubtitleAppearanceSetting.position => widget.onPreviewPosition,
      SubtitleAppearanceSetting.opacity => widget.onPreviewOpacity,
    };
    preview?.call(setting.read(_appearance));
  }

  /// 迟到的保存仅可同步尚未被再次调整的设置。
  Future<void> _commitAppearance(
    SubtitleAppearanceSetting setting,
    double value,
  ) async {
    final revision = _appearanceRevisions[setting];
    final saved = await switch (setting) {
      SubtitleAppearanceSetting.fontSize => widget.onCommitFontSize(value),
      SubtitleAppearanceSetting.position => widget.onPositionChanged!(value),
      SubtitleAppearanceSetting.opacity => widget.onOpacityChanged!(value),
    };
    if (mounted && revision == _appearanceRevisions[setting]) {
      setState(() => _appearance = setting.apply(_appearance, saved));
    }
  }

  Iterable<SubtitleAppearanceSetting> get _appearanceSettings sync* {
    yield SubtitleAppearanceSetting.fontSize;
    if (widget.onPositionChanged != null) {
      yield SubtitleAppearanceSetting.position;
    }
    if (widget.onOpacityChanged != null) {
      yield SubtitleAppearanceSetting.opacity;
    }
  }

  void _resetAppearance() {
    for (final setting in _appearanceSettings) {
      final value = setting.read(const PlaybackPreferences());
      _previewAppearance(setting, value);
      unawaited(_commitAppearance(setting, value));
    }
  }

  Widget _buildAppearance() {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 100,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Align(
              alignment: Alignment(0, _appearance.subtitlePosition * 2 - 1),
              child: PlayerSubtitleCaption(
                key: const Key('subtitle-appearance-preview'),
                text: '这是字幕预览',
                fontSize: _appearance.subtitleFontSize,
                opacity: _appearance.subtitleOpacity,
              ),
            ),
          ),
          const SizedBox(height: 12),
          for (final setting in _appearanceSettings)
            _buildAppearanceSlider(setting),
        ],
      ),
    );
  }

  Widget _buildAppearanceSlider(SubtitleAppearanceSetting setting) {
    final value = setting.read(_appearance);
    final (id, min, max, divisions, label) = switch (setting) {
      SubtitleAppearanceSetting.fontSize => (
        'font-size',
        PlaybackPreferences.minSubtitleFontSize,
        PlaybackPreferences.maxSubtitleFontSize,
        24,
        '${value.round()}',
      ),
      SubtitleAppearanceSetting.position => (
        'position',
        0.0,
        1.0,
        20,
        _positionLabel(value),
      ),
      SubtitleAppearanceSetting.opacity => (
        'opacity',
        PlaybackPreferences.minSubtitleOpacity,
        1.0,
        14,
        '${(value * 100).round()}%',
      ),
    };
    return Column(
      children: [
        Row(
          children: [
            Expanded(child: Text(setting.label)),
            Text(label),
          ],
        ),
        Semantics(
          label: setting.label,
          child: Slider(
            key: Key('subtitle-$id-slider'),
            value: value,
            min: min,
            max: max,
            divisions: divisions,
            label: label,
            semanticFormatterCallback: switch (setting) {
              SubtitleAppearanceSetting.fontSize =>
                (value) => '${value.round()}',
              SubtitleAppearanceSetting.position => _positionLabel,
              SubtitleAppearanceSetting.opacity =>
                (value) => '${(value * 100).round()}%',
            },
            onChanged: (value) => _previewAppearance(setting, value),
            onChangeEnd: (value) => _commitAppearance(setting, value),
          ),
        ),
      ],
    );
  }

  String _positionLabel(double position) => switch (position) {
    0 => '顶部',
    0.5 => '居中',
    1 => '底部',
    _ => '${(position * 100).round()}%',
  };

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

  /// 固定返回与关闭入口，轨道、外观和字幕正文各自滚动。
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
                    if (_browsingTrack != null || _appearanceOpen)
                      IconButton(
                        key: const Key('back-to-subtitle-tracks'),
                        tooltip: '返回字幕轨道',
                        onPressed: () => setState(() {
                          _cueRevision++;
                          _browsingTrack = null;
                          _cueResult = null;
                          _cuesLoading = false;
                          _appearanceOpen = false;
                        }),
                        icon: const Icon(Icons.arrow_back_rounded),
                      ),
                    Expanded(
                      child: Text(
                        _appearanceOpen
                            ? '字幕外观'
                            : _browsingTrack == null
                            ? '字幕'
                            : '字幕列表',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    if (_appearanceOpen)
                      IconButton(
                        tooltip: '恢复默认字幕外观',
                        onPressed: _resetAppearance,
                        icon: const Icon(Icons.restart_alt_rounded),
                      )
                    else ...[
                      if (_browsingTrack == null)
                        Tooltip(
                          key: const Key('open-subtitle-appearance'),
                          message: '调整字幕外观',
                          child: TextButton(
                            onPressed: () =>
                                setState(() => _appearanceOpen = true),
                            child: const Text('外观'),
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
                    ],
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
                child: _appearanceOpen
                    ? _buildAppearance()
                    : _browsingTrack != null
                    ? _buildCueBrowser()
                    : SingleChildScrollView(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
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
                              selected: widget.selectedTrackId == null,
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
                                selected: widget.selectedTrackId == track.id,
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
