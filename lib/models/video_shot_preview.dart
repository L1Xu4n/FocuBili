/// 保存进度预览图在雪碧图中的地址、行列和单格尺寸。
class VideoShotFrame {
  /// 创建一帧可以由播放器裁切显示的预览图位置。
  const VideoShotFrame({
    required this.imageUrl,
    required this.column,
    required this.row,
    required this.frameWidth,
    required this.frameHeight,
    required this.sheetColumns,
    required this.sheetRows,
  });

  final String imageUrl;
  final int column;
  final int row;
  final double frameWidth;
  final double frameHeight;
  final int sheetColumns;
  final int sheetRows;
}

/// 保存一支视频的进度时间点与多张雪碧预览图元数据。
class VideoShotPreview {
  /// 创建不可变预览元数据，接口缺少图片时页面会退回纯文字进度提示。
  const VideoShotPreview({
    required this.imageUrls,
    required this.sampleSeconds,
    required this.columns,
    required this.rows,
    required this.frameWidth,
    required this.frameHeight,
  });

  final List<String> imageUrls;
  final List<int> sampleSeconds;
  final int columns;
  final int rows;
  final double frameWidth;
  final double frameHeight;

  /// 按目标进度找到不晚于该时刻的最近一格，并换算到对应雪碧图行列。
  VideoShotFrame? frameFor(Duration position) {
    if (imageUrls.isEmpty ||
        sampleSeconds.isEmpty ||
        columns <= 0 ||
        rows <= 0 ||
        frameWidth <= 0 ||
        frameHeight <= 0) {
      return null;
    }
    final int targetSeconds = position.inSeconds.clamp(0, 1 << 31).toInt();
    int lower = 0;
    int upper = sampleSeconds.length;
    while (lower < upper) {
      final int middle = (lower + upper) ~/ 2;
      if (sampleSeconds[middle] <= targetSeconds) {
        lower = middle + 1;
      } else {
        upper = middle;
      }
    }
    final int frameIndex = (lower - 1).clamp(0, sampleSeconds.length - 1);
    final int cellsPerSheet = columns * rows;
    final int sheetIndex = (frameIndex ~/ cellsPerSheet).clamp(
      0,
      imageUrls.length - 1,
    );
    final int cellIndex = frameIndex % cellsPerSheet;
    return VideoShotFrame(
      imageUrl: imageUrls[sheetIndex],
      column: cellIndex % columns,
      row: cellIndex ~/ columns,
      frameWidth: frameWidth,
      frameHeight: frameHeight,
      sheetColumns: columns,
      sheetRows: rows,
    );
  }
}
