import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 表示一次 GitHub Release 更新检查的最终状态。
enum AppUpdateStatus { idle, disabled, checking, upToDate, available, failed }

/// 保存当前版本、远端版本和 Release 页面，供“关于”页统一展示。
class AppUpdateResult {
  /// 创建一份可供设置页和关于页共同读取的更新检查结果。
  const AppUpdateResult({
    required this.status,
    required this.currentVersion,
    this.latestVersion,
    this.releaseUrl,
    this.message,
  });

  /// 创建尚未读取版本、也未发起网络请求的初始结果。
  const AppUpdateResult.idle()
    : status = AppUpdateStatus.idle,
      currentVersion = '',
      latestVersion = null,
      releaseUrl = null,
      message = null;

  final AppUpdateStatus status;
  final String currentVersion;
  final String? latestVersion;
  final Uri? releaseUrl;
  final String? message;

  /// 指示当前结果是否需要显示新版本红点。
  bool get updateAvailable => status == AppUpdateStatus.available;
}

/// 提供安装包版本，测试可以用内存实现替代平台插件。
abstract interface class AppVersionProvider {
  /// 返回当前安装包去掉构建号后的公开版本号。
  Future<String> loadVersion();
}

/// 从 Android/iOS 安装包元数据读取 pubspec 对应版本号。
class PlatformAppVersionProvider implements AppVersionProvider {
  /// 创建使用 package_info_plus 读取版本的平台实现。
  const PlatformAppVersionProvider();

  /// 从系统安装包元数据读取当前应用版本。
  @override
  Future<String> loadVersion() async {
    final PackageInfo info = await PackageInfo.fromPlatform();
    return info.version;
  }
}

/// 保存“启动时检查更新”开关，数据仅存放在当前设备。
class AppUpdatePreferencesService {
  /// 创建只访问当前设备 SharedPreferences 的开关服务。
  const AppUpdatePreferencesService();

  static const String _enabledKey = 'app_update.check_on_start';

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

/// 读取 GitHub 最新正式 Release，并进行纯本地语义版本比较。
class AppUpdateService {
  /// 创建更新服务；测试可以注入本地 Release 数据或 HTTP 客户端。
  AppUpdateService({
    Future<Map<String, Object?>> Function()? releaseLoader,
    HttpClient? httpClient,
  }) : _releaseLoader = releaseLoader,
       _httpClient = httpClient;

  static final Uri releasesUri = Uri.parse(
    'https://github.com/L1Xu4n/FocuBili/releases',
  );
  static final Uri latestReleaseApiUri = Uri.parse(
    'https://api.github.com/repos/L1Xu4n/FocuBili/releases/latest',
  );

  final Future<Map<String, Object?>> Function()? _releaseLoader;
  final HttpClient? _httpClient;

