/// 从原生请求事件构造严格白名单，禁止动态字符串、凭据和媒体地址进入存储或导出。
class PlaybackRequestDiagnostic {
  PlaybackRequestDiagnostic._(this.fields);

  final Map<String, String> fields;

  /// 未知字段全部丢弃；已知字段也必须满足精确类型、枚举及范围要求。
  static PlaybackRequestDiagnostic? fromPlatformMap(Map<Object?, Object?> raw) {
    final fields = <String, String>{};
    void integer(String name, int minimum, int maximum) {
      final value = raw[name];
      if (value is int && value >= minimum && value <= maximum) {
        fields[name] = value.toString();
      }
    }

    void boolean(String name) {
      final value = raw[name];
      if (value is bool) fields[name] = value.toString();
    }

    void enumeration(String name, Set<String> allowed) {
      final value = raw[name];
      fields[name] = value is String && allowed.contains(value)
          ? value
          : 'unknown';
    }

    integer('request_id', 1, 9007199254740991);
    if (!fields.containsKey('request_id')) return null;
    for (final key in [
      'wbi_enabled',
      'wbi_signed',
      'wbi_fallback',
      'playurl_attempted',
      'guest_selected',
      'codec_fallback',
    ]) {
      boolean(key);
    }
    enumeration('session_read', {
      'not_attempted',
      'ok',
      'error',
      'unknown',
      'partial',
      'conflict',
      'changing',
    });
    enumeration('auth_state', {
      'anonymous',
      'session_present_unverified',
      'authenticated',
      'expired',
      'unknown',
    });
    for (final key in [
      'requested_quality',
      'returned_quality',
      'selected_quality',
    ]) {
      integer(key, 1, 1000);
    }
    enumeration('stage', {'cookie', 'signing', 'playurl', 'parse', 'complete'});
    enumeration('outcome', {'success', 'quality_downgrade', 'error'});
    integer('api_code', -999999, 999999);
    integer('http_status', 100, 599);
    return PlaybackRequestDiagnostic._(Map.unmodifiable(fields));
  }
}
