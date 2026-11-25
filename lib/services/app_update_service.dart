import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/widgets.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../platform/platform_capabilities.dart';
import '../platform/platform_services.dart';
import 'app_update_release_manifest.dart';
import 'app_update_transport.dart';

export '../platform/platform_capabilities.dart' show AppUpdateTargetPlatform;

/// 表示一次 GitHub Release 更新检查的最终状态。
enum AppUpdateStatus { idle, disabled, checking, upToDate, available, failed }

/// 保存当前版本、远端版本和 Release 页面，供“关于”页统一展示。
class AppUpdateResult {
  /// 创建一份可供设置页和关于页共同读取的更新检查结果。
  const AppUpdateResult({
    required this.status,
    required this.currentVersion,
    this.latestVersion,
    this.updateIdentity,
    this.releaseUrl,
    this.downloadUrl,
    this.downloadActionLabel = '查看 Release',
    this.releaseHighlights = const <String>[],
    this.message,
  });

  /// 创建尚未读取版本、也未发起网络请求的初始结果。
  const AppUpdateResult.idle()
    : status = AppUpdateStatus.idle,
      currentVersion = '',
      latestVersion = null,
      updateIdentity = null,
      releaseUrl = null,
      downloadUrl = null,
      downloadActionLabel = '查看 Release',
      releaseHighlights = const <String>[],
      message = null;

  final AppUpdateStatus status;
  final String currentVersion;
  final String? latestVersion;

  /// 当前仓库、平台、发布通道和版本组成的本地忽略身份。
  final String? updateIdentity;
  final Uri? releaseUrl;
  final Uri? downloadUrl;
  final String downloadActionLabel;

  /// 保存 Release 正文中专门提供给 App 展示的全部简短更新内容。
  final List<String> releaseHighlights;
  final String? message;

  /// 指示此次检查是否发现更新，独立于用户是否忽略红点。
  bool get updateAvailable => status == AppUpdateStatus.available;
}

/// 提供安装包版本，测试可以用内存实现替代平台插件。
abstract interface class AppVersionProvider {
  /// 返回当前安装包去掉构建号后的公开版本号。
  Future<String> loadVersion();
}

/// Only this application's public package metadata; never account/session data.
class AppUpdateInstallation {
  const AppUpdateInstallation({
    required this.packageName,
    this.buildNumber = '',
    this.certificateSha256 = '',
  });
  final String packageName;
  final String buildNumber;
  final String certificateSha256;
}

abstract interface class AppUpdateInstallationProvider {
  Future<AppUpdateInstallation> loadUpdateInstallation();
}

/// 从当前平台安装包元数据读取 pubspec 对应版本号。
class PlatformAppVersionProvider
    implements AppVersionProvider, AppUpdateInstallationProvider {
  /// 创建使用 package_info_plus 读取版本的平台实现。
  const PlatformAppVersionProvider({
    this.releaseChannel = const String.fromEnvironment(
      'FOCUBILI_RELEASE_CHANNEL',
    ),
    this.releaseVersion = const String.fromEnvironment(
      'FOCUBILI_RELEASE_VERSION',
    ),
  });
  final String releaseChannel;
  final String releaseVersion;

  /// 从系统安装包元数据读取当前应用版本。
  @override
  Future<String> loadVersion() async {
    final PackageInfo info = await PackageInfo.fromPlatform();
    final useReleaseVersion =
        releaseChannel == 'beta' &&
        AppUpdateService.isBetaVersion(releaseVersion) &&
        AppUpdateService.validSemVer(releaseVersion);
    final version = useReleaseVersion ? releaseVersion : info.version;
    if (info.buildNumber.trim().isEmpty) return version;
    // A SemVer has one metadata suffix; prefer the installed native counter.
    final displayVersion = useReleaseVersion
        ? version.split('+').first
        : version;
    return '$displayVersion+${info.buildNumber}';
  }

  @override
  Future<AppUpdateInstallation> loadUpdateInstallation() async {
    final info = await PackageInfo.fromPlatform();
    return AppUpdateInstallation(
      packageName: info.packageName,
      buildNumber: info.buildNumber,
      certificateSha256: info.buildSignature,
    );
  }
}

/// 保存“启动时检查更新”开关，数据仅存放在当前设备。
class AppUpdatePreferencesService {
  /// 创建只访问当前设备 SharedPreferences 的开关服务。
  const AppUpdatePreferencesService();

  static const String _enabledKey = 'app_update.check_on_start';
  static const String _ignoredUpdateKey = 'app_update.ignored_release';

  Future<String?> loadIgnoredUpdate() async =>
      (await SharedPreferences.getInstance()).getString(_ignoredUpdateKey);

  Future<void> saveIgnoredUpdate(String? identity) async {
    final preferences = await SharedPreferences.getInstance();
    final saved = identity == null
        ? await preferences.remove(_ignoredUpdateKey)
        : await preferences.setString(_ignoredUpdateKey, identity);
    if (!saved) throw StateError('无法保存更新提示偏好。');
  }

  /// 读取启动检查开关；首次安装默认开启。
  Future<bool> loadEnabled() async {
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    return preferences.getBool(_enabledKey) ?? true;
  }

  /// 保存启动检查开关，不上传任何设备数据。
  Future<void> saveEnabled(bool enabled) async {
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    await preferences.setBool(_enabledKey, enabled);
  }
}

