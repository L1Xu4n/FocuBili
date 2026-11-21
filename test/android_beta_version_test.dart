import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:focubili/core/build_metadata.g.dart';

void main() {
  test(
    'Android preview marks beta while the shared version remains desktop-compatible',
    () {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      final numeric = RegExp(
        r'^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$',
        multiLine: true,
      ).firstMatch(pubspec);
      expect(numeric, isNotNull);
      expect(numeric!.group(1), '1.9.0');
      final build = int.parse(numeric.group(2)!);
      expect(build, 2037);
      expect(build, greaterThan(2036), reason: 'next after signed Beta 11');
      final archived =
          jsonDecode(
                File('docs/beta5/apk-verification.json').readAsStringSync(),
              )
              as Map<String, dynamic>;
      final archivedPreview = archived['localArm64'] as Map<String, dynamic>;
      expect(build, greaterThan(archivedPreview['versionCode'] as int));
      expect(build, lessThanOrEqualTo(65535));
      expect(appFallbackVersion, '${numeric.group(1)}+$build');
      expect(
        RegExp(
          r'^\s+msix_version:\s*(\S+)',
          multiLine: true,
        ).firstMatch(pubspec)!.group(1),
        '${numeric.group(1)}.$build',
      );
      const beta = '12';
      expect(
        RegExp(
          r'^\s+output_name:\s*(\S+)',
          multiLine: true,
        ).firstMatch(pubspec)!.group(1),
        'FocuBili-v${numeric.group(1)}-beta.$beta-windows-x64',
      );
      final gradle = File('android/app/build.gradle').readAsStringSync();
      expect(gradle, contains('applicationId "com.focubili.app"'));
      final debug = RegExp(
        r'debug\s*\{([^}]+)\}',
      ).firstMatch(gradle)!.group(1)!;
      expect(debug, contains('applicationIdSuffix ".preview"'));
      expect(debug, contains('versionNameSuffix "-beta.$beta"'));
      expect(debug, contains('焦点哔哩 Beta'));
      final debugManifest = File(
        'android/app/src/debug/AndroidManifest.xml',
      ).readAsStringSync();
      expect(debugManifest, contains(r'android:label="${appLabel}"'));
    },
  );
}
