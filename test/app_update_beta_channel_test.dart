import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/services/app_update_service.dart';

const _preview = AppUpdateInstallation(
  packageName: 'com.focubili.app.preview',
  buildNumber: '2031',
  certificateSha256:
      'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
);
const _stable = AppUpdateInstallation(packageName: 'com.focubili.app');
const _root = 'https://github.com/L1Xu4n/FocuBili/releases/download';

Map<String, Object?> _manifest(int beta) {
  final version = '1.9.0-beta.$beta';
  final file = 'FocuBili-v$version-android-preview.apk';
  return {
    'format': 'focubili.beta-release',
    'version': 1,
    'channel': 'beta',
    'tag': 'v$version',
    'sourceSha': '1' * 40,
    'baseVersion': '1.9.0',
    'betaNumber': beta,
    'buildNumber': 2030 + beta,
    'android': {
      'package': 'com.focubili.app.preview',
      'versionName': version,
      'versionCode': 2030 + beta,
      'certificateSha256': 'b' * 64,
      'file': file,
      'bytes': 100,
      'sha256': 'a' * 64,
    },
    'assets': [
      {'platform': 'android', 'file': file, 'bytes': 100, 'sha256': 'a' * 64},
      {
        'platform': 'windows',
        'file': 'FocuBili-v$version-windows-x64-setup.exe',
        'bytes': 200,
        'sha256': 'c' * 64,
      },
    ],
  };
}

Map<String, Object?> _asset(
  String tag,
  String file,
  int bytes, {
  String? digest,
}) => {
  'name': file,
  'size': bytes,
  'digest': ?digest,
  'browser_download_url': '$_root/$tag/$file',
};

Map<String, Object?> _release(int beta, {bool manifest = true}) {
  final tag = 'v1.9.0-beta.$beta';
  return {
    'tag_name': tag,
    'draft': false,
    'prerelease': true,
    'html_url': 'https://github.com/L1Xu4n/FocuBili/releases/tag/$tag',
    'assets': [
      if (manifest) _asset(tag, 'beta-release-manifest.json', 2048),
      _asset(
        tag,
        'FocuBili-$tag-android-preview.apk',
        100,
        digest: 'sha256:${'a' * 64}',
      ),
      _asset(tag, 'FocuBili-$tag-windows-x64-setup.exe', 200),
    ],
  };
}

class _Headers extends Fake implements HttpHeaders {
  final values = <String, String>{};
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) =>
      values[name.toLowerCase()] = value.toString();
  @override
  String? value(String name) => values[name.toLowerCase()];
}

class _Response extends Stream<List<int>> implements HttpClientResponse {
  _Response(
    Object? json, {
    this.statusCode = 200,
    String? location,
    List<int>? bytes,
    int? advertisedLength,
  }) : data = bytes ?? utf8.encode(jsonEncode(json)),
       _length = advertisedLength {
    if (location != null) headers.set('location', location);
  }
  final List<int> data;
  final int? _length;
  @override
  final int statusCode;
  @override
  int get contentLength => _length ?? data.length;
  @override
  final _Headers headers = _Headers();
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream<List<int>>.value(data).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Request extends Fake implements HttpClientRequest {
  _Request(this.uri, this.client);
  @override
  final Uri uri;
  final _Client client;
  @override
  final _Headers headers = _Headers();
  @override
  bool followRedirects = true;
  @override
  Future<HttpClientResponse> close() async => client.respond(uri);
}

class _Client extends Fake implements HttpClient {
  _Client(this.respond);
  final _Response Function(Uri) respond;
  final requests = <_Request>[];
  int closes = 0;
  @override
  set connectionTimeout(Duration? value) {}
  @override
  Future<HttpClientRequest> getUrl(Uri uri) async {
    final request = _Request(uri, this);
    requests.add(request);
    return request;
  }

