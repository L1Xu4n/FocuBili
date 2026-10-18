import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/video_preview.dart';
import 'bilibili_course_link.dart';
import 'bilibili_auth_service.dart';

/// Transport is injectable so tests never use a real login or paid content.
typedef CourseJsonRequest = Future<String> Function(Uri uri, String cookie);

class PurchasedCourse {
  const PurchasedCourse({
    required this.id,
    required this.title,
    required this.cover,
    required this.description,
    required this.unavailable,
    required this.expired,
  });
  final int id;
  final String title, cover, description;
  final bool unavailable, expired;
  Uri get uri => Uri.https('www.bilibili.com', '/cheese/play/ss$id');
}

class CourseLookupException implements Exception {
  const CourseLookupException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Reads official classroom metadata. Playback authorization remains server-side.
class BilibiliCourseService {
  BilibiliCourseService({
    CourseJsonRequest? requestJson,
    Future<String> Function()? readCookies,
  }) : _requestJson = requestJson ?? _request,
       _readCookies = readCookies ?? BilibiliAuthService().readCookieHeader;

  final CourseJsonRequest _requestJson;
  final Future<String> Function() _readCookies;

  /// 仅确认目标课程的当前账号购买资格，不保存或返回其他购买资料。
  Future<void> requirePurchasedCourse(int seasonId, String cookie) async {
    if (seasonId <= 0 || cookie.trim().isEmpty) {
      throw const CourseLookupException('请先登录购买课程的 B 站账号。');
    }
    var received = 0;
    final seen = <int>{};
    for (var page = 1; page <= 100; page++) {
      if (cookie != await _readCookies().timeout(const Duration(seconds: 10))) {
        throw const CourseLookupException('登录状态已变化，请重新打开课程。');
      }
      final data = _data(
        await _requestJson(
          Uri.https('api.bilibili.com', '/pugv/pay/web/my/paid', {
            'pn': '$page',
            'ps': '10',
          }),
          cookie,
        ).timeout(const Duration(seconds: 30)),
      );
      final total = _int(data['total'], fallback: -1);
      final raw = data['data'];
      if (total < 0 || (raw is! List && !(total == 0 && raw == null))) {
        throw const CourseLookupException('无法确认课程购买状态，请重试。');
      }
      final items = raw is List ? raw : const [];
      final before = seen.length;
      for (final value in items) {
        final item = _map(value);
        final id = _int(item['id']);
        if (id <= 0) throw const CourseLookupException('无法确认课程购买状态，请重试。');
        seen.add(id);
        if (id != seasonId) continue;
        if (_int(item['status']) == -3 ||
            item['is_expired'] == true ||
            _int(item['is_expired']) == 1) {
          throw const CourseLookupException('本课程已过期或已下架，请到官方课堂确认。');
        }
        if (cookie !=
            await _readCookies().timeout(const Duration(seconds: 10))) {
          throw const CourseLookupException('登录状态已变化，请重新打开课程。');
        }
        return;
      }
      received += items.length;
      if (received >= total) break;
      if (seen.length == before) {
        throw const CourseLookupException('无法完整确认课程购买状态，请重试。');
      }
    }
    throw const CourseLookupException('当前账号未购买本课程，或购买资格已失效。');
  }

