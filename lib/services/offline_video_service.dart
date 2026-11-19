import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/offline_video_download.dart';
import '../models/video_preview.dart';
import '../models/playback_preferences.dart';
import '../platform/platform_services.dart';
import 'bilibili_cookie_store.dart';
import 'offline_cache_locations.dart';
import 'offline_media_plan.dart';
import 'download_control.dart';
import 'resumable_media_download.dart';

/// Supplies isolated preferences for storage tests.
typedef OfflineVideoPreferencesLoader = Future<SharedPreferences> Function();

/// Supplies the application-owned download root.
typedef OfflineVideoDirectoryLoader = Future<Directory> Function();

/// Reports user-readable failures without URLs or credentials.
class OfflineVideoException implements Exception {
  /// Creates a sanitized error message.
  const OfflineVideoException(this.message);
  final String message;

  /// Returns only the sanitized explanation.
  @override
  String toString() => message;
}

/// Downloads one selected part, publishing metadata only after complete persistence.
class OfflineVideoService {
  /// Injects network/storage boundaries without requiring a logged-in account.
  OfflineVideoService({
    OfflineVideoPreferencesLoader? preferencesLoader,
    OfflineVideoDirectoryLoader? directoryLoader,
    OfflineCacheLocations? cacheLocations,
    BilibiliCookieStore? cookieStore,
    Future<String> Function(Uri, Map<String, String>)? requestText,
    Future<int> Function(
      Uri,
      Map<String, String>,
      File,
      void Function(int, int?),
    )?
    downloadFile,
  }) : _preferencesLoader = preferencesLoader ?? SharedPreferences.getInstance,
       _directoryLoader = directoryLoader ?? getApplicationDocumentsDirectory,
       cacheLocations =
           cacheLocations ??
           (directoryLoader == null
               ? OfflineCacheLocations.instance
               : OfflineCacheLocations.systemOnly),
       _cookieStore =
           cookieStore ?? PlatformServices.current.createBilibiliCookieStore(),
       _requestText = requestText,
       _downloadFile = downloadFile;

  static const _storageKey = 'focubili_offline_videos_v1';
  static final revision = ValueNotifier<int>(0);
  static const _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/126.0.0.0 Safari/537.36';
  static final _bvidPattern = RegExp(r'^BV[0-9A-Za-z]{10}$');
  static final Set<String> _activeDownloads = <String>{};
  static Future<void> _queue = Future<void>.value();
  final OfflineVideoPreferencesLoader _preferencesLoader;
  final OfflineVideoDirectoryLoader _directoryLoader;
  final OfflineCacheLocations cacheLocations;
  final BilibiliCookieStore _cookieStore;
  final Future<String> Function(Uri, Map<String, String>)? _requestText;
  final Future<int> Function(
    Uri,
    Map<String, String>,
    File,
    void Function(int, int?),
  )?
  _downloadFile;

