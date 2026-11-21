/// Public release metadata is a package-selection hint, never APK verification.
class AppUpdateReleaseManifest {
  AppUpdateReleaseManifest._(this.assets, this.android, this.sourceSha);

  final List<Map<String, Object?>> assets;
  final Map<String, Object?> android;
  final String sourceSha;

  static AppUpdateReleaseManifest? tryParse(Object? raw, String tag) {
    if (raw is! Map ||
        raw['format'] != 'focubili.beta-release' ||
        raw['version'] is! int ||
        raw['version'] != 1 ||
        raw['channel'] != 'beta' ||
        raw['tag'] != tag ||
        !_hex(raw['sourceSha'], 40)) {
      return null;
    }
    final version = tag.startsWith('v') ? tag.substring(1) : tag;
    final beta = RegExp(
      r'^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)-beta\.([1-9]\d*)$',
    ).firstMatch(version);
    if (beta == null ||
        (raw.containsKey('releaseVersion') &&
            raw['releaseVersion'] != version) ||
        raw['baseVersion'] != '${beta[1]}.${beta[2]}.${beta[3]}' ||
        raw['betaNumber'] is! int ||
        raw['betaNumber'].toString() != beta[4] ||
        raw['buildNumber'] is! int ||
        (raw['buildNumber'] as int) <= 0 ||
        (raw['buildNumber'] as int) > 2147483647) {
      return null;
    }
    final entries = raw['assets'];
    final android = raw['android'];
    if (entries is! List ||
        entries.isEmpty ||
        entries.length > 20 ||
        android is! Map ||
        android.keys.any((key) => key is! String) ||
        android['package'] != 'com.focubili.app.preview' ||
        android['versionName'] != version ||
        android['versionCode'] is! int ||
        android['versionCode'] != raw['buildNumber'] ||
        (android.containsKey('sourceSha') &&
            android['sourceSha'] != raw['sourceSha']) ||
        android['file'] != 'FocuBili-v$version-android-preview.apk' ||
        !_hex(android['certificateSha256'], 64) ||
        !_fileFields(android)) {
      return null;
    }
    final assets = <Map<String, Object?>>[];
    final names = <String>{};
    for (final entry in entries) {
      if (entry is! Map ||
          entry.keys.any((key) => key is! String) ||
          !_fileFields(entry) ||
          !(entry['file'] as String).startsWith('FocuBili-v$version-') ||
          !{
            'android',
            'windows',
            'macos',
            'linux',
            'ios',
          }.contains(entry['platform']) ||
          !names.add(entry['file'] as String)) {
        return null;
      }
      assets.add(Map<String, Object?>.from(entry));
    }
    final matchingAndroid = assets.where(
      (asset) =>
          asset['platform'] == 'android' &&
          asset['file'] == android['file'] &&
          asset['bytes'] == android['bytes'] &&
          asset['sha256'] == android['sha256'],
    );
    if (matchingAndroid.length != 1 ||
        assets.where((asset) => asset['platform'] == 'android').length != 1) {
      return null;
    }
    return AppUpdateReleaseManifest._(
      List.unmodifiable(assets),
      Map<String, Object?>.unmodifiable(android),
      raw['sourceSha'] as String,
    );
  }

  static bool _hex(Object? value, int length) =>
      value is String && RegExp('^[0-9a-fA-F]{$length}\$').hasMatch(value);

  static bool _fileFields(Map raw) =>
      raw['file'] is String &&
      RegExp(r'^[A-Za-z0-9][A-Za-z0-9._+()-]{0,179}$').hasMatch(raw['file']) &&
      raw['bytes'] is int &&
      (raw['bytes'] as int) > 0 &&
      (raw['bytes'] as int) <= 2147483648 &&
      _hex(raw['sha256'], 64);
}