  /// Same paginated endpoint and fields as the official classroom "mine" page.
  /// Publish only a complete list from one session; never cache purchase data.
  Future<List<PurchasedCourse>> purchasedCourses() async {
    try {
      final cookie = await _readCookies().timeout(const Duration(seconds: 10));
      if (cookie.trim().isEmpty) {
        throw const CourseLookupException('请先在“我的”登录购买课程的 B 站账号。');
      }
      final courses = <PurchasedCourse>[];
      final seen = <int>{};
      var received = 0;
      for (var pn = 1; pn <= 100; pn++) {
        final data = _data(
          await _requestJson(
            Uri.https('api.bilibili.com', '/pugv/pay/web/my/paid', {
              'pn': '$pn',
              'ps': '10',
            }),
            cookie,
          ).timeout(const Duration(seconds: 30)),
        );
        final total = _int(data['total'], fallback: -1);
        final items = data['data'];
        if (total < 0 || (items is! List && !(total == 0 && items == null))) {
          throw const CourseLookupException('已购课程返回格式发生变化，请稍后重试。');
        }
        final batch = items is List ? items : const [];
        final before = courses.length;
        for (final raw in batch) {
          final item = _map(raw);
          final id = _int(item['id']);
          if (id <= 0) {
            throw const CourseLookupException('已购课程数据不完整，请重试。');
          }
          if (!seen.add(id)) continue;
          courses.add(
            PurchasedCourse(
              id: id,
              title: _text(item['title'], 'B站课堂'),
              cover: _image(item['cover']),
              description: [
                _text(item['sub_title'], ''),
                _text(item['update_info'], ''),
              ].where((text) => text.isNotEmpty).join(' · '),
              unavailable: _int(item['status']) == -3,
              expired:
                  item['is_expired'] == true || _int(item['is_expired']) == 1,
            ),
          );
        }
        if (cookie !=
            await _readCookies().timeout(const Duration(seconds: 10))) {
          throw const CourseLookupException('登录状态已变化，请刷新已购课程。');
        }
        received += batch.length;
        if (received >= total) {
          if (courses.length < total) {
            throw const CourseLookupException('已购课程列表未加载完整，请刷新重试。');
          }
          return List.unmodifiable(courses);
        }
        if (courses.length == before) break;
      }
      throw const CourseLookupException('已购课程列表未加载完整，请刷新重试。');
    } on CourseLookupException {
      rethrow;
    } on TimeoutException {
      throw const CourseLookupException('已购课程加载超时，请检查网络后重试。');
    } catch (_) {
      throw const CourseLookupException('已购课程加载失败，请检查网络后重试。');
    }
  }

  Future<VideoPreview> lookup(Uri input) async {
    final uri = BilibiliCourseLink.parse(input.toString());
    if (uri == null) throw const CourseLookupException('无效的课堂链接。');
    try {
      // Keep a single session snapshot across pagination. Never store it in data.
      final cookie = await _readCookies().timeout(const Duration(seconds: 10));
      final target = uri.pathSegments.last;
      if (cookie.trim().isEmpty) {
        throw const CourseLookupException('请先登录购买课程的 B 站账号。');
      }
      final requestedEpisode = target.startsWith('ep')
          ? int.parse(target.substring(2))
          : null;
      final data = _data(
        await _requestJson(
          Uri.https('api.bilibili.com', '/pugv/view/web/season', {
            requestedEpisode == null ? 'season_id' : 'ep_id': target.substring(
              2,
            ),
          }),
          cookie,
        ),
      );
      final seasonId = _int(data['season_id']);
      if (seasonId <= 0) throw const CourseLookupException('课程接口缺少课程编号。');
      if (requestedEpisode == null &&
          seasonId != int.parse(target.substring(2))) {
        throw const CourseLookupException('返回的课程编号不一致，请重试。');
      }
      final rawEpisodes = <Map<String, dynamic>>[];
      await requirePurchasedCourse(seasonId, cookie);
      final episodeIds = <int>{};
      void append(Object? items) {
        if (items is List) {
          for (final item in items) {
            if (item is Map<String, dynamic> &&
                episodeIds.add(_int(item['id']))) {
              rawEpisodes.add(item);
            }
          }
        }
      }

      append(data['episodes']);
      final page = _map(data['episode_page']);
      final total = _int(page['total']);
      if (page['next'] == true || (total > rawEpisodes.length)) {
        // Restart the dedicated list at page 1: season endpoint page size varies.
        rawEpisodes.clear();
        episodeIds.clear();
        var finished = false;
        for (var pn = 1; pn <= 100; pn++) {
          final batch = _data(
            await _requestJson(
              Uri.https('api.bilibili.com', '/pugv/view/web/ep/list', {
                'season_id': '$seasonId',
                'pn': '$pn',
                'ps': '100',
              }),
              cookie,
            ),
          );
          final before = rawEpisodes.length;
          append(batch['items']);
          final pageInfo = _map(batch['page']);
          final batchTotal = _int(pageInfo['total']);
          if (pageInfo['next'] == false ||
              (batchTotal > 0 && rawEpisodes.length >= batchTotal)) {
            finished = true;
            break;
          }
          if (before == rawEpisodes.length) break;
        }
        if (!finished || (total > 0 && rawEpisodes.length < total)) {
          throw const CourseLookupException('课程目录未加载完整，请重试。');
        }
      }
      // Preserve official order, keep valid unavailable chapters so the server
      // can explain purchase restrictions when selected; never infer entitlement.
      final seen = <int>{};
      final parts = <VideoPart>[];
      for (final ep in rawEpisodes) {
        final id = _int(ep['id']);
        final cid = _int(ep['cid']);
        final aid = _int(ep['aid']);
        if (id <= 0 || cid <= 0 || aid <= 0 || !seen.add(id)) continue;
        parts.add(
          VideoPart(
            pageNumber: parts.length + 1,
            cid: cid,
            title: _text(ep['title'], '课程章节'),
            duration: Duration(seconds: _int(ep['duration']).clamp(0, 86400)),
            courseEpisodeId: id,
            courseAid: aid,
          ),
        );
      }
      if (parts.isEmpty) throw const CourseLookupException('该课程尚无可播放的视频章节。');
      final selected = requestedEpisode == null
          ? parts.first
          : parts
                .where((part) => part.courseEpisodeId == requestedEpisode)
                .firstOrNull;
      if (selected == null) {
        throw const CourseLookupException('目录中没有找到指定章节，请从课程主页重新打开。');
      }
      // A concurrent logout/account switch must not publish stale metadata.
      if (cookie != await _readCookies().timeout(const Duration(seconds: 10))) {
        throw const CourseLookupException('登录状态已变化，请重新打开课程。');
      }
      final author = _map(data['up_info']);
      return VideoPreview(
        bvid: 'cheese:ss$seasonId',
        courseSeasonId: seasonId,
        requestedCourseEpisodeId: requestedEpisode,
        cid: selected.cid,
        title: _text(data['title'], 'B站课堂'),
        ownerName: _text(author['uname'], '课程讲师'),
        ownerMid: _int(author['mid']),
        ownerAvatarUrl: _image(author['avatar']),
        thumbnailUrl: _image(data['cover']),
        description: _text(data['subtitle'], ''),
        duration: Duration(
          seconds: parts.fold<int>(0, (sum, p) => sum + p.duration.inSeconds),
        ),
        parts: List.unmodifiable(parts),
      );
    } on CourseLookupException {
      rethrow;
    } on TimeoutException {
      throw const CourseLookupException('课程目录请求超时，请检查网络后重试。');
    } catch (_) {
      throw const CourseLookupException('课程目录加载失败，请检查网络和登录状态后重试。');
    }
  }

