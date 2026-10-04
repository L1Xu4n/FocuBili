import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

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
      expect(numeric!.group(1), '1.8.0');
      expect(numeric.group(2), '21');
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
