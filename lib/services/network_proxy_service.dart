import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/network_proxy_settings.dart';
import 'routing_http_client.dart';

/// Safe, actionable playback errors without proxy addresses or credentials.
class NetworkProxyException extends HttpException {
  const NetworkProxyException(super.message);
}

/// One startup snapshot shared by API, images, downloads and native playback.
/// Saving a setting does not disrupt an in-flight download or playing video.
class NetworkProxyService {
  NetworkProxyService({
    Future<SharedPreferences> Function()? preferencesLoader,
    MethodChannel channel = const MethodChannel('com.focubili/network_proxy'),
  }) : _preferencesLoader = preferencesLoader ?? SharedPreferences.getInstance,
       _channel = channel;

  static final instance = NetworkProxyService();
  static const settingsKey = 'network.proxy_settings';
  final Future<SharedPreferences> Function() _preferencesLoader;
  final MethodChannel _channel;
  NetworkProxySettings _active = const NetworkProxySettings();
  bool _initialized = false;
  Future<void>? _initialization;
  Object? _startupError;
  NetworkProxySettings get active => _active;

  Future<NetworkProxySettings> load() async {
    final preferences = await _preferencesLoader();
    final stored = preferences.getString(settingsKey);
    if (stored == null) return const NetworkProxySettings();
    return NetworkProxySettings.fromJson(
      jsonDecode(stored) as Map<String, dynamic>,
    );
  }

  Future<void> save(NetworkProxySettings settings) async {
    settings.validate();
    final preferences = await _preferencesLoader();
    if (!await preferences.setString(
      settingsKey,
      jsonEncode(settings.toJson()),
    )) {
      await preferences.reload();
      throw StateError('Proxy settings were not saved');
    }
  }

  /// Also called by headless subscription engines before their first request.
  Future<void> initialize() => _initialization ??= _initialize();

  Future<void> _initialize() async {
    try {
      _active = await load();
      final activated = await _channel.invokeMapMethod<String, dynamic>(
        'configure',
        {..._active.toJson(), 'host': _active.normalizedHost},
      );
      if (activated != null) {
        _active = NetworkProxySettings.fromJson(activated);
      }
    } catch (error) {
      // Corrupt preferences / unavailable bridges must not leak a direct request.
      // Keep the UI usable so the user can repair settings and restart.
      _startupError = error;
      try {
        final activated = await _channel.invokeMapMethod<String, dynamic>(
          'blockIfUnconfigured',
        );
        if (activated != null) {
          _active = NetworkProxySettings.fromJson(activated);
          _startupError = null;
        }
      } catch (_) {
        // Non-Android platforms have no separate native HTTP stack to block.
      }
    }
    final previous = HttpOverrides.current;
    HttpOverrides.global = RoutingHttpOverrides(
      resolve: resolve,
      previous: previous,
    );
    _initialized = true;
  }

  Future<NetworkProxyRoute> resolve(Uri uri) async {
    if (_startupError != null) {
      throw const HttpException('代理设置未能载入，请检查代理设置并重启应用');
    }
    switch (_active.mode) {
      case NetworkProxyMode.direct:
        return const NetworkProxyRoute.direct();
      case NetworkProxyMode.manual:
        _active.validate();
        return NetworkProxyRoute.http(_active.normalizedHost, _active.port);
      case NetworkProxyMode.system:
        final directive = await _channel
            .invokeMethod<String>('resolve', {'url': uri.toString()})
            .timeout(const Duration(seconds: 10));
        if (directive == null) {
          throw const HttpException('系统代理查询失败');
        }
        // Use the first OS-selected route consistently for Dart and mpv. Never
        // silently fall back to DIRECT after proxy connection/authentication errors.
        return NetworkProxyRoute.parse(directive.split(';').first.trim());
    }
  }

  /// mpv delegates HTTP to FFmpeg. Empty http_proxy explicitly disables inherited
  /// env proxies. FFmpeg only reads no_proxy from the process environment.
  Future<void> configurePlayer({
    required List<Uri> uris,
    required Future<void> Function(String, String) writeProperty,
    bool Function()? isCurrent,
  }) async {
    await _initialization;
    if (!_initialized) {
      return; // Unit-test players do not install app networking.
    }
    final routes = <String>{};
    for (final uri in uris) {
      if (uri.scheme == 'http' || uri.scheme == 'https') {
        try {
          routes.add((await resolve(uri)).url);
        } catch (_) {
          throw const NetworkProxyException('无法解析系统代理，请检查代理设置及平台支持范围。');
        }
      }
    }
    if (routes.length > 1) {
      throw const NetworkProxyException('系统为音视频选择了不同代理，请改用统一的手动代理');
    }
    final proxy = routes.firstOrNull ?? '';
    if (proxy.isNotEmpty &&
        (Platform.environment['no_proxy'] ?? '').isNotEmpty) {
      throw const NetworkProxyException('播放器受 no_proxy 环境变量限制，请移除该变量后重启应用');
    }
    if (isCurrent != null && !isCurrent()) return;
    await writeProperty('http-proxy', proxy);
    await writeProperty('stream-lavf-o', 'http_proxy=$proxy');
    await writeProperty('tls-verify', 'yes');
  }
}
