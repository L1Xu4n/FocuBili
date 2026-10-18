import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 抽象出 B 站 Cookie 安全容器，业务层不需要知道平台存储细节。
abstract interface class BilibiliCookieStore {
  /// 读取 B 站域可用于请求的 Cookie 请求头。
  Future<String> readCookies();

  /// 清理旧 B 站 Cookie 后写入已验证的新 Cookie，完成单账号替换。
  Future<void> replaceCookies(String cookieHeader);

  /// 仅清理 B 站域 Cookie，不影响应用中的其他本机数据。
  Future<void> clearBilibiliCookies();
}

/// 通过 Android 方法通道访问应用 WebView Cookie 容器。
class PlatformBilibiliCookieStore implements BilibiliCookieStore {
  /// 创建使用 FocuBili Android 登录通道的 Cookie 存储实现。
  const PlatformBilibiliCookieStore();

  static const MethodChannel _channel = MethodChannel('com.focubili.app/auth');

  /// 从 Android WebView 的 B 站域读取 Cookie，不在 Dart 中持久化副本。
  @override
  Future<String> readCookies() async {
    final String? cookie = await _channel.invokeMethod<String>('readCookies');
    return cookie?.trim() ?? '';
  }

  /// 调用 Android 原子替换操作，只在新 Cookie 已被官方验证后保存。
  @override
  Future<void> replaceCookies(String cookieHeader) {
    return _channel.invokeMethod<void>('replaceCookies', <String, Object?>{
      'cookie': cookieHeader,
    });
  }

  /// 调用 Android 仅清理 B 站域 Cookie 的操作，用于退出和切换账号。
  @override
  Future<void> clearBilibiliCookies() {
    return _channel.invokeMethod<void>('clearBilibiliCookies');
  }
}

/// 使用 Windows 凭据管理器保护的加密存储保存当前单账号 Cookie。
class WindowsSecureBilibiliCookieStore implements BilibiliCookieStore {
  /// 创建 Windows 安全 Cookie 存储；测试可以注入不会访问系统凭据的实例。
  WindowsSecureBilibiliCookieStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  static const String _cookieKey = 'focubili_bilibili_cookie';
  final FlutterSecureStorage _storage;

  /// 从 Windows 加密存储读取 Cookie，并在不存在时返回空字符串。
  @override
  Future<String> readCookies() async {
    return (await _storage.read(key: _cookieKey))?.trim() ?? '';
  }

  /// 把已经通过官方接口验证的 Cookie 原子写入 Windows 加密存储。
  @override
  Future<void> replaceCookies(String cookieHeader) {
    return _storage.write(key: _cookieKey, value: cookieHeader.trim());
  }

  /// 删除 Windows 中唯一的 B 站会话，不影响应用其他本机设置。
  @override
  Future<void> clearBilibiliCookies() {
    return _storage.delete(key: _cookieKey);
  }
}

/// 为尚未实现安全会话容器的平台提供明确不可用行为。
class UnavailableBilibiliCookieStore implements BilibiliCookieStore {
  /// 创建不会读取或保存任何敏感会话的不可用实现。
  const UnavailableBilibiliCookieStore();

  /// 未支持平台始终视为没有登录会话。
  @override
  Future<String> readCookies() async => '';

  /// 拒绝在没有安全存储方案的平台保存 Cookie。
  @override
  Future<void> replaceCookies(String cookieHeader) async {
    throw UnsupportedError('当前平台暂不支持安全保存 B 站登录会话。');
  }

  /// 未支持平台没有已保存会话，因此清理操作安全返回。
  @override
  Future<void> clearBilibiliCookies() async {}
}

/// An endpoint-scoped, in-memory native snapshot. Never stringify its header.
class BilibiliPlaybackCookieSnapshot {
  const BilibiliPlaybackCookieSnapshot({
    required this.header,
    required this.state,
    required this.generation,
  });
  final String header;
  final String state;
  final int generation;
  bool get usable => state == 'session' || state == 'anonymous';

  factory BilibiliPlaybackCookieSnapshot.fromMap(Map<String, dynamic>? map) {
    final state = map?['state'];
    final generation = map?['generation'];
    final header = map?['header'];
    if (generation is! int ||
        generation < 0 ||
        header is! String ||
        !{
          'session',
          'anonymous',
          'partial',
          'conflict',
          'changing',
          'unknown',
        }.contains(state)) {
      throw const BilibiliPlaybackSessionException('unknown');
    }
    return BilibiliPlaybackCookieSnapshot(
      header: header,
      state: state as String,
      generation: generation,
    );
  }
}

class BilibiliPlaybackSessionException implements Exception {
  const BilibiliPlaybackSessionException(this.state);
  final String state;
  @override
  String toString() => switch (state) {
    'conflict' => '登录会话存在冲突，请到“我的”重新登录。',
    'partial' => '登录会话不完整，请到“我的”重新登录。',
    'changing' => '登录状态已变化，请重新打开视频。',
    _ => '暂时无法读取播放会话，请稍后重试。',
  };
}

abstract interface class BilibiliPlaybackSessionStore {
  Future<BilibiliPlaybackCookieSnapshot> readPlaybackSession(String path);
  Future<bool> validatePlaybackSession(int generation, String path);
  Future<BilibiliPlaybackCookieSnapshot> mergePlaybackResponseCookies(
    int generation,
    String path,
    List<String> cookies,
  );
}

/// Apple uses its WK container's scoped transaction protocol. Android retains
/// the existing native 1.7.1 playback/session implementation unchanged.
class AppleBilibiliCookieStore extends PlatformBilibiliCookieStore
    implements BilibiliPlaybackSessionStore {
  const AppleBilibiliCookieStore();
  static const _timeout = Duration(seconds: 12);
  @override
  Future<BilibiliPlaybackCookieSnapshot> readPlaybackSession(
    String path,
  ) async {
    final map = await PlatformBilibiliCookieStore._channel
        .invokeMapMethod<String, dynamic>('readPlaybackSession', {'path': path})
        .timeout(_timeout);
    return BilibiliPlaybackCookieSnapshot.fromMap(map);
  }

  @override
  Future<bool> validatePlaybackSession(int generation, String path) async =>
      await PlatformBilibiliCookieStore._channel
          .invokeMethod<bool>('validatePlaybackSession', {
            'generation': generation,
            'path': path,
          })
          .timeout(_timeout) ==
      true;
  @override
  Future<BilibiliPlaybackCookieSnapshot> mergePlaybackResponseCookies(
    int generation,
    String path,
    List<String> cookies,
  ) async {
    final map = await PlatformBilibiliCookieStore._channel
        .invokeMapMethod<String, dynamic>('mergePlaybackResponseCookies', {
          'generation': generation,
          'path': path,
          'cookies': cookies,
        })
        .timeout(_timeout);
    return BilibiliPlaybackCookieSnapshot.fromMap(map);
  }
}
