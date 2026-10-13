import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/services/app_update_service.dart';

class _Version implements AppVersionProvider {
  @override
  Future<String> loadVersion() async => '1.7.0';
}

Map<String, Object?> _release(String version, {bool prerelease = false}) => {
  'tag_name': 'v$version',
  'prerelease': prerelease,
  'html_url': 'https://github.com/L1Xu4n/FocuBili/releases/tag/v$version',
  'assets': [
    {
      'name': 'FocuBili-v$version-android.apk',
      'browser_download_url':
          'https://github.com/L1Xu4n/FocuBili/releases/download/v$version/FocuBili-v$version-android.apk',
    },
  ],
};

class _DelayedPreferences extends AppUpdatePreferencesService {
  final pendingIgnore = Completer<void>();
  Completer<void>? pendingClear;
  String? identity;
  bool fail = false;
  @override
  Future<String?> loadIgnoredUpdate() async => identity;
  @override
  Future<void> saveIgnoredUpdate(String? value) async {
    if (value != null) await pendingIgnore.future;
    if (value == null) await pendingClear?.future;
    if (fail) throw StateError('storage unavailable');
    identity = value;
  }
}

class _UnreadableIgnorePreferences extends AppUpdatePreferencesService {
  @override
  Future<String?> loadIgnoredUpdate() async =>
      throw StateError('optional preference unavailable');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  AppUpdateController controller({
    Future<Map<String, Object?>> Function()? load,
    AppUpdatePreferencesService? preferences,
    AppUpdateTargetPlatform platform = AppUpdateTargetPlatform.android,
  }) {
    final result = AppUpdateController(
      versionProvider: _Version(),
      preferencesService: preferences,
      updateService: AppUpdateService(
        targetPlatform: platform,
        releaseLoader: load ?? () async => _release('1.7.1'),
      ),
    );
    addTearDown(result.dispose);
    return result;
  }

  test('忽略仅隐藏红点，保留检测结果和下载；重启及自动检查不取消', () async {
    final first = controller();
    await first.initialize();
    final received = first.availableUpdate;
    expect(first.showUpdateBadge, isTrue);
    await first.ignoreCurrentUpdate();
    expect(first.hasUpdate, isTrue);
    expect(first.showUpdateBadge, isFalse);
    expect(first.result.updateAvailable, isTrue);
    expect(first.availableUpdate, same(received));
    expect(first.availableUpdate!.downloadUrl, isNotNull);
    await first.checkNow(manual: false);
    expect(first.showUpdateBadge, isFalse);
    final restarted = controller();
    await restarted.initialize();
    expect(restarted.updateIgnored, isTrue);
    expect(restarted.hasUpdate, isTrue);
    expect(restarted.showUpdateBadge, isFalse);
  });

  for (final wrongType in [false, true]) {
    test('忽略记录读取${wrongType ? '类型损坏' : '异常'}不阻止自动或手动检查', () async {
      if (wrongType) {
        SharedPreferences.setMockInitialValues({
          'app_update.ignored_release': 42,
        });
      }
      var calls = 0;
      final updates = controller(
        preferences: wrongType ? null : _UnreadableIgnorePreferences(),
        load: () async {
          calls++;
          return _release('1.7.1');
        },
      );
      await updates.initialize();
      expect(updates.result.currentVersion, '1.7.0');
      expect(calls, 1);
      expect(updates.showUpdateBadge, isTrue);
      expect(updates.availableUpdate!.downloadUrl, isNotNull);
      await updates.checkNow();
      expect(calls, 2);
      expect(updates.showUpdateBadge, isTrue);
    });
  }

  test('新版本、发布通道或平台不同不会被旧忽略记录屏蔽', () async {
    var version = '1.7.1';
    var prerelease = false;
    final updates = controller(
      load: () async => _release(version, prerelease: prerelease),
    );
    await updates.initialize();
    await updates.ignoreCurrentUpdate();
    version = '1.7.2';
    await updates.checkNow(manual: false);
    expect(updates.showUpdateBadge, isTrue);
    version = '1.7.1';
    prerelease = true;
    await updates.checkNow(manual: false);
    expect(updates.showUpdateBadge, isTrue);
    final otherPlatform = controller(platform: AppUpdateTargetPlatform.windows);
    await otherPlatform.initialize();
    expect(otherPlatform.showUpdateBadge, isTrue);
  });

  test('手动检查立即取消忽略，网络失败也保留已知更新和下载', () async {
    Completer<Map<String, Object?>>? response;
    final updates = controller(
      load: () => response?.future ?? Future.value(_release('1.7.1')),
    );
    await updates.initialize();
    await updates.ignoreCurrentUpdate();
    response = Completer<Map<String, Object?>>();
    final pending = updates.checkNow();
    expect(updates.updateIgnored, isFalse);
    expect(updates.showUpdateBadge, isTrue);
    await Future<void>.delayed(Duration.zero);
    expect(updates.checking, isTrue);
    expect(updates.canIgnoreUpdate, isFalse);
    response.completeError(StateError('offline'));
    await pending;
    expect(updates.result.status, AppUpdateStatus.failed);
    expect(updates.showUpdateBadge, isTrue);
    expect(updates.availableUpdate!.downloadUrl, isNotNull);
    expect(
      await const AppUpdatePreferencesService().loadIgnoredUpdate(),
      isNull,
    );
    final restarted = controller();
    await restarted.initialize();
    expect(restarted.showUpdateBadge, isTrue);
  });

