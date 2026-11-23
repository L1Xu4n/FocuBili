import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'app_http_client.dart';
import 'cache_lifecycle.dart';

/// 只读取固定官方接口 JSON；测试可替换网络，签名材料不包含登录凭据。
typedef WbiJsonRequest =
    Future<String> Function(Uri endpoint, Map<String, String> headers);

/// 仅保留可安全跨请求层传递的状态码，不保留地址、正文或凭据。
abstract interface class BilibiliRequestFailure {
  int? get httpStatus;
  int? get apiCode;
}

/// 表示签名材料不可用，错误消息不回显 Cookie、地址或响应正文。
class WbiSigningException implements Exception, BilibiliRequestFailure {
  /// 创建固定、可直接展示的签名失败提示。
  const WbiSigningException({this.httpStatus, this.apiCode});

  @override
  final int? httpStatus;
  @override
  final int? apiCode;

  /// 提示用户重试或显式恢复原请求方式，避免静默切换模式。
  @override
  String toString() => httpStatus != null
      ? 'WBI 签名材料请求失败（HTTP $httpStatus），请稍后重试。'
      : apiCode != null
      ? 'WBI 签名材料请求失败（错误码：$apiCode），请稍后重试。'
      : 'WBI 签名材料暂时无法获取，请稍后重试，或在“播放与专注”中关闭“启用 WBI 签名”。';
}

/// 获取官方 nav 签名材料并在内存缓存一小时，只为播放数据请求生成 WBI。
class BilibiliWbiSigningService {
  /// 注入官方请求函数和时钟，允许用固定材料核验签名与过期行为。
  BilibiliWbiSigningService({
    required WbiJsonRequest requestJson,
    DateTime Function()? clock,
  }) : _requestJson = requestJson,
       _clock = clock ?? DateTime.now;

  static final BilibiliWbiSigningService shared = _createShared();

  /// 清除旧会话的签名材料，并让旧请求无法重新写入公共缓存。
  static BilibiliWbiSigningService _createShared() {
    final service = BilibiliWbiSigningService(requestJson: _requestNav);
    CacheLifecycle.account.addListener(service._keys.clear);
    return service;
  }

  /// 使用共享连接请求官方签名材料。
  static Future<String> _requestNav(
    Uri uri,
    Map<String, String> headers,
  ) async {
    final response = await AppHttpTransport.shared.send(
      uri: uri,
      headers: headers,
      followRedirects: false,
    );
    if (response.statusCode != 200) {
      throw WbiSigningException(httpStatus: response.statusCode);
    }
    return response.bodyUtf8;
  }

  static const _keyOrder = <int>[
    46,
    47,
    18,
    2,
    53,
    8,
    23,
    32,
    15,
    50,
    10,
    31,
    58,
    3,
    45,
    35,
    27,
    43,
    5,
    49,
    33,
    9,
    42,
    19,
    29,
    28,
    14,
    39,
    12,
    38,
    41,
    13,
  ];
  static final _keyPattern = RegExp(r'^[0-9a-fA-F]{32}$');
  static final _filteredCharacters = RegExp(r"[!'()*]");
  final WbiJsonRequest _requestJson;
  final DateTime Function() _clock;
  final Map<Object, _WbiKeyBucket> _keys = {};
  static const _defaultScope = 'default';

  /// 为当前请求生成新时间戳；并发请求共享一次材料获取，失败不缓存。
  Future<Map<String, String>> signParameters(
    Map<String, String> parameters, {
    required Map<String, String> headers,
    WbiJsonRequest? requestJson,
    Object scopeKey = _defaultScope,
  }) async {
    final bucket = _keys.putIfAbsent(scopeKey, _WbiKeyBucket.new);
    final now = _clock();
    final age = bucket.cachedAt == null
        ? null
        : now.difference(bucket.cachedAt!);
    final String key;
    if (bucket.key != null &&
        age != null &&
        !age.isNegative &&
        age < const Duration(hours: 1)) {
      key = bucket.key!;
    } else {
      final seedVersion = bucket.seedVersion;
      key = await (bucket.pending ??= _loadKey(headers, requestJson)
          .then((key) {
            if (!identical(_keys[scopeKey], bucket)) {
              throw const WbiSigningException();
            }
            if (bucket.seedVersion == seedVersion) {
              bucket.key = key;
              bucket.cachedAt = _clock();
            }
            return bucket.key!;
          })
          .whenComplete(() {
            bucket.pending = null;
          }));
    }
    if (!identical(_keys[scopeKey], bucket)) throw const WbiSigningException();
    return sign(parameters, key, _clock().millisecondsSinceEpoch ~/ 1000);
  }

