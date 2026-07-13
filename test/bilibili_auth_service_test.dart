import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:focubili/services/bilibili_auth_service.dart';

/// 用于测试的 Cookie 容器，会记录读取、替换和仅清理 B 站 Cookie 的调用。
class _RecordingCookieStore implements BilibiliCookieStore {
  /// 创建带指定初始 Cookie 的内存 Cookie 容器。
  _RecordingCookieStore({this.cookies = ''});

  String cookies;
  String? replacedCookie;
  int replaceCalls = 0;
  int clearCalls = 0;

  /// 返回测试预设的当前 Cookie 请求头。
  @override
  Future<String> readCookies() async => cookies;

  /// 记录新 Cookie 替换请求，并把它作为后续读取的唯一会话。
  @override
  Future<void> replaceCookies(String cookieHeader) async {
    replaceCalls += 1;
    replacedCookie = cookieHeader;
    cookies = cookieHeader;
  }

  /// 记录仅清理 B 站 Cookie 的请求，并清空测试内存容器。
  @override
  Future<void> clearBilibiliCookies() async {
    clearCalls += 1;
    cookies = '';
  }
}

/// 以回调形式提供可控账号状态响应的测试网络客户端。
class _CallbackAuthApi implements BilibiliAuthApi {
  /// 创建调用指定回调的测试账号状态客户端。
  _CallbackAuthApi(this._handler);

  final Future<BilibiliNavResponse> Function(String cookieHeader) _handler;
  final List<String> requestedCookies = <String>[];

  /// 记录请求 Cookie 后交给测试回调返回固定响应或抛出网络错误。
  @override
  Future<BilibiliNavResponse> requestNavigation(String cookieHeader) {
    requestedCookies.add(cookieHeader);
    return _handler(cookieHeader);
  }
}

/// 创建一份最小的、已确认登录成功的 `/nav` 响应。
BilibiliNavResponse _activeResponse() {
  return const BilibiliNavResponse(
    statusCode: HttpStatus.ok,
    body: '''
      {
        "code": 0,
        "data": {
          "isLogin": true,
          "mid": 42,
          "uname": "测试账号",
          "face": "//i0.hdslb.com/avatar.jpg"
        }
      }
    ''',
  );
}

/// 创建一份官方明确表示未登录的 `/nav` 响应。
BilibiliNavResponse _expiredResponse() {
  return const BilibiliNavResponse(
    statusCode: HttpStatus.ok,
    body: '{"code": -101, "message": "账号未登录"}',
  );
}

void main() {
  /// 验证本机没有会话 Cookie 时会显示“未登录”，且不会发起网络请求。
  test('没有 Cookie 时返回未登录且不请求账号接口', () async {
    final _RecordingCookieStore store = _RecordingCookieStore();
    final _CallbackAuthApi api = _CallbackAuthApi((String _) async {
      fail('未登录状态不应请求账号接口');
    });
    final BilibiliAuthService service = BilibiliAuthService(
      cookieStore: store,
      api: api,
    );

    final BilibiliSessionState session = await service.loadCurrentSession();

    expect(session.status, BilibiliSessionStatus.signedOut);
    expect(api.requestedCookies, isEmpty);
  });

  /// 验证存在 Cookie 且官方拒绝登录时会显示“已过期”，而不是未登录。
  test('官方返回未登录时将现有 Cookie 标记为已过期', () async {
    final _RecordingCookieStore store = _RecordingCookieStore(
      cookies: 'SESSDATA=expired; bili_jct=csrf',
    );
    final BilibiliAuthService service = BilibiliAuthService(
      cookieStore: store,
      api: _CallbackAuthApi((String _) async => _expiredResponse()),
    );

    final BilibiliSessionState session = await service.loadCurrentSession();

    expect(session.status, BilibiliSessionStatus.expired);
    expect(store.cookies, contains('SESSDATA=expired'));
  });

  /// 验证断网只显示网络错误，绝不会自动删除原有 Cookie。
  test('网络错误不清除当前 Cookie', () async {
    final _RecordingCookieStore store = _RecordingCookieStore(
      cookies: 'SESSDATA=still-valid',
    );
    final BilibiliAuthService service = BilibiliAuthService(
      cookieStore: store,
      api: _CallbackAuthApi((String _) async {
        throw const SocketException('offline');
      }),
    );

    final BilibiliSessionState session = await service.loadCurrentSession();

    expect(session.status, BilibiliSessionStatus.networkError);
    expect(store.cookies, 'SESSDATA=still-valid');
    expect(store.clearCalls, 0);
  });

  /// 验证粘贴 Cookie 会先请求官方接口，通过后才替换本机会话。
  test('有效 Cookie 通过官方验证后才写入本机 Cookie 容器', () async {
    final _RecordingCookieStore store = _RecordingCookieStore(
      cookies: 'SESSDATA=old-account',
    );
    final _CallbackAuthApi api = _CallbackAuthApi(
      (String _) async => _activeResponse(),
    );
    final BilibiliAuthService service = BilibiliAuthService(
      cookieStore: store,
      api: api,
    );
    const String newCookie = 'SESSDATA=verified-account; bili_jct=new-csrf';

    final BilibiliAccount account = await service.loginWithCookie(newCookie);

    expect(account.mid, 42);
    expect(api.requestedCookies, <String>[newCookie]);
    expect(store.replaceCalls, 1);
    expect(store.replacedCookie, newCookie);
  });

  /// 验证失效 Cookie 不会覆盖当前登录状态，即使它本身包含 SESSDATA 字段。
  test('失效 Cookie 验证失败时不写入本机容器', () async {
    final _RecordingCookieStore store = _RecordingCookieStore(
      cookies: 'SESSDATA=old-account',
    );
    final BilibiliAuthService service = BilibiliAuthService(
      cookieStore: store,
      api: _CallbackAuthApi((String _) async => _expiredResponse()),
    );

    await expectLater(
      () => service.loginWithCookie('SESSDATA=expired-account'),
      throwsA(isA<BilibiliAuthException>()),
    );

    expect(store.replaceCalls, 0);
    expect(store.cookies, 'SESSDATA=old-account');
  });

  /// 验证验证 Cookie 时断网不会替换或清除当前本机会话。
  test('Cookie 验证网络错误时不写入也不清除当前会话', () async {
    final _RecordingCookieStore store = _RecordingCookieStore(
      cookies: 'SESSDATA=old-account',
    );
    final BilibiliAuthService service = BilibiliAuthService(
      cookieStore: store,
      api: _CallbackAuthApi((String _) async {
        throw const SocketException('offline');
      }),
    );

    await expectLater(
      () => service.loginWithCookie('SESSDATA=unverified-account'),
      throwsA(isA<BilibiliAuthException>()),
    );

    expect(store.replaceCalls, 0);
    expect(store.clearCalls, 0);
    expect(store.cookies, 'SESSDATA=old-account');
  });
}
