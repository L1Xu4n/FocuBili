import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/services/bilibili_qr_login_service.dart';

/// 验证 B 站 Windows 扫码登录会话生成、轮询状态和 Cookie 边界。
void main() {
  test('生成二维码时固定使用官方 HTTPS 主机', () async {
    late Uri requestedEndpoint;
    final BilibiliQrLoginService service = BilibiliQrLoginService(
      // 固定生成响应用于检查请求地址和字段解析。
      request: (Uri endpoint) async {
        requestedEndpoint = endpoint;
        return const BilibiliQrHttpResponse(
          statusCode: 200,
          body:
              '{"code":0,"data":{"url":"https://passport.bilibili.com/qr-test","qrcode_key":"test-key"}}',
        );
      },
    );

    final BilibiliQrLoginSession session = await service.generate();

    expect(requestedEndpoint.scheme, 'https');
    expect(requestedEndpoint.host, 'passport.bilibili.com');
    expect(requestedEndpoint.path, '/x/passport-login/web/qrcode/generate');
    expect(session.url, 'https://passport.bilibili.com/qr-test');
    expect(session.key, 'test-key');
  });

  test('轮询准确区分未扫码、已扫码和过期', () async {
    final List<int> statusCodes = <int>[86101, 86090, 86038];
    int requestIndex = 0;
    final BilibiliQrLoginService service = BilibiliQrLoginService(
      // 每次轮询依次返回三种官方状态码，验证业务状态映射。
      request: (Uri endpoint) async {
        expect(endpoint.queryParameters['qrcode_key'], 'test-key');
        final int code = statusCodes[requestIndex++];
        return BilibiliQrHttpResponse(
          statusCode: 200,
          body: '{"code":0,"data":{"code":$code}}',
        );
      },
    );

    expect(
      (await service.poll('test-key')).status,
      BilibiliQrLoginStatus.waiting,
    );
    expect(
      (await service.poll('test-key')).status,
      BilibiliQrLoginStatus.scanned,
    );
    expect(
      (await service.poll('test-key')).status,
      BilibiliQrLoginStatus.expired,
    );
  });

  test('确认成功时仅合并 Cookie 名值对并要求 SESSDATA', () async {
    final BilibiliQrLoginService service = BilibiliQrLoginService(
      // 成功响应模拟官方 Set-Cookie 解析后的多个名值对。
      request: (Uri endpoint) async {
        return const BilibiliQrHttpResponse(
          statusCode: 200,
          body: '{"code":0,"data":{"code":0}}',
          cookies: <String>[
            'SESSDATA=session-value',
            'bili_jct=csrf-value',
            'DedeUserID=123',
          ],
        );
      },
    );

    final BilibiliQrLoginPollResult result = await service.poll('test-key');

    expect(result.status, BilibiliQrLoginStatus.confirmed);
    expect(result.cookieHeader, contains('SESSDATA=session-value'));
    expect(result.cookieHeader, contains('bili_jct=csrf-value'));
  });

  test('确认响应缺少 SESSDATA 时拒绝建立会话', () async {
    final BilibiliQrLoginService service = BilibiliQrLoginService(
      // 缺失登录核心 Cookie 的响应不得被误判为可用账号。
      request: (Uri endpoint) async {
        return const BilibiliQrHttpResponse(
          statusCode: 200,
          body: '{"code":0,"data":{"code":0}}',
          cookies: <String>['bili_jct=csrf-value'],
        );
      },
    );

    await expectLater(
      service.poll('test-key'),
      throwsA(
        isA<BilibiliQrLoginException>().having(
          (BilibiliQrLoginException error) => error.message,
          'message',
          contains('会话不完整'),
        ),
      ),
    );
  });
}