/// Stable uses latest; explicitly marked previews read bounded prerelease history.
class AppUpdateService {
  /// 创建更新服务；测试可以注入本地 Release 数据或 HTTP 客户端。
  AppUpdateService({
    Future<Map<String, Object?>> Function()? releaseLoader,
    HttpClient? httpClient,
    HttpClient Function()? httpClientFactory,
    AppUpdateTargetPlatform? targetPlatform,
    String releaseChannel = const String.fromEnvironment(
      'FOCUBILI_RELEASE_CHANNEL',
    ),
  }) : _releaseLoader = releaseLoader,
       _transport = AppUpdateTransport(
         client: httpClient,
         clientFactory: httpClientFactory,
       ),
       _releaseChannel = releaseChannel,
       _targetPlatform = targetPlatform ?? _currentTargetPlatform();

  static final Uri releasesUri = Uri.parse(
    'https://github.com/L1Xu4n/FocuBili/releases',
  );
  static final Uri latestReleaseApiUri = Uri.parse(
    'https://api.github.com/repos/L1Xu4n/FocuBili/releases/latest',
  );
  static final Uri releasesApiUri = Uri.parse(
    'https://api.github.com/repos/L1Xu4n/FocuBili/releases',
  );
  static const int betaPageSize = 30;
  static const int maximumBetaPages = 3;
  static const String releaseSummaryStartMarker =
      '<!-- focubili-update-summary:start -->';
  static const String releaseSummaryEndMarker =
      '<!-- focubili-update-summary:end -->';
  static const int _maximumReleaseHighlightLength = 80;

  final Future<Map<String, Object?>> Function()? _releaseLoader;
  final AppUpdateTransport _transport;
  final AppUpdateTargetPlatform _targetPlatform;
  final String _releaseChannel;

  /// Resolves the effective channel from the build and installed package.
  bool _usesBeta(String currentVersion, AppUpdateInstallation? installation) =>
      _releaseChannel == 'beta' ||
      isBetaVersion(currentVersion) ||
      (_targetPlatform == AppUpdateTargetPlatform.android &&
          installation?.packageName == 'com.focubili.app.preview');

  /// 请求最新正式 Release；网络、限流和格式错误均转换为可展示的失败状态。
  Future<AppUpdateResult> check({
    required String currentVersion,
    AppUpdateInstallation? installation,
  }) async {
    try {
      final beta = _usesBeta(currentVersion, installation);
      final Map<String, Object?>? release = beta
          ? await _loadBetaRelease(currentVersion)
          : _releaseLoader == null
          ? await _loadLatestRelease()
          : await _releaseLoader();
      if (release == null) {
        return AppUpdateResult(
          status: AppUpdateStatus.upToDate,
          currentVersion: currentVersion,
          releaseUrl: releasesUri,
          message: '近期发布中未发现更高的测试版（最多检查 90 条发布）。',
        );
      }
      if (release['draft'] == true ||
          (!beta && release['prerelease'] == true)) {
        throw const FormatException('Unexpected release channel');
      }
      final String latestVersion = _readVersion(
        release['tag_name'] ?? release['name'],
      );
      if (latestVersion.isEmpty) {
        throw const FormatException('Release 没有可识别的版本号。');
      }
      if (!beta && latestVersion.contains('-')) {
        throw const FormatException('Unexpected stable release version');
      }
      final tag = release['tag_name']?.toString() ?? '';
      final Uri releaseUrl = _safeReleasePage(release['html_url'], tag);
      final bool available = compareVersions(latestVersion, currentVersion) > 0;
      final Uri? downloadUrl = beta
          ? await _selectBetaDownload(release, installation)
          : _selectDownloadAsset(
              release['assets'],
              tag: tag,
              androidPackage: installation?.packageName,
            );
      final List<String> releaseHighlights = _readReleaseHighlights(
        release['body'],
      );
      return AppUpdateResult(
        status: available
            ? AppUpdateStatus.available
            : AppUpdateStatus.upToDate,
        currentVersion: currentVersion,
        latestVersion: latestVersion,
        updateIdentity: jsonEncode([
          'L1Xu4n/FocuBili',
          _targetPlatform.name,
          release['prerelease'] == true || latestVersion.contains('-')
              ? 'prerelease'
              : 'stable',
          latestVersion,
        ]),
        releaseUrl: releaseUrl,
        downloadUrl: downloadUrl,
        downloadActionLabel: _downloadActionLabel(downloadUrl),
        releaseHighlights: releaseHighlights,
        message: beta
            ? '近期发布中发现更高测试版 $latestVersion（最多检查 90 条发布）。'
            : available
            ? '发现新版本 $latestVersion'
            : '当前已是最新版本',
      );
    } catch (error) {
      return AppUpdateResult(
        status: AppUpdateStatus.failed,
        currentVersion: currentVersion,
        releaseUrl: AppUpdateService.releasesUri,
        message: '暂时无法检查更新，请稍后重试。',
      );
    }
  }