  test('手动检查遇到进行中的自动请求仍取消忽略且不重复请求', () async {
    var calls = 0;
    final response = Completer<Map<String, Object?>>();
    final updates = controller(
      load: () {
        calls++;
        return calls == 1 ? Future.value(_release('1.7.1')) : response.future;
      },
    );
    await updates.initialize();
    await updates.ignoreCurrentUpdate();
    final auto = updates.checkNow(manual: false);
    expect(updates.checking, isTrue);
    await updates.checkNow();
    expect(updates.updateIgnored, isFalse);
    expect(calls, 2);
    response.complete(_release('1.7.1'));
    await auto;
    expect(updates.showUpdateBadge, isTrue);
  });

  test('迟到的忽略保存不能覆盖之后的手动检查', () async {
    final preferences = _DelayedPreferences();
    var calls = 0;
    final updates = controller(
      preferences: preferences,
      load: () async {
        calls++;
        return _release(calls == 1 ? '1.7.1' : '1.7.2');
      },
    );
    await updates.initialize();
    final ignore = updates.ignoreCurrentUpdate();
    await Future<void>.delayed(Duration.zero);
    final manual = updates.checkNow();
    await Future<void>.delayed(Duration.zero);
    expect(calls, 2);
    expect(updates.availableUpdate!.latestVersion, '1.7.2');
    expect(updates.checking, isFalse);
    expect(preferences.pendingIgnore.isCompleted, isFalse);
    preferences.pendingIgnore.complete();
    await Future.wait([ignore, manual]);
    expect(preferences.identity, isNull);
    expect(updates.showUpdateBadge, isTrue);
  });

  test('取消忽略写入失败仍发起手动检查并呈现新结果', () async {
    final preferences = _DelayedPreferences();
    preferences.pendingIgnore.complete();
    var calls = 0;
    final response = Completer<Map<String, Object?>>();
    final updates = controller(
      preferences: preferences,
      load: () {
        calls++;
        return calls == 1 ? Future.value(_release('1.7.1')) : response.future;
      },
    );
    await updates.initialize();
    await updates.ignoreCurrentUpdate();
    preferences.fail = true;
    await expectLater(updates.checkNow(), throwsStateError);
    expect(calls, 2);
    expect(updates.updateIgnored, isFalse);
    expect(updates.checking, isTrue);
    response.complete(_release('1.7.2'));
    await Future<void>.delayed(Duration.zero);
    expect(updates.result.status, AppUpdateStatus.available);
    expect(updates.availableUpdate!.latestVersion, '1.7.2');
    expect(updates.showUpdateBadge, isTrue);
    expect(updates.checking, isFalse);
    preferences.fail = false;
    await updates.checkNow();
    expect(preferences.identity, isNull);
  });

  test('首次加载前手动检查不会从慢存储重新引入旧忽略记录', () async {
    final previous = controller();
    await previous.initialize();
    final preferences = _DelayedPreferences()
      ..identity = previous.availableUpdate!.updateIdentity
      ..pendingClear = Completer<void>();
    final updates = controller(preferences: preferences);
    final manual = updates.checkNow();
    await Future<void>.delayed(Duration.zero);
    expect(updates.loaded, isTrue);
    expect(updates.hasUpdate, isTrue);
    expect(updates.checking, isFalse);
    expect(updates.showUpdateBadge, isTrue);
    expect(preferences.pendingClear!.isCompleted, isFalse);
    preferences.pendingClear!.complete();
    await manual;
    expect(updates.showUpdateBadge, isTrue);
    expect(preferences.identity, isNull);
  });

  test('没有更新时不能忽略；重新开启启动检查也不取消已忽略版本', () async {
    final current = controller(load: () async => _release('1.7.0'));
    await current.initialize();
    expect(current.canIgnoreUpdate, isFalse);
    await current.ignoreCurrentUpdate();
    expect(
      await const AppUpdatePreferencesService().loadIgnoredUpdate(),
      isNull,
    );
    final updates = controller();
    await updates.initialize();
    await updates.ignoreCurrentUpdate();
    await updates.setEnabled(false);
    await updates.setEnabled(true);
    expect(updates.updateIgnored, isTrue);
    expect(updates.showUpdateBadge, isFalse);
  });

  test('忽略保存失败不假装成功，后续操作仍可保存', () async {
    final preferences = _DelayedPreferences()..fail = true;
    preferences.pendingIgnore.complete();
    final updates = controller(preferences: preferences);
    await updates.initialize();
    await expectLater(updates.ignoreCurrentUpdate(), throwsStateError);
    expect(updates.showUpdateBadge, isTrue);
    preferences.fail = false;
    await updates.ignoreCurrentUpdate();
    expect(updates.showUpdateBadge, isFalse);
  });
}
