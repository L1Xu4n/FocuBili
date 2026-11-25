import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/services/bilibili_wbi_signing_service.dart';

const _imageKey = '7cd084941338484aae1ad9425b84077c';
const _subKey = '4932caff0ff746eab6f01bf08b70ac45';
const _nav =
    '{"code":-101,"data":{"wbi_img":{'
    '"img_url":"https://i0.hdslb.com/$_imageKey.png",'
    '"sub_url":"https://i0.hdslb.com/$_subKey.png"}}}';

/// 核对作用域播种、单飞和失效后迟到的签名材料。
void main() {
  test('nav 播种只服务于相同作用域', () async {
    var requests = 0;
    final signer = BilibiliWbiSigningService(
      requestJson: (_, _) async {
        requests++;
        return _nav;
      },
    );
    signer.seedFromNavImages(
      'A',
      'https://i0.hdslb.com/$_imageKey.png',
      'https://i0.hdslb.com/$_subKey.png',
    );
    await signer.signParameters({}, headers: {}, scopeKey: 'A');
    expect(requests, 0);
    await signer.signParameters({}, headers: {}, scopeKey: 'B');
    expect(requests, 1);
  });

  test('invalidate 后旧单飞拒绝回填，已开始的新请求保持可用', () async {
    final old = Completer<String>();
    final fresh = Completer<String>();
    var requests = 0;
    final signer = BilibiliWbiSigningService(
      requestJson: (_, _) {
        return ++requests == 1 ? old.future : fresh.future;
      },
    );

    /// 读取同一个签名作用域。
    Future<Map<String, String>> sign() =>
        signer.signParameters({}, headers: {}, scopeKey: 'A');

    final rejected = [
      expectLater(sign(), throwsA(isA<WbiSigningException>())),
      expectLater(sign(), throwsA(isA<WbiSigningException>())),
    ];
    expect(requests, 1);
    signer.invalidate('A');
    final current = sign();
    fresh.complete(_nav);
    expect((await current)['w_rid'], isNotEmpty);
    old.complete(_nav);
    await Future.wait(rejected);
    expect((await sign())['w_rid'], isNotEmpty);
    expect(requests, 2);
  });
}
