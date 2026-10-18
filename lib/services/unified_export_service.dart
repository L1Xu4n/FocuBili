import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/video_note.dart';
import '../models/player_overlay_data.dart';
import '../platform/app_platform.dart';
import 'native_playback_progress_export.dart';
import 'subtitle_export_service.dart';
import 'cached_player_overlay_service.dart';
import 'problem_diagnostics_service.dart';
import 'subscription_service.dart';
import 'settings_runtime_adapter.dart';
import 'video_note_export_service.dart';
import 'video_note_service.dart';

enum UnifiedExportSection {
  settings('设置与筛选规则'),
  notes('时间点笔记与截图'),
  learning('学习清单与专注记录'),
  favorites('本地收藏夹'),
  history('观看、搜索与播放进度'),
  subscriptions('焦点订阅与已载入历史'),
  subtitles('本次运行已载入的字幕'),
  offline('离线视频目录信息'),
  diagnostics('问题诊断（脱敏）');

  const UnifiedExportSection(this.label);
  final String label;
}

class UnifiedExportPackage {
  const UnifiedExportPackage({
    required this.fileName,
    required this.bytes,
    required this.sections,
    required this.warnings,
  });
  final String fileName;
  final Uint8List bytes;
  final List<UnifiedExportSection> sections;
  final List<String> warnings;
}

/// Exports local user information through an explicit allowlist. This class
/// never calls auth, cookie stores, secure storage or a network endpoint.
class UnifiedExportService {
  UnifiedExportService({
    Future<SharedPreferences> Function()? preferencesLoader,
    this.noteExporter = const VideoNoteExportService(),
    Future<Map<String, Object?>> Function()? subscriptionLoader,
    List<Map<String, Object?>> Function()? subtitleLoader,
    Future<String> Function()? diagnosticsLoader,
    SettingsRuntimeAdapter? settingsRuntimeAdapter,
    AppPlatform? platform,
    Future<Object?> Function()? nativePlaybackProgressLoader,
    DateTime Function()? clock,
  }) : _preferencesLoader = preferencesLoader ?? SharedPreferences.getInstance,
       _subscriptionLoader =
           subscriptionLoader ?? SubscriptionService.instance.exportLocalData,
       _subtitleLoader =
           subtitleLoader ??
           (() => SubtitleMemoryCache.instance.exportCues(DateTime.now())),
       _diagnosticsLoader =
           diagnosticsLoader ??
           (() => ProblemDiagnosticsService(
             preferencesLoader: preferencesLoader,
           ).buildCopyText(strictStorage: true)),
       _settingsRuntimeAdapter =
           settingsRuntimeAdapter ?? const DeviceSettingsRuntimeAdapter(),
       _platform = platform ?? AppPlatformDetector.current,
       _nativePlaybackProgressLoader =
           nativePlaybackProgressLoader ??
           const NativePlaybackProgressExport().read,
       _clock = clock ?? DateTime.now;

  final Future<SharedPreferences> Function() _preferencesLoader;
  final VideoNoteExportService noteExporter;
  final Future<Map<String, Object?>> Function() _subscriptionLoader;
  final List<Map<String, Object?>> Function() _subtitleLoader;
  final DateTime Function() _clock;
  final Future<String> Function() _diagnosticsLoader;
  final SettingsRuntimeAdapter _settingsRuntimeAdapter;
  final AppPlatform _platform;
  final Future<Object?> Function() _nativePlaybackProgressLoader;

  static const _settingsKeys = <String>{
    'appearance.theme_mode',
    'appearance.theme_color',
    'appearance.layout_orientation',
    'playback_preferences.enable_double_tap_seek',
    'playback_preferences.speeds',
    'playback_preferences.double_tap_regions',
    'playback_preferences.action_animation',
    'playback_preferences.control_scale',
    'playback_preferences.show_note_time_markers',
    'playback_preferences.subtitle_font_size',
    'playback_preferences.two_finger_video_transform',
    'playback_preferences.prefer_offline_cache',
    'playback_preferences.wifi_default_quality',
    'playback_preferences.mobile_default_quality',
    'playback_preferences.long_press_speed',
    'focus_preferences.enable_do_not_disturb',
    'app_behavior.account_read_only',
    'app_behavior.search_history_enabled',
    'app_behavior.watch_history_enabled',
    'app_behavior.wbi_signing_enabled',
    'windows_clipboard_link_detection.enabled',
    'app_update.check_on_start',
    'app_update.ignored_release',
    'windows_media_cache_capacity_bytes',
    'focubili_danmaku_preferences_v1',
    'search.content_filter_v2',
    'content.blocklist_v1',
    'dashboard.layout.home',
    'dashboard.layout.profile',
  };
  static const _learningKeys = <String>{
    'focubili_learning_list_v2',
    'focubili_learning_list_v1',
    'focubili_focus_active_session',
    'focubili_focus_history',
  };
  static const _historyKeys = <String>{
    'focubili_watch_history',
    'focubili_search_history',
  };
  static final _favoriteItems = RegExp(
    r'^app_favorites\.items_v1\.[a-zA-Z0-9_-]+$',
  );
  static final _progress = RegExp(
    r'^windows_playback_state_(?:BV[0-9A-Za-z]{10}|CHEESE:SS[1-9][0-9]*)(?:_cid_[0-9]+)?$',
  );