  /// Checks every applicable page before publishing the best Beta.
  Future<Map<String, Object?>?> _loadBetaRelease(String currentVersion) async {
    if (!validSemVer(currentVersion.replaceFirst(RegExp(r'^v'), ''))) {
      throw const FormatException('Invalid installed preview version');
    }
    Map<String, Object?>? best;
    String? bestVersion;
    for (var page = 1; page <= maximumBetaPages; page++) {
      final Object? raw = _releaseLoader != null
          ? [await _releaseLoader()]
          : await _readReleasePage(
              releasesApiUri.replace(
                queryParameters: {'per_page': '$betaPageSize', 'page': '$page'},
              ),
              channel: 'beta',
              page: page,
              isValid: (raw) => raw is List && raw.length <= betaPageSize,
            );
      if (raw is! List || raw.length > betaPageSize) {
        throw const FormatException('Invalid release history');
      }
      for (final entry in raw) {
        if (entry is! Map ||
            entry.keys.any((key) => key is! String) ||
            entry['draft'] == true ||
            entry['prerelease'] != true) {
          continue;
        }
        final tag = entry['tag_name'];
        if (tag is! String) continue;
        final version = tag.startsWith('v') ? tag.substring(1) : tag;
        if (!validSemVer(version) ||
            !version.split('+').first.contains('-') ||
            compareVersions(version, currentVersion) <= 0 ||
            (bestVersion != null &&
                compareVersions(version, bestVersion) <= 0)) {
          continue;
        }
        best = Map<String, Object?>.from(entry);
        bestVersion = version;
      }
      if (_releaseLoader != null || raw.length < betaPageSize) break;
    }
    return best;
  }

  Future<Uri?> _selectBetaDownload(
    Map<String, Object?> release,
    AppUpdateInstallation? installation,
  ) async {
    if (_targetPlatform == AppUpdateTargetPlatform.other) return null;
    if (_targetPlatform == AppUpdateTargetPlatform.android &&
        installation?.packageName != 'com.focubili.app.preview') {
      return null;
    }
    try {
      final tag = release['tag_name'] as String;
      final rawAssets = release['assets'];
      if (rawAssets is! List) return null;
      final manifests = rawAssets.whereType<Map>().where(
        (asset) => asset['name'] == 'beta-release-manifest.json',
      );
      if (manifests.length != 1) return null;
      final asset = manifests.single;
      final uri = Uri.tryParse(asset['browser_download_url']?.toString() ?? '');
      if (uri == null ||
          !_isTrustedReleaseAsset(uri, tag, 'beta-release-manifest.json') ||
          asset['size'] is! int ||
          (asset['size'] as int) <= 0 ||
          (asset['size'] as int) > 64 * 1024) {
        return null;
      }
      final manifest = AppUpdateReleaseManifest.tryParse(
        await _transport.readJson(uri, releaseAsset: true),
        tag,
      );
      if (manifest == null) return null;
      final target = release['target_commitish'];
      if (target is String &&
          RegExp(r'^[0-9a-fA-F]{40}$').hasMatch(target) &&
          target.toLowerCase() != manifest.sourceSha.toLowerCase()) {
        return null;
      }
      if (_targetPlatform == AppUpdateTargetPlatform.android) {
        if (installation?.packageName != manifest.android['package']) {
          return null;
        }
        final certificate = installation!.certificateSha256.trim();
        if (!RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(certificate) ||
            certificate.toLowerCase() !=
                (manifest.android['certificateSha256'] as String)
                    .toLowerCase()) {
          return null;
        }
        final build = int.tryParse(installation.buildNumber);
        if (!RegExp(r'^(0|[1-9][0-9]*)$').hasMatch(installation.buildNumber) ||
            build == null ||
            (manifest.android['versionCode'] as int) <= build) {
          return null;
        }
      }
      final matches = <Map>[];
      for (final declared in manifest.assets) {
        if (declared['platform'] != _targetPlatform.name) continue;
        final actual = rawAssets.whereType<Map>().where(
          (asset) => asset['name'] == declared['file'],
        );
        if (actual.length != 1) continue;
        final candidate = actual.single;
        final digest = candidate['digest'];
        if (candidate['size'] is int &&
            candidate['size'] == declared['bytes'] &&
            (digest == null ||
                digest.toString().toLowerCase() ==
                    'sha256:${(declared['sha256'] as String).toLowerCase()}')) {
          matches.add(candidate);
        }
      }
      return _selectDownloadAsset(
        matches,
        tag: tag,
        androidPackage: installation?.packageName,
        beta: true,
      );
    } catch (_) {
      // Valid release discovery may still offer its safe page, never an unverified APK.
      return null;
    }
  }

  /// 从统一能力表读取安装包类型，未支持平台只保留 Release 页面入口。
  static AppUpdateTargetPlatform _currentTargetPlatform() {
    return PlatformServices.current.capabilities.updateTargetPlatform;
  }

