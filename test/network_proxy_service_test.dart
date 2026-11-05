import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/models/network_proxy_settings.dart';
import 'package:focubili/services/network_proxy_service.dart';
import 'package:focubili/services/routing_http_client.dart';

class _FailedPreferences implements SharedPreferences {
  bool reloaded = false;
  @override
  Future<bool> setString(String key, String value) async => false;
  @override
  Future<void> reload() async {
    reloaded = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/focubili/network_proxy');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late HttpOverrides? previous;
  late List<MethodCall> calls;
  var directive = 'DIRECT';
  Object? configuredSettings;

  setUp(() {
    previous = HttpOverrides.current;
    calls = [];
    directive = 'DIRECT';
    configuredSettings = null;
    SharedPreferences.setMockInitialValues({});
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'configure') return configuredSettings;
      if (call.method == 'resolve') return directive;
      throw MissingPluginException();
    });
  });
  tearDown(() {
    HttpOverrides.global = previous;
    messenger.setMockMethodCallHandler(channel, null);
  });

  NetworkProxyService service() => NetworkProxyService(channel: channel);

  test(
    'fresh install and upgrade without saved settings follow system',
    () async {
      final instance = service();
      final loaded = await instance.load();
      expect(loaded.mode, NetworkProxyMode.system);
      await instance.initialize();
      expect(instance.active.mode, NetworkProxyMode.system);
      expect(calls.single.method, 'configure');
      expect(calls.single.arguments['mode'], 'system');
      expect(HttpOverrides.current, isA<RoutingHttpOverrides>());
      directive = 'PROXY 127.0.0.1:7890';
      final uri = Uri.parse('https://example.test/video');
      expect((await instance.resolve(uri)).directive, directive);
      expect(calls.last.arguments, {'url': uri.toString()});
    },
  );

  test(
    'save persists next-start settings without changing active routing',
    () async {
      final instance = service();
      await instance.initialize();
      const manual = NetworkProxySettings(
        mode: NetworkProxyMode.manual,
        host: ' [::1] ',
        port: 8080,
      );
      await instance.save(manual);
      expect(instance.active.mode, NetworkProxyMode.system);
      expect(
        (await instance.resolve(Uri.parse('https://example.test'))).isDirect,
        isTrue,
      );
      final restarted = service();
      await restarted.initialize();
      expect(restarted.active.mode, NetworkProxyMode.manual);
      expect(
        (await restarted.resolve(Uri.parse('https://example.test'))).directive,
        'PROXY [::1]:8080',
      );
      expect(
        calls
            .where((call) => call.method == 'configure')
            .last
            .arguments['host'],
        '::1',
      );
      final prefs = await SharedPreferences.getInstance();
      expect(
        jsonDecode(prefs.getString(NetworkProxyService.settingsKey)!)['host'],
        '[::1]',
      );
    },
  );

  test('direct mode does not perform OS route lookup', () async {
    final instance = service();
    await instance.save(
      const NetworkProxySettings(mode: NetworkProxyMode.direct),
    );
    await instance.initialize();
    expect(
      (await instance.resolve(Uri.parse('https://example.test'))).isDirect,
      isTrue,
    );
    expect(calls.map((call) => call.method), ['configure']);
  });

  test('initialize is idempotent', () async {
    final instance = service();
    await instance.initialize();
    final installed = HttpOverrides.current;
    await instance.initialize();
    expect(calls.where((call) => call.method == 'configure'), hasLength(1));
    expect(HttpOverrides.current, same(installed));
  });

  test(
    'native first-start snapshot wins across another engine startup',
    () async {
      configuredSettings = {
        'mode': 'manual',
        'host': '127.0.0.1',
        'port': 3128,
      };
      final instance = service();
      await instance.save(
        const NetworkProxySettings(mode: NetworkProxyMode.direct),
      );
      await instance.initialize();
      expect(instance.active.mode, NetworkProxyMode.manual);
      expect(
        (await instance.resolve(Uri.parse('https://example.test'))).directive,
        'PROXY 127.0.0.1:3128',
      );
    },
  );

  for (final stored in [
    'not json',
    '[]',
    '{"mode":"manual","host":"secret@proxy.local","port":7890}',
    '{"mode":"manual","host":"proxy.local","port":0}',
    '{"mode":"unknown","host":"proxy.local","port":7890}',
  ]) {
    test('bad persisted configuration fails closed: $stored', () async {
      SharedPreferences.setMockInitialValues({
        NetworkProxyService.settingsKey: stored,
      });
      final instance = service();
      await instance.initialize();
      await expectLater(
        instance.resolve(Uri.parse('http://example.test')),
        throwsA(isA<HttpException>()),
      );
      expect(calls.map((call) => call.method), ['blockIfUnconfigured']);
      expect(HttpOverrides.current, isA<RoutingHttpOverrides>());
    });
  }

  test('native configure failure fails closed even in direct mode', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => throw PlatformException(code: 'unavailable'),
    );
    final instance = service();
    await instance.save(
      const NetworkProxySettings(mode: NetworkProxyMode.direct),
    );
    await instance.initialize();
    await expectLater(
      instance.resolve(Uri.parse('http://example.test')),
      throwsA(isA<HttpException>()),
    );
  });

  test('invalid configuration cannot overwrite saved settings', () async {
    final instance = service();
    await instance.save(
      const NetworkProxySettings(mode: NetworkProxyMode.direct),
    );
    await expectLater(
      instance.save(
        const NetworkProxySettings(
          mode: NetworkProxyMode.manual,
          host: 'user:secret@proxy.local',
        ),
      ),
      throwsFormatException,
    );
    expect((await instance.load()).mode, NetworkProxyMode.direct);
  });

  test(
    'storage write failure is reported and preferences are reloaded',
    () async {
      final prefs = _FailedPreferences();
      final instance = NetworkProxyService(
        preferencesLoader: () async => prefs,
        channel: channel,
      );
      await expectLater(
        instance.save(
          const NetworkProxySettings(mode: NetworkProxyMode.direct),
        ),
        throwsStateError,
      );
      expect(prefs.reloaded, isTrue);
    },
  );

  for (final route in [
    'SOCKS proxy.local:1080; DIRECT',
    'HTTPS proxy.local:443; DIRECT',
    'UNSUPPORTED; DIRECT',
    'PROXY user:secret@proxy.local:7890; DIRECT',
  ]) {
    test('unsupported first system route never falls back: $route', () async {
      directive = route;
      final instance = service();
      await instance.initialize();
      await expectLater(
        instance.resolve(Uri.parse('http://example.test')),
        throwsFormatException,
      );
    });
  }

  test('system uses only the first route, with per-URL lookup', () async {
    final instance = service();
    await instance.initialize();
    directive = 'PROXY proxy.local:7890; DIRECT';
    expect(
      (await instance.resolve(Uri.parse('https://one.test'))).directive,
      'PROXY proxy.local:7890',
    );
    directive = 'DIRECT; PROXY proxy.local:7890';
    expect(
      (await instance.resolve(Uri.parse('https://two.test'))).isDirect,
      isTrue,
    );
    expect(
      calls
          .where((call) => call.method == 'resolve')
          .map((call) => call.arguments['url']),
      ['https://one.test', 'https://two.test'],
    );
  });

  test('missing native system response fails closed', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => null);
    final instance = service();
    await instance.initialize();
    await expectLater(
      instance.resolve(Uri.parse('https://example.test')),
      throwsA(isA<HttpException>()),
    );
  });

  test('player direct mode clears inherited proxy and enforces TLS', () async {
    final instance = service();
    await instance.save(
      const NetworkProxySettings(mode: NetworkProxyMode.direct),
    );
    await instance.initialize();
    final properties = <String, String>{};
    await instance.configurePlayer(
      uris: [Uri.parse('https://video.test'), Uri.file('/local/video.mp4')],
      writeProperty: (key, value) async {
        properties[key] = value;
      },
    );
    expect(properties, {
      'http-proxy': '',
      'stream-lavf-o': 'http_proxy=',
      'tls-verify': 'yes',
    });
  });

  test(
    'player fails before writing properties for mismatched stream routes',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'configure') return null;
        return (call.arguments['url'] as String).contains('video.test')
            ? 'DIRECT'
            : 'PROXY proxy.local:7890';
      });
      final instance = service();
      await instance.initialize();
      final writes = <String>[];
      await expectLater(
        instance.configurePlayer(
          uris: [
            Uri.parse('https://video.test'),
            Uri.parse('https://audio.test'),
          ],
          writeProperty: (key, value) async {
            writes.add(key);
          },
        ),
        throwsA(isA<HttpException>()),
      );
      expect(writes, isEmpty);
    },
  );
  test(
    'a stale player resolver never overwrites current player properties',
    () async {
      final resolved = Completer<String>();
      final requested = Completer<void>();
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'configure') return null;
        requested.complete();
        return resolved.future;
      });
      final instance = service();
      await instance.initialize();
      var current = true;
      final writes = <String>[];
      final pending = instance.configurePlayer(
        uris: [Uri.parse('https://video.test')],
        isCurrent: () => current,
        writeProperty: (key, value) async {
          writes.add(key);
        },
      );
      await requested.future;
      current = false;
      resolved.complete('DIRECT');
      await pending;
      expect(writes, isEmpty);
    },
  );
  test(
    'concurrent initialize callers both wait for native setup and overrides',
    () async {
      final preferences = Completer<SharedPreferences>();
      final native = Completer<Object?>();
      final configuring = Completer<void>();
      var loads = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        configuring.complete();
        return native.future;
      });
      final instance = NetworkProxyService(
        preferencesLoader: () {
          loads++;
          return preferences.future;
        },
        channel: channel,
      );
      var firstDone = false;
      var secondDone = false;
      final first = instance.initialize();
      final second = instance.initialize();
      unawaited(
        first.then((_) {
          firstDone = true;
        }),
      );
      unawaited(
        second.then((_) {
          secondDone = true;
        }),
      );
      await Future<void>.delayed(Duration.zero);
      expect(loads, 1);
      expect(firstDone, isFalse);
      expect(secondDone, isFalse);
      preferences.complete(await SharedPreferences.getInstance());
      await configuring.future;
      expect(firstDone, isFalse);
      expect(secondDone, isFalse);
      native.complete(null);
      await Future.wait([first, second]);
      expect(HttpOverrides.current, isA<RoutingHttpOverrides>());
      expect(calls.where((call) => call.method == 'configure'), hasLength(1));
      expect(firstDone, isTrue);
      expect(secondDone, isTrue);
    },
  );

  test(
    'a valid already-active native snapshot survives corrupt saved preferences',
    () async {
      SharedPreferences.setMockInitialValues({
        NetworkProxyService.settingsKey: 'corrupt',
      });
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        expect(call.method, 'blockIfUnconfigured');
        return {'mode': 'manual', 'host': '127.0.0.1', 'port': 3128};
      });
      final instance = service();
      await instance.initialize();
      expect(
        (await instance.resolve(Uri.parse('https://video.test'))).directive,
        'PROXY 127.0.0.1:3128',
      );
      expect(calls, hasLength(1));
    },
  );
}
