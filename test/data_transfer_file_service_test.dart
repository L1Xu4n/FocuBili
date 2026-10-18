import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/platform/app_platform.dart';
import 'package:focubili/services/data_transfer_file_service.dart';

/// 实际读回桌面临时文件，并验证取消与存储错误不会被当作导出成功。
void main() {
  for (final platform in [
    AppPlatform.windows,
    AppPlatform.macos,
    AppPlatform.linux,
  ]) {
    test('${platform.name} 选择路径后写入完整 UTF-8 JSON', () async {
      final directory = await Directory.systemTemp.createTemp(
        'focubili-export-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/synthetic-settings.json');
      final service = DataTransferFileService(
        platform: platform,
        saveDialog: (name, bytes) async => file.path,
      );
      const source = '{"format":"focubili-settings","合成数据":true}';
      expect(await service.saveJson('settings.json', source), isTrue);
      expect(await file.readAsString(), source);
    });
  }

  test('取消保存不创建文件也不返回成功', () async {
    final service = DataTransferFileService(
      platform: AppPlatform.windows,
      saveDialog: (name, bytes) async => null,
    );
    expect(await service.saveJson('settings.json', '{}'), isFalse);
  });

  test('桌面目标无法写入时传播存储异常', () async {
    final directory = await Directory.systemTemp.createTemp('focubili-export-');
    addTearDown(() => directory.delete(recursive: true));
    final service = DataTransferFileService(
      platform: AppPlatform.macos,
      saveDialog: (name, bytes) async => directory.path,
    );
    await expectLater(
      service.saveJson('settings.json', '{}'),
      throwsA(isA<FileSystemException>()),
    );
  });
}
