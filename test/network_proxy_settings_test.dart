import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/models/network_proxy_settings.dart';

void main() {
  group('NetworkProxySettings', () {
    test('fresh settings follow the system', () {
      const settings = NetworkProxySettings();
      expect(settings.mode, NetworkProxyMode.system);
      expect(settings.host, isEmpty);
      expect(settings.port, 7890);
    });

    for (final host in [
      'localhost',
      'proxy.example.com',
      'proxy-1.example.com',
      '127.0.0.1',
      '10.23.45.67',
      '::1',
      '2001:db8::1234',
      '[::1]',
      '  proxy.example.com  ',
    ]) {
      test('accepts host $host', () {
        expect(NetworkProxySettings.validateHost(host), isNull);
      });
    }

    for (final host in [
      '',
      ' ',
      'http://proxy.example.com',
      'https://proxy.example.com',
      'user:secret@proxy.example.com',
      'proxy.example.com:7890',
      'proxy.example.com/path',
      'proxy.example.com?token=secret',
      'proxy.example.com#fragment',
      'proxy.example.com; DIRECT',
      'proxy.example.com\r\nDIRECT',
      'proxy host',
      'proxy\\host',
      '%70roxy.example.com',
      '[::1',
      '::1]',
      '::invalid',
      '.proxy.example.com',
      'proxy..example.com',
      '-proxy.example.com',
      'proxy-.example.com',
      'proxy.-example.com',
      '${'a' * 64}.example.com',
      'a' * 254,
    ]) {
      test(
        'rejects invalid or credential-bearing host ${host.replaceAll('\n', r'\n')}',
        () {
          expect(NetworkProxySettings.validateHost(host), isNotNull);
        },
      );
    }

    for (final port in ['1', '7890', '65535', ' 8080 ']) {
      test('accepts port $port', () {
        expect(NetworkProxySettings.validatePort(port), isNull);
      });
    }
    for (final port in ['', '0', '-1', '65536', '1.5', '80; DIRECT', 'http']) {
      test('rejects port $port', () {
        expect(NetworkProxySettings.validatePort(port), isNotNull);
      });
    }

    test('IPv6 is normalized and bracketed exactly once in authorities', () {
      const settings = NetworkProxySettings(
        mode: NetworkProxyMode.manual,
        host: ' [2001:db8::1] ',
        port: 8080,
      );
      expect(settings.normalizedHost, '2001:db8::1');
      expect(settings.authority, '[2001:db8::1]:8080');
      expect(
        NetworkProxySettings.fromJson(settings.toJson()).authority,
        '[2001:db8::1]:8080',
      );
    });

    test('all modes round trip with stable serialized names', () {
      for (final mode in NetworkProxyMode.values) {
        final settings = NetworkProxySettings(
          mode: mode,
          host: ' proxy.local ',
          port: 8080,
        );
        final restored = NetworkProxySettings.fromJson(settings.toJson());
        expect(restored.mode, mode);
        expect(
          restored.host,
          mode == NetworkProxyMode.manual ? 'proxy.local' : '',
        );
        expect(restored.port, mode == NetworkProxyMode.manual ? 8080 : 7890);
      }
    });

    test('invalid persisted manual settings are rejected', () {
      for (final json in <Map<String, dynamic>>[
        {'mode': 'manual', 'host': '', 'port': 7890},
        {'mode': 'manual', 'host': 'proxy.local', 'port': 0},
        {'mode': 'manual', 'host': 'proxy.local', 'port': '7890'},
        {'mode': 'manual', 'host': 'secret@proxy.local', 'port': 7890},
      ]) {
        expect(
          () => NetworkProxySettings.fromJson(json),
          throwsFormatException,
        );
      }
    });

    test('unknown persisted mode never silently becomes system or direct', () {
      expect(
        () => NetworkProxySettings.fromJson({
          'mode': 'corrupt-mode',
          'host': 'proxy.local',
          'port': 7890,
        }),
        throwsFormatException,
      );
    });
  });

  group('NetworkProxyRoute', () {
    test('parses DIRECT and HTTP proxy IPv4, DNS and IPv6', () {
      expect(NetworkProxyRoute.parse(' DIRECT ').isDirect, isTrue);
      for (final authority in [
        '127.0.0.1:7890',
        'proxy.local:8080',
        '[::1]:3128',
      ]) {
        final route = NetworkProxyRoute.parse('PROXY $authority');
        expect(route.isDirect, isFalse);
        expect(route.authority, authority);
        expect(route.directive, 'PROXY $authority');
        expect(route.url, 'http://$authority');
      }
      expect(const NetworkProxyRoute.direct().url, isEmpty);
    });

    for (final directive in [
      '',
      'SOCKS proxy.local:1080',
      'SOCKS5 proxy.local:1080',
      'HTTPS proxy.local:443',
      'UNSUPPORTED',
      'PROXY user:secret@proxy.local:7890',
      'PROXY proxy.local',
      'PROXY proxy.local:0',
      'PROXY proxy.local:65536',
      'PROXY proxy.local:7890/path',
      'PROXY proxy.local:7890?secret',
      'PROXY proxy.local:7890#fragment',
      'PROXY proxy.local:7890; DIRECT',
      'PROXY proxy.local:7890\r\nInjected: secret',
    ]) {
      test('unsupported or unsafe directive fails closed: $directive', () {
        expect(() => NetworkProxyRoute.parse(directive), throwsFormatException);
      });
    }
  });
}
