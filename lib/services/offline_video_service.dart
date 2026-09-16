import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/offline_video_download.dart';
import '../models/video_preview.dart';
import 'bilibili_cookie_store.dart';

/// 定义读取离线缓存偏好设置的可替换入口，便于单元测试使用内存存储。
typedef OfflineVideoPreferencesLoader = Future<SharedPreferences> Function();

/// 定义离线下载目录读取函数，测试可注入独立临时目录。
typedef OfflineVideoDirectoryLoader = Future<Directory> Function();

/// 表示离线下载失败，并只携带可直接展示的中文说明。
class OfflineVideoException implements Exception {
  /// 创建不包含 Cookie 或临时地址的离线下载异常。
  const OfflineVideoException(this.message);

  final String message;

  /// 返回可直接展示给普通用户的错误文字。
  @override
  String toString() => message;
}

/// 保存解析渐进式播放响应后的可下载地址列表与真实清晰度。
class _ProgressivePlayInfo {
  /// 创建包含按优先顺序排列的媒体地址与接口返回清晰度的信息。
  const _ProgressivePlayInfo({required this.urls, required this.actualQuality});

  final List<String> urls;
  final int actualQuality;
}

/// 把视频完整下载到本机，供无网络时直接播放。
///
/// 下载使用不带 Cookie 依赖的公开播放接口，并尽量选择免登录可用的
/// 渐进式单一音视频流；已下载文件保存在应用私有目录中。
class OfflineVideoService {
  /// 创建离线下载服务；测试可注入存储、目录、Cookie 与请求函数。
  OfflineVideoService({
    OfflineVideoPreferencesLoader? preferencesLoader,
    OfflineVideoDirectoryLoader? directoryLoader,
    BilibiliCookieStore? cookieStore,
    Future<String> Function(Uri uri, Map<String, String> headers)? requestText,
    Future<int> Function(
      Uri uri,
      Map<String, String> headers,
      File output,
      void Function(int received, int? total) onProgress,
    )?
    downloadFile,
  }) : _preferencesLoader = preferencesLoader ?? SharedPreferences.getInstance,
       _directoryLoader = directoryLoader ?? _loadDefaultDownloadDirectory,
       _cookieStore = cookieStore ?? PlatformBilibiliCookieStore(),
       _requestText = requestText ?? _defaultRequestText,
       _downloadFile = downloadFile ?? _defaultDownloadFile;

  static const String _storageKey = 'focubili_offline_videos_v1';
  static const String _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
      'AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/126.0.0.0 Safari/537.36';
  static final RegExp _bvidPattern = RegExp(
    r'^BV[0-9A-Za-z]{10}$',
    caseSensitive: false,
  );

  final OfflineVideoPreferencesLoader _preferencesLoader;
  final OfflineVideoDirectoryLoader _directoryLoader;
  final BilibiliCookieStore _cookieStore;
  final Future<String> Function(Uri uri, Map<String, String> headers)
  _requestText;
  final Future<int> Function(
    Uri uri,
    Map<String, String> headers,
    File output,
    void Function(int received, int? total) onProgress,
  )
  _downloadFile;

  /// 读取全部已完成的离线视频，按下载时间从新到旧排序。
  Future<List<OfflineVideoDownload>> loadDownloads() async {
    final List<OfflineVideoDownload> downloads = _decodeDownloads(
      await _readStorage(),
    );
    final List<OfflineVideoDownload> ready =
        downloads
            .where(
              (OfflineVideoDownload download) =>
                  download.status != OfflineDownloadStatus.failed &&
                  File(download.filePath).existsSync(),
            )
            .toList(growable: false)
          ..sort(
            (OfflineVideoDownload left, OfflineVideoDownload right) =>
                right.downloadedAt.compareTo(left.downloadedAt),
          );
    return List<OfflineVideoDownload>.unmodifiable(ready);
  }

  /// 判断指定 BV 是否已有可播放的离线文件。
  Future<bool> isDownloaded(String bvid) async {
    final String normalizedBvid = bvid.trim();
    if (normalizedBvid.isEmpty) {
      return false;
    }
    final List<OfflineVideoDownload> downloads = await loadDownloads();
    return downloads.any(
      (OfflineVideoDownload download) => download.bvid == normalizedBvid,
    );
  }

