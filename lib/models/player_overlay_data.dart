/// 表示原生字幕服务可以明确说明的可用状态。
enum SubtitleLoadStatus {
  /// 至少有一条当前会话可读取的字幕轨道或字幕条目。
  available,

  /// 视频没有返回任何字幕轨道。
  empty,

  /// 服务明确表示需要用户先在官方网页完成登录。
  loginRequired,

  /// 视频返回了字幕轨道，但当前轨道处于锁定状态。
  locked,

  /// 网络、平台通道或数据格式暂时无法完成字幕读取。
  unavailable,
}

/// 保存一条可在播放器中选择的字幕轨道，不包含临时字幕地址或会话资料。
class SubtitleTrack {
  /// 创建只包含页面展示和后续安全请求所需字段的字幕轨道。
  const SubtitleTrack({
    required this.id,
    required this.language,
    required this.label,
    required this.isLocked,
  });

  /// 单条轨道允许展示的最长名称，避免异常服务数据撑坏菜单布局。
  static const int maxLabelLength = 80;

  final String id;
  final String language;
  final String label;
  final bool isLocked;

  /// 从原生方法通道的安全字典解析轨道；无编号的异常条目会被忽略。
  static SubtitleTrack? tryParse(Map<Object?, Object?> values) {
    final String id = values['id']?.toString().trim() ?? '';
    if (id.isEmpty) {
      return null;
    }
    final String language = values['language']?.toString().trim() ?? '';
    final String rawLabel = values['label']?.toString().trim() ?? '';
    final String label = _limitText(
      rawLabel.isEmpty ? (language.isEmpty ? '未知语言' : language) : rawLabel,
      maxLabelLength,
    );
    return SubtitleTrack(
      id: id,
      language: language,
      label: label,
      isLocked: values['isLocked'] == true,
    );
  }
}

/// 保存加载字幕轨道后的展示状态、说明和不包含临时链接的轨道列表。
class SubtitleTrackLoadResult {
  /// 创建一个可直接供播放器菜单使用的字幕轨道结果。
  const SubtitleTrackLoadResult({
    required this.status,
    required this.message,
    required this.tracks,
  });

  final SubtitleLoadStatus status;
  final String message;
  final List<SubtitleTrack> tracks;

  /// 判断结果中是否存在可继续请求字幕条目的非锁定轨道。
  bool get hasSelectableTrack =>
      tracks.any((SubtitleTrack track) => !track.isLocked);

  /// 创建“没有字幕”的稳定结果，供原生明确返回空数组时使用。
  const SubtitleTrackLoadResult.empty({
    this.message = '此视频没有可用字幕。',
  })  : status = SubtitleLoadStatus.empty,
        tracks = const <SubtitleTrack>[];

  /// 创建“需要登录”的稳定结果，不把登录会话详情传给页面。
  const SubtitleTrackLoadResult.loginRequired({
    this.message = '登录后可尝试读取字幕。',
  })  : status = SubtitleLoadStatus.loginRequired,
        tracks = const <SubtitleTrack>[];

  /// 创建“字幕锁定”的稳定结果，提示页面不要伪造或继续请求内容。
  const SubtitleTrackLoadResult.locked({
    this.message = '此视频的字幕当前不可用。',
    this.tracks = const <SubtitleTrack>[],
  }) : status = SubtitleLoadStatus.locked;

  /// 创建“暂时无法读取”的稳定结果，页面可展示重试入口但不能伪造字幕。
  const SubtitleTrackLoadResult.unavailable({
    this.message = '字幕暂时无法读取，请稍后重试。',
  })  : status = SubtitleLoadStatus.unavailable,
        tracks = const <SubtitleTrack>[];

  /// 从平台字典转换出稳定结果，并过滤重复或损坏的轨道条目。
  factory SubtitleTrackLoadResult.fromPlatformMap(
    Map<Object?, Object?> values,
  ) {
    final SubtitleLoadStatus status =
        _parseSubtitleLoadStatus(values['status']);
    final String message = values['message']?.toString().trim() ?? '';
    final Object? rawTracks = values['tracks'];
    final Map<String, SubtitleTrack> tracksById = <String, SubtitleTrack>{};
    if (rawTracks is List) {
      for (final Object? rawTrack in rawTracks) {
        if (rawTrack is! Map) {
          continue;
        }
        final SubtitleTrack? track = SubtitleTrack.tryParse(
          Map<Object?, Object?>.from(rawTrack),
        );
        if (track != null) {
          tracksById.putIfAbsent(track.id, () => track);
        }
      }
    }
    final List<SubtitleTrack> tracks = List<SubtitleTrack>.unmodifiable(
      tracksById.values.take(20),
    );
    if (status == SubtitleLoadStatus.available &&
        !tracks.any((SubtitleTrack track) => !track.isLocked)) {
      return SubtitleTrackLoadResult.locked(
        message: message.isEmpty ? '此视频的字幕当前不可用。' : message,
        tracks: tracks,
      );
    }
    return SubtitleTrackLoadResult(
      status: status,
      message: message.isEmpty ? _defaultMessageForStatus(status) : message,
      tracks: tracks,
    );
  }
}

