import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:focubili/services/first_launch_service.dart';
import 'package:focubili/services/media_cache_service.dart';

class _RejectedPreferences implements SharedPreferences {
  @override
  Future<bool> setBool(String key, bool value) async {
    await Future<void>.value();
    throw StateError('Asynchronous storage rejection');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RejectedStatusCache extends WindowsMediaCacheService {
  _RejectedStatusCache(Directory directory)
    : super(
        directoryLoader: () async => directory,
        preferencesLoader: SharedPreferences.getInstance,
        playbackActiveLoader: () => false,
      );

  @override
  Future<MediaCacheStatus> loadStatus() async {
    await Future<void>.value();
    throw StateError('Asynchronous status rejection');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final agreement in [true, false]) {
    test(
      'Onboarding catches rejected ${agreement ? 'agreement' : 'guide'} write',
      () async {
        final service = FirstLaunchService(
          preferencesLoader: () async => _RejectedPreferences(),
        );
        expect(
          await (agreement
              ? service.acceptAgreement()
              : service.markLoginGuideShown()),
          isFalse,
        );
      },
    );
  }

  for (final clear in [true, false]) {
    test(
      'Cache catches rejected status after ${clear ? 'clear' : 'resize'}',
      () async {
        SharedPreferences.setMockInitialValues({});
        final root = await Directory.systemTemp.createTemp('async_cache_test_');
        try {
          final directory = Directory(
            '${root.path}/${WindowsMediaCacheService.cacheDirectoryName}',
          );
          final service = _RejectedStatusCache(directory);
          await expectLater(
            clear
                ? service.clearCache()
                : service.setCapacityBytes(supportedMediaCacheBytes.first),
            throwsA(
              isA<MediaCacheException>().having(
                (error) => error.code,
                'code',
                'cache_error',
              ),
            ),
          );
        } finally {
          await root.delete(recursive: true);
        }
      },
    );
  }
}
