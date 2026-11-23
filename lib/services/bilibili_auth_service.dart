import 'cache_lifecycle.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:crypto/crypto.dart';

import 'app_http_client.dart';
import 'bilibili_cookie_store.dart';
import 'bilibili_cookie_store_factory.dart';
import 'bilibili_wbi_signing_service.dart';

export 'bilibili_cookie_store.dart';
export 'bilibili_cookie_store_factory.dart';

/// 保存 B 站登录成功后“我的”页面需要展示的最小账号信息。
class BilibiliAccount {
  /// 创建包含用户编号、昵称和头像地址的账号状态。
  const BilibiliAccount({
    required this.mid,
    required this.name,
    required this.avatarUrl,
  });

  final int mid;
  final String name;
  final String avatarUrl;
}

/// 列出“我的”页面可区分的 B 站会话状态。
enum BilibiliSessionStatus {
  /// 本机没有可用的登录 Cookie。
  signedOut,

  /// Cookie 已被官方接口确认，账号可以正常使用。
  active,

  /// 本机仍有会话 Cookie，但官方接口明确表示未登录。
  expired,

  /// 网络、服务器或本机桥接暂时无法确认会话，绝不能据此清除 Cookie。
  networkError,
}

/// 保存一次会话检查的结果，避免页面把“未登录”和“暂时不可用”混为一谈。
class BilibiliSessionState {
  /// 创建携带状态、可选账号资料和可展示说明的会话检查结果。
  const BilibiliSessionState({required this.status, this.account, this.message})
    : transientTransportFailure = false;

  /// 创建本机没有登录 Cookie 时使用的未登录结果。
  const BilibiliSessionState.signedOut()
    : status = BilibiliSessionStatus.signedOut,
      account = null,
      message = null,
      transientTransportFailure = false;

  /// 创建官方接口已经确认登录成功时使用的结果。
  const BilibiliSessionState.active(this.account)
    : status = BilibiliSessionStatus.active,
      message = null,
      transientTransportFailure = false;

  /// 创建 Cookie 存在但官方接口明确拒绝登录时使用的过期结果。
  const BilibiliSessionState.expired({this.message = '登录已过期，请重新登录。'})
    : status = BilibiliSessionStatus.expired,
      account = null,
      transientTransportFailure = false;

  /// 创建暂时无法验证会话时使用的结果，保留 Cookie 供稍后重试。
  const BilibiliSessionState.networkError({
    this.message = '暂时无法读取登录状态，请检查网络后重试。',
    this.transientTransportFailure = false,
  }) : status = BilibiliSessionStatus.networkError,
       account = null;

  final BilibiliSessionStatus status;
  final BilibiliAccount? account;
  final String? message;

  /// The remote check hit a transport fault, not a local identity/read fault.
  /// This is only suitable for retaining an already-visible, read-only view.
  final bool transientTransportFailure;

  /// 判断该结果是否包含已被官方确认的账号资料。
  bool get isActive =>
      status == BilibiliSessionStatus.active && account != null;
}

/// 表示登录操作无法继续，并携带不包含 Cookie 内容的中文说明。
class BilibiliAuthException implements Exception {
  /// 创建一条不会暴露 Cookie 内容的登录错误说明。
  const BilibiliAuthException(this.message);

  final String message;

  /// 把异常转换成页面和调试器都容易阅读的文字。
  @override
  String toString() => message;
}

/// 表示账号状态接口的一次 HTTP 响应，便于服务层解析和单元测试替换网络。
class BilibiliNavResponse {
  /// 创建包含状态码和 JSON 正文的账号状态接口响应。
  const BilibiliNavResponse({required this.statusCode, required this.body});

  final int statusCode;
  final String body;
}

/// 抽象出请求 B 站账号状态接口的能力，测试时可用固定响应代替真实网络。
abstract interface class BilibiliAuthApi {
  /// 使用传入的 Cookie 请求官方账号状态接口，且不得记录 Cookie 内容。
  Future<BilibiliNavResponse> requestNavigation(String cookieHeader);
}