/// 保存单条字幕的时间范围和文本，不包含账号、地址或服务端原始资料。
class SubtitleCue {
  /// 创建已经通过时长和文字上限校验的字幕条目。
  const SubtitleCue({
    required this.from,
    required this.to,
    required this.content,
  });

  /// 单条字幕在 Flutter 层最多保留的字符数，与原生层共同限制异常长文本。
  static const int maxContentLength = 400;

  final Duration from;
  final Duration to;
  final String content;

  /// 从原生字典转换字幕条目；无效时间范围和空文本均直接忽略。
  static SubtitleCue? tryParse(Map<Object?, Object?> values) {
    final int fromMilliseconds = _readMilliseconds(values['fromMs']);
    final int toMilliseconds = _readMilliseconds(values['toMs']);
    final String content = _limitText(
      values['content']?.toString().trim() ?? '',
      maxContentLength,
    );
    if (toMilliseconds <= fromMilliseconds || content.isEmpty) {
      return null;
    }
    return SubtitleCue(
      from: Duration(milliseconds: fromMilliseconds),
      to: Duration(milliseconds: toMilliseconds),
      content: content,
    );
  }
}

/// 保存某一轨字幕条目的读取结果，供页面按状态决定显示、提示或重试。
class SubtitleCueLoadResult {
  /// 创建带有状态和字幕条目的读取结果。
  const SubtitleCueLoadResult({
    required this.status,
    required this.message,
    required this.cues,
  });

  final SubtitleLoadStatus status;
  final String message;
  final List<SubtitleCue> cues;

  /// 创建没有字幕条目的稳定结果。
  const SubtitleCueLoadResult.empty({this.message = '此字幕轨道没有可显示内容。'})
      : status = SubtitleLoadStatus.empty,
        cues = const <SubtitleCue>[];

  /// 创建字幕受登录限制时的稳定结果。
  const SubtitleCueLoadResult.loginRequired({
    this.message = '登录后可尝试读取字幕。',
  })  : status = SubtitleLoadStatus.loginRequired,
        cues = const <SubtitleCue>[];

  /// 创建锁定轨道的稳定结果。
  const SubtitleCueLoadResult.locked({
    this.message = '此字幕当前不可用。',
  })  : status = SubtitleLoadStatus.locked,
        cues = const <SubtitleCue>[];

  /// 创建网络或数据暂时不可用时的稳定结果。
  const SubtitleCueLoadResult.unavailable({
    this.message = '字幕暂时无法读取，请稍后重试。',
  })  : status = SubtitleLoadStatus.unavailable,
        cues = const <SubtitleCue>[];

  /// 从原生字典转换字幕条目，并限制总条数避免异常响应造成内存压力。
  factory SubtitleCueLoadResult.fromPlatformMap(
    Map<Object?, Object?> values,
  ) {
    final SubtitleLoadStatus status =
        _parseSubtitleLoadStatus(values['status']);
    final String message = values['message']?.toString().trim() ?? '';
    final Object? rawCues = values['cues'];
    final List<SubtitleCue> cues = <SubtitleCue>[];
    if (rawCues is List) {
      for (final Object? rawCue in rawCues) {
        if (cues.length >= 10000 || rawCue is! Map) {
          break;
        }
        final SubtitleCue? cue = SubtitleCue.tryParse(
          Map<Object?, Object?>.from(rawCue),
        );
        if (cue != null) {
          cues.add(cue);
        }
      }
    }
    if (status == SubtitleLoadStatus.available && cues.isEmpty) {
      return SubtitleCueLoadResult.empty(
        message: message.isEmpty ? '此字幕轨道没有可显示内容。' : message,
      );
    }
    return SubtitleCueLoadResult(
      status: status,
      message: message.isEmpty ? _defaultMessageForStatus(status) : message,
      cues: List<SubtitleCue>.unmodifiable(cues),
    );
  }
}

