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
      final gradle = File('android/app/build.gradle').readAsStringSync();
      final debug = RegExp(
        r'debug\s*\{([^}]+)\}',
      ).firstMatch(gradle)!.group(1)!;
      expect(debug, contains('applicationIdSuffix ".preview"'));
      expect(debug, contains('versionNameSuffix "-beta.1"'));
      expect(debug, contains('焦点哔哩 Beta'));
      final debugManifest = File(
        'android/app/src/debug/AndroidManifest.xml',
      ).readAsStringSync();
      expect(debugManifest, contains(r'android:label="${appLabel}"'));
    },
  );
}
