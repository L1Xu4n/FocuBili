/// 表示从桌面 WebView 浏览器容器读取的一条 Cookie。
class WebviewCookie {
  final String name;
  final String value;
  final String domain;
  final String path;
  final DateTime? expires;
  final bool secure;
  final bool httpOnly;
  final bool sessionOnly;

  /// 创建包含浏览器 Cookie 常用属性的数据对象。
  WebviewCookie({
    required this.name,
    required this.value,
    required this.domain,
    required this.path,
    required this.expires,
    required this.secure,
    required this.httpOnly,
    required this.sessionOnly,
  });

  /// 把原生桥接数据转换为 Dart 对象；会话 Cookie 不使用无意义的过期时间。
  factory WebviewCookie.fromJson(Map<String, dynamic> json) {
    final bool sessionOnly = json['sessionOnly'] ?? false;
    return WebviewCookie(
      name: json['name'],
      value: json['value'],
      domain: json['domain'],
      expires: sessionOnly || json['expires'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(
              ((json['expires'] as num) * 1000).toInt(),
            ),
      httpOnly: json['httpOnly'] ?? false,
      path: json['path'] ?? '/',
      secure: json['secure'] ?? false,
      sessionOnly: sessionOnly,
    );
  }

  /// 把 Cookie 转换为原生桥接可识别的键值表，会话 Cookie 的过期时间保持为空。
  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'value': value,
      'domain': domain,
      'path': path,
      'expires': sessionOnly || expires == null
          ? null
          : expires!.millisecondsSinceEpoch ~/ 1000,
      'secure': secure,
      'httpOnly': httpOnly,
      'sessionOnly': sessionOnly,
    };
  }
}