  @override
  void close({bool force = false}) => closes++;
}

_Client _betaClient(
  List<Object?> releases, {
  Object? manifest,
  void Function(Uri)? inspect,
}) => _Client((uri) {
  inspect?.call(uri);
  if (uri.host == 'api.github.com') return _Response(releases);
  return _Response(manifest ?? _manifest(2));
});

Future<AppUpdateResult> _check(
  _Client client, {
  String version = '1.9.0-beta.1+2031',
  AppUpdateInstallation? installation = _preview,
  AppUpdateTargetPlatform platform = AppUpdateTargetPlatform.android,
  String channel = '',
}) => AppUpdateService(
  httpClient: client,
  targetPlatform: platform,
  releaseChannel: channel,
).check(currentVersion: version, installation: installation);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'Android bridge missing signature keeps discovery but only offers Release',
    () async {
      const channel = MethodChannel('dev.fluttercommunity.plus/package_info');
      var nativeReads = 0;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'getAll');
        nativeReads++;
        // Mirrors getAll when Kotlin getBuildSignature returns null: it omits
        // buildSignature while returning package/version/code successfully.
        return <String, Object?>{
          'appName': 'Synthetic native metadata',
          'packageName': _preview.packageName,
          'version': '1.9.0-beta.1',
          'buildNumber': '2031',
        };
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      const provider = PlatformAppVersionProvider();
      final version = await provider.loadVersion();
      final installation = await provider.loadUpdateInstallation();
      expect(nativeReads, 1);
      expect(installation.packageName, _preview.packageName);
      expect(installation.buildNumber, '2031');
      expect(installation.certificateSha256, isEmpty);
      final result = await _check(
        _betaClient([_release(2)]),
        version: version,
        installation: installation,
      );
      expect(result.status, AppUpdateStatus.available);
      expect(result.downloadUrl, isNull);
      expect(result.downloadActionLabel, '查看 Release');
    },
  );

  for (final invalidCode in [
    '',
    'unavailable',
    '2031.0',
    '0x7ef',
    '+2031',
    '-1',
  ]) {
    test(
      'preview with unusable native code "$invalidCode" only offers Release',
      () async {
        final result = await _check(
          _betaClient([_release(2)]),
          installation: AppUpdateInstallation(
            packageName: _preview.packageName,
            buildNumber: invalidCode,
            certificateSha256: _preview.certificateSha256,
          ),
        );
        expect(result.status, AppUpdateStatus.available);
        expect(result.downloadUrl, isNull);
        expect(result.downloadActionLabel, '查看 Release');
      },
    );
  }

  for (final legacyCode in ['2024', '2025']) {
    test(
      'known legacy preview certificate at $legacyCode cannot select CI APK',
      () async {
        final manifest = _manifest(2)..['buildNumber'] = 2026;
        (manifest['android'] as Map)
          ..['versionCode'] = 2026
          ..['certificateSha256'] =
              '65ef1fb301fb1121c1803e752f5b1eb24e55846502d8b5478f0fc11f58e9a8a9';
        final result = await _check(
          _betaClient([_release(2)], manifest: manifest),
          installation: AppUpdateInstallation(
            packageName: _preview.packageName,
            buildNumber: legacyCode,
            certificateSha256:
                '5bd1fc4daa8a0887e213c4dc1231d0eba4f7f309a0e64c2d15fe404302bd00b0',
          ),
        );
        expect(result.status, AppUpdateStatus.available);
        expect(result.downloadUrl, isNull);
      },
    );
  }

  test(
    'matching public CI certificate and lower native code retain direct APK',
    () async {
      const certificate =
          '65ef1fb301fb1121c1803e752f5b1eb24e55846502d8b5478f0fc11f58e9a8a9';
      final manifest = _manifest(2)..['buildNumber'] = 2026;
      (manifest['android'] as Map)
        ..['versionCode'] = 2026
        ..['certificateSha256'] = certificate;
      final result = await _check(
        _betaClient([_release(2)], manifest: manifest),
        installation: const AppUpdateInstallation(
          packageName: 'com.focubili.app.preview',
          buildNumber: '2025',
          certificateSha256: certificate,
        ),
      );
      expect(result.downloadUrl?.path, endsWith('-android-preview.apk'));
    },
  );

  test(
    'stable keeps latest endpoint and selects only its package APK',
    () async {
      final tag = 'v1.9.1';
      final client = _Client((uri) {
        expect(uri, AppUpdateService.latestReleaseApiUri);
        return _Response({
          'tag_name': tag,
          'prerelease': false,
          'draft': false,
          'assets': [
            _asset(tag, 'FocuBili-$tag-android-preview.apk', 100),
            _asset(tag, 'FocuBili-$tag-android-debug.apk', 100),
            _asset(tag, 'FocuBili-$tag-android.apk', 100),
          ],
        });
      });
      final result = await _check(
        client,
        version: '1.9.0+27',
        installation: _stable,
      );
      expect(result.status, AppUpdateStatus.available);
      expect(result.downloadUrl?.path, endsWith('-android.apk'));
      expect(client.requests, hasLength(1));
    },
  );

  test(
    'preview never queries latest; highest SemVer beats API order and stable/draft entries',
    () async {
      final client = _betaClient([
        _release(2),
        {..._release(99), 'draft': true},
        {..._release(90), 'prerelease': false},
        _release(10),
        {..._release(80), 'tag_name': 'v99.0.0'},
        {..._release(80), 'tag_name': 'v1.9.0-beta.080'},
      ], manifest: _manifest(10));
      final result = await _check(client);
      expect(result.latestVersion, '1.9.0-beta.10');
      expect(
        result.downloadUrl?.path,
        endsWith('-beta.10-android-preview.apk'),
      );
      expect(client.requests.first.uri.queryParameters, {
        'per_page': '30',
        'page': '1',
      });
      expect(
        client.requests.any((r) => r.uri.path.endsWith('/latest')),
        isFalse,
      );
      expect(result.message, contains('90'));
    },
  );

  for (final invalid in [
    {'tag_name': 'v1.9.1', 'draft': true},
    {'tag_name': 'v1.9.1', 'prerelease': true},
    {'tag_name': 'v1.9.1-beta.1', 'prerelease': false},
  ]) {
    test('stable latest rejects an unexpected channel $invalid', () async {
      final client = _Client((uri) {
        expect(uri, AppUpdateService.latestReleaseApiUri);
        return _Response(invalid);
      });
      expect(
        (await _check(client, version: '1.9.0', installation: _stable)).status,
        AppUpdateStatus.failed,
      );
      expect(client.requests, hasLength(1));
    });
  }

  test(
    'API redirect and transport failure never follow another endpoint',
    () async {
      final redirected = _Client(
        (_) => _Response(
          null,
          statusCode: 302,
          location: 'https://example.com/releases',
        ),
      );
      expect((await _check(redirected)).status, AppUpdateStatus.failed);
      expect(redirected.requests, hasLength(1));
      final failed = _Client(
        (_) => throw const SocketException('SYNTHETIC_SECRET'),
      );
      final result = await _check(failed);
      expect(result.status, AppUpdateStatus.failed);
      expect(result.message, isNot(contains('SYNTHETIC')));
    },
  );

  test(
    'no higher prerelease is a bounded no-update result without stable fallback',
    () async {
      final client = _betaClient([
        _release(1),
        {..._release(9), 'prerelease': false},
        {..._release(2), 'draft': true},
      ]);
      final result = await _check(client);
      expect(result.status, AppUpdateStatus.upToDate);
      expect(result.downloadUrl, isNull);
      expect(result.message, contains('90'));
      expect(client.requests, hasLength(1));
    },
  );

  test(
    'pagination computes only three same-repo URLs and reads later higher beta',
    () async {
      final client = _Client((uri) {
        final page = int.parse(uri.queryParameters['page']!);
        expect(uri.host, 'api.github.com');
        return _Response([
          for (var i = 0; i < 29; i++)
            {'tag_name': 'v0.1.$i', 'prerelease': false},
          _release(page + 1, manifest: false),
        ]);
      });
      final result = await _check(client);
      expect(client.requests.map((r) => r.uri.queryParameters['page']), [
        '1',
        '2',
        '3',
      ]);
      expect(result.latestVersion, '1.9.0-beta.4');
      expect(result.downloadUrl, isNull);
    },
  );

  for (final status in [401, 403, 429, 500]) {
    test(
      'API $status fails without partial success, auth or error-body leakage',
      () async {
        final client = _Client(
          (uri) => _Response('SYNTHETIC_TOKEN_COOKIE', statusCode: status),
        );
        final result = await _check(client);
        expect(result.status, AppUpdateStatus.failed);
        expect(result.downloadUrl, isNull);
        expect(result.message, isNot(contains('SYNTHETIC')));
        expect(
          client.requests.single.headers.values.keys,
          isNot(contains('authorization')),
        );
        expect(
          client.requests.single.headers.values.keys,
          isNot(contains('cookie')),
        );
        expect(client.requests.single.followRedirects, isFalse);
        expect(
          client.closes,
          0,
          reason: 'Injected client remains caller-owned',
        );
      },
    );
  }

  test('later page error never promotes a partial earlier candidate', () async {
    final client = _Client(
      (uri) => uri.queryParameters['page'] == '1'
          ? _Response([
              for (var i = 0; i < 30; i++) _release(2, manifest: false),
            ])
          : _Response({}, statusCode: 403),
    );
    expect((await _check(client)).status, AppUpdateStatus.failed);
    expect(client.requests, hasLength(2));
  });

  for (final bad in [
    _Response({'unexpected': 'map'}),
    _Response(null, bytes: [255]),
    _Response([], advertisedLength: 1024 * 1024 + 1),
    _Response(
      null,
      bytes: List.filled(1024 * 1024 + 1, 32),
      advertisedLength: -1,
    ),
  ]) {
    test(
      'malformed or oversized release response is a static failure ${bad.data.length}/${bad.contentLength}',
      () async {
        expect(
          (await _check(_Client((_) => bad))).status,
          AppUpdateStatus.failed,
        );
      },
    );
  }

  final mutations = <String, void Function(Map<String, Object?>)>{
    'channel': (m) => m['channel'] = 'stable',
    'tag': (m) => m['tag'] = 'v1.9.0-beta.3',
    'source': (m) => m['sourceSha'] = 'invalid',
    'nested source': (m) => (m['android'] as Map)['sourceSha'] = '2' * 40,
    'release version': (m) => m['releaseVersion'] = '1.9.0-beta.3',
    'schema type': (m) => m['version'] = 1.0,
    'base version': (m) => m['baseVersion'] = '1.8.0',
    'beta number': (m) => m['betaNumber'] = 3,
    'package': (m) => (m['android'] as Map)['package'] = 'com.focubili.app',
    'version code': (m) => (m['android'] as Map)['versionCode'] = 2032.0,
    'file': (m) =>
        (m['android'] as Map)['file'] = 'FocuBili-v1.9.0-android.apk',
    'hash': (m) => (m['android'] as Map)['sha256'] = 'bad',
    'size': (m) => (m['android'] as Map)['bytes'] = -1,
    'duplicate': (m) => (m['assets'] as List).add((m['assets'] as List).first),
    'extra android': (m) => (m['assets'] as List).insert(0, {
      'platform': 'android',
      'file': 'FocuBili-v1.9.0-beta.2-android.apk',
      'bytes': 100,
      'sha256': 'a' * 64,
    }),
  };
  for (final mutation in mutations.entries) {
    test(
      'manifest ${mutation.key} mismatch keeps only safe release page',
      () async {
        final manifest = _manifest(2);
        mutation.value(manifest);
        final result = await _check(
          _betaClient([_release(2)], manifest: manifest),
        );
        expect(result.status, AppUpdateStatus.available);
        expect(result.downloadUrl, isNull);
        expect(result.releaseUrl?.host, 'github.com');
        expect(result.downloadActionLabel, '查看 Release');
      },
    );
  }

  test('full release source SHA mismatch blocks direct asset', () async {
    final release = _release(2)..['target_commitish'] = '2' * 40;
    expect((await _check(_betaClient([release]))).downloadUrl, isNull);
  });

  test(
    'producer verification extensions preserve the required contract',
    () async {
      final manifest = _manifest(2)
        ..['releaseVersion'] = '1.9.0-beta.2'
        ..['verification'] = {'scope': 'synthetic'}
        ..['limitations'] = ['not device tested']
        ..['macosArchitectures'] = ['arm64'];
      (manifest['android'] as Map)['sourceSha'] = manifest['sourceSha'];
      final release = _release(2)..['target_commitish'] = manifest['sourceSha'];
      expect(
        (await _check(
          _betaClient([release], manifest: manifest),
        )).downloadUrl?.path,
        endsWith('-android-preview.apk'),
      );
    },
  );

  for (final wrong in ['tag', 'name', 'size', 'size type', 'digest', 'host']) {
    test(
      'API asset $wrong mismatch cannot become a preview download',
      () async {
        final release = _release(2);
        final asset = (release['assets'] as List)[1] as Map;
        switch (wrong) {
          case 'tag':
            asset['browser_download_url'] =
                '$_root/v1.9.0/FocuBili-v1.9.0-beta.2-android-preview.apk';
          case 'name':
            asset['browser_download_url'] =
                '$_root/v1.9.0-beta.2/different.apk';
          case 'size':
            asset['size'] = 101;
          case 'size type':
            asset['size'] = 100.0;
          case 'digest':
            asset['digest'] = 'sha256:${'d' * 64}';
          case 'host':
            asset['browser_download_url'] = 'https://example.com/preview.apk';
        }
        expect((await _check(_betaClient([release]))).downloadUrl, isNull);
      },
    );
  }

  for (final identity in [
    null,
    _stable,
    const AppUpdateInstallation(packageName: 'other.preview'),
    const AppUpdateInstallation(
      packageName: 'com.focubili.app.preview',
      certificateSha256: 'different',
    ),
    const AppUpdateInstallation(
      packageName: 'com.focubili.app.preview',
      buildNumber: '9999',
    ),
  ]) {
    test(
      'unknown, different package/certificate or lower build blocks direct APK ${identity?.packageName}/${identity?.buildNumber}/${identity?.certificateSha256}',
      () async {
        final result = await _check(
          _betaClient([_release(2)]),
          installation: identity,
        );
        expect(result.status, AppUpdateStatus.available);
        expect(result.downloadUrl, isNull);
      },
    );
  }

  test(
    'missing manifest and foreign release page never use stable APK as fallback',
    () async {
      final release = _release(2, manifest: false)
        ..['html_url'] = 'https://example.com/SYNTHETIC_TOKEN';
      (release['assets'] as List).add(
        _asset('v1.9.0-beta.2', 'FocuBili-v1.9.0-android.apk', 100),
      );
      final result = await _check(_betaClient([release]));
      expect(result.downloadUrl, isNull);
      expect(result.releaseUrl, AppUpdateService.releasesUri);
    },
  );

  test(
    'exact preview package chooses prereleases even with numeric version',
    () async {
      final client = _betaClient([]);
      expect(
        (await _check(client, version: '1.9.0+2031')).status,
        AppUpdateStatus.upToDate,
      );
      expect(client.requests.single.uri.path.endsWith('/latest'), isFalse);
    },
  );

  test(
    'compiled desktop beta channel uses prereleases and matching platform metadata',
    () async {
      final result = await _check(
        _betaClient([_release(2)]),
        platform: AppUpdateTargetPlatform.windows,
        installation: null,
        channel: 'beta',
        version: '1.8.9+2031',
      );
      expect(result.downloadUrl?.path, endsWith('-windows-x64-setup.exe'));
    },
  );

  test(
    'manifest redirect allows bounded GitHub asset CDN but no foreign destination or auth',
    () async {
      final client = _Client((uri) {
        if (uri.host == 'api.github.com') return _Response([_release(2)]);
        if (uri.host == 'github.com') {
          return _Response(
            null,
            statusCode: 302,
            location:
                'https://release-assets.githubusercontent.com/public/manifest?signature=SYNTHETIC',
          );
        }
        return _Response(_manifest(2));
      });
      final result = await _check(client);
      expect(result.downloadUrl?.host, 'github.com');
      expect(client.requests, hasLength(3));
      for (final request in client.requests) {
        expect(request.headers.values.keys, isNot(contains('authorization')));
        expect(request.headers.values.keys, isNot(contains('cookie')));
      }
      final foreign = _Client(
        (uri) => uri.host == 'api.github.com'
            ? _Response([_release(2)])
            : _Response(
                null,
                statusCode: 302,
                location: 'https://example.com/manifest',
              ),
      );
      expect((await _check(foreign)).downloadUrl, isNull);
      expect(foreign.requests, hasLength(2));
    },
  );

  test('manifest CDN redirects stop after three hops', () async {
    final client = _Client(
      (uri) => uri.host == 'api.github.com'
          ? _Response([_release(2)])
          : _Response(
              null,
              statusCode: 302,
              location: 'https://release-assets.githubusercontent.com/loop',
            ),
    );
    final result = await _check(client);
    expect(result.status, AppUpdateStatus.available);
    expect(result.downloadUrl, isNull);
    expect(client.requests, hasLength(5)); // API + initial asset + 3 CDN hops.
  });

  for (final response in [
    _Response({}, statusCode: 403),
    _Response(null, bytes: [255]),
    _Response({}, advertisedLength: 64 * 1024 + 1),
    _Response(
      null,
      bytes: List.filled(64 * 1024 + 1, 32),
      advertisedLength: -1,
    ),
  ]) {
    test(
      'invalid metadata transport preserves discovery without a direct asset ${response.statusCode}/${response.data.length}/${response.contentLength}',
      () async {
        final client = _Client(
          (uri) => uri.host == 'api.github.com'
              ? _Response([_release(2)])
              : response,
        );
        final result = await _check(client);
        expect(result.status, AppUpdateStatus.available);
        expect(result.downloadUrl, isNull);
        expect(result.downloadActionLabel, '查看 Release');
      },
    );
  }

  test(
    'installed package metadata and compiled display version flow through controller',
    () async {
      PackageInfo.setMockInitialValues(
        appName: 'Synthetic',
        packageName: _preview.packageName,
        version: '1.9.0',
        buildNumber: '2031',
        buildSignature: _preview.certificateSha256,
      );
      const platform = PlatformAppVersionProvider();
      expect(
        await platform.loadVersion(),
        '1.9.0+2031',
        reason: 'No defines preserves stable display',
      );
      const beta = PlatformAppVersionProvider(
        releaseChannel: 'beta',
        releaseVersion: '1.9.0-beta.1',
      );
      expect(await beta.loadVersion(), '1.9.0-beta.1+2031');
      expect(
        (await beta.loadUpdateInstallation()).packageName,
        _preview.packageName,
      );
      final client = _betaClient([_release(2)]);
      final controller = AppUpdateController(
        versionProvider: beta,
        updateService: AppUpdateService(
          httpClient: client,
          targetPlatform: AppUpdateTargetPlatform.android,
        ),
      );
      try {
        await controller.initialize();
        expect(controller.result.currentVersion, '1.9.0-beta.1+2031');
        expect(
          controller.availableUpdate?.downloadUrl?.path,
          endsWith('-android-preview.apk'),
        );
      } finally {
        controller.dispose();
      }
    },
  );

  for (final nativeBuild in ['2031', '2033', '']) {
    test(
      'compiled beta metadata stays valid with native build "$nativeBuild"',
      () async {
        PackageInfo.setMockInitialValues(
          appName: 'Synthetic metadata review',
          packageName: _preview.packageName,
          version: '1.9.0',
          buildNumber: nativeBuild,
          buildSignature: _preview.certificateSha256,
        );
        const provider = PlatformAppVersionProvider(
          releaseChannel: 'beta',
          releaseVersion: '1.9.0-beta.1+local',
        );
        final version = await provider.loadVersion();
        expect(
          version,
          nativeBuild.isEmpty
              ? '1.9.0-beta.1+local'
              : '1.9.0-beta.1+$nativeBuild',
        );
        expect(AppUpdateService.validSemVer(version), isTrue);
        final installation = await provider.loadUpdateInstallation();
        expect(installation.buildNumber, nativeBuild);
        final result = await _check(
          _betaClient([_release(2)]),
          version: version,
          installation: installation,
        );
        expect(result.status, AppUpdateStatus.available);
        expect(result.latestVersion, '1.9.0-beta.2');
        if (nativeBuild == '2031') {
          expect(result.downloadUrl?.path, endsWith('-android-preview.apk'));
        } else if (nativeBuild == '2033') {
          // The real native counter, not the display override, gates upgrades.
          expect(result.downloadUrl, isNull);
        }
      },
    );
  }

  test('SemVer numeric identifiers do not overflow or compare lexically', () {
    expect(
      AppUpdateService.compareVersions(
        '1.9.0-beta.100000000000000000000',
        '1.9.0-beta.99999999999999999999',
      ),
      greaterThan(0),
    );
    expect(AppUpdateService.validSemVer('1.9.0-beta.01'), isFalse);
  });
}
