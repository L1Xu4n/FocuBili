import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/services/app_update_service.dart';

class _MemoryVersionProvider implements AppVersionProvider {
  const _MemoryVersionProvider(this.version);

  final String version;

  @override
  Future<String> loadVersion() async => version;
}

class _MemoryUpdatePreferences extends AppUpdatePreferencesService {
  _MemoryUpdatePreferences(this.value, {this.failSaving = false});

  bool value;
  final bool failSaving;

  @override
  Future<bool> loadEnabled() async => value;

  @override
  Future<void> saveEnabled(bool enabled) async {
    if (failSaving) {
      throw StateError('save failed');
    }
    value = enabled;
  }
}

void main() {
  test('语义版本比较忽略 v 和构建号，并正确处理预发布版本', () {
    expect(
      AppUpdateService.compareVersions('v0.3.0', '0.2.2+4'),
      greaterThan(0),
    );
    expect(AppUpdateService.compareVersions('0.2.2', '0.2.2+4'), 0);
    expect(
      AppUpdateService.compareVersions('0.2.2-beta.1', '0.2.2'),
      lessThan(0),
    );
    expect(
      AppUpdateService.compareVersions('0.2.2-beta.10', '0.2.2-beta.2'),
      greaterThan(0),
    );
  });

  /// 验证更新检查返回 Release 地址，并完整保留超过三条的简报内容。
  test('GitHub 最新版本高于安装版本时返回全部更新简报', () async {
    final AppUpdateService service = AppUpdateService(
      releaseLoader: () async => <String, Object?>{
        'tag_name': 'v0.3.0',
        'html_url': 'https://github.com/L1Xu4n/FocuBili/releases/tag/v0.3.0',
        'body': '''
普通发布说明不会直接显示。
<!-- focubili-update-summary:start -->
- 优化平板播放器和账号卡片
- 修复画幅设置，并查看 [完整说明](https://example.com)
- 增加简略更新内容
- 支持任意行数的更新简报
- 第五条也会进入 App
<!-- focubili-update-summary:end -->
''',
      },
    );

    final AppUpdateResult result = await service.check(currentVersion: '0.2.2');

    expect(result.status, AppUpdateStatus.available);
    expect(result.latestVersion, '0.3.0');
    expect(result.releaseUrl?.path, contains('/releases/tag/v0.3.0'));
    expect(result.releaseHighlights, <String>[
      '优化平板播放器和账号卡片',
      '修复画幅设置，并查看 完整说明',
      '增加简略更新内容',
      '支持任意行数的更新简报',
      '第五条也会进入 App',
    ]);
  });

  /// 验证 Windows 只选择本项目的 MSIX 资产，即使 Release 同时把 APK 排在前面。
  test('Windows 更新优先返回安全 MSIX 安装包', () async {
    final AppUpdateResult result = await AppUpdateService(
      targetPlatform: AppUpdateTargetPlatform.windows,
      releaseLoader: () async => <String, Object?>{
        'tag_name': 'v1.4.0',
        'html_url': 'https://github.com/L1Xu4n/FocuBili/releases/tag/v1.4.0',
        'assets': <Map<String, Object?>>[
          <String, Object?>{
            'name': 'FocuBili-v1.4.0-release.apk',
            'browser_download_url':
                'https://github.com/L1Xu4n/FocuBili/releases/download/v1.4.0/FocuBili-v1.4.0-release.apk',
          },
          <String, Object?>{
            'name': 'FocuBili-v1.4.0-x64.msix',
            'browser_download_url':
                'https://github.com/L1Xu4n/FocuBili/releases/download/v1.4.0/FocuBili-v1.4.0-x64.msix',
          },
        ],
      },
    ).check(currentVersion: '1.3.1');

    expect(result.downloadUrl?.path, endsWith('.msix'));
    expect(result.downloadActionLabel, '下载 Windows 安装包');
    expect(result.downloadUrl?.path, isNot(endsWith('.apk')));
  });

  /// 验证 Android 只选择 APK，且伪造域名的同名文件不会成为下载入口。
  test('Android 更新忽略 Windows 和非 GitHub 安装包', () async {
    final AppUpdateResult result = await AppUpdateService(
      targetPlatform: AppUpdateTargetPlatform.android,
      releaseLoader: () async => <String, Object?>{
        'tag_name': 'v1.4.0',
        'assets': <Map<String, Object?>>[
          <String, Object?>{
            'name': 'FocuBili-v1.4.0-release.apk',
            'browser_download_url':
                'https://example.com/L1Xu4n/FocuBili/releases/download/v1.4.0/FocuBili-v1.4.0-release.apk',
          },
          <String, Object?>{
            'name': 'FocuBili-v1.4.0-x64.msix',
            'browser_download_url':
                'https://github.com/L1Xu4n/FocuBili/releases/download/v1.4.0/FocuBili-v1.4.0-x64.msix',
          },
        ],
      },
    ).check(currentVersion: '1.3.1');

    expect(result.downloadUrl, isNull);
    expect(result.downloadActionLabel, '查看 Release');
  });

  test('Release 未按约定提供摘要标记时不会把整篇正文显示到 App', () async {
    final AppUpdateResult result = await AppUpdateService(
      releaseLoader: () async => <String, Object?>{
        'tag_name': 'v0.3.0',
        'body': '## 完整更新日志\n- 这是一篇很长的正文',
      },
    ).check(currentVersion: '0.2.2');

    expect(result.status, AppUpdateStatus.available);
    expect(result.releaseHighlights, isEmpty);
  });

  test('控制器保存关闭状态并停止自动检查', () async {
    int requestCount = 0;
    final _MemoryUpdatePreferences preferences = _MemoryUpdatePreferences(true);
    final AppUpdateController controller = AppUpdateController(
      versionProvider: const _MemoryVersionProvider('0.2.2'),
      preferencesService: preferences,
      updateService: AppUpdateService(
        releaseLoader: () async {
          requestCount += 1;
          return <String, Object?>{'tag_name': 'v0.2.2'};
        },
      ),
    );

    await controller.initialize(checkOnStart: true);
    await controller.setEnabled(false);

    expect(requestCount, 1);
    expect(preferences.value, isFalse);
    expect(controller.result.status, AppUpdateStatus.disabled);
    controller.dispose();
  });

  test('关闭自动检查后忽略仍在等待的旧检查结果', () async {
    final Completer<Map<String, Object?>> release =
        Completer<Map<String, Object?>>();
    final AppUpdateController controller = AppUpdateController(
      versionProvider: const _MemoryVersionProvider('0.2.2'),
      preferencesService: _MemoryUpdatePreferences(true),
      updateService: AppUpdateService(releaseLoader: () => release.future),
    );

    final Future<void> checking = controller.initialize(checkOnStart: true);
    await Future<void>.delayed(Duration.zero);
    await controller.setEnabled(false);
    release.complete(<String, Object?>{
      'tag_name': 'v9.0.0',
      'html_url': 'https://example.com/release',
    });
    await checking;

    expect(controller.enabled, isFalse);
    expect(controller.result.status, AppUpdateStatus.disabled);
    expect(controller.hasUpdate, isFalse);
    controller.dispose();
  });

  test('开关保存失败时保留正在执行的检查结果', () async {
    final Completer<Map<String, Object?>> release =
        Completer<Map<String, Object?>>();
    final AppUpdateController controller = AppUpdateController(
      versionProvider: const _MemoryVersionProvider('0.2.2'),
      preferencesService: _MemoryUpdatePreferences(true, failSaving: true),
      updateService: AppUpdateService(releaseLoader: () => release.future),
    );
    await controller.initialize(checkOnStart: false);
    final Future<void> checking = controller.checkNow();
    await Future<void>.delayed(Duration.zero);

    await expectLater(controller.setEnabled(false), throwsStateError);
    release.complete(<String, Object?>{'tag_name': 'v0.2.2'});
    await checking;

    expect(controller.enabled, isTrue);
    expect(controller.checking, isFalse);
    expect(controller.result.status, AppUpdateStatus.upToDate);
    controller.dispose();
  });
}
