import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/search_content_filter.dart';

/// Saves the search sheet's local rules as one atomic preferences value.
class SearchContentFilterService {
  /// Uses isolated injection for tests without notifying unrelated settings pages.
  const SearchContentFilterService({
    this.preferencesLoader = SharedPreferences.getInstance,
  });
  final Future<SharedPreferences> Function() preferencesLoader;
  static const storageKey = 'search.content_filter_v2';

  /// Loads validated rules; the removed global play-count setting is not reused.
  Future<SearchContentFilter> load() async {
    try {
      final raw = (await preferencesLoader()).getString(storageKey);
      if (raw == null) return const SearchContentFilter();
      final data = jsonDecode(raw) as Map;
      final minimum = data['minimumPlayCount'] as int;
      if (minimum < 0 || minimum > SearchContentFilter.maximumPlayCount) {
        throw const FormatException();
      }
      return SearchContentFilter(
        learningOnly: data['learningOnly'] as bool,
        minimumPlayCount: minimum,
      );
    } catch (_) {
      return const SearchContentFilter();
    }
  }

  /// Reports failed storage rather than silently applying non-persistent settings.
  Future<void> save(SearchContentFilter filter) async {
    if (filter.minimumPlayCount < 0 ||
        filter.minimumPlayCount > SearchContentFilter.maximumPlayCount) {
      throw ArgumentError.value(filter.minimumPlayCount);
    }
    final saved = await (await preferencesLoader()).setString(
      storageKey,
      jsonEncode({
        'learningOnly': filter.learningOnly,
        'minimumPlayCount': filter.minimumPlayCount,
      }),
    );
    if (!saved) throw StateError('Search filter was not saved');
  }
}