  /// 下一次请求可刷新此会话的签名材料，旧的在途请求不能回填。
  void invalidate([Object scopeKey = _defaultScope]) {
    _keys.remove(scopeKey);
  }

  /// 复用已收到的 nav 材料；字段无效时保留现有缓存。
  void seedFromNavImages(Object scopeKey, Object? imgUrl, Object? subUrl) {
    try {
      final key = deriveMixinKey(_keyFromUrl(imgUrl), _keyFromUrl(subUrl));
      final bucket = _keys.putIfAbsent(scopeKey, _WbiKeyBucket.new);
      bucket.seedVersion++;
      bucket.key = key;
      bucket.cachedAt = _clock();
    } on WbiSigningException {
      // 部分 nav 响应不包含签名图片。
    }
  }

  /// 从 nav 的 wbi_img 提取材料；游客 nav 的 -101 仍可能包含有效材料。
  Future<String> _loadKey(
    Map<String, String> headers,
    WbiJsonRequest? requestJson,
  ) async {
    try {
      final text = await (requestJson ?? _requestJson)(
        Uri.https('api.bilibili.com', '/x/web-interface/nav'),
        headers,
      );
      final root = jsonDecode(text) as Map<String, dynamic>;
      final code = root['code'];
      if (code is int && code != 0 && code != -101) {
        throw WbiSigningException(apiCode: code);
      }
      return mixinKeyFromNavImages(root['data']['wbi_img']);
    } on BilibiliRequestFailure catch (error) {
      throw WbiSigningException(
        httpStatus: error.httpStatus,
        apiCode: error.apiCode,
      );
    } catch (_) {
      throw const WbiSigningException();
    }
  }

  /// Reuses the signing material from an already verified nav response.
  static String mixinKeyFromNavImages(Object? images) {
    if (images is! Map) throw const WbiSigningException();
    return deriveMixinKey(
      _keyFromUrl(images['img_url']),
      _keyFromUrl(images['sub_url']),
    );
  }

  /// 只解析材料文件名，不下载图片，不把服务端 URL 当成新的请求地址。
  static String _keyFromUrl(Object? value) {
    final uri = value is String ? Uri.tryParse(value) : null;
    if (uri == null || uri.pathSegments.isEmpty) {
      throw const WbiSigningException();
    }
    return uri.pathSegments.last.split('.').first;
  }

  /// 按 WBI 固定置换表从两个 32 位材料生成 32 位混合键。
  static String deriveMixinKey(String imageKey, String subKey) {
    if (!_keyPattern.hasMatch(imageKey) || !_keyPattern.hasMatch(subKey)) {
      throw const WbiSigningException();
    }
    final combined = imageKey + subKey;
    return _keyOrder.map((index) => combined[index]).join();
  }

  /// 清洗值、覆盖旧签名并排序，再对规范查询串和混合键计算 MD5。
  static Map<String, String> sign(
    Map<String, String> parameters,
    String mixinKey,
    int timestamp,
  ) {
    if (!_keyPattern.hasMatch(mixinKey)) {
      throw const WbiSigningException();
    }
    final result = <String, String>{
      for (final entry in parameters.entries)
        if (entry.key != 'w_rid' && entry.key != 'wts')
          entry.key: entry.value.replaceAll(_filteredCharacters, ''),
      'wts': '$timestamp',
    };
    result['w_rid'] = md5
        .convert(utf8.encode(encodeQuery(result) + mixinKey))
        .toString();
    return result;
  }

  /// 使用百分号编码而非加号编码空格，保证实际请求与签名规范串一致。
  static String encodeQuery(Map<String, String> parameters) {
    final keys = parameters.keys.toList()..sort();
    return keys
        .map(
          (key) =>
              '${Uri.encodeComponent(key)}=${Uri.encodeComponent(parameters[key]!)}',
        )
        .join('&');
  }
}

/// 保存单一会话的签名材料与在途请求。
class _WbiKeyBucket {
  int seedVersion = 0;
  String? key;
  DateTime? cachedAt;
  Future<String>? pending;
}
