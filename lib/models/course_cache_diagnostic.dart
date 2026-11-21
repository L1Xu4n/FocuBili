/// Fixed, non-identifying labels used by shareable course download diagnostics.
enum CourseCacheStage {
  input,
  account,
  purchase,
  course,
  chapter,
  playback,
  media,
  transport,
}

enum CourseCacheReason {
  sessionChanged,
  entitlementNotConfirmed,
  restrictionReported,
  policyUnknown,
  // Legacy Beta 8 diagnostic; keep decoding it for existing queue entries.
  offlinePermissionUnknown,
  watermarkUnknown,
  previewUnknown,
  drmUnknown,
  unsupportedMedia,
  invalidDeadline,
  incompleteMedia,
  containerUnverified,
  requestFailed,
  addressUnavailable,
}

class CourseCacheDiagnostic {
  const CourseCacheDiagnostic(this.stage, this.reason);

  static const _prefix = 'course-cache/v1';

  final CourseCacheStage stage;
  final CourseCacheReason reason;

  String get code => '$_prefix/${stage.name}/${reason.name}';

  /// Never treat arbitrary JSON string content as a shareable diagnostic.
  static CourseCacheDiagnostic? fromCode(Object? value) {
    if (value is! String || !value.startsWith('$_prefix/')) return null;
    final parts = value.split('/');
    if (parts.length != 4) return null;
    final stage = CourseCacheStage.values
        .where((stage) => stage.name == parts[2])
        .firstOrNull;
    final reason = CourseCacheReason.values
        .where((reason) => reason.name == parts[3])
        .firstOrNull;
    return stage == null || reason == null
        ? null
        : CourseCacheDiagnostic(stage, reason);
  }
}