/// 使用共享连接请求官方账号状态接口。
class BilibiliHttpAuthApi implements BilibiliAuthApi {
  /// 创建使用官方账号状态地址的网络客户端。
  BilibiliHttpAuthApi({HttpClient Function()? clientFactory})
    : _transport = clientFactory == null
          ? AppHttpTransport.shared
          : AppHttpTransport(clientFactory: clientFactory);

  static final Uri accountEndpoint = Uri.https(
    'api.bilibili.com',
    '/x/web-interface/nav',
  );
  static const String desktopUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
      'AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/126.0.0.0 Safari/537.36';

  final AppHttpTransport _transport;

  /// 携带指定 Cookie 请求官方账号状态接口，并返回未经业务解释的响应。
  @override
  Future<BilibiliNavResponse> requestNavigation(String cookieHeader) async {
    final response = await _transport.send(
      uri: accountEndpoint,
      followRedirects: false,
      timeout: const Duration(seconds: 12),
      headers: {
        HttpHeaders.acceptHeader: 'application/json',
        HttpHeaders.cookieHeader: cookieHeader,
        HttpHeaders.userAgentHeader: desktopUserAgent,
        HttpHeaders.refererHeader: 'https://www.bilibili.com/',
      },
    );
    return BilibiliNavResponse(
      statusCode: response.statusCode,
      body: response.bodyUtf8,
    );
  }
}

/// 验证 B 站会话、导入已验证 Cookie，并且永不保存多账号或密码资料。
class BilibiliAuthService {
  /// 创建可替换网络和 Cookie 容器的登录服务，默认使用当前平台安全存储与真实官方接口。
  BilibiliAuthService({
    BilibiliCookieStore? cookieStore,
    BilibiliAuthApi? api,
    Duration requestTimeout = const Duration(seconds: 12),
  }) : _cookieStore = cookieStore ?? createDefaultBilibiliCookieStore(),
       _api = api ?? BilibiliHttpAuthApi(),
       _usesDefaultStore = cookieStore == null && api == null,
       _display = cookieStore == null && api == null
           ? _sharedDisplay
           : _SessionDisplayCache(),
       _requestTimeout = requestTimeout;

  static final _sharedDisplay = _SessionDisplayCache();
  static final _forcedSessionRead = Object();
  static int _loginGeneration = 0;

  /// Opaque epoch for app-initiated login/logout/replacement, not a credential.
  int get accountMutationGeneration => _loginGeneration;
  static Future<void> _accountWrites = Future.value();

  final BilibiliCookieStore _cookieStore;
  final BilibiliAuthApi _api;
  final Duration _requestTimeout;
  final bool _usesDefaultStore;
  final _SessionDisplayCache _display;

  /// 默认存储跨实例共享，注入存储只与使用同一对象的调用协作。
  Object get _storeScope =>
      _usesDefaultStore ? _cookieStore.runtimeType : _cookieStore;

  /// 记录实际注入的存储种类；平台通道在 Apple 上由 WKWebView 插件处理。
  String get cookieStoreSource => switch (_cookieStore) {
    AppleBilibiliCookieStore() => 'apple_wkwebview',
    PlatformBilibiliCookieStore() => 'platform_webview',
    WindowsSecureBilibiliCookieStore() => 'secure_storage',
    UnavailableBilibiliCookieStore() => 'unavailable',
    _ => 'injected',
  };
  String? _checkedWebSession;
  BilibiliSessionState? _checkedWebSessionState;
  bool _checkedWebSessionWasActive = false;

  /// 读取当前账号会话；[forceRefresh] 为 true 时绕过短时展示缓存立即向服务端复核。
  Future<BilibiliSessionState> loadCurrentSession({bool forceRefresh = false}) {
    if (forceRefresh || Zone.current[_forcedSessionRead] == true) {
      return _loadScopedSession(reuseUnchangedSession: false);
    }
    return _loadDisplaySession();
  }

  /// 让经过账号资料服务转发的敏感复核也发起实时验证。
  static Future<T> withForcedSessionRefresh<T>(Future<T> Function() read) {
    return runZoned(read, zoneValues: {_forcedSessionRead: true});
  }