  /// 从 Release 资产中选择当前平台安装包；Windows 不会退回选择 APK，Android 也不会选择 MSIX。
  Uri? _selectDownloadAsset(
    Object? rawAssets, {
    required String tag,
    String? androidPackage,
    bool beta = false,
  }) {
    if (rawAssets is! List ||
        _targetPlatform == AppUpdateTargetPlatform.other) {
      return null;
    }
    if (_targetPlatform == AppUpdateTargetPlatform.android &&
        androidPackage !=
            (beta ? 'com.focubili.app.preview' : 'com.focubili.app')) {
      return null;
    }
    final List<String> extensions = switch (_targetPlatform) {
      AppUpdateTargetPlatform.windows => const <String>[
        '.msixbundle',
        '.msix',
        '.exe',
      ],
      AppUpdateTargetPlatform.android => const <String>['.apk'],
      AppUpdateTargetPlatform.macos => const <String>['.dmg', '.pkg'],
      AppUpdateTargetPlatform.linux => const <String>[
        '.deb',
        '.appimage',
        '.tar.gz',
      ],
      AppUpdateTargetPlatform.other => const <String>[],
    };
    for (final String extension in extensions) {
      for (final Object? rawAsset in rawAssets) {
        if (rawAsset is! Map) {
          continue;
        }
        final Map<Object?, Object?> asset = Map<Object?, Object?>.from(
          rawAsset,
        );
        final String name = (asset['name']?.toString() ?? '').trim();
        final Uri? uri = Uri.tryParse(
          (asset['browser_download_url']?.toString() ?? '').trim(),
        );
        if ((_targetPlatform != AppUpdateTargetPlatform.linux ||
                name.toLowerCase().contains('linux')) &&
            (_targetPlatform != AppUpdateTargetPlatform.android ||
                beta ||
                !RegExp(
                  r'preview|beta|debug',
                  caseSensitive: false,
                ).hasMatch(name)) &&
            name.toLowerCase().endsWith(extension) &&
            uri != null &&
            uri.path.toLowerCase().endsWith(extension) &&
            _isTrustedReleaseAsset(uri, tag, name)) {
          return uri;
        }
      }
    }
    return null;
  }

  /// 只允许打开本项目 GitHub Release 的 HTTPS 下载地址，拒绝用户信息、自定义端口和片段。
  static bool _isTrustedReleaseAsset(Uri uri, String tag, String name) {
    final segments = uri.pathSegments;
    return uri.scheme.toLowerCase() == 'https' &&
        uri.host.toLowerCase() == 'github.com' &&
        uri.userInfo.isEmpty &&
        (!uri.hasPort || uri.port == 443) &&
        uri.fragment.isEmpty &&
        !uri.hasQuery &&
        RegExp(r'^(?:v|release-)?[0-9][A-Za-z0-9.+-]*$').hasMatch(tag) &&
        RegExp(r'^[A-Za-z0-9][A-Za-z0-9._+()-]{0,179}$').hasMatch(name) &&
        segments.length == 6 &&
        segments[0].toLowerCase() == 'l1xu4n' &&
        segments[1].toLowerCase() == 'focubili' &&
        segments[2] == 'releases' &&
        segments[3] == 'download' &&
        segments[4] == tag &&
        segments[5] == name;
  }

  static Uri _safeReleasePage(Object? value, String tag) {
    final uri = Uri.tryParse(value?.toString() ?? '');
    final expected = Uri.https(
      'github.com',
      '/L1Xu4n/FocuBili/releases/tag/$tag',
    );
    return uri != null &&
            uri.scheme == 'https' &&
            uri.host.toLowerCase() == 'github.com' &&
            uri.userInfo.isEmpty &&
            (!uri.hasPort || uri.port == 443) &&
            !uri.hasQuery &&
            uri.fragment.isEmpty &&
            RegExp(r'^(?:v|release-)?[0-9][A-Za-z0-9.+-]*$').hasMatch(tag) &&
            uri.path == expected.path
        ? uri
        : releasesUri;
  }

  /// 返回与选中资产一致的按钮文案；没有安全匹配资产时引导用户查看完整 Release。
  String _downloadActionLabel(Uri? downloadUrl) {
    if (downloadUrl == null) {
      return '查看 Release';
    }
    return switch (_targetPlatform) {
      AppUpdateTargetPlatform.windows => '下载 Windows 安装包',
      AppUpdateTargetPlatform.android => '下载 Android 安装包',
      AppUpdateTargetPlatform.macos => '下载 macOS 安装包',
      AppUpdateTargetPlatform.linux => '下载 Linux 安装包',
      AppUpdateTargetPlatform.other => '查看 Release',
    };
  }

  /// Loads and validates the stable endpoint through the conditional page cache.
  Future<Map<String, Object?>> _loadLatestRelease() async {
    final decoded = await _readReleasePage(
      latestReleaseApiUri,
      channel: 'stable',
      page: 1,
      isValid: (raw) {
        if (raw is! Map<String, Object?> ||
            raw['draft'] == true ||
            raw['prerelease'] == true) {
          return false;
        }
        final version = _readVersion(raw['tag_name'] ?? raw['name']);
        return version.isNotEmpty && !version.contains('-');
      },
    );
    return decoded as Map<String, Object?>;
  }

