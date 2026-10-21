import '../platform/app_platform.dart';

/// The iOS CPU render path needs copy-back decoding. These are preferences,
/// never a promise that a particular stream can use hardware decoding.
enum IosDecodeMode {
  automatic('自动（推荐）', 'auto-copy'),
  videoToolbox('VideoToolbox 优先', 'videotoolbox-copy'),
  software('软件解码（排查用）', 'no');

  const IosDecodeMode(this.label, this.hwdec);
  final String label;
  final String hwdec;

  static IosDecodeMode fromStored(Object? value) =>
      values.firstWhere((mode) => mode.name == value, orElse: () => automatic);
}

/// Streaming representation selection is independent from local decoding.
enum IosVideoCodecPreference {
  avc('AVC / H.264（兼容优先）'),
  hevc('HEVC / H.265 优先');

  const IosVideoCodecPreference(this.label);
  final String label;

  static IosVideoCodecPreference fromStored(Object? value) =>
      values.firstWhere((codec) => codec.name == value, orElse: () => avc);

  int rank(String codec) {
    final value = codec.toLowerCase();
    final avc = value.startsWith('avc1') || value.startsWith('avc3');
    final hevc = value.startsWith('hev1') || value.startsWith('hvc1');
    return switch (this) {
      IosVideoCodecPreference.avc =>
        avc
            ? 2
            : hevc
            ? 1
            : 0,
      IosVideoCodecPreference.hevc =>
        hevc
            ? 2
            : avc
            ? 1
            : 0,
    };
  }
}

bool supportsIosDecodePreferences(AppPlatform platform) =>
    platform == AppPlatform.ios;
