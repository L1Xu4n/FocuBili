import 'dart:convert';

import 'package:flutter/services.dart';

/// 从独立 JSON 读取可编辑的继续专注鼓励语料。
class FocusEncouragementService {
  /// 创建语料服务；测试可替换资源读取函数。
  FocusEncouragementService({Future<String> Function()? loadAsset})
    : _loadAsset =
          loadAsset ??
          (() =>
              rootBundle.loadString('assets/data/focus_encouragements.json'));

  final Future<String> Function() _loadAsset;
  Map<String, List<String>>? _cachedMessages;

  /// 根据是否接近完成返回一条稳定轮换的鼓励文案，资源损坏时使用内置兜底。
  Future<String> messageFor({
    required bool nearCompletion,
    required int seed,
  }) async {
    final Map<String, List<String>> messages = _cachedMessages ??=
        await _loadMessages();
    final String key = nearCompletion ? 'nearCompletion' : 'regular';
    final List<String> candidates = messages[key] ?? _fallback[key]!;
    return candidates[seed.abs() % candidates.length];
  }

  /// 解析 JSON 中的字符串数组，并过滤空内容。
  Future<Map<String, List<String>>> _loadMessages() async {
    try {
      final Object? decoded = jsonDecode(await _loadAsset());
      if (decoded is! Map<String, dynamic>) {
        return _fallback;
      }
      final Map<String, List<String>> result = <String, List<String>>{};
      for (final String key in <String>['regular', 'nearCompletion']) {
        final Object? values = decoded[key];
        if (values is List<Object?>) {
          final List<String> items = values
              .whereType<String>()
              .map((String item) => item.trim())
              .where((String item) => item.isNotEmpty)
              .toList(growable: false);
          if (items.isNotEmpty) {
            result[key] = items;
          }
        }
      }
      return <String, List<String>>{..._fallback, ...result};
    } on Object {
      return _fallback;
    }
  }

  static const Map<String, List<String>> _fallback = <String, List<String>>{
    'regular': <String>['先别急着停下来，再陪目标走五分钟。'],
    'nearCompletion': <String>['终点已经很近，再专注几分钟就能完整收尾。'],
  };
}
