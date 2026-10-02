part of 'player_page.dart';

/// 负责听视频的原地切换；真实媒体选择、后台服务与计时由播放后端负责。
mixin _PlayerListeningCoordinator on State<PlayerPage>, _PlayerPlaybackSession {
  bool _switchingListening = false;

  /// 切换后显示现有进度与播放操作，让用户可以继续调整声音。
  void _showPlayerControls();

  /// 请求后端切换独立音轨，失败时保留错误原因，不把隐藏画面误称省流。
  Future<void> _toggleAudioOnly() async {
    final service = _playbackService;
    if (service is! ListeningPlaybackService || _switchingListening) return;
    final enabled = !_playbackSnapshot.audioOnly;
    setState(() => _switchingListening = true);
    try {
      await (service as ListeningPlaybackService).setAudioOnly(enabled);
      if (!mounted) return;
      _showTransientSnackBar(enabled ? '已切换为仅音频，可后台或锁屏收听' : '已恢复视频画面');
    } on PlatformException catch (error) {
      if (mounted) _showTransientSnackBar(error.message ?? '无法切换听视频，请稍后重试');
    } catch (_) {
      if (mounted) _showTransientSnackBar('当前媒体暂不能切换，请确认有独立音轨后重试');
    } finally {
      if (mounted) {
        setState(() => _switchingListening = false);
        _showPlayerControls();
      }
    }
  }
}

/// 仅展示听视频状态，播放器仍沿用原有进度、倍速、选集和定时操作。
extension _PlayerListeningView on _PlayerPageState {
  /// 以补齐两位的分秒显示进度，超过一小时沿用时分秒格式。
  String _listeningProgress() {
    final total = _displayDuration.inSeconds;
    final current = (_progress * total).round().clamp(0, total);
    return '${_formatSeconds(current).padLeft(5, '0')}/${_formatSeconds(total).padLeft(5, '0')}';
  }

  /// 创建轻量听视频状态卡，位置由统一反馈区避让放大后的控制栏。
  Widget _buildListeningSurface() => ColoredBox(
    key: const Key('audio-only-surface'),
    color: const Color(0xff17131b),
    child: Center(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.headphones_rounded,
                color: Colors.white70,
                size: 36,
              ),
              const SizedBox(height: 8),
              const Text(
                '听视频',
                style: TextStyle(color: Colors.white, fontSize: 17),
              ),
              const SizedBox(height: 4),
              const Text(
                '仅音频 · 不加载画面',
                style: TextStyle(color: Colors.white60, fontSize: 11),
              ),
              const SizedBox(height: 8),
              Text(
                _listeningProgress(),
                key: const Key('listening-time-progress'),
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 14,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
