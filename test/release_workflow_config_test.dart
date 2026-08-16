import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 验证正式构建与发布工作流保留校验、分支和公开资产边界。
void main() {
  /// 检查正式构建恢复固定密钥、验证 APK 身份，并生成 Windows 资产。
  test('Release Build 固定 Android 签名并生成 Windows 安装包', () {
    final String workflow = File(
      '.github/workflows/release-build.yml',
    ).readAsStringSync();
    final String androidBuild = File(
      'android/app/build.gradle',
    ).readAsStringSync();

    expect(workflow, contains('ANDROID_RELEASE_KEYSTORE_BASE64'));
    expect(workflow, contains('ANDROID_RELEASE_STORE_PASSWORD'));
    expect(workflow, contains('ANDROID_RELEASE_KEY_PASSWORD'));
    expect(workflow, contains('ANDROID_RELEASE_KEY_ALIAS'));
    expect(workflow, contains('android/key.properties'));
    expect(
      workflow,
      contains(
        '65EF1FB301FB1121C1803E752F5B1EB24E55846502D8B5478F0FC11F58E9A8A9',
      ),
    );
    expect(workflow, contains(r'''stat -c '%s' "$apk"'''));
    expect(workflow, contains(r'''sha256sum "$apk"'''));
    expect(workflow, contains('aapt" dump badging'));
    expect(workflow, contains('apksigner" verify --verbose --print-certs'));
    expect(workflow, contains(r'test "$cert_sha256" ='));
    expect(androidBuild, contains("rootProject.file('key.properties')"));
    expect(androidBuild, contains('gradle.taskGraph.whenReady'));
    expect(androidBuild, contains('taskGraph.allTasks.any'));
    expect(androidBuild, contains('signingConfig signingConfigs.release'));
    expect(androidBuild, isNot(contains('signingConfig signingConfigs.debug')));
    expect(
      workflow,
      contains(r'.\windows\installer\build_windows_packages.ps1'),
    );
  });

  /// 检查发布只响应明确的最终提交，并创建注释标签和三种公开资产。
  test('发布工作流受提交信息保护并排除 MSIX', () {
    final String workflow = File(
      '.github/workflows/publish-release.yml',
    ).readAsStringSync();

    expect(
      workflow,
      contains(
        "startsWith(github.event.head_commit.message, 'release: publish v')",
      ),
    );
    expect(workflow, contains('git tag -a'));
    expect(workflow, contains('gh release create'));
    expect(workflow, contains('FocuBili-v\${VERSION}-android.apk'));
    expect(workflow, contains('windows-x64-setup.exe'));
    expect(workflow, contains('windows-x64-portable.zip'));
    expect(workflow.toLowerCase(), isNot(contains('.msix')));
  });
}