  /// 每次先读取真实 Cookie，再合并同一快照的展示请求。
  /// 等待共享验证完成，统一处理会话读取错误。
  Future<BilibiliSessionState> _loadDisplaySession() async {
    try {
      await _accountWrites;
      final generation = _loginGeneration;
      final revision = CacheLifecycle.account.value;
      final cookie = (await readCookieHeader().timeout(_requestTimeout)).trim();
      if (generation != _loginGeneration ||
          revision != CacheLifecycle.account.value) {
        return const BilibiliSessionState.networkError(
          message: '账号正在切换，请重新读取登录状态。',
        );
      }
      if (cookie.isEmpty) {
        return await _loadScopedSession(
          reuseUnchangedSession: false,
          displayCookie: cookie,
          displayEpoch: _display.epoch,
        );
      }
      final digest = sha256.convert(utf8.encode(cookie));
      final key = (_storeScope, generation, revision, digest);
      final cached = _display.completed;
      if (cached != null &&
          cached.key == key &&
          DateTime.now().isBefore(cached.until)) {
        return cached.state;
      }
      // 按当前 Zone 隔离在途单飞表，避免不同测试 FakeAsync Zone 互相等待已结束的孤儿 Future。
      final pendingKey = (Zone.current, key);
      final pending = _display.pending[pendingKey];
      if (pending != null) return await pending;
      final epoch = _display.epoch;
      final work = _loadScopedSession(
        reuseUnchangedSession: false,
        displayCookie: cookie,
        displayEpoch: epoch,
      );
      _display.pending[pendingKey] = work;
      try {
        final state = await work;
        if (epoch == _display.epoch &&
            generation == _loginGeneration &&
            (state.status == BilibiliSessionStatus.active ||
                state.status == BilibiliSessionStatus.expired)) {
          final resultScope = state.account == null
              ? 'guest'
              : 'mid:${state.account!.mid}';
          if (CacheLifecycle.accountScope == resultScope) {
            _display.completed = (
              key: (
                _storeScope,
                generation,
                CacheLifecycle.account.value,
                digest,
              ),
              until: DateTime.now().add(const Duration(seconds: 30)),
              state: state,
            );
          }
        }
        return state;
      } finally {
        if (identical(_display.pending[pendingKey], work)) {
          _display.pending.remove(pendingKey);
        }
      }
    } on MissingPluginException {
      return const BilibiliSessionState.networkError(
        message: '当前设备暂不支持读取登录状态，请稍后重试。',
      );
    } catch (_) {
      return const BilibiliSessionState.networkError(
        message: '暂时无法读取本机登录状态，请稍后重试。',
      );
    }
  }

  /// Use the exact in-memory cookie passed to this check's /nav request.
  /// Only the interaction service receives it, never a page or persisted state.
  Future<T?> withVerifiedInteractionSession<T>(
    T Function(int mid, String cookieHeader, int generation, int revision)
    create,
  ) async {
    T? snapshot;
    await _loadScopedSession(
      reuseUnchangedSession: false,
      onVerified: (mid, cookie, generation, revision) {
        snapshot = create(mid, cookie, generation, revision);
      },
    );
    return snapshot;
  }

  /// 登录页轮询复用未变化的已确认结果，手动检测和网络失败仍允许重试。
  Future<BilibiliSessionState> loadCurrentSessionForWebLogin({
    bool force = false,
  }) => _loadScopedSession(reuseUnchangedSession: !force);

