import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/platform/app_platform.dart';
import 'package:focubili/services/local_export_service.dart';

void main() {
  for (final platform in [
    AppPlatform.windows,
    AppPlatform.macos,
    AppPlatform.linux,
  ]) {
    test(
      'desktop export verifies bytes after the picker: ${platform.name}',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'focubili-save-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final file = File('${directory.path}/笔记 with spaces.md');
        final bytes = Uint8List.fromList([1, 2, 3]);
        final service = LocalExportService(
          platform: platform,
          saveDialog: (request) async {
            expect(request.fileName, '笔记.md');
            expect(request.extension, 'md');
            await file.writeAsBytes(request.bytes);
            return file.path;
          },
        );
        expect(await service.save(fileName: '笔记.md', bytes: bytes), file.path);
        expect(await file.readAsBytes(), bytes);
      },
    );
  }
  test(
    'cancel skips verification and mobile content URI is not read as a file',
    () async {
      var verified = false;
      final cancelled = LocalExportService(
        platform: AppPlatform.windows,
        saveDialog: (_) async => null,
        verifyFile: (_, _) async => verified = true,
      );
      expect(
        await cancelled.save(fileName: 'n.json', bytes: Uint8List(1)),
        isNull,
      );
      expect(verified, isFalse);
      final mobile = LocalExportService(
        platform: AppPlatform.android,
        saveDialog: (_) async => 'content://documents/123',
        verifyFile: (_, _) async => verified = true,
      );
      expect(
        await mobile.save(fileName: 'n.json', bytes: Uint8List(1)),
        'content://documents/123',
      );
      expect(verified, isFalse);
    },
  );
  test(
    'failed save has platform-stage code without paths or original details',
    () async {
      final service = LocalExportService(
        platform: AppPlatform.macos,
        saveDialog: (_) async => throw PlatformException(
          code: 'permission_denied',
          message: '/Users/private/session-cookie',
        ),
      );
      try {
        await service.save(fileName: 'n.md', bytes: Uint8List(1));
        fail('expected export failure');
      } on LocalExportException catch (error) {
        expect(error.diagnosticCode, 'macos/save/permission_denied');
        expect(error.toString(), isNot(contains('private')));
        expect(error.toString(), isNot(contains('session-cookie')));
      }
    },
  );
  test(
    'a returned path with a truncated file is not reported as saved',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'focubili-truncated-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = await File('${directory.path}/broken.md').writeAsBytes([1]);
      final service = LocalExportService(
        platform: AppPlatform.windows,
        saveDialog: (_) async => file.path,
      );
      await expectLater(
        service.save(fileName: 'n.md', bytes: Uint8List(3)),
        throwsA(
          isA<LocalExportException>().having(
            (e) => e.diagnosticCode,
            'diagnostic',
            'windows/verify/size_mismatch',
          ),
        ),
      );
    },
  );
}
