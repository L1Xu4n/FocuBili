/// 保存视频时间轴中的一个公开分段（章节）。
class VideoChapter {
  /// 创建一个带标题、开始时间、结束时间和可选预览图的分段。
  const VideoChapter({
    required this.title,
    required this.start,
    required this.end,
    this.imageUrl = '',
  });

  final String title;
  final Duration start;
  final Duration end;
  final String imageUrl;

  /// 返回分段持续时间；异常的倒序数据会安全回退为零。
  Duration get duration => end > start ? end - start : Duration.zero;

  /// 判断指定播放位置是否位于这个分段中，并允许最后一帧落在末尾。
  bool contains(Duration position, {required bool isLast}) {
    return position >= start && (position < end || (isLast && position == end));
  }
}

/// 保存互动视频在播放器信息接口中提供的剧情图版本。
class InteractiveVideoInfo {
  /// 创建互动视频入口信息；版本号用于继续请求剧情分支。
  const InteractiveVideoInfo({required this.graphVersion});

  final int graphVersion;
}

/// 保存互动视频中一个必须由用户主动选择的剧情分支。
class InteractiveVideoChoice {
  /// 创建一个包含分支编号、目标 CID 和按钮文字的选择。
  const InteractiveVideoChoice({
    required this.edgeId,
    required this.cid,
    required this.label,
  });

  final int edgeId;
  final int cid;
  final String label;
}

/// 保存互动剧情当前节点及其下一步选择。
class InteractiveVideoNode {
  /// 创建剧情节点；叶子节点没有后续选择。
  const InteractiveVideoNode({
    required this.title,
    required this.edgeId,
    required this.isLeaf,
    required this.choices,
    this.choicePromptLeadTime,
    this.pauseVideoForChoice = false,
  });

  final String title;
  final int edgeId;
  final bool isLeaf;
  final List<InteractiveVideoChoice> choices;

  /// 返回剧情选项应在结尾前提前多久出现；接口未提供时由播放结束事件兜底显示。
  final Duration? choicePromptLeadTime;

  /// 标识到达剧情选择点时是否应先暂停当前分支的视频。
  final bool pauseVideoForChoice;

  /// 判断当前节点是否真的存在可供用户主动选择的后续剧情。
  bool get hasChoices => !isLeaf && choices.isNotEmpty;
}

/// 汇总一个分P的章节和互动视频入口信息。
class PlayerEnhancementMetadata {
  /// 创建播放器增强元数据；普通视频的互动信息为空。
  const PlayerEnhancementMetadata({
    this.chapters = const <VideoChapter>[],
    this.interaction,
  });

  final List<VideoChapter> chapters;
  final InteractiveVideoInfo? interaction;
}