  /// 限时读取 Cookie，并按调用场景决定是否复用本次页面生命周期内的验证结果。
  Future<BilibiliSessionState> _loadScopedSession({
    required bool reuseUnchangedSession,
    String? displayCookie,
    int? displayEpoch,
    void Function(int mid, String cookie, int generation, int revision)?
    onVerified,
  }) async {
    if (displayEpoch == null) _display.invalidate();
    await _accountWrites;
    final revision = CacheLifecycle.account.value;
    final generation = _loginGeneration;
    String? verifiedCookie;
    String? navCookie;
    Map? images;
    final result = await _loadCurrentSession(
      reuseUnchangedSession: reuseUnchangedSession,
      knownCookie: displayCookie,
      onNavImages: (cookie, value) {
        navCookie = cookie;
        images = value;
      },
      onVerifiedCookie: onVerified == null
          ? null
          : (cookie) => verifiedCookie = cookie,
    );
    if (displayCookie != null &&
        result.status != BilibiliSessionStatus.networkError &&
        displayCookie !=
            (await readCookieHeader().timeout(_requestTimeout)).trim()) {
      return const BilibiliSessionState.networkError(
        message: '账号正在切换，请重新读取登录状态。',
      );
    }
    if (revision != CacheLifecycle.account.value ||
        generation != _loginGeneration ||
        (displayEpoch != null && displayEpoch != _display.epoch)) {
      return const BilibiliSessionState.networkError(
        message: '账号正在切换，请重新读取登录状态。',
      );
    }
    if (result.isActive) {
      final mid = result.account!.mid;
      final scope = 'mid:$mid';
      // Publishing a newly verified scope advances the revision once.
      final verifiedRevision =
          revision + (CacheLifecycle.accountScope == scope ? 0 : 1);
      await CacheLifecycle.setAccount(mid);
      final cookie = verifiedCookie;
      if (cookie != null &&
          generation == _loginGeneration &&
          verifiedRevision == CacheLifecycle.account.value &&
          scope == CacheLifecycle.accountScope) {
        onVerified?.call(mid, cookie, generation, verifiedRevision);
      }
    } else if (result.status == BilibiliSessionStatus.signedOut ||
        result.status == BilibiliSessionStatus.expired) {
      await CacheLifecycle.setAccount(null);
    }
    if (navCookie != null && generation == _loginGeneration) {
      await _seedSigning(navCookie!, images, generation);
    }
    return result;
  }

  /// 针对指定 Cookie 读取或验证会话，单独保留网页登录的轮询复用。
  Future<BilibiliSessionState> _loadCurrentSession({
    required bool reuseUnchangedSession,
    String? knownCookie,
    required void Function(String, Map) onNavImages,
    void Function(String)? onVerifiedCookie,
  }) async {
    try {
      final String cookieHeader =
          knownCookie ??
          (await readCookieHeader().timeout(_requestTimeout)).trim();
      if (!_containsSessionCookie(cookieHeader)) {
        _checkedWebSession = null;
        _checkedWebSessionState = null;
        _checkedWebSessionWasActive = false;
        return const BilibiliSessionState.signedOut();
      }
      final token = _sessionCookieValue(cookieHeader);
      if (reuseUnchangedSession &&
          token == _checkedWebSession &&
          _checkedWebSessionState != null) {
        return _checkedWebSessionState!;
      }
      final state = await _requestCurrentSession(
        cookieHeader,
        onNavImages: (images) => onNavImages(cookieHeader, images),
      );
      if (state.isActive) onVerifiedCookie?.call(cookieHeader);
      if (state.status == BilibiliSessionStatus.networkError) {
        _checkedWebSessionState = null;
        // A transport failure cannot establish identity. Retain only the
        // existing token equality signal, never a reusable active result.
        if (state.transientTransportFailure &&
            _checkedWebSessionWasActive &&
            token == _checkedWebSession) {
          return state;
        }
        _checkedWebSession = null;
        _checkedWebSessionWasActive = false;
        return BilibiliSessionState.networkError(
          message: state.message ?? '暂时无法读取登录状态，请检查网络后重试。',
        );
      } else {
        _checkedWebSession = token;
        _checkedWebSessionState = state;
        _checkedWebSessionWasActive = state.isActive;
      }
      return state;
    } on PlatformException {
      return const BilibiliSessionState.networkError(
        message: '暂时无法读取本机登录状态，请稍后重试。',
      );
    } on MissingPluginException {
      return const BilibiliSessionState.networkError(
        message: '当前设备暂不支持读取登录状态，请稍后重试。',
      );
    } catch (_) {
      return const BilibiliSessionState.networkError(
        message: '暂时无法读取本机登录状态，请稍后重试。',
      );
    }
  }

  /// 兼容旧调用方：只在会话确认为有效时返回账号，其余状态返回 null。
  Future<BilibiliAccount?> loadCurrentAccount() async {
    return (await loadCurrentSession()).account;
  }

