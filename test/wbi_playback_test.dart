import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/features/profile/personalization_settings_page.dart';
import 'package:focubili/models/video_preview.dart';
import 'package:focubili/platform/app_platform.dart';
import 'package:focubili/services/app_behavior_preferences_service.dart';
import 'package:focubili/services/bilibili_auth_service.dart';
import 'package:focubili/services/bilibili_wbi_signing_service.dart';
import 'package:focubili/services/desktop_playback_source_service.dart';
import 'package:focubili/services/native_playback_service.dart';

const _imageKey = '7cd084941338484aae1ad9425b84077c';
const _subKey = '4932caff0ff746eab6f01bf08b70ac45';
const _nav =
    '{"code":-101,"data":{"wbi_img":{'
    '"img_url":"https://i0.hdslb.com/bfs/wbi/$_imageKey.png",'
    '"sub_url":"https://i0.hdslb.com/bfs/wbi/$_subKey.png"}}}';

/// 隔离真实会话，让请求测试只使用明确的虚构 Cookie。
class _CookieStore implements BilibiliCookieStore {
  /// 返回虚构会话，验证 nav 和播放请求使用同一份凭据。
  @override
  Future<String> readCookies() async => 'SESSDATA=fake-test';

  /// 测试不执行登录或账号写入。
  @override
  Future<void> replaceCookies(String cookieHeader) async {}

  /// 测试不清除任何真实账号。
  @override
  Future<void> clearBilibiliCookies() async {}
}

/// 模拟磁盘写入失败，检查设置页回滚而不是显示伪成功。
class _RejectWbiPreferences extends AppBehaviorPreferencesService {
  /// 明确拒绝保存开关。
  @override
  Future<bool> saveWbiSigningEnabled(bool enabled) async => false;
}