  /// Revalidates a single page and replaces its validator and body together.
  Future<Object?> _readReleasePage(
    Uri endpoint, {
    required String channel,
    required int page,
    required bool Function(Object?) isValid,
  }) async {
    final key = 'app_update.release_page.v1.$channel.$page.$endpoint';
    SharedPreferences? preferences;
    Map<String, dynamic>? cached;
    try {
      preferences = await SharedPreferences.getInstance();
      final record = preferences.getString(key);
      if (record != null &&
          record.length <= AppUpdateTransport.maxReleaseBytes * 2 + 8192) {
        cached = jsonDecode(record) as Map<String, dynamic>;
      }
    } catch (_) {
      // Cache access is optional; a successful request still counts.
    }
    var response = await _transport.fetch(
      endpoint,
      etag: _validValidator(cached?['etag']),
      lastModified: _validValidator(cached?['lastModified']),
    );
    if (response.statusCode == HttpStatus.notModified) {
      final body = cached?['body'];
      if (body is String && body.length <= AppUpdateTransport.maxReleaseBytes) {
        final bytes = utf8.encode(body);
        if (bytes.length <= AppUpdateTransport.maxReleaseBytes &&
            sha256.convert(bytes).toString() == cached?['digest']) {
          try {
            final decoded = jsonDecode(body);
            if (isValid(decoded)) return decoded;
          } on FormatException {
            // Follow the same recovery as a missing cached body.
          }
        }
      }
      response = await _transport.fetch(endpoint);
      if (response.statusCode != HttpStatus.ok) {
        throw const FormatException('Missing release response body');
      }
    }
    final decoded = jsonDecode(response.body);
    if (!isValid(decoded)) {
      throw const FormatException('Invalid release response');
    }
    try {
      final etag = _validValidator(response.etag);
      final lastModified = _validValidator(response.lastModified);
      if (etag == null && lastModified == null) {
        if (cached != null) await preferences?.remove(key);
      } else {
        await preferences?.setString(
          key,
          jsonEncode({
            'etag': etag,
            'lastModified': lastModified,
            'body': response.body,
            'digest': sha256.convert(utf8.encode(response.body)).toString(),
          }),
        );
      }
    } catch (_) {
      // A storage error must not hide a complete network result.
    }
    return decoded;
  }

  /// Bounds response validators before persisting or sending them as headers.
  static String? _validValidator(Object? value) =>
      value is String &&
          value.isNotEmpty &&
          value.length <= 1024 &&
          value.codeUnits.every((code) => code >= 32 && code < 127)
      ? value
      : null;

  static bool isBetaVersion(String version) =>
      (_ParsedVersion.parse(
        version,
      ).preRelease?.toLowerCase().contains('beta') ??
      false);

  static bool validSemVer(String version) {
    final match = RegExp(
      r'^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$',
    ).firstMatch(version);
    return match != null &&
        !(match[4]
                ?.split('.')
                .any(
                  (part) =>
                      RegExp(r'^\d+$').hasMatch(part) &&
                      part.length > 1 &&
                      part.startsWith('0'),
                ) ??
            false);
  }

  /// 去除常见的 v/release 前缀，仅保留可用于比较和展示的版本正文。
  static String _readVersion(Object? value) {
    final String raw = value?.toString().trim() ?? '';
    final RegExpMatch? match = RegExp(
      r'(\d+(?:\.\d+){0,3}(?:-[0-9A-Za-z.-]+)?)',
    ).firstMatch(raw);
    return match?.group(1) ?? '';
  }

  /// 只读取 Release 正文固定标记内的摘要，防止整篇 Markdown 更新日志进入 App。
  static List<String> _readReleaseHighlights(Object? value) {
    final String body = value?.toString() ?? '';
    final int startIndex = body.indexOf(releaseSummaryStartMarker);
    if (startIndex < 0) {
      return const <String>[];
    }
    final int contentStart = startIndex + releaseSummaryStartMarker.length;
    final int endIndex = body.indexOf(releaseSummaryEndMarker, contentStart);
    if (endIndex < contentStart) {
      return const <String>[];
    }
    final List<String> highlights = <String>[];
    for (final String line in const LineSplitter().convert(
      body.substring(contentStart, endIndex),
    )) {
      final String highlight = _sanitizeReleaseHighlight(line);
      if (highlight.isEmpty || highlights.contains(highlight)) {
        continue;
      }
      highlights.add(highlight);
    }
    return List<String>.unmodifiable(highlights);
  }