  /// 先用官方接口验证用户粘贴的 Cookie，成功后才替换本机 B 站 Cookie。
  Future<BilibiliAccount> loginWithCookie(String rawCookie) async {
    _display.invalidate();
    final String cookie = rawCookie.trim();
    if (!_containsSessionCookie(cookie)) {
      throw const BilibiliAuthException('Cookie 中没有找到有效的 SESSDATA，无法建立登录状态。');
    }
    final generation = ++_loginGeneration;
    Map? images;
    final verifiedSession = await _requestCurrentSession(
      cookie,
      onNavImages: (value) => images = value,
    );
    if (verifiedSession.status == BilibiliSessionStatus.networkError) {
      throw BilibiliAuthException(
        verifiedSession.message ?? '暂时无法验证 Cookie，请检查网络后重试。',
      );
    }
    if (!verifiedSession.isActive) {
      await _seedSigning(cookie, images, generation);
      throw const BilibiliAuthException('Cookie 已失效，B 站没有确认登录状态。');
    }
    await _commitAccount(generation, () async {
      await _saveVerifiedCookies(cookie);
      await CacheLifecycle.setAccount(verifiedSession.account!.mid);
    });
    await _seedSigning(cookie, images, generation);
    return verifiedSession.account!;
  }

  /// 检查 Windows 官方网页产生的 Cookie 快照，返回可区分成功、未登录和网络故障的结果。
  Future<BilibiliSessionState> verifyAndSaveWebCookieSnapshot(
    String rawCookie,
  ) async {
    _display.invalidate();
    final String cookie = rawCookie.trim();
    if (cookie.isEmpty) {
      return const BilibiliSessionState.signedOut();
    }
    final generation = ++_loginGeneration;
    Map? images;
    final verifiedSession = await _requestCurrentSession(
      cookie,
      onNavImages: (value) => images = value,
    );
    if (generation == _loginGeneration && !verifiedSession.isActive) {
      await _seedSigning(cookie, images, generation);
    }
    if (!verifiedSession.isActive) {
      return verifiedSession;
    }
    await _commitAccount(generation, () async {
      await _saveVerifiedCookies(cookie);
      await CacheLifecycle.setAccount(verifiedSession.account!.mid);
    });
    await _seedSigning(cookie, images, generation);
    return verifiedSession;
  }

  /// 接收同一 WebView2 会话直接取得的官方 nav 响应，并在成功时保存完整浏览器 Cookie。
  Future<BilibiliSessionState> saveBrowserVerifiedSession({
    required String responseText,
    required String rawCookie,
  }) async {
    _display.invalidate();
    final generation = ++_loginGeneration;
    Map? images;
    final BilibiliSessionState verifiedSession;
    try {
      verifiedSession = _parseCurrentSession(
        responseText,
        onNavImages: (value) => images = value,
      );
    } on FormatException {
      return const BilibiliSessionState.networkError(
        message: '网页登录状态数据无法解析，请重新打开登录窗口。',
      );
    }
    if (!verifiedSession.isActive) {
      if (rawCookie.trim().isNotEmpty) {
        await _seedSigning(rawCookie, images, generation);
      }
      return verifiedSession;
    }
    final String cookie = rawCookie.trim();
    if (!_containsSessionCookie(cookie)) {
      return const BilibiliSessionState.networkError(
        message: '网页已确认登录，但没有读取到完整会话，请重新打开登录窗口。',
      );
    }
    await _commitAccount(generation, () async {
      await _saveVerifiedCookies(cookie);
      await CacheLifecycle.setAccount(verifiedSession.account!.mid);
    });
    await _seedSigning(cookie, images, generation);
    return verifiedSession;
  }

  /// 从当前平台的安全会话容器读取 Cookie 请求头，不创建额外明文副本。
  Future<String> readCookieHeader() => _cookieStore.readCookies();

  /// For classroom metadata: never read the old cookie mid-replacement.
  Future<String> readStableCookieHeader() async {
    await _accountWrites;
    return readCookieHeader();
  }