  /// Serializes metadata mutations across pages without serializing network transfers.
  Future<T> _mutate<T>(Future<T> Function() action) {
    final next = _queue.then((_) => action());
    _queue = next.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );
    return next;
  }

  /// Reads strict metadata, preserving damaged content rather than overwriting it.
  Future<List<OfflineVideoDownload>> _readDownloads() async {
    try {
      final prefs = await _preferencesLoader();
      final raw = prefs.getString(_storageKey);
      if (raw == null) return [];
      final decoded = jsonDecode(raw);
      if (decoded is! List) throw const FormatException();
      final downloads = <OfflineVideoDownload>[];
      for (final entry in decoded) {
        if (entry is! Map) throw const FormatException();
        final item = OfflineVideoDownload.tryParse(
          Map<String, dynamic>.from(entry),
        );
        if (item == null ||
            !_bvidPattern.hasMatch(item.bvid) ||
            item.cid <= 0) {
          throw const FormatException();
        }
        downloads.add(item);
      }
      return downloads;
    } catch (_) {
      throw const OfflineVideoException('离线记录无法读取，原始数据已保留。');
    }
  }

  /// Checks the underlying write result so callers cannot report false success.
  Future<void> _writeStorage(List<OfflineVideoDownload> items) async {
    try {
      final prefs = await _preferencesLoader();
      if (!await prefs.setString(
        _storageKey,
        jsonEncode(items.map((e) => e.toJson()).toList()),
      )) {
        throw StateError('write rejected');
      }
    } catch (_) {
      throw const OfflineVideoException('离线记录保存失败，请检查可用空间后重试。');
    }
  }

  Future<Directory> _root(String? locationId) => locationId == null
      ? _directoryLoader()
      : cacheLocations.requireRoot(locationId);

  /// Builds a narrow BV-owned directory; never accepts path traversal components.
  Future<Directory?> _directory(
    String bvid,
    String? locationId, {
    required bool create,
  }) async {
    if (!_bvidPattern.hasMatch(bvid)) {
      throw const OfflineVideoException('无效的 BV 号。');
    }
    return OfflineCacheLocations.childDirectory(
      await _root(locationId),
      ['offline_videos', bvid],
      create: create,
      createRoot: locationId == null,
    );
  }

  /// Refuses links, directories and special files at generated cache filenames.
  Future<File> _regularFile(Directory directory, String name) =>
      _checkedFile(File.fromUri(directory.uri.resolve(name)));

  Future<File> _checkedFile(File file) async {
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type != FileSystemEntityType.file &&
        type != FileSystemEntityType.notFound) {
      throw const OfflineVideoException('离线文件路径无效，未访问该文件。');
    }
    return file;
  }

  /// Validates both tracks against their original (not current) root before
  /// either file is used for playback, deletion, or replacement.
  Future<List<File>> _ownedFiles(OfflineVideoDownload item) async {
    final root = await _root(item.cacheLocationId);
    final directory = Directory.fromUri(
      root.absolute.uri.resolve('offline_videos/${item.bvid}/'),
    );
    await OfflineCacheLocations.childDirectory(root, [
      'offline_videos',
      item.bvid,
    ], create: false);

    Future<File> validate(String path, String extensionPattern) async {
      final file = File(path).absolute;
      if (file.parent.uri != directory.uri ||
          (item.cacheLocationId != null &&
              !RegExp(
                '^${item.cid}-[0-9]+-$extensionPattern\$',
              ).hasMatch(file.uri.pathSegments.last))) {
        throw const OfflineVideoException('离线文件路径无效，未访问该文件。');
      }
      return _checkedFile(file);
    }

    return [
      await validate(item.filePath, r'video\.mp4'),
      if (item.audioFilePath case final path?)
        await validate(path, r'audio\.m4a'),
    ];
  }

  /// 只有视频及可选音频都完整时才返回缓存，兼容旧版单文件记录。
  Future<List<OfflineVideoDownload>> loadDownloads() async {
    final ready = <OfflineVideoDownload>[];
    for (final item in await _readDownloads()) {
      try {
        final files = await _ownedFiles(item);
        final file = files.first;
        final audio = files.length == 2 ? files.last : null;
        if (item.status == OfflineDownloadStatus.ready &&
            await file.exists() &&
            item.videoSizeBytes > 0 &&
            await file.length() == item.videoSizeBytes &&
            (audio == null ||
                (item.audioSizeBytes > 0 &&
                    await audio.exists() &&
                    await audio.length() == item.audioSizeBytes))) {
          ready.add(item);
        }
      } on OfflineCacheLocationUnavailable {
        // A removed external drive must not hide other downloads or erase
        // metadata needed when the drive comes back.
        if (item.cacheLocationId == null) rethrow;
      } on FileSystemException {
        if (item.cacheLocationId == null) rethrow;
      }
    }
    ready.sort((a, b) => b.downloadedAt.compareTo(a.downloadedAt));
    return List.unmodifiable(ready);
  }

  /// Looks up either a selected part or any downloaded part of the BV.
  Future<bool> isDownloaded(String bvid, {int? cid}) async =>
      (await loadDownloads()).any(
        (item) => item.bvid == bvid && (cid == null || item.cid == cid),
      );

  /// Computes the storage occupied by verified finished downloads.
  Future<int> totalSizeBytes() async =>
      (await loadDownloads()).fold<int>(0, (sum, e) => sum + e.sizeBytes);

  /// Removes only a task's deterministic partial file and its validator sidecar.
  Future<void> discardPartial(
    String bvid,
    int cid,
    int quality, {
    String? cacheLocationId,
  }) async {
    if (cid <= 0 || quality <= 0) throw const OfflineVideoException('下载编号无效。');
    final directory = await _directory(bvid, cacheLocationId, create: false);
    if (directory == null) return;
    final files = [
      for (final suffix in [
        'video.part',
        'video.part.resume',
        'audio.part',
        'audio.part.resume',
      ])
        await _regularFile(directory, '$cid-$quality-$suffix'),
    ];
    for (final file in files) {
      if (await file.exists()) await file.delete();
    }
  }

  /// 从当前账号实际返回的完整音视频地址列出缓存档位，不再把高清 DASH 排除。
  Future<List<PreferredPlaybackQuality>> availableQualities(
    VideoPreview video,
    VideoPart part,
  ) async {
    if (!_bvidPattern.hasMatch(video.bvid) || part.cid <= 0) {
      throw const OfflineVideoException('视频或分 P 编号无效。');
    }
    final cookie = await _cookieStore.readCookies();
    final endpoint = Uri.https('api.bilibili.com', '/x/player/playurl', {
      'bvid': video.bvid,
      'cid': '${part.cid}',
      'qn': '120',
      'fnval': '16',
      'fourk': '1',
    });
    final headers = <String, String>{
      'User-Agent': _userAgent,
      'Referer': 'https://www.bilibili.com/video/${video.bvid}',
      if (cookie.isNotEmpty) 'Cookie': cookie,
    };
    final text =
        await (_requestText != null
                ? _requestText(endpoint, headers)
                : _defaultRequestText(endpoint, headers))
            .timeout(const Duration(seconds: 25));
    final Set<int> ids;
    try {
      ids = OfflineMediaPlan.availableQualityIds(
        OfflineMediaPlan.decodeData(text),
      );
    } on OfflineMediaPlanException {
      throw const OfflineVideoException('无法读取下载清晰度，请检查网络或登录状态。');
    }
    final qualities = PreferredPlaybackQuality.values
        .where((quality) => ids.contains(quality.id))
        .toList()
        .reversed
        .toList();
    if (qualities.isEmpty) throw const OfflineVideoException('当前视频没有可用的离线清晰度。');
    return qualities;
  }

  /// 下载当前分 P 的完整音视频，全部校验通过后一次发布，失败或暂停保留可续传文件。
  Future<OfflineVideoDownload> download(
    VideoPreview video, {
    VideoPart? part,
    int quality = 32,
    void Function(int, int?)? onProgress,
    DownloadControl? control,
    String? cacheLocationId,
  }) async {
    final target = part ?? video.initialPart;
    final bvid = video.bvid.trim();
    if (!_bvidPattern.hasMatch(bvid) || target.cid <= 0 || quality <= 0) {
      throw const OfflineVideoException('视频或分 P 编号无效。');
    }
    final key = '$bvid:${target.cid}';
    if (!_activeDownloads.add(key)) {
      throw const OfflineVideoException('这个分 P 正在下载中。');
    }
    File? temporary;
    File? temporaryAudio;
    File? published;
    File? publishedAudio;
    bool saved = false;
    try {
      control?.check();
      final directory = await _directory(bvid, cacheLocationId, create: true);
      if (directory == null) throw OfflineCacheLocationException.unavailable;
      final prefix = '${target.cid}-$quality';
      await _regularFile(directory, '$prefix-video.part.resume');
      await _regularFile(directory, '$prefix-audio.part.resume');
      temporary = await _regularFile(directory, '$prefix-video.part');
      temporaryAudio = await _regularFile(directory, '$prefix-audio.part');
      final stem = '${target.cid}-${DateTime.now().microsecondsSinceEpoch}';
      final cookieRequest = _cookieStore.readCookies();
      final cookie = await (control?.guard(cookieRequest) ?? cookieRequest);
      final referer = 'https://www.bilibili.com/video/$bvid';
      final apiHeaders = <String, String>{
        'User-Agent': _userAgent,
        'Referer': referer,
        if (cookie.isNotEmpty) 'Cookie': cookie,
      };
      final mediaHeaders = <String, String>{
        'User-Agent': _userAgent,
        'Referer': referer,
        'Origin': 'https://www.bilibili.com',
        'Accept-Encoding': 'identity',
      };
      OfflineMediaPlan? info;
      int? size;
      int audioSize = 0;
      String? completedAudioIdentity;
      for (int attempt = 0; attempt < 2 && size == null; attempt++) {
        control?.check();
        final endpoint = Uri.https('api.bilibili.com', '/x/player/playurl', {
          'bvid': bvid,
          'cid': '${target.cid}',
          'qn': '$quality',
          'fnval': '16',
          'fourk': '1',
        });
        final request = _requestText != null
            ? _requestText(endpoint, apiHeaders)
            : _defaultRequestText(endpoint, apiHeaders, control: control);
        try {
          info = OfflineMediaPlan.fromData(
            OfflineMediaPlan.decodeData(
              await (control?.guard(request) ?? request),
            ),
            quality,
          );
        } on OfflineMediaPlanException catch (error) {
          throw OfflineVideoException(error.message);
        }
        if (info.quality < quality) {
          throw const OfflineVideoException('所选下载清晰度当前不可用，请删除任务后选择其他清晰度。');
        }
        control?.check();
        try {
          final plan = info;
          final audio = plan.audio;
          if (audio != null) {
            if (completedAudioIdentity != audio.identity ||
                audioSize <= 0 ||
                !await temporaryAudio.exists() ||
                await temporaryAudio.length() != audioSize) {
              final existingVideoBytes = await temporary.exists()
                  ? await temporary.length()
                  : 0;
              // 音频先下载；随后视频的 Content-Length 可给出完整的合计进度。
              audioSize = await _downloadTrack(
                audio,
                temporaryAudio,
                mediaHeaders,
                control,
                (received, total) => onProgress?.call(
                  existingVideoBytes + received,
                  plan.video.expectedBytes != null &&
                          (total ?? audio.expectedBytes) != null
                      ? plan.video.expectedBytes! +
                            (total ?? audio.expectedBytes!)
                      : null,
                ),
              );
              completedAudioIdentity = audio.identity;
            }
          } else {
            audioSize = 0;
            completedAudioIdentity = null;
            await _discardTrackPartial(temporaryAudio);
          }
          size = await _downloadTrack(
            plan.video,
            temporary,
            mediaHeaders,
            control,
            (received, total) => onProgress?.call(
              audioSize + received,
              total == null ? null : audioSize + total,
            ),
          );
        } on DownloadInterrupted {
          rethrow;
        } catch (_) {
          control?.check();
          // 下一轮刷新临时地址；同一音轨已完成时可直接复用。
        }
      }
      if (size == null || info == null) {
        throw const OfflineVideoException('下载失败，请检查网络和可用空间后重试。');
      }
      control?.check();
      await _directory(bvid, cacheLocationId, create: false);
      final videoOutput = File.fromUri(
        directory.uri.resolve('$stem-video.mp4'),
      );
      final audioOutput = File.fromUri(
        directory.uri.resolve('$stem-audio.m4a'),
      );
      for (final file in [videoOutput, if (info.audio != null) audioOutput]) {
        if (await FileSystemEntity.type(file.path, followLinks: false) !=
            FileSystemEntityType.notFound) {
          throw const OfflineVideoException('缓存文件名冲突，请重试。');
        }
      }
      published = await temporary.rename(videoOutput.path);
      if (info.audio != null) {
        publishedAudio = await temporaryAudio.rename(audioOutput.path);
      }
      final item = OfflineVideoDownload(
        bvid: bvid,
        cid: target.cid,
        title: video.parts.length > 1
            ? '${video.title} · P${target.pageNumber} ${target.title}'
            : video.title,
        coverUrl: video.thumbnailUrl,
        ownerName: video.ownerName.isEmpty ? '未知 UP 主' : video.ownerName,
        filePath: published.absolute.path,
        cacheLocationId: cacheLocationId,
        audioFilePath: publishedAudio?.absolute.path,
        audioSizeBytes: audioSize,
        sizeBytes: size + audioSize,
        qualityId: info.quality,
        qualityLabel: _qualityLabel(info.quality),
        duration: target.duration,
        downloadedAt: DateTime.now(),
        status: OfflineDownloadStatus.ready,
        originalTitle: video.title,
        parts: video.parts,
      );
      await _mutate(() async {
        final items = await _readDownloads();
        control?.check();
        final previous = items
            .where((e) => e.bvid == bvid && e.cid == target.cid)
            .toList();
        await _writeStorage([
          ...items.where((e) => e.bvid != bvid || e.cid != target.cid),
          item,
        ]);
        saved = true;
        revision.value++;
        for (final old in previous) {
          try {
            for (final file in await _ownedFiles(old)) {
              if (await file.exists()) await file.delete();
            }
          } catch (_) {
            /* Preserve the newly committed record. */
          }
        }
      });
      return item;
    } on DownloadInterrupted {
      rethrow;
    } on OfflineVideoException {
      rethrow;
    } on OfflineCacheLocationException catch (error) {
      throw OfflineVideoException(error.message);
    } catch (_) {
      throw const OfflineVideoException('下载失败，请检查网络和可用空间后重试。');
    } finally {
      try {
        if (temporary != null && (control == null || saved)) {
          await discardPartial(
            bvid,
            target.cid,
            quality,
            cacheLocationId: cacheLocationId,
          );
        }
        if (!saved &&
            (published != null || publishedAudio != null) &&
            await _directory(bvid, cacheLocationId, create: false) != null) {
          if (published != null && await published.exists()) {
            await published.delete();
          }
          if (publishedAudio != null && await publishedAudio.exists()) {
            await publishedAudio.delete();
          }
        }
      } catch (_) {
        // An offline drive must not mask a transfer failure or committed record.
      } finally {
        _activeDownloads.remove(key);
      }
    }
  }

  /// Deletes only selected owned files; pending downloads must finish before deletion.
  Future<bool> delete(String bvid, {int? cid}) => _mutate(() async {
    if (_activeDownloads.any(
      (key) => cid == null ? key.startsWith('$bvid:') : key == '$bvid:$cid',
    )) {
      throw const OfflineVideoException('视频仍在下载，请完成后再删除。');
    }
    final items = await _readDownloads();
    final targets = items
        .where((e) => e.bvid == bvid && (cid == null || e.cid == cid))
        .toList();
    if (targets.isEmpty) return false;
    final files = <File>[];
    for (final item in targets) {
      files.addAll(await _ownedFiles(item));
    }
    for (final file in files) {
      if (await file.exists()) await file.delete();
    }
    await _writeStorage(items.where((e) => !targets.contains(e)).toList());
    revision.value++;
    return true;
  });

  /// Clears known files only, refusing to race a download or recursively remove directories.
  Future<bool> clearAll() => _mutate(() async {
    if (_activeDownloads.isNotEmpty) {
      throw const OfflineVideoException('请等待下载完成后再清空。');
    }
    final items = await _readDownloads();
    if (items.isEmpty) return false;
    final files = <File>[];
    final unavailable = <OfflineVideoDownload>[];
    for (final item in items) {
      try {
        files.addAll(await _ownedFiles(item));
      } on OfflineCacheLocationUnavailable {
        if (item.cacheLocationId == null) rethrow;
        unavailable.add(item);
      }
    }
    if (unavailable.length == items.length) return false;
    for (final file in files) {
      if (await file.exists()) await file.delete();
    }
    await _writeStorage(unavailable);
    revision.value++;
    return true;
  });

  /// 在同一轨道主备地址间重试；续传绑定轨道摘要，防止更换编码后拼接旧字节。
  Future<int> _downloadTrack(
    OfflineMediaTrack track,
    File output,
    Map<String, String> headers,
    DownloadControl? control,
    void Function(int, int?) onProgress,
  ) async {
    for (final url in track.urls) {
      try {
        /// 每次进度回调先检查暂停或取消，再汇总到整份音视频缓存。
        void report(int received, int? total) {
          control?.check();
          onProgress(received, total);
        }

        final received = _downloadFile != null
            ? await _downloadFile(Uri.parse(url), headers, output, report)
            : await const ResumableMediaDownload().download(
                Uri.parse(url),
                headers,
                output,
                report,
                control: control,
                mediaIdentity: sha256
                    .convert(utf8.encode(track.identity))
                    .toString(),
              );
        control?.check();
        if (received <= 0 ||
            !await output.exists() ||
            await output.length() != received ||
            (track.expectedBytes != null && received != track.expectedBytes)) {
          await _discardTrackPartial(output);
          throw const OfflineVideoException('下载文件不完整，请重试。');
        }
        return received;
      } on DownloadInterrupted {
        rethrow;
      } catch (_) {
        control?.check();
        if (control == null) await _discardTrackPartial(output);
      }
    }
    throw const OfflineVideoException('媒体下载失败，可稍后重试。');
  }

  /// 仅清理当前轨道的临时文件与续传信息，不触碰另一条已完成的轨道。
  Future<void> _discardTrackPartial(File output) async {
    for (final file in [output, File('${output.path}.resume')]) {
      if (await file.exists()) await file.delete();
    }
  }

  /// 使用实际轨道清晰度的名称，高清档位沿用播放器已有名称。
  String _qualityLabel(int quality) =>
      PreferredPlaybackQuality.values
          .where((item) => item.id == quality)
          .firstOrNull
          ?.label ??
      '清晰度 $quality';

  /// Calls the fixed HTTPS API without following redirects with session cookies.
  static Future<String> _defaultRequestText(
    Uri uri,
    Map<String, String> headers, {
    DownloadControl? control,
  }) async {
    control?.check();
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    control?.abort = () => client.close(force: true);
    try {
      final request = await client.getUrl(uri);
      request.followRedirects = false;
      headers.forEach(request.headers.set);
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      if (response.statusCode != 200) {
        throw const OfflineVideoException('下载信息请求失败。');
      }
      return await response
          .timeout(const Duration(seconds: 20))
          .transform(utf8.decoder)
          .join();
    } catch (_) {
      control?.check();
      rethrow;
    } finally {
      control?.abort = null;
      client.close(force: true);
    }
  }
}