  /// 清理单条摘要中的列表符号和基础 Markdown，并限制长度保证启动提示易读。
  static String _sanitizeReleaseHighlight(String rawLine) {
    String value = rawLine.trim();
    if (value.isEmpty || value.startsWith('<!--')) {
      return '';
    }
    value = value
        .replaceFirst(RegExp(r'^(?:[-*+]|\d+[.)])\s+'), '')
        .replaceAllMapped(
          RegExp(r'\[([^\]]+)\]\([^\)]+\)'),
          (Match match) => match.group(1) ?? '',
        )
        .replaceAll(RegExp(r'[`*_~]'), '')
        .replaceAll(RegExp(r'<[^>]+>'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (value.length <= _maximumReleaseHighlightLength) {
      return value;
    }
    return '${value.substring(0, _maximumReleaseHighlightLength).trimRight()}…';
  }

  /// 比较两个语义版本；返回正数表示 left 更新，负数表示 right 更新。
  @visibleForTesting
  static int compareVersions(String left, String right) {
    final _ParsedVersion leftVersion = _ParsedVersion.parse(left);
    final _ParsedVersion rightVersion = _ParsedVersion.parse(right);
    final int length = leftVersion.numbers.length > rightVersion.numbers.length
        ? leftVersion.numbers.length
        : rightVersion.numbers.length;
    for (int index = 0; index < length; index += 1) {
      final BigInt leftPart = index < leftVersion.numbers.length
          ? leftVersion.numbers[index]
          : BigInt.zero;
      final BigInt rightPart = index < rightVersion.numbers.length
          ? rightVersion.numbers[index]
          : BigInt.zero;
      if (leftPart != rightPart) {
        return leftPart.compareTo(rightPart);
      }
    }
    if (leftVersion.preRelease == rightVersion.preRelease) {
      return 0;
    }
    if (leftVersion.preRelease == null) {
      return 1;
    }
    if (rightVersion.preRelease == null) {
      return -1;
    }
    return _comparePreRelease(
      leftVersion.preRelease!,
      rightVersion.preRelease!,
    );
  }

  /// 按 SemVer 逐段比较预发布标识，数字段使用数值而不是字符串顺序。
  static int _comparePreRelease(String left, String right) {
    final List<String> leftParts = left.split('.');
    final List<String> rightParts = right.split('.');
    final int length = leftParts.length < rightParts.length
        ? leftParts.length
        : rightParts.length;
    for (int index = 0; index < length; index += 1) {
      final String leftPart = leftParts[index];
      final String rightPart = rightParts[index];
      if (leftPart == rightPart) {
        continue;
      }
      final BigInt? leftNumber = BigInt.tryParse(leftPart);
      final BigInt? rightNumber = BigInt.tryParse(rightPart);
      if (leftNumber != null && rightNumber != null) {
        return leftNumber.compareTo(rightNumber);
      }
      if (leftNumber != null) {
        return -1;
      }
      if (rightNumber != null) {
        return 1;
      }
      return leftPart.compareTo(rightPart);
    }
    return leftParts.length.compareTo(rightParts.length);
  }
}

/// 保存解析后的数字段和预发布标记，构建号不参与更新判断。
class _ParsedVersion {
  /// 保存已经拆分的数字版本段和可选预发布标识。
  const _ParsedVersion(this.numbers, this.preRelease);

  /// 把 v1.2.3-beta.1 等常见写法解析成可逐段比较的数据。
  factory _ParsedVersion.parse(String value) {
    final String normalized = value.trim().replaceFirst(
      RegExp(r'^[^0-9]*'),
      '',
    );
    final String withoutBuild = normalized.split('+').first;
    final List<String> parts = withoutBuild.split('-');
    final List<BigInt> numbers = parts.first
        .split('.')
        .map((String part) => BigInt.tryParse(part) ?? BigInt.zero)
        .toList(growable: false);
    return _ParsedVersion(
      numbers.isEmpty ? <BigInt>[BigInt.zero] : numbers,
      parts.length > 1 ? parts.skip(1).join('-') : null,
    );
  }

  final List<BigInt> numbers;
  final String? preRelease;
}

/// Stores the automatic deadline and the last complete available update.
class _AppUpdateStartupCache {
  /// Creates local startup state for one installation.
  const _AppUpdateStartupCache(this.retryAt, this.update);

  static const key = 'app_update.startup_cache.v1';
  static const maxLength = 16 * 1024;
  final DateTime retryAt;
  final AppUpdateResult? update;

  /// Restores a bounded record for the same installed version and channel.
  static Future<_AppUpdateStartupCache?> read(
    String identity,
    String currentVersion,
    DateTime now,
  ) async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(key);
      if (raw == null || raw.length > maxLength) return null;
      final data = jsonDecode(raw) as Map<String, dynamic>;
      if (data['installation'] != identity) return null;
      final retryAt = DateTime.parse(data['retryAt'] as String);
      if (retryAt.isAfter(now.add(AppUpdateController._startupCooldown))) {
        return null;
      }
      final saved = data['update'] as Map<String, dynamic>?;
      if (saved == null) return _AppUpdateStartupCache(retryAt, null);
      final latest = saved['latestVersion'] as String;
      if (latest.isEmpty ||
          AppUpdateService._readVersion(latest) != latest ||
          AppUpdateService.compareVersions(latest, currentVersion) <= 0) {
        return null;
      }
      final url = Uri.tryParse(saved['releaseUrl'] as String? ?? '');
      final pageTag = url?.pathSegments.lastOrNull ?? '';
      final download = Uri.tryParse(saved['downloadUrl'] as String? ?? '');
      final parts = download?.pathSegments ?? const <String>[];
      final trustedDownload =
          download != null &&
              parts.length == 6 &&
              AppUpdateService._readVersion(parts[4]) == latest &&
              AppUpdateService._isTrustedReleaseAsset(
                download,
                parts[4],
                parts[5],
              )
          ? download
          : null;
      return _AppUpdateStartupCache(
        retryAt,
        AppUpdateResult(
          status: AppUpdateStatus.available,
          currentVersion: currentVersion,
          latestVersion: latest,
          updateIdentity: saved['identity'] as String?,
          releaseUrl: AppUpdateService._safeReleasePage(url, pageTag),
          downloadUrl: trustedDownload,
          downloadActionLabel: trustedDownload == null
              ? '查看 Release'
              : saved['action'] as String,
          releaseHighlights: List<String>.from(saved['highlights'] as List),
          message: saved['message'] as String?,
        ),
      );
    } catch (_) {
      return null;
    }
  }

  /// Persists the deadline and update presentation in one preference write.
  Future<void> save(String identity) async {
    try {
      final available = update;
      final encoded = jsonEncode({
        'installation': identity,
        'retryAt': retryAt.toIso8601String(),
        'update': available == null
            ? null
            : {
                'latestVersion': available.latestVersion,
                'identity': available.updateIdentity,
                'releaseUrl': available.releaseUrl?.toString(),
                'downloadUrl': available.downloadUrl?.toString(),
                'action': available.downloadActionLabel,
                'highlights': available.releaseHighlights,
                'message': available.message,
              },
      });
      final preferences = await SharedPreferences.getInstance();
      if (encoded.length <= maxLength) {
        await preferences.setString(key, encoded);
      } else {
        await preferences.remove(key);
      }
    } catch (_) {
      // The controller still keeps the deadline for this process.
    }
  }
}