  /// Capture only after local account writes finish; Apple additionally fences
  /// mutations performed by WKWebView itself, independent of Dart login state.
  Future<BilibiliPlaybackSession> capturePlaybackSession(String path) async {
    await _accountWrites;
    final generation = _loginGeneration;
    final revision = CacheLifecycle.account.value;
    final native = _cookieStore is BilibiliPlaybackSessionStore
        ? _cookieStore as BilibiliPlaybackSessionStore
        : null;
    final BilibiliPlaybackCookieSnapshot snapshot;
    if (native != null) {
      snapshot = await BilibiliPlaybackSession._nativeCall(
        () => native.readPlaybackSession(path),
      );
    } else {
      final header = await _cookieStore.readCookies();
      final hasSession = RegExp(r'(?:^|;)\s*SESSDATA=([^;]+)').hasMatch(header);
      snapshot = BilibiliPlaybackCookieSnapshot(
        header: header,
        state: hasSession ? 'session' : 'anonymous',
        generation: generation,
      );
    }
    if (generation != _loginGeneration ||
        revision != CacheLifecycle.account.value) {
      throw const BilibiliPlaybackSessionException('changing');
    }
    if (!snapshot.usable) {
      throw BilibiliPlaybackSessionException(snapshot.state);
    }
    return BilibiliPlaybackSession._(
      snapshot,
      native,
      generation,
      revision,
      path,
      this,
    );
  }

  /// 仅供用户明确确认的本地导出读取稳定快照，账号变更期间拒绝导出。
  Future<String> readCookieForExport() async {
    final generation = _loginGeneration;
    await _accountWrites;
    final cookie = await _cookieStore.readCookies();
    if (generation != _loginGeneration || !_containsSessionCookie(cookie)) {
      throw const BilibiliAuthException('登录状态为空或正在切换，请稍后重试。');
    }
    return cookie;
  }

  /// 仅清理 B 站域 Cookie，用于退出或切换账号，不会自动响应网络错误。
  Future<void> clearBilibiliSession() async {
    _display.invalidate();
    final generation = ++_loginGeneration;
    await _commitAccount(generation, () async {
      await _cookieStore.clearBilibiliCookies();
      await CacheLifecycle.setAccount(null);
    });
  }

  /// Cookie replacement and the matching public cache scope form one ordered
  /// transaction across auth service instances. A late verification cannot
  /// overwrite a newer login/logout, and readers wait for a completed write.
  Future<void> _commitAccount(
    int generation,
    Future<void> Function() write,
  ) async {
    final operation = _accountWrites.then((_) async {
      if (generation != _loginGeneration) {
        throw const BilibiliAuthException('登录操作已被更新的账号操作取代。');
      }
      CacheLifecycle.accountChanged();
      try {
        await write();
        _checkedWebSession = null;
        _checkedWebSessionState = null;
        _checkedWebSessionWasActive = false;
      } finally {
        CacheLifecycle.accountChanged();
      }
    });
    _accountWrites = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    await operation;
    if (generation != _loginGeneration) {
      throw const BilibiliAuthException('登录操作已被更新的账号操作取代。');
    }
  }

  /// 保留退出登录名称，实际执行仅清理 B 站域 Cookie 的安全操作。
  Future<void> logout() => clearBilibiliSession();

  /// 判断 Cookie 请求头中是否包含非空的登录会话标识，不读取或输出具体值。
  bool _containsSessionCookie(String cookie) {
    return _sessionCookieValue(cookie).isNotEmpty;
  }

  /// 仅在内存中比较会话标识，避免网页登录轮询反复请求相同的过期会话。
  String _sessionCookieValue(String cookie) {
    final RegExpMatch? match = RegExp(
      r'(^|;\s*)SESSDATA=([^;]+)',
      caseSensitive: false,
    ).firstMatch(cookie);
    return match?.group(2)?.trim() ?? '';
  }

  /// 把已经通过官方接口确认的 Cookie 保存到当前平台的安全单账号容器。
  Future<void> _saveVerifiedCookies(String cookie) async {
    try {
      await _cookieStore.replaceCookies(cookie);
    } on PlatformException {
      throw const BilibiliAuthException('Cookie 已验证，但暂时无法保存到本机，请重试。');
    } on MissingPluginException {
      throw const BilibiliAuthException('当前设备暂不支持保存 Cookie，请稍后重试。');
    } catch (_) {
      throw const BilibiliAuthException('Cookie 已验证，但暂时无法保存到本机，请重试。');
    }
  }

