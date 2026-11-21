/// A–B points belong to exactly one video and chapter and are never persisted.
class AbRepeatRange {
  const AbRepeatRange({
    required this.bvid,
    required this.cid,
    required this.a,
    required this.b,
  });

  final String bvid;
  final int cid;
  final Duration a;
  final Duration b;
  static const minimumLength = Duration(seconds: 1);

  bool matches(String video, int part) => bvid == video && cid == part;
  bool contains(Duration position) => position >= a && position < b;

  String? validate(Duration duration) {
    if (bvid.trim().isEmpty || cid <= 0) return '当前视频或分 P 无效。';
    if (a < Duration.zero || b <= a || b - a < minimumLength) {
      return 'B 点至少比 A 点晚 1 秒。';
    }
    if (duration <= Duration.zero) return '媒体时长尚未就绪，请稍后重试。';
    if (b > duration) return 'A、B 点不能超过当前分 P 的时长。';
    return null;
  }
}

/// Accept seconds, mm:ss or hh:mm:ss, with optional millisecond precision.
Duration? parseAbRepeatTime(String input) {
  final value = input.trim();
  if (!RegExp(r'^\d+(?::\d{1,2}){0,2}(?:\.\d{1,3})?$').hasMatch(value)) {
    return null;
  }
  final parts = value.split(':');
  final seconds = double.tryParse(parts.last);
  if (seconds == null ||
      !seconds.isFinite ||
      (parts.length > 1 && seconds >= 60)) {
    return null;
  }
  var total = seconds;
  if (parts.length >= 2) {
    final minutes = int.tryParse(parts[parts.length - 2]);
    if (minutes == null || (parts.length == 3 && minutes >= 60)) return null;
    total += minutes * 60;
  }
  if (parts.length == 3) {
    final hours = int.tryParse(parts.first);
    if (hours == null) return null;
    total += hours * 3600;
  }
  if (!total.isFinite || total > 604800) return null;
  return Duration(milliseconds: (total * 1000).round());
}

String formatAbRepeatTime(Duration time) {
  final ms = time.inMilliseconds;
  final seconds = (ms ~/ 1000 % 60).toString().padLeft(2, '0');
  final minutes = (ms ~/ 60000 % 60).toString().padLeft(2, '0');
  final hours = ms ~/ 3600000;
  final fraction = ms % 1000 == 0
      ? ''
      : '.${(ms % 1000).toString().padLeft(3, '0')}';
  return '${hours > 0 ? '$hours:' : ''}$minutes:$seconds$fraction';
}
