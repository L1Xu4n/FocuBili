import 'dart:convert';
import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';

import 'settings_transfer_service.dart';
import 'subscription_service.dart';
import 'unified_export_service.dart';
import 'unified_restore_notes.dart';
import 'unified_restore_preferences.dart';
import 'unified_restore_zip.dart';
import 'unified_settings_restore.dart';
import 'video_note_service.dart';

final class UnifiedRestorePlan {
  const UnifiedRestorePlan._({
    required this.sections,
    required this.preview,
    required this.warnings,
    required this.notes,
    required this.preferences,
    required this.settings,
    required this.subscriptions,
  });

  final List<UnifiedExportSection> sections;
  final List<String> preview;
  final List<String> warnings;
  final UnifiedRestoreNotesPlan? notes;
  final List<UnifiedRestorePreferencePlan> preferences;
  final UnifiedSettingsRestorePlan? settings;
  final SubscriptionUnifiedRestoreData? subscriptions;
}

final class UnifiedRestoreResult {
  const UnifiedRestoreResult(this.added, this.kept, this.warnings);

  final int added;
  final int kept;
  final List<String> warnings;
}

/// Restores an application-generated backup after a read-only preview and
/// explicit user confirmation. No archive filenames become device paths.
final class UnifiedRestoreService {
  UnifiedRestoreService({
    Future<SharedPreferences> Function()? preferencesLoader,
    UnifiedRestoreNotes? notes,
    UnifiedSettingsRestore? settings,
    SubscriptionService? subscriptions,
  }) : _preferencesLoader = preferencesLoader ?? SharedPreferences.getInstance,
       _notes =
           notes ??
           UnifiedRestoreNotes(
             VideoNoteService(preferencesLoader: preferencesLoader),
           ),
       _settings =
           settings ??
           UnifiedSettingsRestore(
             settingsTransfer: SettingsTransferService(
               preferencesLoader:
                   preferencesLoader ?? SharedPreferences.getInstance,
             ),
           ),
       _subscriptions = subscriptions;

  static const maximumZipBytes = UnifiedRestoreZip.maximumBytes;
  final Future<SharedPreferences> Function() _preferencesLoader;
  final UnifiedRestoreNotes _notes;
  final UnifiedSettingsRestore _settings;
  final SubscriptionService? _subscriptions;

  Future<UnifiedRestorePlan> inspect(Uint8List bytes) async {
    final zip = UnifiedRestoreZip(bytes);
    final manifest = zip.object('manifest.json');
    final names = manifest['sections'];
    if (manifest['format'] != 'focubili.unified-export' ||
        manifest['version'] != 1 ||
        manifest['credentialsIncluded'] != false ||
        names is! List ||
        names.isEmpty ||
        names.length > UnifiedExportSection.values.length) {
      throw const FormatException('Invalid unified backup manifest');
    }
    final sections = <UnifiedExportSection>[];
    final preview = <String>[];
    final warnings = <String>[];
    final preferences = <UnifiedRestorePreferencePlan>[];
    UnifiedRestoreNotesPlan? notes;
    UnifiedSettingsRestorePlan? settings;
    SubscriptionUnifiedRestoreData? subscriptions;
    for (final name in names) {
      final section = UnifiedExportSection.values
          .where((section) => section.name == name)
          .firstOrNull;
      if (section == null || sections.contains(section)) {
        throw const FormatException('Unsupported or repeated backup section');
      }
      sections.add(section);
      switch (section) {
        case UnifiedExportSection.notes:
          final parsed = await UnifiedRestoreNotes.inspect(zip);
          notes = parsed;
          preview.add('时间点笔记：${parsed.count} 条');
          if (parsed.missingFrames > 0) {
            warnings.add('有 ${parsed.missingFrames} 张笔记截图缺失或不可读，只恢复文字及仍可用的截图。');
          }
        case UnifiedExportSection.settings:
          final doc = zip.object('settings.json');
          final raw = doc['values'];
          if (doc['format'] != 'focubili.local.settings' ||
              doc['version'] != 1 ||
              raw is! Map<String, dynamic>) {
            throw const FormatException('Invalid backup settings document');
          }
          final parsed = _settings.validate(raw);
          settings = parsed;
          preview.add('设置与筛选规则：${parsed.candidateCount} 项');
          if (parsed.skippedCount > 0) {
            warnings.add('有 ${parsed.skippedCount} 项系统相关或不再支持的设置不导入。');
          }
        case UnifiedExportSection.learning:
        case UnifiedExportSection.favorites:
        case UnifiedExportSection.followingGroups:
        case UnifiedExportSection.history:
          final plan = UnifiedRestorePreferences.inspect(
            section,
            zip.object('${section.name}.json'),
          );
          preferences.add(plan);
          preview.add('${section.label}：${plan.itemCount} 项');
          warnings.addAll(plan.warnings);
          if (section == UnifiedExportSection.history &&
              zip.contains('native_playback_progress.json')) {
            warnings.add('Android 原生播放进度暂不恢复；包内原文件仍保留。');
          }
        case UnifiedExportSection.subscriptions:
          subscriptions = SubscriptionService.parseUnifiedRestore(
            zip.object('subscriptions.json'),
          );
          preview.add(
            '焦点订阅：${subscriptions.sources.length} 个来源、${subscriptions.feed.length} 条更新',
          );
          if (subscriptions.historyCount > 0) {
            warnings.add(
              '此前手动导入的 ${subscriptions.historyCount} 条订阅历史不会重建任务或进度。',
            );
          }
        case UnifiedExportSection.offline:
          warnings.add('离线目录仅供参考；ZIP 不含视频文件，不恢复缓存记录。');
        case UnifiedExportSection.subtitles:
          warnings.add('字幕仍可从 ZIP 取出查看，不写入应用的临时字幕缓存。');
        case UnifiedExportSection.diagnostics:
          warnings.add('诊断报告只供查看，不写入本机诊断记录。');
      }
    }
    return UnifiedRestorePlan._(
      sections: List.unmodifiable(sections),
      preview: List.unmodifiable(preview),
      warnings: List.unmodifiable(warnings),
      notes: notes,
      preferences: List.unmodifiable(preferences),
      settings: settings,
      subscriptions: subscriptions,
    );
  }