  /// 请求账号状态接口，并把官方明确的未登录结果和暂时故障分开处理。
  Future<BilibiliSessionState> _requestCurrentSession(
    String cookieHeader, {
    void Function(Map)? onNavImages,
  }) async {
    try {
      final BilibiliNavResponse response = await _api
          .requestNavigation(cookieHeader)
          .timeout(_requestTimeout);
      if (response.statusCode != HttpStatus.ok) {
        return BilibiliSessionState.networkError(
          message: '登录状态服务暂时不可用（HTTP ${response.statusCode}）。',
          transientTransportFailure:
              response.statusCode >= 500 && response.statusCode < 600,
        );
      }
      return _parseCurrentSession(response.body, onNavImages: onNavImages);
    } on SocketException {
      return const BilibiliSessionState.networkError(
        message: '无法连接到登录状态服务，请检查网络。',
        transientTransportFailure: true,
      );
    } on HttpException {
      return const BilibiliSessionState.networkError(
        message: '登录状态网络响应异常，请稍后重试。',
        transientTransportFailure: true,
      );
    } on TimeoutException {
      return const BilibiliSessionState.networkError(
        message: '验证登录状态超时，请检查网络后重试。',
        transientTransportFailure: true,
      );
    } on FormatException {
      return const BilibiliSessionState.networkError(
        message: '登录状态数据无法解析，请稍后重试。',
      );
    } catch (_) {
      return const BilibiliSessionState.networkError(
        message: '暂时无法读取登录状态，请稍后重试。',
      );
    }
  }

  /// 解析账号状态 JSON；只有官方明确的未登录信号才会被判断为会话过期。
  BilibiliSessionState _parseCurrentSession(
    String responseText, {
    void Function(Map)? onNavImages,
  }) {
    final Object? decoded = jsonDecode(responseText);
    if (decoded is! Map) {
      throw const FormatException('账号状态根节点不是对象。');
    }
    final Map<Object?, Object?> root = Map<Object?, Object?>.from(decoded);
    final int code = (root['code'] as num?)?.toInt() ?? -1;
    final Object? rawData = root['data'];
    if ((code == 0 || code == -101) && rawData is Map) {
      final images = rawData['wbi_img'];
      if (images is Map) onNavImages?.call(images);
    }
    if (code == -101) {
      return const BilibiliSessionState.expired();
    }
    if (code != 0 || rawData is! Map) {
      return const BilibiliSessionState.networkError(
        message: '登录状态服务暂时不可用，请稍后重试。',
      );
    }
    final Map<Object?, Object?> data = Map<Object?, Object?>.from(rawData);
    if (data['isLogin'] != true) {
      return const BilibiliSessionState.expired();
    }
    return BilibiliSessionState.active(
      BilibiliAccount(
        mid: (data['mid'] as num?)?.toInt() ?? 0,
        name: _readText(data['uname'], '已登录用户'),
        avatarUrl: _normalizeHttpsUrl(_readText(data['face'], '')),
      ),
    );
  }

  /// 以会话令牌摘要构建签名作用域，兼容不同请求路径上的 Cookie 子集。
  Object _signingScope(
    String cookie,
    int generation,
    int revision, [
    int? nativeGeneration,
  ]) => (
    _storeScope,
    generation,
    revision,
    nativeGeneration,
    sha256.convert(utf8.encode(_sessionCookieValue(cookie))),
  );