  /// 计算全部离线文件占用字节数。
  Future<int> totalSizeBytes() async {
    final List<OfflineVideoDownload> downloads = await loadDownloads();
    int total = 0;
    for (final OfflineVideoDownload download in downloads) {
      total += download.sizeBytes;
    }
    return total;
  }

  /// 下载指定视频的首个分P；完成后写入本机记录并返回可播放的离线条目。
  Future<OfflineVideoDownload> download(
    VideoPreview video, {
    int quality = 32,
    void Function(int received, int? total)? onProgress,
  }) async {
    final String bvid = video.bvid.trim();
    final int cid = video.initialPart.cid;
    if (!_bvidPattern.hasMatch(bvid)) {
      throw const OfflineVideoException('请输入有效的 BV 号。');
    }
    if (cid <= 0) {
      throw const OfflineVideoException('该视频没有可下载的分P编号。');
    }
    final Directory directory = await _resolveDownloadDirectory(bvid);
    final File output = File(
      '${directory.path}${Platform.pathSeparator}video.mp4',
    );
    final String referer = 'https://www.bilibili.com/video/$bvid';
    final String cookieHeader = await _cookieStore.readCookies();
    final Map<String, String> requestHeaders = <String, String>{
      'Accept': 'application/json',
      'Referer': referer,
      'User-Agent': _userAgent,
      if (cookieHeader.isNotEmpty) 'Cookie': cookieHeader,
    };
    final Map<String, String> mediaHeaders = <String, String>{
      'Accept': '*/*',
      'Accept-Encoding': 'identity',
      'Origin': 'https://www.bilibili.com',
      'Referer': referer,
      'User-Agent': _userAgent,
      if (cookieHeader.isNotEmpty) 'Cookie': cookieHeader,
    };
    // CDN 节点偶发故障或签名失效时，重新请求一次播放接口拿到带新签名的
    // 地址再试，行为与 yt-dlp 在下载失败后重新提取一致。
    late int sizeBytes;
    _ProgressivePlayInfo playInfo;
    for (int attempt = 0; ; attempt += 1) {
      final Uri playurl = Uri.https(
        'api.bilibili.com',
        '/x/player/playurl',
        <String, String>{
          'bvid': bvid,
          'cid': '$cid',
          'qn': '$quality',
          'fnval': '0',
          'fourk': '0',
        },
      );
      final String responseText = await _requestText(playurl, requestHeaders);
      playInfo = _parseProgressiveInfo(responseText);
      try {
        sizeBytes = await _downloadWithFallback(
          playInfo.urls,
          headers: mediaHeaders,
          output: output,
          onProgress: onProgress ?? (int received, int? total) {},
        );
        break;
      } on OfflineVideoException {
        if (attempt >= 1) {
          rethrow;
        }
        // 第一次主备地址全部失败时继续循环，重新拉取播放地址后重试。
      }
    }
    final OfflineVideoDownload download = OfflineVideoDownload(
      bvid: bvid,
      cid: cid,
      title: video.title.trim().isEmpty ? '未命名视频' : video.title.trim(),
      coverUrl: video.thumbnailUrl.trim(),
      ownerName: video.ownerName.trim(),
      filePath: output.absolute.path,
      sizeBytes: sizeBytes,
      qualityId: playInfo.actualQuality,
      qualityLabel: _qualityLabel(playInfo.actualQuality),
      duration: video.initialPart.duration,
      downloadedAt: DateTime.now(),
      status: OfflineDownloadStatus.ready,
    );
    final List<OfflineVideoDownload> downloads = _decodeDownloads(
      await _readStorage(),
    );
    final List<OfflineVideoDownload> updated =
        downloads
            .where((OfflineVideoDownload existing) => existing.bvid != bvid)
            .toList()
          ..add(download);
    await _writeStorage(updated);
    return download;
  }