  /// 请求最新正式 Release；网络、限流和格式错误均转换为可展示的失败状态。
  Future<AppUpdateResult> check({required String currentVersion}) async {
    try {
      final Map<String, Object?> release = _releaseLoader == null
          ? await _loadLatestRelease()
          : await _releaseLoader();
      final String latestVersion = _readVersion(
        release['tag_name'] ?? release['name'],
      );
      if (latestVersion.isEmpty) {
        throw const FormatException('Release 没有可识别的版本号。');
      }
      final Uri releaseUrl =
          Uri.tryParse(release['html_url']?.toString() ?? '') ??
          AppUpdateService.releasesUri;
      final bool available = compareVersions(latestVersion, currentVersion) > 0;
      return AppUpdateResult(
        status: available
            ? AppUpdateStatus.available
            : AppUpdateStatus.upToDate,
        currentVersion: currentVersion,
        latestVersion: latestVersion,
        releaseUrl: releaseUrl,
        message: available ? '发现新版本 $latestVersion' : '当前已是最新版本',
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

  /// 使用带超时的系统 HTTP 客户端访问 GitHub API，避免启动检查长期占用连接。
  Future<Map<String, Object?>> _loadLatestRelease() async {
    final HttpClient client = _httpClient ?? HttpClient();
    final bool ownsClient = _httpClient == null;
    try {
      client.connectionTimeout = const Duration(seconds: 8);
      final HttpClientRequest request = await client.getUrl(
        latestReleaseApiUri,
      );
      request.headers
        ..set(HttpHeaders.acceptHeader, 'application/vnd.github+json')
        ..set(HttpHeaders.userAgentHeader, 'FocuBili-update-checker')
        ..set('X-GitHub-Api-Version', '2022-11-28');
      final HttpClientResponse response = await request.close().timeout(
        const Duration(seconds: 10),
      );
      final String body = await utf8.decoder
          .bind(response)
          .join()
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException(
          'GitHub update check returned ${response.statusCode}.',
          uri: latestReleaseApiUri,
        );
      }
      final Object? decoded = jsonDecode(body);
      if (decoded is! Map<String, Object?>) {
        throw const FormatException('GitHub Release 响应格式无效。');
      }
      return decoded;
    } finally {
      if (ownsClient) {
        client.close(force: true);
      }
    }
  }

  /// 去除常见的 v/release 前缀，仅保留可用于比较和展示的版本正文。
  static String _readVersion(Object? value) {
    final String raw = value?.toString().trim() ?? '';
    final RegExpMatch? match = RegExp(
      r'(\d+(?:\.\d+){0,3}(?:-[0-9A-Za-z.-]+)?)',
    ).firstMatch(raw);
    return match?.group(1) ?? '';
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
      final int leftPart = index < leftVersion.numbers.length
          ? leftVersion.numbers[index]
          : 0;
      final int rightPart = index < rightVersion.numbers.length
          ? rightVersion.numbers[index]
          : 0;
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
      final int? leftNumber = int.tryParse(leftPart);
      final int? rightNumber = int.tryParse(rightPart);
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
    final List<int> numbers = parts.first
        .split('.')
        .map((String part) => int.tryParse(part) ?? 0)
        .toList(growable: false);
    return _ParsedVersion(
      numbers.isEmpty ? const <int>[0] : numbers,
      parts.length > 1 ? parts.skip(1).join('-') : null,
    );
  }

  final List<int> numbers;
  final String? preRelease;
}

/// 统一管理启动检查、手动重试、红点和设置开关。
class AppUpdateController extends ChangeNotifier {
  /// 创建更新状态控制器，并允许测试替换网络、存储和版本读取服务。
  AppUpdateController({
    AppUpdateService? updateService,
    AppUpdatePreferencesService? preferencesService,
    AppVersionProvider? versionProvider,
  }) : _updateService = updateService ?? AppUpdateService(),
       _preferencesService =
           preferencesService ?? const AppUpdatePreferencesService(),
       _versionProvider = versionProvider ?? const PlatformAppVersionProvider();

  final AppUpdateService _updateService;
  final AppUpdatePreferencesService _preferencesService;
  final AppVersionProvider _versionProvider;

  AppUpdateResult _result = const AppUpdateResult.idle();
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
  bool get hasUpdate => _result.updateAvailable;

  /// 启动时读取开关和安装版本；仅在用户启用时访问 GitHub。
  Future<void> initialize({bool checkOnStart = true}) async {
    if (!_loaded) {
      _loadingFuture ??= _loadInitialState();
      await _loadingFuture;
      _loadingFuture = null;
    }
    if (!_disposed && checkOnStart && _enabled) {
      await checkNow();
    }
  }

  /// 合并并发初始化请求，页面快速重建时不会重复访问平台插件。
  Future<void> _loadInitialState() async {
    try {
      _enabled = await _preferencesService.loadEnabled();
      final String currentVersion = await _versionProvider.loadVersion();
      _result = AppUpdateResult(
        status: _enabled ? AppUpdateStatus.idle : AppUpdateStatus.disabled,
        currentVersion: currentVersion,
        message: _enabled ? null : '已关闭启动时检查更新',
      );
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
      _result = AppUpdateResult(
        status: AppUpdateStatus.disabled,
        currentVersion: _result.currentVersion,
        message: '已关闭启动时检查更新',
      );
      _notify();
      return;
    }
    _notify();
    await checkNow();
  }

  /// 手动检查始终执行，即使启动自动检查开关处于关闭状态。
  Future<void> checkNow() async {
    if (_checking) {
      return;
    }
    if (!_loaded) {
      await initialize(checkOnStart: false);
    }
    if (_result.currentVersion.isEmpty) {
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
    );
    if (_disposed || requestGeneration != _requestGeneration) {
      return;
    }
    _result = checkedResult;
    _checking = false;
    _notify();
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
