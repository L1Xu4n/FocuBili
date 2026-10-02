import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/services/webview_environment_service.dart';

/// 验证公开内核读取失败不阻塞页面，并限定兼容模式适用设备。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/webview_environment');
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null),
  );

  test('旧华为内核启用兼容方式，现代设备保留默认方式', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'getWebViewInfo');
          return {
            'packageName': 'com.huawei.webview',
            'version': '100',
            'manufacturer': 'HUAWEI',
            'apiLevel': 29,
            'providerAvailable': true,
          };
        });
    final info = await const WebViewEnvironmentService(channel: channel).load();
    expect(info.prefersHybridComposition, isTrue);
    expect(info.statusLabel, '已检测到内核');
    expect(
      const WebViewEnvironment(
        manufacturer: 'Huawei',
        apiLevel: 35,
      ).prefersHybridComposition,
      isFalse,
    );
    expect(
      const WebViewEnvironment(
        manufacturer: 'Other',
        apiLevel: 29,
      ).prefersHybridComposition,
      isFalse,
    );
  });

  test('内核查询异常返回未知状态，缺失内核与读取失败可区分', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async {
          throw PlatformException(code: 'unavailable');
        });
    final info = await const WebViewEnvironmentService(channel: channel).load();
    expect(info.providerAvailable, isNull);
    expect(info.statusLabel, '暂时无法读取');
    expect(
      const WebViewEnvironment(providerAvailable: false).statusLabel,
      '未检测到可用内核',
    );
  });
}