  /// 删除指定 BV 的离线文件与本机记录，并返回是否确实删除了内容。
  Future<bool> delete(String bvid) async {
    final String normalizedBvid = bvid.trim();
    if (normalizedBvid.isEmpty) {
      return false;
    }
    final List<OfflineVideoDownload> downloads = _decodeDownloads(
      await _readStorage(),
    );
    final List<OfflineVideoDownload> updated = downloads
        .where(
          (OfflineVideoDownload download) => download.bvid != normalizedBvid,
        )
        .toList(growable: false);
    if (updated.length == downloads.length) {
      return false;
    }
    try {
      final Directory directory = await _resolveDownloadDirectory(
        normalizedBvid,
      );
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    } on Object {
      // 文件删除失败时不阻止记录清理，避免残留元数据反复提示下载完成。
    }
    await _writeStorage(updated);
    return true;
  }

  /// 清空全部离线缓存并返回是否清理了内容。
  Future<bool> clearAll() async {
    final List<OfflineVideoDownload> downloads = _decodeDownloads(
      await _readStorage(),
    );
    if (downloads.isEmpty) {
      return false;
    }
    for (final OfflineVideoDownload download in downloads) {
      try {
        final Directory directory = await _resolveDownloadDirectory(
          download.bvid,
        );
        if (await directory.exists()) {
          await directory.delete(recursive: true);
        }
      } on Object {
        // 单个文件删除失败不阻止继续清理其余离线内容。
      }
    }
    await _writeStorage(const <OfflineVideoDownload>[]);
    return true;
  }

  /// 依次尝试下载地址，主地址失败时继续使用接口提供的备用地址。
  Future<int> _downloadWithFallback(
    List<String> urls, {
    required Map<String, String> headers,
    required File output,
    required void Function(int received, int? total) onProgress,
  }) async {
    Object? lastError;
    for (final String mediaUrl in urls) {
      final Uri mediaUri = Uri.parse(mediaUrl);
      try {
        return await _downloadFile(mediaUri, headers, output, onProgress);
      } on Object catch (error) {
        lastError = error;
        if (urls.length == 1) {
          break;
        }
        // 主地址所在节点不可达或返回错误时，改用备用 CDN 地址重试。
      }
    }
    if (lastError is OfflineVideoException) {
      throw lastError;
    }
    throw const OfflineVideoException('视频下载失败，请稍后重试。');
  }

  /// 解析渐进式播放响应，返回经过安全校验的媒体地址列表与真实清晰度。
  _ProgressivePlayInfo _parseProgressiveInfo(String responseText) {
    final Object? decoded;
    try {
      decoded = jsonDecode(responseText);
    } on FormatException {
      throw const OfflineVideoException('播放数据格式不正确，请稍后重试。');
    }
    if (decoded is! Map) {
      throw const OfflineVideoException('播放数据格式不正确，请稍后重试。');
    }
    final Map<Object?, Object?> root = Map<Object?, Object?>.from(decoded);
    final int code = (root['code'] as num?)?.toInt() ?? -1;
    if (code != 0) {
      final String message = (root['message'] as String?)?.trim() ?? '';
      throw OfflineVideoException(
        message.isEmpty || message == '0'
            ? '无法取得下载地址（错误码：$code）。未登录账号通常只能下载较低清晰度。'
            : '无法取得下载地址：$message（错误码：$code）。',
      );
    }
    final Object? rawData = root['data'];
    if (rawData is! Map) {
      throw const OfflineVideoException('播放数据服务没有返回下载信息。');
    }
    final Map<Object?, Object?> data = Map<Object?, Object?>.from(rawData);
    final int actualQuality = (data['quality'] as num?)?.toInt() ?? 32;
    final Object? rawDurl = data['durl'];
    if (rawDurl is! List || rawDurl.isEmpty) {
      throw const OfflineVideoException('该视频没有可用于下载的渐进式播放数据。');
    }
    final Object? first = rawDurl.first;
    if (first is! Map) {
      throw const OfflineVideoException('播放数据返回了无法识别的下载条目。');
    }
    final Map<Object?, Object?> durl = Map<Object?, Object?>.from(first);
    final List<String> candidates = <String>[];
    final String primaryUrl = (durl['url'] as String?)?.trim() ?? '';
    if (_isSafeMediaUrl(primaryUrl)) {
      candidates.add(primaryUrl);
    }
    final Object? rawBackups = durl['backup_url'];
    if (rawBackups is List) {
      for (final Object? rawUrl in rawBackups) {
        final String backupUrl = (rawUrl as String?)?.trim() ?? '';
        if (_isSafeMediaUrl(backupUrl) && !candidates.contains(backupUrl)) {
          candidates.add(backupUrl);
        }
      }
    }
    if (candidates.isEmpty) {
      throw const OfflineVideoException('播放数据返回了不可用的下载地址，请稍后重试。');
    }
    return _ProgressivePlayInfo(
      urls: List<String>.unmodifiable(candidates),
      actualQuality: actualQuality > 0 ? actualQuality : 32,
    );
  }