/// 只验证 WBI 相关规则、设置与两端请求交接，不连接真实网站。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.focubili.app/playback');

  /// 每项检查从空白内存偏好开始，确保新开关默认关闭。
  setUp(() => SharedPreferences.setMockInitialValues({}));

  /// 移除测试通道，避免干扰其他播放服务检查。
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  /// 用固定材料核验混合键与摘要；参考摘要由 Python hashlib 独立计算。
  test('WBI 固定材料和时间戳产生已知签名', () {
    final key = BilibiliWbiSigningService.deriveMixinKey(_imageKey, _subKey);
    expect(key, 'ea1db124af3c7062474693fa704f4ff8');
    final signed = BilibiliWbiSigningService.sign(
      {'foo': '114', 'bar': '514', 'baz': '1919810'},
      key,
      1702204169,
    );
    expect(signed['w_rid'], '6149fdadf571698ca7e6a567265cd0ee');
    expect(signed['wts'], '1702204169');
  });

  /// 防止空格、中文及特殊字符让线上查询串与摘要计算串不同。
  test('WBI 清洗值、覆盖旧签名并使用百分号编码', () {
    final signed = BilibiliWbiSigningService.sign(
      {'z': "a!b'()* 中文", 'wts': '1', 'w_rid': 'stale'},
      BilibiliWbiSigningService.deriveMixinKey(_imageKey, _subKey),
      123,
    );
    expect(signed['z'], 'ab 中文');
    expect(signed['wts'], '123');
    expect(signed['w_rid'], isNot('stale'));
    expect(
      BilibiliWbiSigningService.encodeQuery({'z': signed['z']!, 'a': '1'}),
      'a=1&z=ab%20%E4%B8%AD%E6%96%87',
    );
  });

  /// 游客仍可签名，并发不重复获取材料，一小时后刷新。
  test('游客材料可用、并发共享获取且过期刷新', () async {
    var requests = 0;
    var now = DateTime.fromMillisecondsSinceEpoch(1702204169000);
    final signer = BilibiliWbiSigningService(
      clock: () => now,
      requestJson: (endpoint, headers) async {
        requests++;
        expect(endpoint.path, '/x/web-interface/nav');
        await Future<void>.delayed(Duration.zero);
        return _nav;
      },
    );
    await Future.wait([
      signer.signParameters({'bvid': 'BV1GJ411x7h7'}, headers: {}),
      signer.signParameters({'bvid': 'BV1GJ411x7h7'}, headers: {}),
    ]);
    expect(requests, 1);
    now = now.add(const Duration(hours: 1));
    await signer.signParameters({'bvid': 'BV1GJ411x7h7'}, headers: {});
    expect(requests, 2);
  });

  /// 材料损坏时失败不缓存，下一次请求能够重新获取。
  test('损坏材料明确失败且可重新获取', () async {
    var requests = 0;
    final signer = BilibiliWbiSigningService(
      requestJson: (endpoint, headers) async {
        requests++;
        return requests == 1 ? '{"code":0,"data":{}}' : _nav;
      },
    );
    await expectLater(
      signer.signParameters({}, headers: {}),
      throwsA(isA<WbiSigningException>()),
    );
    expect(await signer.signParameters({}, headers: {}), contains('w_rid'));
    expect(requests, 2);
  });

  /// 配置不依赖已有用户升级状态，打开和切清晰度都携带最新保存值。
  test('默认关闭且 Android 打开与清晰度传递新模式', () async {
    final preferences = AppBehaviorPreferencesService();
    expect(await preferences.loadWbiSigningEnabled(), isFalse);
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return null;
        });
    final service = NativePlaybackService(behaviorPreferences: preferences);
    await service.openVideo(VideoPreview.placeholder());
    expect((calls.last.arguments as Map)['wbiEnabled'], isFalse);
    expect(await preferences.saveWbiSigningEnabled(true), isTrue);
    await service.selectQuality(80);
    expect((calls.last.arguments as Map)['wbiEnabled'], isTrue);
    await service.openVideo(VideoPreview.placeholder());
    expect((calls.last.arguments as Map)['wbiEnabled'], isTrue);
    expect(await preferences.saveWbiSigningEnabled(false), isTrue);
    await service.selectQuality(64);
    expect((calls.last.arguments as Map)['wbiEnabled'], isFalse);
    await service.dispose();
  });

  /// 同一服务实例切模式立即生效；-351 不产生自动回退或重试请求。
  test('桌面请求模式切换并按开关状态提示 -351', () async {
    final preferences = AppBehaviorPreferencesService();
    final endpoints = <Uri>[];
    final service = BilibiliDesktopPlaybackSourceService(
      behaviorPreferences: preferences,
      authService: BilibiliAuthService(cookieStore: _CookieStore()),
      requestJson: (endpoint, headers) async {
        endpoints.add(endpoint);
        expect(headers['Cookie'], 'SESSDATA=fake-test');
        return endpoint.path.endsWith('/nav')
            ? _nav
            : '{"code":-351,"message":"受到神秘力量干扰"}';
      },
    );
    await expectLater(
      service.load(bvid: 'BV1GJ411x7h7', cid: 1, quality: 64),
      throwsA(predicate((error) => error.toString().contains('开启“启用 WBI 签名”'))),
    );
    expect(endpoints.single.path, '/x/player/playurl');
    await preferences.saveWbiSigningEnabled(true);
    await expectLater(
      service.load(bvid: 'BV1GJ411x7h7', cid: 1, quality: 64),
      throwsA(predicate((error) => error.toString().contains('WBI 签名已启用'))),
    );
    expect(endpoints.map((uri) => uri.path), [
      '/x/player/playurl',
      '/x/web-interface/nav',
      '/x/player/wbi/playurl',
    ]);
    expect(endpoints.last.queryParameters['w_rid'], matches(r'^[0-9a-f]{32}$'));
    expect(endpoints.last.queryParameters['fnval'], '16');
    await preferences.saveWbiSigningEnabled(false);
    await expectLater(
      service.load(bvid: 'BV1GJ411x7h7', cid: 1, quality: 64),
      throwsException,
    );
    expect(endpoints.last.path, '/x/player/playurl');
    expect(endpoints, hasLength(4));
  });

  /// 开启后材料不可用应明确报错，不额外调用无签名播放接口。
  test('桌面签名材料失败不静默回退游客或旧接口', () async {
    final preferences = AppBehaviorPreferencesService();
    await preferences.saveWbiSigningEnabled(true);
    final paths = <String>[];
    final service = BilibiliDesktopPlaybackSourceService(
      behaviorPreferences: preferences,
      authService: BilibiliAuthService(cookieStore: _CookieStore()),
      requestJson: (uri, headers) async {
        paths.add(uri.path);
        return '{}';
      },
    );
    await expectLater(
      service.load(bvid: 'BV1GJ411x7h7', cid: 1, quality: 64),
      throwsA(isA<WbiSigningException>()),
    );
    expect(paths, ['/x/web-interface/nav']);
  });

  /// WBI 在设置中可搜索；成功保存会保持新值，写入失败则恢复默认。
  for (final fail in [false, true]) {
    testWidgets('WBI 设置可搜索并${fail ? '失败回滚' : '持久保存'}', (tester) async {
      final preferences = fail
          ? _RejectWbiPreferences()
          : AppBehaviorPreferencesService();
      await tester.pumpWidget(
        MaterialApp(
          home: PersonalizationSettingsPage(
            appPlatform: AppPlatform.windows,
            behaviorPreferencesService: preferences,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('settings-search')), 'WBI');
      await tester.pumpAndSettle();
      final toggle = find.byKey(const Key('enable-wbi-signing'));
      expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(toggle).value, !fail);
      expect(
        await AppBehaviorPreferencesService().loadWbiSigningEnabled(),
        !fail,
      );
      if (fail) expect(find.text('WBI 签名设置保存失败，请稍后重试。'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
