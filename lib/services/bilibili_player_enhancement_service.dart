import 'dart:convert';
import 'dart:io';

import '../models/player_enhancement.dart';

/// 定义可替换的播放器增强 JSON 请求函数，组件测试不需要访问真实网络。
typedef PlayerEnhancementJsonRequest = Future<String> Function(Uri uri);

/// 表示章节或互动剧情接口失败，并保留适合直接显示的简短说明。
class PlayerEnhancementException implements Exception {
  /// 创建一条播放器增强功能的失败说明。
  const PlayerEnhancementException(this.message);

  final String message;

  /// 把异常转换为页面和日志都可读的文字。
  @override
  String toString() => message;
}

/// 定义播放器读取章节和互动剧情所需的最小能力。
abstract interface class BilibiliPlayerEnhancementService {
  /// 读取指定 BV 与 CID 的章节及互动视频版本信息。
  Future<PlayerEnhancementMetadata> loadMetadata({
    required String bvid,
    required int cid,
  });

  /// 读取互动剧情的起始节点或用户刚选择的目标节点。
  Future<InteractiveVideoNode> loadInteractiveNode({
    required String bvid,
    required int graphVersion,
    int? edgeId,
  });
}

/// 使用 B 站公开网页接口读取章节和互动剧情，不读取或保存用户 Cookie。
class BilibiliPublicPlayerEnhancementService
    implements BilibiliPlayerEnhancementService {
  /// 创建服务；正式环境使用 HTTPS，测试可以传入固定 JSON 请求函数。
  BilibiliPublicPlayerEnhancementService({
    PlayerEnhancementJsonRequest? requestJson,
  }) : _requestJson = requestJson ?? _requestPublicJson;

  static const String _apiHost = 'api.bilibili.com';
  static const String _playerInfoPath = '/x/player/wbi/v2';
  static const String _interactiveEdgePath = '/x/stein/edgeinfo_v2';
  static const String _desktopUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
      'AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/126.0.0.0 Safari/537.36';

  final PlayerEnhancementJsonRequest _requestJson;

  /// 请求播放器信息，并把 view_points 与 interaction 转为稳定的本地模型。
  @override
  Future<PlayerEnhancementMetadata> loadMetadata({
    required String bvid,
    required int cid,
  }) async {
    final Uri endpoint = Uri.https(_apiHost, _playerInfoPath, <String, String>{
      'bvid': bvid,
      'cid': cid.toString(),
    });
    final Map<Object?, Object?> data = _readApiData(
      await _requestJson(endpoint),
      fallbackMessage: '暂时无法读取视频分段信息。',
    );
    final List<VideoChapter> chapters = _parseChapters(data['view_points']);
    final Map<Object?, Object?> interaction = _readMap(data['interaction']);
    final int graphVersion = _readInt(interaction['graph_version']);
    return PlayerEnhancementMetadata(
      chapters: List<VideoChapter>.unmodifiable(chapters),
      interaction: graphVersion > 0
          ? InteractiveVideoInfo(graphVersion: graphVersion)
          : null,
    );
  }

  /// 请求剧情节点，并只保留播放器切换分支真正需要的编号、CID 与文案。
  @override
  Future<InteractiveVideoNode> loadInteractiveNode({
    required String bvid,
    required int graphVersion,
    int? edgeId,
  }) async {
    final Map<String, String> query = <String, String>{
      'bvid': bvid,
      'graph_version': graphVersion.toString(),
      if (edgeId != null && edgeId > 0) 'edge_id': edgeId.toString(),
    };
    final Uri endpoint = Uri.https(_apiHost, _interactiveEdgePath, query);
    final Map<Object?, Object?> data = _readApiData(
      await _requestJson(endpoint),
      fallbackMessage: '暂时无法读取互动剧情选项。',
    );
    final Map<Object?, Object?> edges = _readMap(data['edges']);
    final List<Object?> questions = _readList(edges['questions']);
    final Map<Object?, Object?> firstQuestion = questions.isEmpty
        ? const <Object?, Object?>{}
        : _readMap(questions.first);
    final List<InteractiveVideoChoice> choices = _readList(
      firstQuestion['choices'],
    ).map(_parseChoice).whereType<InteractiveVideoChoice>().toList();
    return InteractiveVideoNode(
      title: _readText(data['title']),
      edgeId: _readInt(data['edge_id']),
      isLeaf: _readInt(data['is_leaf']) == 1,
      choices: List<InteractiveVideoChoice>.unmodifiable(choices),
    );
  }

  /// 把单个剧情选项转换为本地模型，缺少目标 CID 的损坏项会被忽略。
  static InteractiveVideoChoice? _parseChoice(Object? rawChoice) {
    final Map<Object?, Object?> choice = _readMap(rawChoice);
    final int cid = _readInt(choice['cid']);
    final int edgeId = _readInt(choice['id']);
    if (cid <= 0 || edgeId <= 0) {
      return null;
    }
    final String label = _readText(choice['option']);
    return InteractiveVideoChoice(
      edgeId: edgeId,
      cid: cid,
      label: label.isEmpty ? '继续剧情' : label,
    );
  }

  /// 解析按时间排列的章节，并过滤空标题、倒序和重复数据。
  static List<VideoChapter> _parseChapters(Object? rawChapters) {
    final List<VideoChapter> chapters = <VideoChapter>[];
    final Set<String> seen = <String>{};
    for (final Object? rawChapter in _readList(rawChapters)) {
      final Map<Object?, Object?> chapter = _readMap(rawChapter);
      final int startSeconds = _readNumber(chapter['from']).round();
      final int endSeconds = _readNumber(chapter['to']).round();
      final String title = _readText(chapter['content']);
      final String identity = '$startSeconds:$endSeconds:$title';
      if (title.isEmpty || endSeconds <= startSeconds || !seen.add(identity)) {
        continue;
      }
      chapters.add(
        VideoChapter(
          title: title,
          start: Duration(seconds: startSeconds),
          end: Duration(seconds: endSeconds),
          imageUrl: _normalizeImageUrl(_readText(chapter['img_url'])),
        ),
      );
    }
    chapters.sort(
      (VideoChapter left, VideoChapter right) =>
          left.start.compareTo(right.start),
    );
    return chapters;
  }

  /// 检查接口状态码并返回 data 对象，异常响应统一转为可理解的错误。
  static Map<Object?, Object?> _readApiData(
    String responseText, {
    required String fallbackMessage,
  }) {
    final Object? decoded = jsonDecode(responseText);
    final Map<Object?, Object?> root = _readMap(decoded);
    if (_readInt(root['code']) != 0 || root['data'] is! Map) {
      final String message = _readText(root['message']);
      throw PlayerEnhancementException(
        message.isEmpty ? fallbackMessage : message,
      );
    }
    return _readMap(root['data']);
  }

  /// 把协议相对地址和 HTTP 图片地址统一升级为可缓存的 HTTPS 地址。
  static String _normalizeImageUrl(String value) {
    if (value.startsWith('//')) {
      return 'https:$value';
    }
    if (value.startsWith('http://')) {
      return 'https://${value.substring(7)}';
    }
    return value;
  }

  /// 将任意映射安全转换为 Object 映射，字段缺失时返回空映射。
  static Map<Object?, Object?> _readMap(Object? value) {
    return value is Map
        ? Map<Object?, Object?>.from(value)
        : const <Object?, Object?>{};
  }

  /// 将任意数组安全转换为列表，字段缺失时返回空列表。
  static List<Object?> _readList(Object? value) {
    return value is List ? List<Object?>.from(value) : const <Object?>[];
  }

  /// 读取可能为数字或字符串的整数字段，无法解析时返回零。
  static int _readInt(Object? value) {
    return value is num
        ? value.toInt()
        : int.tryParse(value?.toString() ?? '') ?? 0;
  }

  /// 读取可能为数字或字符串的小数字段，无法解析时返回零。
  static double _readNumber(Object? value) {
    return value is num
        ? value.toDouble()
        : double.tryParse(value?.toString() ?? '') ?? 0;
  }

  /// 读取文字并去掉两端空白，非文字字段会安全转为空字符串。
  static String _readText(Object? value) => value?.toString().trim() ?? '';

  /// 使用一次性 HttpClient 请求公开 JSON，并设置网页接口需要的基础请求头。
  static Future<String> _requestPublicJson(Uri uri) async {
    final HttpClient client = HttpClient();
    try {
      final HttpClientRequest request = await client.getUrl(uri);
      request.headers.set(HttpHeaders.userAgentHeader, _desktopUserAgent);
      request.headers.set(
        HttpHeaders.refererHeader,
        'https://www.bilibili.com/',
      );
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final HttpClientResponse response = await request.close();
      final String body = await utf8.decoder.bind(response).join();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw PlayerEnhancementException(
          '播放器增强接口请求失败（${response.statusCode}）。',
        );
      }
      return body;
    } finally {
      client.close(force: true);
    }
  }
}

/// 在组件测试或离线播放器中关闭网络增强功能，保持旧测试完全可控。
class EmptyPlayerEnhancementService
    implements BilibiliPlayerEnhancementService {
  /// 创建不会访问网络的空服务。
  const EmptyPlayerEnhancementService();

  /// 返回空章节和普通视频信息。
  @override
  Future<PlayerEnhancementMetadata> loadMetadata({
    required String bvid,
    required int cid,
  }) async {
    return const PlayerEnhancementMetadata();
  }

  /// 空服务不会拥有互动节点，调用时返回明确错误帮助定位错误接线。
  @override
  Future<InteractiveVideoNode> loadInteractiveNode({
    required String bvid,
    required int graphVersion,
    int? edgeId,
  }) {
    throw const PlayerEnhancementException('当前播放器未启用互动视频服务。');
  }
}