/// 统一管理启动检查、手动重试、红点和设置开关。
class AppUpdateController extends ChangeNotifier {
  /// 创建更新状态控制器，并允许测试替换网络、存储和版本读取服务。
  AppUpdateController({
    AppUpdateService? updateService,
    AppUpdatePreferencesService? preferencesService,
    AppVersionProvider? versionProvider,
    DateTime Function()? clock,
  }) : _updateService = updateService ?? AppUpdateService(),
       _persistStartupCache = preferencesService == null,
       _preferencesService =
           preferencesService ?? const AppUpdatePreferencesService(),
       _versionProvider = versionProvider ?? const PlatformAppVersionProvider(),
       _clock = clock ?? DateTime.now;

  final AppUpdateService _updateService;
  final bool _persistStartupCache;
  final AppUpdatePreferencesService _preferencesService;
  final AppVersionProvider _versionProvider;
  final DateTime Function() _clock;
  static const _startupCooldown = Duration(hours: 6);
  static const _failureBackoff = Duration(minutes: 15);
  _AppUpdateStartupCache? _startupCache;
  String? _startupCacheIdentity;
  Future<void>? _startupCheck;
  AppUpdateInstallation? _installation;

  AppUpdateResult _result = const AppUpdateResult.idle();
  AppUpdateResult? _availableUpdate;
  String? _ignoredUpdate;
  int _ignoreGeneration = 0;
  bool _savingIgnore = false;
  Future<void> _preferenceWrites = Future<void>.value();
  bool _enabled = true;
  bool _loaded = false;
  bool _checking = false;
  bool _disposed = false;
  Future<void>? _loadingFuture;
  int _requestGeneration = 0;

  /// 返回最近一次更新检查结果。
  AppUpdateResult get result => _result;

  /// 返回用户是否允许启动时检查更新。
  bool get enabled => _enabled;

  /// 返回本机开关和应用版本是否已经完成读取。
  bool get loaded => _loaded;

  /// 返回当前是否存在进行中的 GitHub 请求。
  bool get checking => _checking;

  /// 返回设置入口是否应显示新版本红点。
  bool get hasUpdate => _availableUpdate != null;

  /// 保留已经检测到的详情，后续检查失败不会移除下载入口。
  AppUpdateResult? get availableUpdate => _availableUpdate;
  bool get updateIgnored =>
      _availableUpdate?.updateIdentity != null &&
      _availableUpdate!.updateIdentity == _ignoredUpdate;
  bool get showUpdateBadge => hasUpdate && !updateIgnored;
  bool get canIgnoreUpdate =>
      _availableUpdate?.updateIdentity != null &&
      !checking &&
      !_savingIgnore &&
      !updateIgnored;

  Future<void> _saveIgnoredUpdate(String? identity) {
    final operation = _preferenceWrites.then(
      (_) => _preferencesService.saveIgnoredUpdate(identity),
    );
    _preferenceWrites = operation.catchError((Object _) {});
    return operation;
  }

  /// 只忽略调用时已经检测到的版本；迟到的写入不能撤销之后的手动检查。
  Future<void> ignoreCurrentUpdate() async {
    if (!canIgnoreUpdate || _disposed) return;
    final identity = _availableUpdate!.updateIdentity!;
    final generation = ++_ignoreGeneration;
    _savingIgnore = true;
    _notify();
    try {
      await _saveIgnoredUpdate(identity);
      if (!_disposed && generation == _ignoreGeneration) {
        _ignoredUpdate = identity;
      }
    } finally {
      _savingIgnore = false;
      _notify();
    }
  }

  /// 启动时读取开关和安装版本；仅在用户启用时访问 GitHub。
  Future<void> initialize({bool checkOnStart = true}) async {
    if (!_loaded) {
      _loadingFuture ??= _loadInitialState();
      await _loadingFuture;
      _loadingFuture = null;
    }
    if (checkOnStart) await triggerStartupCheckIfNeeded();
  }

  /// Call after the first-launch agreement is ready. Runs once per controller.
  Future<void> triggerStartupCheckIfNeeded() =>
      _startupCheck ??= _checkLatestUpdate(bypassCooldown: false);