  /// 把已验证的 nav 签名材料提供给同一会话的元数据请求。
  Future<void> _seedSigning(String cookie, Map? images, int generation) async {
    if (images == null || generation != _loginGeneration) return;
    final revision = CacheLifecycle.account.value;
    int? nativeGeneration;
    final store = _cookieStore;
    if (store is BilibiliPlaybackSessionStore) {
      try {
        final native = store as BilibiliPlaybackSessionStore;
        final snapshot = await native
            .readPlaybackSession('/x/web-interface/nav')
            .timeout(_requestTimeout);
        if (!snapshot.usable ||
            _sessionCookieValue(cookie) !=
                _sessionCookieValue(snapshot.header)) {
          return;
        }
        nativeGeneration = snapshot.generation;
      } catch (_) {
        // 签名材料预热只是复用机会，不能改变账号验证结果。
        return;
      }
    }
    if (generation != _loginGeneration ||
        revision != CacheLifecycle.account.value) {
      return;
    }
    BilibiliWbiSigningService.shared.seedFromNavImages(
      _signingScope(cookie, generation, revision, nativeGeneration),
      images['img_url'],
      images['sub_url'],
    );
  }

  /// 把未知字段安全转换为非空文字，空内容使用指定默认值。
  String _readText(Object? value, String fallback) {
    final String text = value is String ? value.trim() : '';
    return text.isEmpty ? fallback : text;
  }

  /// 只接受 HTTPS 头像地址，并补全 B 站常见的省略协议写法。
  String _normalizeHttpsUrl(String value) {
    if (value.startsWith('//')) {
      return 'https:$value';
    }
    return value.startsWith('https://') ? value : '';
  }
}

/// 保存展示读及其失效代次，强制验证会把旧请求从单飞表移除。
class _SessionDisplayCache {
  int epoch = 0;
  ({Object key, DateTime until, BilibiliSessionState state})? completed;
  final pending = <Object, Future<BilibiliSessionState>>{};

  /// 拒绝旧请求的回填并清除当前展示结果。
  void invalidate() {
    epoch++;
    completed = null;
    pending.clear();
  }
}

/// Request-scoped session guard. Headers and native revision stay in memory.
class BilibiliPlaybackSession {
  BilibiliPlaybackSession._(
    this.snapshot,
    this._native,
    this._localGeneration,
    this._revision,
    this._path,
    BilibiliAuthService auth,
  ) : signingScopeKey = auth._signingScope(
        snapshot.header,
        _localGeneration,
        _revision,
        _native == null ? null : snapshot.generation,
      );
  BilibiliPlaybackCookieSnapshot snapshot;
  final BilibiliPlaybackSessionStore? _native;
  final int _localGeneration;
  final int _revision;
  final String _path;
  final Object signingScopeKey;

  static Future<T> _nativeCall<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on BilibiliPlaybackSessionException {
      rethrow;
    } catch (_) {
      throw const BilibiliPlaybackSessionException('unknown');
    }
  }

  Future<void> _checkLocal() async {
    await BilibiliAuthService._accountWrites;
    if (_localGeneration != BilibiliAuthService._loginGeneration ||
        _revision != CacheLifecycle.account.value) {
      throw const BilibiliPlaybackSessionException('changing');
    }
  }

  void _accept(BilibiliPlaybackCookieSnapshot next) {
    if (!next.usable) throw BilibiliPlaybackSessionException(next.state);
    if (next.generation != snapshot.generation) {
      throw const BilibiliPlaybackSessionException('changing');
    }
    snapshot = next;
  }

  /// Opaque request identity; never exported or persisted.
  Object get scopeKey => (signingScopeKey, snapshot.state);

  /// A native playback store selects cookies against each exact request path.
  bool get hasScopedCookieHeaders => _native != null;

  Future<String> headerFor(String path) async {
    await _checkLocal();
    if (_native case final native?) {
      _accept(await _nativeCall(() => native.readPlaybackSession(path)));
    }
    await _checkLocal();
    return snapshot.header;
  }

  Future<void> mergeResponse(String path, List<String> cookies) async {
    await _checkLocal();
    if (_native case final native? when cookies.isNotEmpty) {
      _accept(
        await _nativeCall(
          () => native.mergePlaybackResponseCookies(
            snapshot.generation,
            path,
            cookies,
          ),
        ),
      );
    }
    await _checkLocal();
  }

  Future<void> validate() async {
    await _checkLocal();
    if (_native case final native?) {
      if (!await _nativeCall(
        () => native.validatePlaybackSession(snapshot.generation, _path),
      )) {
        throw const BilibiliPlaybackSessionException('changing');
      }
    }
    await _checkLocal();
  }
}
