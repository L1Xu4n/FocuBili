/// Metadata diagnostics accept only bounded numbers, booleans and fixed enums.
class VideoMetadataRequestDiagnostic {
  VideoMetadataRequestDiagnostic._(this.fields);
  final Map<String, String> fields;

  static VideoMetadataRequestDiagnostic? fromMap(Map<String, Object?> raw) {
    final fields = <String, String>{};
    void integer(String key, int min, int max) {
      final value = raw[key];
      if (value is int && value >= min && value <= max) {
        fields[key] = '$value';
      }
    }

    void enumeration(String key, Set<String> allowed) {
      final value = raw[key];
      fields[key] = value is String && allowed.contains(value)
          ? value
          : 'unknown';
    }

    integer('request_id', 1, 9007199254740991);
    if (!fields.containsKey('request_id')) return null;
    integer('http_status', 100, 599);
    integer('api_code', -999999, 999999);
    enumeration('endpoint_kind', {'nav', 'view_wbi', 'pagelist'});
    enumeration('stage', {'cookie', 'signing', 'request', 'parse', 'complete'});
    enumeration('outcome', {'success', 'error'});
    enumeration('session_read', {
      'ok',
      'error',
      'partial',
      'conflict',
      'changing',
    });
    enumeration('auth_state', {'anonymous', 'session_present_unverified'});
    enumeration('session_source', {
      'apple_wkwebview',
      'platform_webview',
      'secure_storage',
      'unavailable',
      'injected',
    });
    for (final key in ['wbi_signed', 'dedup_shared', 'offline_cache']) {
      final value = raw[key];
      if (value is bool) fields[key] = '$value';
    }
    return VideoMetadataRequestDiagnostic._(Map.unmodifiable(fields));
  }
}