  /// Kept public for auditing and fixture tests; unrecognized future data is
  /// excluded until deliberately added here, rather than dumped wholesale.
  static bool includesKey(UnifiedExportSection section, String key) =>
      switch (section) {
        UnifiedExportSection.settings =>
          _settingsKeys.contains(key) ||
              DeviceSettingsRuntimeAdapter.keys.contains(key),
        UnifiedExportSection.learning => _learningKeys.contains(key),
        UnifiedExportSection.favorites =>
          key == 'app_favorites.folders_v1' || _favoriteItems.hasMatch(key),
        UnifiedExportSection.offline => key == 'focubili_offline_videos_v1',
        UnifiedExportSection.history =>
          _historyKeys.contains(key) || _progress.hasMatch(key),
        _ => false,
      };

  Future<UnifiedExportPackage> buildPackage({
    Set<UnifiedExportSection> sections = const {...UnifiedExportSection.values},
  }) async {
    if (sections.isEmpty) throw ArgumentError('请至少选择一项导出内容。');
    final now = _clock().toUtc();
    final archive = Archive();
    final warnings = <String>[];
    final ordered = UnifiedExportSection.values
        .where(sections.contains)
        .toList();
    final prefs = await _preferencesLoader();
    await prefs.reload();
    final notesRaw = sections.contains(UnifiedExportSection.notes)
        ? prefs.get(VideoNoteService.storageKey)
        : null;
    // Capture one local preferences snapshot before asynchronous image reads.
    final captured = <String, Object?>{
      for (final key in prefs.getKeys())
        if (!DeviceSettingsRuntimeAdapter.keys.contains(key) &&
            ordered.any((section) => includesKey(section, key)))
          key: prefs.get(key),
    };
    if (sections.contains(UnifiedExportSection.settings)) {
      final runtime = await _settingsRuntimeAdapter.readSettings();
      for (final key in DeviceSettingsRuntimeAdapter.subscriptionKeys) {
        if (runtime[key] is! bool) {
          throw const FormatException('Invalid subscription preference');
        }
        captured[key] = runtime[key];
      }
      final capacity = runtime[DeviceSettingsRuntimeAdapter.imageCapacityKey];
      if (capacity is! int || capacity < 0) {
        throw const FormatException('Invalid image cache capacity');
      }
      captured[DeviceSettingsRuntimeAdapter.imageCapacityKey] = capacity;
    }
    for (final section in ordered) {
      if (section == UnifiedExportSection.notes) {
        final List<VideoNote> notes = _strictNotes(notesRaw);
        if (notes.isEmpty) {
          _addJson(archive, 'notes/notes.json', {'notes': <Object>[]});
          continue;
        }
        // Both human-readable and structured exports reuse the same image
        // handling as the standalone note export, including multi-frame notes.
        var missingFrames = 0;
        for (final format in VideoNoteExportFormat.values) {
          final package = await noteExporter.buildPackage(notes, format);
          if (package.missingImageCount > missingFrames) {
            missingFrames = package.missingImageCount;
          }
          if (package.extension == 'zip') {
            final inner = ZipDecoder().decodeBytes(package.bytes);
            for (final entry in inner.files.where((file) => file.isFile)) {
              final name = 'notes/${entry.name}';
              if (!archive.files.any((file) => file.name == name)) {
                archive.add(ArchiveFile.bytes(name, entry.content));
              }
            }
          } else {
            final extension = format == VideoNoteExportFormat.json
                ? 'json'
                : 'md';
            archive.add(
              ArchiveFile.bytes(
                'notes/focubili_notes.$extension',
                package.bytes,
              ),
            );
          }
        }
        if (missingFrames > 0) {
          warnings.add('有 $missingFrames 张笔记截图无法读取，文字、时间点和缺图位置已保留。');
        }
      } else if (section == UnifiedExportSection.diagnostics) {
        archive.add(
          ArchiveFile.string('diagnostics.txt', await _diagnosticsLoader()),
        );
      } else if (section == UnifiedExportSection.subscriptions) {
        _addJson(archive, 'subscriptions.json', await _subscriptionLoader());
      } else if (section == UnifiedExportSection.subtitles) {
        final tracks = _subtitleLoader();
        _addJson(archive, 'subtitles.json', {'tracks': tracks});
        for (var index = 0; index < tracks.length; index++) {
          final track = tracks[index];
          final cues = <SubtitleCue>[];
          for (final raw in (track['cues'] as List? ?? const [])) {
            if (raw is Map) {
              final cue = SubtitleCue.tryParse(Map<Object?, Object?>.from(raw));
              if (cue != null) cues.add(cue);
            }
          }
          if (cues.isEmpty) continue;
          for (final format in SubtitleExportFormat.values) {
            final package = const SubtitleExportService().buildPackage(
              cues: cues,
              format: format,
              videoLabel: '${track['bvid'] ?? ''} / CID ${track['cid'] ?? ''}',
              trackLabel: '${track['trackId'] ?? ''}',
            );
            archive.add(
              ArchiveFile.bytes(
                'subtitles/track_${index + 1}.${package.extension}',
                package.bytes,
              ),
            );
          }
        }
        if (tracks.isEmpty) {
          warnings.add('当前没有可导出的已载入字幕；可在播放页打开字幕列表后再次导出。');
        }
      } else {
        if (section == UnifiedExportSection.history &&
            _platform == AppPlatform.android) {
          _addJson(
            archive,
            'native_playback_progress.json',
            NativePlaybackProgressExport.validate(
              await _nativePlaybackProgressLoader(),
            ),
          );
        }
        _addJson(archive, '${section.name}.json', {
          'format': 'focubili.local.${section.name}',
          'version': 1,
          'values': {
            for (final entry in captured.entries)
              if (includesKey(section, entry.key)) entry.key: entry.value,
          },
        });
      }
    }
    _addJson(archive, 'manifest.json', {
      'format': 'focubili.unified-export',
      'version': 1,
      'exportedAt': now.toIso8601String(),
      'sections': ordered.map((section) => section.name).toList(),
      'credentialsIncluded': false,
      'warnings': warnings,
    });
    archive.add(
      ArchiveFile.string(
        'README.txt',
        '焦点哔哩统一导出\n\n'
            '内容：${ordered.map((section) => section.label).join('、')}\n'
            '登录凭据、Cookie、Token、安全存储、临时媒体URL一律不包含。\n'
            '本文件包含个人笔记和使用记录，请妥善保存。\n'
            '字幕仅包含本次运行仍有效的已载入内容；不会联网下载。\n'
            '缓存/离线视频媒体不打包；已下载视频请在离线视频页面导出。\n'
            '这是可阅读的本地资料包，不承诺可一键恢复所有状态。\n'
            'Android 原生逐 P 进度仅在 Android 勾选历史时附带，来自已提交文件，不含未落盘位置；各服务并非全局同一时刻快照。\n'
            '${warnings.join('\n')}\n',
      ),
    );
    return UnifiedExportPackage(
      fileName: 'FocuBili-export-${now.millisecondsSinceEpoch}.zip',
      bytes: ZipEncoder().encodeBytes(archive),
      sections: List.unmodifiable(ordered),
      warnings: List.unmodifiable(warnings),
    );
  }