  static Map<String, dynamic> _data(String json) {
    final root = _map(jsonDecode(json));
    final code = _int(root['code'], fallback: -1);
    if (code != 0) {
      throw CourseLookupException(switch (code) {
        -101 || -401 => '登录已失效，请在“我的”重新登录购买课程的账号。',
        -403 => '当前账号没有该课程的访问权限，请确认购买账号。',
        -404 => '课程不存在或已下架。',
        _ => '课程接口请求失败（错误码 $code），请稍后重试。',
      });
    }
    if (root['data'] is! Map) {
      throw const CourseLookupException('课程接口返回的数据不完整。');
    }
    return _map(root['data']);
  }

  static Map<String, dynamic> _map(Object? value) =>
      value is Map<String, dynamic> ? value : {};
  static int _int(Object? value, {int fallback = 0}) =>
      value is num ? value.toInt() : int.tryParse('$value') ?? fallback;
  static String _text(Object? value, String fallback) =>
      value is String && value.trim().isNotEmpty ? value.trim() : fallback;
  static String _image(Object? value) {
    var text = _text(value, '');
    if (text.startsWith('//')) text = 'https:$text';
    if (text.startsWith('http://')) text = 'https://${text.substring(7)}';
    return Uri.tryParse(text)?.scheme == 'https' ? text : '';
  }

  static Future<String> _request(Uri uri, String cookie) async {
    // Only fixed official API endpoints may receive the in-memory session.
    if (uri.scheme != 'https' ||
        uri.host != 'api.bilibili.com' ||
        !const {
          '/pugv/view/web/season',
          '/pugv/view/web/ep/list',
          '/pugv/pay/web/my/paid',
        }.contains(uri.path)) {
      throw const CourseLookupException('无效的课程请求地址。');
    }
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 12);
    try {
      final request = await client
          .getUrl(uri)
          .timeout(const Duration(seconds: 15));
      request.followRedirects = false;
      request.headers.set(
        HttpHeaders.refererHeader,
        'https://www.bilibili.com/',
      );
      request.headers.set(
        HttpHeaders.userAgentHeader,
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
      );
      if (cookie.isNotEmpty) {
        request.headers.set(HttpHeaders.cookieHeader, cookie);
      }
      final response = await request.close().timeout(
        const Duration(seconds: 15),
      );
      if (response.statusCode != 200) {
        throw CourseLookupException('课程服务暂不可用（HTTP ${response.statusCode}）。');
      }
      return await response
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 15));
    } finally {
      client.close(force: true);
    }
  }
}