  /// 判断地址是否可安全下载。
  ///
  /// 与 yt-dlp / Seal 的做法一致：地址来自 B 站官方接口，本身已可信，不再
  /// 按域名过滤（B 站 CDN 域名会持续变化，维护白名单只会误伤）。只保留
  /// 最小校验：必须 http/https、不带用户信息或片段，且不能指向本机或
  /// 内网的字面 IP（防 SSRF），其余公开主机名一律放行。
  bool _isSafeMediaUrl(String value) {
    final Uri? uri = Uri.tryParse(value);
    final String scheme = uri?.scheme.toLowerCase() ?? '';
    if (uri == null ||
        (scheme != 'https' && scheme != 'http') ||
        uri.userInfo.isNotEmpty ||
        uri.fragment.isNotEmpty) {
      return false;
    }
    final String host = uri.host.toLowerCase();
    if (host.isEmpty || host.contains(RegExp(r'\s'))) {
      return false;
    }
    final InternetAddress? address = InternetAddress.tryParse(host);
    if (address == null) {
      // 非字面 IP 的公开主机名：放行，解析交给系统与 CDN。
      return true;
    }
    if (address.isLoopback || address.isLinkLocal || address.isMulticast) {
      return false;
    }
    if (address.type == InternetAddressType.IPv4 && _isPrivateIpv4(host)) {
      return false;
    }
    return true;
  }

  /// 判断点分 IPv4 文本是否属于私有或保留网段。
  static bool _isPrivateIpv4(String host) {
    final List<int> parts = <int>[];
    for (final String part in host.split('.')) {
      final int? value = int.tryParse(part);
      if (value == null || value < 0 || value > 255) {
        return false;
      }
      parts.add(value);
    }
    if (parts.length != 4) {
      return false;
    }
    final int first = parts[0];
    final int second = parts[1];
    return first == 0 ||
        first == 10 ||
        first == 127 ||
        (first == 100 && second >= 64 && second <= 127) ||
        (first == 169 && second == 254) ||
        (first == 172 && second >= 16 && second <= 31) ||
        (first == 192 && second == 168) ||
        (first == 198 && (second == 18 || second == 19));
  }

  /// 解析并创建唯一允许管理的下载目录，拒绝指向文件系统根目录等宽泛目标。
  Future<Directory> _resolveDownloadDirectory(String bvid) async {
    final Directory root = await _directoryLoader();
    final Directory directory = Directory(
      '${root.path}${Platform.pathSeparator}offline_videos'
      '${Platform.pathSeparator}$bvid',
    );
    await directory.create(recursive: true);
    return directory;
  }

  /// 为常见 B 站清晰度编号生成稳定中文名称。
  String _qualityLabel(int quality) {
    return switch (quality) {
      120 => '超清 4K',
      116 => '高清 1080P60',
      112 => '高清 1080P+',
      80 => '高清 1080P',
      64 => '高清 720P',
      32 => '清晰 480P',
      16 => '流畅 360P',
      _ => '清晰度 $quality',
    };
  }

  /// 读取本机存储的原始文本；存储不可用时返回 null。
  Future<String?> _readStorage() async {
    try {
      final SharedPreferences preferences = await _preferencesLoader();
      return preferences.getString(_storageKey);
    } on Object {
      return null;
    }
  }

