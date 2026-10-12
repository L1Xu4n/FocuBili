import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A process-local invalidation fence. Contains no account identifier or secret.
/// Readers capture the revision before awaiting work and reject late results.
abstract final class CacheLifecycle {
  static final ValueNotifier<int> subtitles = ValueNotifier(0);
  static final ValueNotifier<int> account = ValueNotifier(0);
  static String accountScope = 'guest';
  static const _scopeKey = 'resource_cache_account_scope';

  static Future<void> initialize() async {
    accountScope =
        (await SharedPreferences.getInstance()).getString(_scopeKey) ?? 'guest';
  }

  /// Only a verified public MID is persisted, never a cookie or cookie hash.
  static Future<void> setAccount(int? mid) async {
    final scope = mid == null ? 'guest' : 'mid:$mid';
    if (scope == accountScope) return;
    accountScope = scope;
    accountChanged();
    try {
      await (await SharedPreferences.getInstance()).setString(_scopeKey, scope);
    } catch (_) {
      /* Runtime partition remains safe even if preferences fail. */
    }
  }

  static void clearSubtitles() => subtitles.value++;

  static void accountChanged() {
    account.value++;
    clearSubtitles();
  }
}