  Future<UnifiedRestoreResult> apply(UnifiedRestorePlan plan) async {
    var added = 0;
    var kept = 0;
    final warnings = <String>[];
    final notes = plan.notes;
    final preferences = plan.preferences;
    // Each domain uses a storage boundary. A later domain's failure never
    // deletes an earlier successful import, and is explicitly reported.
    if (notes != null && notes.count > 0) {
      try {
        final result = await _notes.apply(notes);
        added += result.added;
        kept += result.kept;
      } catch (_) {
        warnings.add('时间点笔记未恢复，请检查本机笔记和存储空间。');
      }
    }
    if (preferences.isNotEmpty) {
      try {
        final result = await _applyPreferences(preferences);
        added += result.added;
        kept += result.skipped;
        warnings.addAll(result.warnings);
      } catch (_) {
        warnings.add('学习、收藏、关注分组或历史记录未能完整恢复，请检查本机数据和存储空间。');
      }
    }
    final subscriptions = plan.subscriptions;
    if (subscriptions != null) {
      try {
        final result = await (_subscriptions ?? SubscriptionService.instance)
            .restoreUnifiedData(subscriptions);
        added += result.added;
        kept += result.kept - subscriptions.historyCount;
      } catch (_) {
        warnings.add('焦点订阅未能完整恢复，请检查本机数据和存储空间。');
      }
    }
    final settings = plan.settings;
    if (settings != null) {
      try {
        final result = await _settings.apply(settings);
        added += result.added;
        kept += result.retained;
      } catch (_) {
        warnings.add('设置未能完整恢复，请检查本机数据和存储空间。');
      }
    }
    return UnifiedRestoreResult(
      added,
      kept,
      List.unmodifiable(warnings.toSet()),
    );
  }

  Future<UnifiedRestorePreferenceWrites> _applyPreferences(
    List<UnifiedRestorePreferencePlan> plans,
  ) async {
    final prefs = await _preferencesLoader();
    await prefs.reload();
    const sections = [
      UnifiedExportSection.learning,
      UnifiedExportSection.favorites,
      UnifiedExportSection.followingGroups,
      UnifiedExportSection.history,
    ];
    final local = <String, Object?>{
      for (final key in prefs.getKeys())
        if (sections.any(
          (section) => UnifiedExportService.includesKey(section, key),
        ))
          key: prefs.get(key),
    };
    final plan = UnifiedRestorePreferences.planWrites(plans, local);
    final written = <String, Object>{};
    try {
      // Abort if affected device state changed after computing the merge.
      for (final entry in plan.values.entries) {
        if (!_sameValue(prefs.get(entry.key), local[entry.key])) {
          throw StateError('Local data changed before restore');
        }
        written[entry.key] = entry.value;
        await _write(prefs, entry.key, entry.value);
      }
    } catch (_) {
      try {
        await prefs.reload();
        for (final entry in written.entries.toList().reversed) {
          if (_sameValue(prefs.get(entry.key), entry.value)) {
            await _write(prefs, entry.key, local[entry.key]);
          }
        }
      } catch (_) {
        // Caller reports an incomplete domain; never overwrite newer edits.
      }
      rethrow;
    }
    return plan;
  }

  static bool _sameValue(Object? a, Object? b) =>
      a is List && b is List ? jsonEncode(a) == jsonEncode(b) : a == b;

  static Future<void> _write(
    SharedPreferences prefs,
    String key,
    Object? value,
  ) async {
    final saved = await switch (value) {
      null => prefs.remove(key),
      String value => prefs.setString(key, value),
      List<String> value => prefs.setStringList(key, value),
      _ => throw StateError('Unsupported preference value'),
    };
    if (!saved) throw StateError('Restore write failed');
  }
}
