import 'dart:io';

/// Device-local network routing. Fresh installs and upgrades follow the OS.
enum NetworkProxyMode { system, direct, manual }

class NetworkProxySettings {
  const NetworkProxySettings({
    this.mode = NetworkProxyMode.system,
    this.host = '',
    this.port = 7890,
  });

  final NetworkProxyMode mode;
  final String host;
  final int port;

  /// No URLs, credentials, paths or PAC directives may enter a host field.
  static String? validateHost(String value) {
    final host = value.trim();
    if (host.isEmpty) return '请输入代理服务器地址';
    if (host.length > 253 || RegExp(r'[\s/@?#;,%\\]').hasMatch(host)) {
      return '只填写主机名或 IP，不包含协议、路径或账号密码';
    }
    final unbracketed = host.startsWith('[') && host.endsWith(']')
        ? host.substring(1, host.length - 1)
        : host;
    if (InternetAddress.tryParse(unbracketed) != null) return null;
    if (!RegExp(
          r'^[a-zA-Z0-9](?:[a-zA-Z0-9.-]*[a-zA-Z0-9])?$',
        ).hasMatch(host) ||
        host
            .split('.')
            .any(
              (part) =>
                  part.isEmpty ||
                  part.length > 63 ||
                  part.startsWith('-') ||
                  part.endsWith('-'),
            )) {
      return '请输入有效的主机名、IPv4 或 IPv6 地址';
    }
    return null;
  }

  static String? validatePort(String value) {
    final port = int.tryParse(value.trim());
    return port == null || port < 1 || port > 65535 ? '端口须为 1–65535 的整数' : null;
  }

  String get normalizedHost {
    final value = host.trim();
    return value.startsWith('[') && value.endsWith(']')
        ? value.substring(1, value.length - 1)
        : value;
  }

  String get authority => Uri(host: normalizedHost, port: port).authority;

  void validate() {
    if (mode == NetworkProxyMode.manual &&
        (validateHost(host) != null || validatePort('$port') != null)) {
      throw const FormatException('Invalid proxy settings');
    }
  }

  Map<String, Object> toJson() => {
    'mode': mode.name,
    // This is intentionally not part of settings export/diagnostics.
    'host': mode == NetworkProxyMode.manual ? host.trim() : '',
    'port': mode == NetworkProxyMode.manual ? port : 7890,
  };

  factory NetworkProxySettings.fromJson(Map<String, dynamic> json) {
    final mode = NetworkProxyMode.values.firstWhere(
      (mode) => mode.name == json['mode'],
      orElse: () => throw const FormatException('Unknown proxy mode'),
    );
    final settings = NetworkProxySettings(
      mode: mode,
      host: json['host'] is String ? json['host'] as String : '',
      port: json['port'] is int
          ? json['port'] as int
          : (mode == NetworkProxyMode.manual ? 0 : 7890),
    );
    settings.validate();
    return settings;
  }
}

/// A validated single route. Unsupported system protocols must not become DIRECT.
class NetworkProxyRoute {
  const NetworkProxyRoute.direct() : host = null, port = null;
  const NetworkProxyRoute.http(this.host, this.port);
  final String? host;
  final int? port;
  bool get isDirect => host == null;
  String get authority => Uri(host: host, port: port).authority;
  String get directive => isDirect ? 'DIRECT' : 'PROXY $authority';
  String get url => isDirect ? '' : 'http://$authority';

  factory NetworkProxyRoute.parse(String value) {
    if (value.trim() == 'DIRECT') return const NetworkProxyRoute.direct();
    if (!value.startsWith('PROXY ')) {
      throw const FormatException('Unsupported system proxy');
    }
    final uri = Uri.tryParse('http://${value.substring(6).trim()}');
    if (uri == null ||
        uri.userInfo.isNotEmpty ||
        uri.path.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        !uri.hasPort ||
        NetworkProxySettings.validateHost(uri.host) != null ||
        NetworkProxySettings.validatePort('${uri.port}') != null) {
      throw const FormatException('Invalid system proxy');
    }
    return NetworkProxyRoute.http(
      uri.host.replaceAll(RegExp(r'[\[\]]'), ''),
      uri.port,
    );
  }
}