  // Normal browsing tolerates corrupt rows. A backup must not silently turn
  // damaged or future-incompatible data into a successful empty/partial export.
  static List<VideoNote> _strictNotes(Object? raw) {
    if (raw == null) return [];
    if (raw is! String) throw const FormatException('Invalid notes storage');
    final decoded = jsonDecode(raw);
    if (decoded is! List) throw const FormatException('Invalid notes document');
    final notes = <VideoNote>[];
    final ids = <String>{};
    for (final row in decoded) {
      if (row is! Map) throw const FormatException('Invalid note record');
      if (row.keys.any((key) => !_noteFields.contains(key)) ||
          !_positiveInteger(row['partCid']) ||
          !_positiveInteger(row['partPageNumber']) ||
          (row['videoCoverUrl'] != null && row['videoCoverUrl'] is! String)) {
        throw const FormatException('Unsupported note fields or identity');
      }
      // Browsing may skip malformed frames, but a backup must not silently
      // discard a frame or change its timestamp through tolerant parsing.
      if (row.containsKey('frames')) {
        final frames = row['frames'];
        if (frames is! List) {
          throw const FormatException('Invalid note frames');
        }
        for (final frame in frames) {
          if (frame is! Map ||
              frame.keys.any((key) => key != 'path' && key != 'positionMs') ||
              frame['path'] is! String ||
              (frame['path'] as String).trim().isEmpty ||
              !_validPosition(frame['positionMs'])) {
            throw const FormatException('Invalid note frame');
          }
        }
      }
      if (!_validPosition(row['positionMs']) ||
          (row['framePath'] != null && row['framePath'] is! String)) {
        throw const FormatException('Invalid note position or legacy frame');
      }
      final note = VideoNote.tryParse(Map<String, dynamic>.from(row));
      if (note == null || !ids.add(note.id)) {
        throw const FormatException('Unsupported or duplicate note record');
      }
      notes.add(note);
    }
    notes.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return notes;
  }

  static bool _validPosition(Object? value) =>
      value is num &&
      value.isFinite &&
      value >= 0 &&
      value <= 604800000 &&
      value == value.toInt();

  static bool _positiveInteger(Object? value) =>
      value is num && value.isFinite && value > 0 && value == value.toInt();

  static const _noteFields = {
    'id',
    'bvid',
    'videoTitle',
    'ownerName',
    'partCid',
    'partPageNumber',
    'partTitle',
    'title',
    'body',
    'createdAt',
    'updatedAt',
    'positionMs',
    'videoCoverUrl',
    'framePath',
    'frames',
  };

  static void _addJson(Archive archive, String name, Object value) =>
      archive.add(
        ArchiveFile.string(
          name,
          const JsonEncoder.withIndent('  ').convert(value),
        ),
      );
}