/// 将平台字符串转换为有限字幕状态，未知值安全回退为暂时不可用。
SubtitleLoadStatus _parseSubtitleLoadStatus(Object? rawStatus) {
  switch (rawStatus?.toString()) {
    case 'available':
      return SubtitleLoadStatus.available;
    case 'none':
      return SubtitleLoadStatus.empty;
    case 'login_required':
      return SubtitleLoadStatus.loginRequired;
    case 'locked':
      return SubtitleLoadStatus.locked;
    default:
      return SubtitleLoadStatus.unavailable;
  }
}

/// 返回每种字幕状态的简短默认文案，确保异常响应也不会让页面展示空白提示。
String _defaultMessageForStatus(SubtitleLoadStatus status) {
  switch (status) {
    case SubtitleLoadStatus.available:
      return '';
    case SubtitleLoadStatus.empty:
      return '此视频没有可用字幕。';
    case SubtitleLoadStatus.loginRequired:
      return '登录后可尝试读取字幕。';
    case SubtitleLoadStatus.locked:
      return '此字幕当前不可用。';
    case SubtitleLoadStatus.unavailable:
      return '字幕暂时无法读取，请稍后重试。';
  }
}

/// 读取非负毫秒数，异常、负数或超长数值都回退为零以保护时间轴计算。
int _readMilliseconds(Object? rawValue) {
  final int value = rawValue is num
      ? rawValue.toInt()
      : int.tryParse(rawValue?.toString() ?? '') ?? 0;
  return value.clamp(0, const Duration(hours: 48).inMilliseconds).toInt();
}

/// 按 Unicode 码点裁剪文本，避免切断 emoji 等代理对并限制页面布局压力。
String _limitText(String value, int maximumLength) {
  if (value.runes.length <= maximumLength) {
    return value;
  }
  return String.fromCharCodes(value.runes.take(maximumLength));
}

/// 表示原生弹幕服务可以明确说明的单个六分钟片段读取状态。
enum DanmakuLoadStatus {
  /// 片段中至少包含一条已经通过 Flutter 数据校验的弹幕。
  available,

  /// 服务成功读取片段，但其中没有可显示的普通弹幕。
  empty,

  /// 网络、平台通道或 Protobuf 数据暂时无法完成本片段读取。
  unavailable,
}

/// 保存单条普通弹幕的时间点、文本、RGB 颜色和 B 站模式编号。
class DanmakuEntry {
  /// 创建已经由原生与 Flutter 两层限制校验过的普通弹幕数据。
  const DanmakuEntry({
    required this.position,
    required this.content,
    required this.color,
    required this.mode,
  });

  /// Flutter 层保留的单条弹幕最大 Unicode 码点数，与原生限制保持一致。
  static const int maxContentLength = 200;

  /// 正常普通弹幕可接受的最低模式编号。
  static const int minimumMode = 1;

  /// 正常普通弹幕可接受的最高模式编号。
  static const int maximumMode = 9;

  /// B 站分段接口中单个视频时间轴允许保留的最长位置，防止异常值撑大缓存。
  static const Duration maximumPosition = Duration(hours: 48);

  final Duration position;
  final String content;
  final int color;
  final int mode;

  /// 从原生安全字典解析弹幕；非法模式、颜色、进度或空文字都会被丢弃。
  static DanmakuEntry? tryParse(Map<Object?, Object?> values) {
    final int progressMilliseconds = _readInt(values['progressMs']);
    final int color = _readInt(values['color']);
    final int mode = _readInt(values['mode']);
    final String content = _limitText(
      values['content']?.toString().trim() ?? '',
      maxContentLength,
    );
    if (progressMilliseconds < 0 ||
        progressMilliseconds > maximumPosition.inMilliseconds ||
        color < 0 ||
        color > 0xFFFFFF ||
        mode < minimumMode ||
        mode > maximumMode ||
        content.isEmpty) {
      return null;
    }
    return DanmakuEntry(
      position: Duration(milliseconds: progressMilliseconds),
      content: content,
      color: color,
      mode: mode,
    );
  }
}

/// 保存按六分钟分页读取的弹幕结果，不包含 Protobuf、Cookie 或请求地址。
class DanmakuSegmentLoadResult {
  /// 创建播放器可缓存或直接显示的一段只读弹幕数据。
  const DanmakuSegmentLoadResult({
    required this.status,
    required this.message,
    required this.segmentIndex,
    required this.entries,
  });

  /// B 站网页弹幕分段接口的固定时间跨度，用于播放器按当前位置分页请求。
  static const Duration segmentDuration = Duration(minutes: 6);