  /// 合并并发初始化请求，页面快速重建时不会重复访问平台插件。
  Future<void> _loadInitialState() async {
    final ignoreGeneration = _ignoreGeneration;
    try {
      _enabled = await _preferencesService.loadEnabled();
      String? ignored;
      try {
        ignored = await _preferencesService.loadIgnoredUpdate();
      } catch (_) {
        // 忽略记录是可选偏好；损坏或读取失败时仍应加载版本并检查更新。
      }
      // 手动检查可能早于首次初始化；不能重新载入它已经取消的旧记录。
      if (ignoreGeneration == 0 && ignoreGeneration == _ignoreGeneration) {
        _ignoredUpdate = ignored;
      }
      final String currentVersion = await _versionProvider.loadVersion();
      final provider = _versionProvider;
      if (provider is AppUpdateInstallationProvider) {
        try {
          _installation = await (provider as AppUpdateInstallationProvider)
              .loadUpdateInstallation();
        } catch (_) {
          // Unknown package identity can inspect releases but never select an APK.
        }
      }
      _result = AppUpdateResult(
        status: _enabled ? AppUpdateStatus.idle : AppUpdateStatus.disabled,
        currentVersion: currentVersion,
        message: _enabled ? null : '已关闭启动时检查更新',
      );
      _startupCacheIdentity = jsonEncode([
        currentVersion,
        _updateService._usesBeta(currentVersion, _installation),
        _updateService._targetPlatform.name,
        _installation?.packageName,
        _installation?.certificateSha256,
        _installation?.buildNumber,
      ]);
      _startupCache = _persistStartupCache
          ? await _AppUpdateStartupCache.read(
              _startupCacheIdentity!,
              currentVersion,
              _clock(),
            )
          : null;
      final cachedUpdate = _startupCache?.update;
      if (_enabled && cachedUpdate != null) {
        _result = cachedUpdate;
        _availableUpdate = cachedUpdate;
      }
    } catch (_) {
      _result = const AppUpdateResult(
        status: AppUpdateStatus.failed,
        currentVersion: '',
        message: '无法读取应用版本信息。',
      );
    }
    _loaded = true;
    _notify();
  }

  /// 保存开关；重新开启时立即检查一次，不必等到下次启动。
  Future<void> setEnabled(bool enabled) async {
    if (!_loaded) {
      await initialize(checkOnStart: false);
    }
    await _preferencesService.saveEnabled(enabled);
    _requestGeneration += 1;
    _checking = false;
    _enabled = enabled;
    if (!enabled) {
      _availableUpdate = null;
      _result = AppUpdateResult(
        status: AppUpdateStatus.disabled,
        currentVersion: _result.currentVersion,
        message: '已关闭启动时检查更新',
      );
      _notify();
      return;
    }
    _notify();
    await _checkLatestUpdate(bypassCooldown: true);
  }

  /// 手动检查始终执行，即使启动自动检查开关处于关闭状态。
  Future<void> checkNow({bool manual = true}) async {
    if (_disposed) return;
    Future<void>? clearIgnoredUpdate;
    if (manual) {
      _ignoreGeneration++;
      _ignoredUpdate = null;
      _notify();
      clearIgnoredUpdate = _saveIgnoredUpdate(null);
    }
    // 保持偏好写入顺序，但存储迟缓或失败不能阻止主动联网检查。
    // 同时接管两个 Future 的错误，持久化失败仍由调用页面明确提示。
    await Future.wait<void>([
      ?clearIgnoredUpdate,
      _checkLatestUpdate(bypassCooldown: true),
    ], eagerError: true);
  }

  /// Consults the startup deadline for auto checks and refreshes it on completion.
  Future<void> _checkLatestUpdate({required bool bypassCooldown}) async {
    if (_checking || _disposed) {
      return;
    }
    if (!_loaded) {
      await initialize(checkOnStart: false);
    }
    if (_checking || _disposed || _result.currentVersion.isEmpty) {
      return;
    }
    final retryAt = _startupCache?.retryAt;
    if (!bypassCooldown &&
        (!_enabled || (retryAt != null && _clock().isBefore(retryAt)))) {
      return;
    }
    final int requestGeneration = ++_requestGeneration;
    _checking = true;
    _result = AppUpdateResult(
      status: AppUpdateStatus.checking,
      currentVersion: _result.currentVersion,
      message: '正在检查更新…',
    );
    _notify();
    final AppUpdateResult checkedResult = await _updateService.check(
      currentVersion: _result.currentVersion,
      installation: _installation,
    );
    if (_disposed || requestGeneration != _requestGeneration) {
      return;
    }
    _result = checkedResult;
    if (checkedResult.updateAvailable) {
      _availableUpdate = checkedResult;
    } else if (checkedResult.status == AppUpdateStatus.upToDate) {
      _availableUpdate = null;
    }
    final identity = _startupCacheIdentity;
    final delay = checkedResult.status == AppUpdateStatus.failed
        ? _failureBackoff
        : _startupCooldown;
    final cache = _AppUpdateStartupCache(_clock().add(delay), _availableUpdate);
    _startupCache = cache;
    _checking = false;
    _notify();
    if (_persistStartupCache && identity != null) await cache.save(identity);
  }

  /// 异步平台调用返回较晚时，不向已经释放的页面控制器发送通知。
  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  /// 释放控制器并让尚未返回的异步请求自动失效。
  @override
  void dispose() {
    _disposed = true;
    _requestGeneration += 1;
    super.dispose();
  }
}

/// 把全应用唯一更新控制器暴露给“我的”、设置和关于页。
class AppUpdateScope extends InheritedNotifier<AppUpdateController> {
  /// 创建全应用更新状态作用域，使多个入口共享同一份结果。
  const AppUpdateScope({
    super.key,
    required AppUpdateController controller,
    required super.child,
  }) : super(notifier: controller);

  /// 尝试读取更新控制器；没有作用域时返回 null，方便独立组件测试。
  static AppUpdateController? maybeOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<AppUpdateScope>()
        ?.notifier;
  }

  /// 读取必需的更新控制器，并在开发模式下提示缺少作用域。
  static AppUpdateController of(BuildContext context) {
    final AppUpdateController? controller = maybeOf(context);
    assert(controller != null, 'No AppUpdateScope found in context.');
    return controller!;
  }
}
