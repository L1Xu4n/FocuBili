import 'settings_transfer_service.dart';
import 'unified_export_service.dart';

class UnifiedSettingsRestorePlan {
  const UnifiedSettingsRestorePlan._(this._values, this.skippedCount);

  final Map<String, Object> _values;

  /// A candidate may already exist locally when the confirmed plan is applied.
  int get candidateCount => _values.length;
  final int skippedCount;
}

class UnifiedSettingsRestoreResult {
  const UnifiedSettingsRestoreResult({
    required this.added,
    required this.retained,
    required this.skipped,
  });

  final int added;
  final int retained;
  final int skipped;
}

/// Validates the settings section of a v1 unified export. This never applies
/// runtime settings, starts subscriptions, or copies account/OS state.
class UnifiedSettingsRestore {
  const UnifiedSettingsRestore({
    this.settingsTransfer = const SettingsTransferService(),
  });

  final SettingsTransferService settingsTransfer;

  UnifiedSettingsRestorePlan validate(Map<String, Object?> values) {
    final candidates = <String, Object>{};
    for (final entry in values.entries) {
      if (!UnifiedExportService.includesKey(
            UnifiedExportSection.settings,
            entry.key,
          ) ||
          !SettingsTransferService.isPortableZipKey(entry.key)) {
        continue;
      }
      final value = entry.value;
      SettingsTransferService.validatePortableZipValue(entry.key, value);
      candidates[entry.key] = value is List
          ? List<String>.unmodifiable(value.cast<String>())
          : value!;
    }
    return UnifiedSettingsRestorePlan._(
      Map.unmodifiable(candidates),
      values.length - candidates.length,
    );
  }

  Future<UnifiedSettingsRestoreResult> restore(
    Map<String, Object?> values,
  ) async => apply(validate(values));

  Future<UnifiedSettingsRestoreResult> apply(
    UnifiedSettingsRestorePlan plan,
  ) async {
    final added = await settingsTransfer.importMissingZipSettings(plan._values);
    return UnifiedSettingsRestoreResult(
      added: added,
      retained: plan.candidateCount - added,
      skipped: plan.skippedCount,
    );
  }
}
