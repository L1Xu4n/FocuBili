import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 验证正式构建与发布工作流保留校验、分支和公开资产边界。
void main() {
  /// 检查正式构建会输出 APK 精确元数据，并由打包脚本生成 Windows 资产。
  test('Release Build 输出 APK 元数据并生成 Windows 安装包', () {
    final String workflow = File(
      '.github/workflows/release-build.yml',
    ).readAsStringSync();

    expect(workflow, contains("stat -c '%s' \"\$apk\""));
    expect(workflow, contains('sha256sum \"\$apk\"'));
    expect(workflow, contains('aapt\" dump badging'));
    expect(workflow, contains('apksigner\" verify --verbose --print-certs'));
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
      contains("startsWith(github.event.head_commit.message, 'release: publish v')"),
    );
    expect(workflow, contains('git tag -a'));
    expect(workflow, contains('gh release create'));
    expect(workflow, contains('FocuBili-v\${VERSION}-android.apk'));
    expect(workflow, contains('windows-x64-setup.exe'));
    expect(workflow, contains('windows-x64-portable.zip'));
    expect(workflow.toLowerCase(), isNot(contains('.msix')));
  });
}
