import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/native_playback_service.dart';

/// 播放已下载到本机的离线视频，不请求任何网络播放数据。
///
/// 只提供播放、暂停、拖动进度和倍速等基础控制；弹幕、笔记、互动等
/// 在线功能不适用于离线文件。
class OfflinePlayerPage extends StatefulWidget {
  /// 创建离线播放页；测试可注入替换的原生播放服务。
  const OfflinePlayerPage({
    super.key,
    required this.filePath,
    required this.title,
    this.playbackService,
  });

  /// 本地视频文件绝对路径。
  final String filePath;

  /// 展示标题。
  final String title;

  /// 可选的播放服务，未传入时创建连接 Android 原生播放器的服务。
  final NativePlaybackService? playbackService;

  /// 创建管理纹理、播放状态与基础控制的状态对象。
  @override
  State<OfflinePlayerPage> createState() => _OfflinePlayerPageState();
}

/// 管理离线视频纹理初始化、状态订阅和基础播放控制。
class _OfflinePlayerPageState extends State<OfflinePlayerPage> {
  late final NativePlaybackService _playbackService;
  StreamSubscription<PlaybackSnapshot>? _stateSubscription;
  PlaybackSnapshot _snapshot = const PlaybackSnapshot();
  int? _textureId;
  bool _busy = true;
  double _scrubbingPositionMs = -1;
  double _playbackSpeed = 1;

  /// 创建播放服务并初始化视频纹理，随后开始播放本地文件。
  @override
  void initState() {
    super.initState();
    _playbackService = widget.playbackService ?? NativePlaybackService();
    _stateSubscription = _playbackService.states.listen(_handleStateChanged);
    unawaited(_initializePlayback());
  }

  /// 订阅原生播放状态，并在页面存活时刷新界面。
  void _handleStateChanged(PlaybackSnapshot snapshot) {
    if (mounted) {
      setState(() => _snapshot = snapshot);
    }
  }

  /// 初始化纹理并打开本地文件；初始化失败时显示可重试的错误状态。
  Future<void> _initializePlayback() async {
    setState(() => _busy = true);
    try {
      final int? textureId = await _playbackService.initialize();
      if (!mounted) {
        return;
      }
      if (textureId == null) {
        setState(() {
          _busy = false;
          _snapshot = _snapshot.copyWith(
            phase: PlaybackPhase.error,
            message: '无法创建播放器画面，请返回后重试。',
          );
        });
        return;
      }
      setState(() => _textureId = textureId);
      await _playbackService.openLocalFile(
        filePath: widget.filePath,
        title: widget.title,
      );
    } on Object {
      if (mounted) {
        setState(() {
          _busy = false;
          _snapshot = _snapshot.copyWith(
            phase: PlaybackPhase.error,
            message: '无法打开离线视频，请确认文件仍然存在。',
          );
        });
      }
    }
  }

  /// 释放状态订阅和原生播放器资源。
  @override
  void dispose() {
    _stateSubscription?.cancel();
    unawaited(_playbackService.dispose());
    super.dispose();
  }

  /// 把毫秒格式化为可读时间文本。
  String _formatPosition(Duration position) {
    final int hours = position.inHours;
    final int minutes = position.inMinutes % 60;
    final int seconds = position.inSeconds % 60;
    final String minuteText = minutes.toString().padLeft(2, '0');
    final String secondText = seconds.toString().padLeft(2, '0');
    return hours > 0
        ? '$hours:$minuteText:$secondText'
        : '$minutes:$secondText';
  }

  /// 创建播放画面；纹理未就绪时显示加载或错误占位。
  Widget _buildVideoSurface() {
    final int? textureId = _textureId;
    if (textureId != null) {
      return AspectRatio(
        aspectRatio: _snapshot.videoAspectRatio > 0
            ? _snapshot.videoAspectRatio
            : 16 / 9,
        child: Texture(textureId: textureId),
      );
    }
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          CircularProgressIndicator(),
          SizedBox(height: 12),
          Text('正在打开离线视频…'),
        ],
      ),
    );
  }

  /// 创建播放/暂停、进度拖动和倍速切换的基础控制条。
  Widget _buildControls() {
    final Duration duration = _snapshot.duration;
    final double durationMs = duration.inMilliseconds.toDouble();
    final double sliderValue = _scrubbingPositionMs >= 0
        ? _scrubbingPositionMs
        : _snapshot.position.inMilliseconds.toDouble().clamp(
            0,
            durationMs > 0 ? durationMs : double.infinity,
          );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Slider(
          key: const Key('offline-player-progress'),
          min: 0,
          max: durationMs > 0 ? durationMs : 1,
          value: sliderValue.clamp(0, durationMs > 0 ? durationMs : 1),
          onChangeStart: (double value) {
            setState(() => _scrubbingPositionMs = value);
          },
          onChanged: durationMs > 0
              ? (double value) {
                  setState(() => _scrubbingPositionMs = value);
                }
              : null,
          onChangeEnd: (double value) {
            unawaited(
              _playbackService.seekTo(Duration(milliseconds: value.round())),
            );
            setState(() => _scrubbingPositionMs = -1);
          },
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: <Widget>[
              Text(_formatPosition(_snapshot.position)),
              const Spacer(),
              Text(durationMs > 0 ? _formatPosition(duration) : '时长未知'),
            ],
          ),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            TextButton(
              key: const Key('offline-player-speed'),
              // 倍速按钮函数在 0.75、1、1.25、1.5、2 之间循环。
              onPressed: () {
                const List<double> speeds = <double>[0.75, 1, 1.25, 1.5, 2];
                final int nextIndex =
                    (speeds.indexOf(_playbackSpeed) + 1) % speeds.length;
                final double nextSpeed = speeds[nextIndex];
                setState(() => _playbackSpeed = nextSpeed);
                unawaited(_playbackService.setPlaybackSpeed(nextSpeed));
              },
              child: Text('${_playbackSpeed}x'),
            ),
            IconButton.filled(
              key: const Key('offline-player-toggle'),
              iconSize: 40,
              tooltip: _snapshot.isPlaying ? '暂停' : '播放',
              onPressed: _busy || _snapshot.duration <= Duration.zero
                  ? null
                  : () {
                      if (_snapshot.isPlaying) {
                        unawaited(_playbackService.pause());
                      } else {
                        unawaited(_playbackService.play());
                      }
                    },
              icon: Icon(
                _snapshot.isPlaying
                    ? Icons.pause_rounded
                    : Icons.play_arrow_rounded,
              ),
            ),
            const SizedBox(width: 48),
          ],
        ),
      ],
    );
  }

  /// 创建包含错误信息与重试入口的状态提示。
  Widget _buildStatusMessage(String message) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: () => unawaited(_initializePlayback()),
            child: const Text('重试'),
          ),
        ],
      ),
    );
  }

  /// 组合视频画面、错误提示和底部控制条。
  @override
  Widget build(BuildContext context) {
    final String? message = _snapshot.message;
    final bool hasError = _snapshot.phase == PlaybackPhase.error;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: SafeArea(
        child: Column(
          children: <Widget>[
            Expanded(
              child: Center(
                child: hasError && message != null
                    ? _buildStatusMessage(message)
                    : _buildVideoSurface(),
              ),
            ),
            Material(color: Colors.black, child: _buildControls()),
          ],
        ),
      ),
    );
  }
}