  /// 单个视频可请求的最大段号，与 Android 侧请求上限保持一致。
  static const int maximumSegmentIndex = 1000;

  /// 单段在 Flutter 层允许保留的最大条目数，与原生限制共同防止内存压力。
  static const int maximumEntries = 6000;

  final DanmakuLoadStatus status;
  final String message;
  final int segmentIndex;
  final List<DanmakuEntry> entries;

  /// 判断此段是否有可绘制弹幕，页面可据此避免创建无意义的绘制层。
  bool get hasEntries => entries.isNotEmpty;

  /// 创建读取成功但没有普通弹幕的稳定结果。
  const DanmakuSegmentLoadResult.empty({
    this.segmentIndex = 1,
    this.message = '当前六分钟片段没有可显示弹幕。',
  })  : status = DanmakuLoadStatus.empty,
        entries = const <DanmakuEntry>[];

  /// 创建网络、平台通道或数据格式失败时可展示的稳定结果。
  const DanmakuSegmentLoadResult.unavailable({
    this.segmentIndex = 1,
    this.message = '弹幕暂时无法读取，请稍后重试。',
  })  : status = DanmakuLoadStatus.unavailable,
        entries = const <DanmakuEntry>[];

  /// 从 Android 方法通道字典转换结果，并过滤损坏或超量的弹幕条目。
  factory DanmakuSegmentLoadResult.fromPlatformMap(
    Map<Object?, Object?> values,
  ) {
    final DanmakuLoadStatus status = _parseDanmakuLoadStatus(values['status']);
    final String message = values['message']?.toString().trim() ?? '';
    final int segmentIndex = _readDanmakuSegmentIndex(values['segmentIndex']);
    final List<DanmakuEntry> entries = <DanmakuEntry>[];
    final Object? rawEntries = values['entries'];
    if (rawEntries is List) {
      for (final Object? rawEntry in rawEntries) {
        if (entries.length >= maximumEntries || rawEntry is! Map) {
          break;
        }
        final DanmakuEntry? entry = DanmakuEntry.tryParse(
          Map<Object?, Object?>.from(rawEntry),
        );
        if (entry != null) {
          entries.add(entry);
        }
      }
    }
    if (status == DanmakuLoadStatus.available && entries.isEmpty) {
      return DanmakuSegmentLoadResult.empty(
        segmentIndex: segmentIndex,
        message: message.isEmpty ? '当前六分钟片段没有可显示弹幕。' : message,
      );
    }
    return DanmakuSegmentLoadResult(
      status: status,
      message:
          message.isEmpty ? _defaultMessageForDanmakuStatus(status) : message,
      segmentIndex: segmentIndex,
      entries: List<DanmakuEntry>.unmodifiable(entries),
    );
  }

  /// 根据播放器时间轴计算要读取的段号，负时间和过长时间会安全夹在可请求范围内。
  static int segmentIndexForPosition(Duration position) {
    final int rawIndex = position.isNegative
        ? 1
        : position.inMilliseconds ~/ segmentDuration.inMilliseconds + 1;
    return rawIndex.clamp(1, maximumSegmentIndex).toInt();
  }
}

/// 将平台字符串转换为有限弹幕状态，未知响应一律安全回退为暂时不可用。
DanmakuLoadStatus _parseDanmakuLoadStatus(Object? rawStatus) {
  switch (rawStatus?.toString()) {
    case 'available':
      return DanmakuLoadStatus.available;
    case 'none':
      return DanmakuLoadStatus.empty;
    default:
      return DanmakuLoadStatus.unavailable;
  }
}

/// 返回每种弹幕状态的简短默认提示，避免异常响应在页面上显示空白文字。
String _defaultMessageForDanmakuStatus(DanmakuLoadStatus status) {
  switch (status) {
    case DanmakuLoadStatus.available:
      return '';
    case DanmakuLoadStatus.empty:
      return '当前六分钟片段没有可显示弹幕。';
    case DanmakuLoadStatus.unavailable:
      return '弹幕暂时无法读取，请稍后重试。';
  }
}

/// 将方法通道的数值安全转为整数；非数值保留为最小整数，随后由调用者校验。
int _readInt(Object? rawValue) {
  return rawValue is num
      ? rawValue.toInt()
      : int.tryParse(rawValue?.toString() ?? '') ?? -1;
}

/// 读取并限制段号，避免异常平台返回让播放器把数据写入错误的分页缓存位置。
int _readDanmakuSegmentIndex(Object? rawValue) {
  final int index = _readInt(rawValue);
  return index.clamp(1, DanmakuSegmentLoadResult.maximumSegmentIndex).toInt();
}