  /// 解析本机 JSON，只保留可安全恢复且文件仍存在的离线记录。
  List<OfflineVideoDownload> _decodeDownloads(String? rawJson) {
    if (rawJson == null || rawJson.trim().isEmpty) {
      return const <OfflineVideoDownload>[];
    }
    try {
      final Object? decoded = jsonDecode(rawJson);
      if (decoded is! List) {
        return const <OfflineVideoDownload>[];
      }
      final Set<String> seenBvids = <String>{};
      final List<OfflineVideoDownload> downloads = <OfflineVideoDownload>[];
      for (final Object? entry in decoded) {
        if (entry is! Map) {
          continue;
        }
        final OfflineVideoDownload? download = OfflineVideoDownload.tryParse(
          Map<String, dynamic>.from(entry),
        );
        if (download != null && seenBvids.add(download.bvid)) {
          downloads.add(download);
        }
      }
      return downloads;
    } on Object {
      // JSON 被截断或被手动修改时按空列表处理，避免应用启动崩溃。
      return const <OfflineVideoDownload>[];
    }
  }

  /// 序列化并写入本机；写入失败时静默返回，下次操作会再次尝试保存。
  Future<void> _writeStorage(List<OfflineVideoDownload> downloads) async {
    try {
      final SharedPreferences preferences = await _preferencesLoader();
      await preferences.setString(
        _storageKey,
        jsonEncode(
          downloads
              .map((OfflineVideoDownload download) => download.toJson())
              .toList(growable: false),
        ),
      );
    } on Object {
      // 本机写入失败时用户仍可继续使用当前页面。
    }
  }

  /// 在 path_provider 返回的应用文档目录下创建固定下载目录。
  static Future<Directory> _loadDefaultDownloadDirectory() async {
    final Directory documents = await getApplicationDocumentsDirectory();
    return Directory(
      '${documents.path}${Platform.pathSeparator}offline_videos',
    );
  }

  /// 默认播放接口请求函数，带超时并拒绝非成功状态。
  static Future<String> _defaultRequestText(
    Uri uri,
    Map<String, String> headers,
  ) async {
    final HttpClient client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final HttpClientRequest request = await client.getUrl(uri);
      headers.forEach(request.headers.set);
      final HttpClientResponse response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      final String body = await response.transform(utf8.decoder).join();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw OfflineVideoException('下载服务暂时不可用（HTTP ${response.statusCode}）。');
      }
      if (body.trim().isEmpty) {
        throw const OfflineVideoException('下载服务返回了空内容。');
      }
      return body;
    } on TimeoutException {
      throw const OfflineVideoException('请求下载信息超时，请检查网络。');
    } on SocketException {
      throw const OfflineVideoException('无法连接下载服务，请检查网络。');
    } finally {
      client.close(force: true);
    }
  }

  /// 默认流式下载函数，把响应按块写入文件并回报进度。
  static Future<int> _defaultDownloadFile(
    Uri uri,
    Map<String, String> headers,
    File output,
    void Function(int received, int? total) onProgress,
  ) async {
    final HttpClient client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20);
    try {
      final HttpClientRequest request = await client.getUrl(uri);
      headers.forEach(request.headers.set);
      final HttpClientResponse response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw OfflineVideoException('视频下载失败（HTTP ${response.statusCode}）。');
      }
      final int? total = response.contentLength > 0
          ? response.contentLength
          : null;
      final IOSink sink = output.openWrite();
      int received = 0;
      try {
        await for (final List<int> chunk in response) {
          sink.add(chunk);
          received += chunk.length;
          onProgress(received, total);
        }
      } finally {
        await sink.close();
      }
      if (received <= 0) {
        throw const OfflineVideoException('视频下载内容为空。');
      }
      return received;
    } on TimeoutException {
      throw const OfflineVideoException('视频下载超时，请稍后重试。');
    } on SocketException {
      throw const OfflineVideoException('下载连接中断，请检查网络后重试。');
    } finally {
      client.close(force: true);
    }
  }
}
