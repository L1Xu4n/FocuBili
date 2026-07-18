part of 'player_page.dart';

/// 在全屏顶栏同一行展示专注目标、当前时间和电量。
class _FullscreenDeviceStatus extends StatelessWidget {
  /// 创建只监听专注控制器局部刷新的设备状态栏。
  const _FullscreenDeviceStatus({
    required this.focusController,
    required this.clock,
    required this.batteryPercent,
  });

  final FocusTimerController? focusController;
  final DateTime clock;
  final int? batteryPercent;

  /// 把本地时间格式化为全屏状态栏使用的“时:分”。
  String _formatClock() {
    return '${clock.hour.toString().padLeft(2, '0')}:'
        '${clock.minute.toString().padLeft(2, '0')}';
  }

  /// 把专注剩余时间格式化为紧凑的分秒或时分秒。
  String _formatRemaining(Duration duration) {
    final int totalSeconds = ((duration.inMilliseconds + 999) ~/ 1000).clamp(
      0,
      24 * 60 * 60,
    );
    final int hours = totalSeconds ~/ 3600;
    final int minutes = (totalSeconds % 3600) ~/ 60;
    final int seconds = totalSeconds % 60;
    if (hours > 0) {
      return '$hours:${minutes.toString().padLeft(2, '0')}:'
          '${seconds.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:'
        '${seconds.toString().padLeft(2, '0')}';
  }

  /// 构建左侧专注目标和倒计时，超长目标沿水平方向循环滚动。
  Widget _buildFocusStatus(FocusTimerController controller) {
    final FocusSession? session = controller.activeSession;
    if (session == null) {
      return const SizedBox.shrink();
    }
    final bool paused = session.status == FocusSessionStatus.paused;
    return Row(
      key: const Key('fullscreen-focus-status'),
      children: <Widget>[
        Icon(
          paused ? Icons.pause_rounded : Icons.timer_outlined,
          color: Colors.white70,
          size: 11,
        ),
        const SizedBox(width: 3),
        Flexible(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 120),
            child: _AutoScrollingText(
              key: const Key('fullscreen-focus-goal'),
              text: session.goal,
              scrollAfterCharacters: 12,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 10,
                height: 1,
              ),
            ),
          ),
        ),
        const SizedBox(width: 5),
        Text(
          _formatRemaining(controller.remainingDuration),
          key: const Key('fullscreen-focus-remaining'),
          style: const TextStyle(
            color: Colors.white,
            fontSize: 10,
            height: 1,
            fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }

  /// 构建三段互不遮挡的全屏状态栏，并只监听左侧专注数据刷新。
  @override
  Widget build(BuildContext context) {
    final String batteryText = batteryPercent == null
        ? '--'
        : '$batteryPercent%';
    return SizedBox(
      key: const Key('fullscreen-device-status'),
      height: 15,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: LayoutBuilder(
          // 状态栏布局函数限制专注区域最多占 48%，避免覆盖居中时间和右侧电量。
          builder: (BuildContext context, BoxConstraints constraints) {
            final double focusWidth = (constraints.maxWidth * 0.48)
                .clamp(140.0, 360.0)
                .toDouble();
            return Stack(
              alignment: Alignment.center,
              children: <Widget>[
                Align(
                  alignment: Alignment.centerLeft,
                  child: SizedBox(
                    width: focusWidth,
                    child: focusController == null
                        ? const SizedBox.shrink()
                        : ListenableBuilder(
                            listenable: focusController!,
                            // 专注刷新函数只重建左侧目标和倒计时，不重复读取电量。
                            builder: (BuildContext context, Widget? child) =>
                                _buildFocusStatus(focusController!),
                          ),
                  ),
                ),
                Text(
                  _formatClock(),
                  key: const Key('fullscreen-local-clock'),
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 10,
                    height: 1,
                  ),
                ),
                Positioned(
                  right: 0,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      const Icon(
                        Icons.battery_full_rounded,
                        color: Colors.white70,
                        size: 12,
                      ),
                      const SizedBox(width: 2),
                      Text(
                        batteryText,
                        key: const Key('fullscreen-battery'),
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 10,
                          height: 1,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// 让播放器随详情页滚动连续改变高度，收起后不保留占位空间。
class _CollapsingPlayerHeaderDelegate extends SliverPersistentHeaderDelegate {
  /// 创建最大高度固定、最小高度为零的播放器折叠头。
  const _CollapsingPlayerHeaderDelegate({
    required this.maximumHeight,
    required this.child,
  });

  final double maximumHeight;
  final Widget child;

  /// 返回完全收起后的高度，使详情内容能够占满整个屏幕。
  @override
  double get minExtent => 0;

  /// 返回播放器初始展开高度，由真实视频比例和屏幕尺寸共同决定。
  @override
  double get maxExtent => maximumHeight;

  /// 按当前 Sliver 高度裁切并重排播放器，形成连续收起效果。
  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    return ClipRect(child: SizedBox.expand(child: child));
  }

  /// 仅在播放器高度或实例变化时重新创建折叠布局。
  @override
  bool shouldRebuild(covariant _CollapsingPlayerHeaderDelegate oldDelegate) {
    return maximumHeight != oldDelegate.maximumHeight ||
        child != oldDelegate.child;
  }
}

/// 在视频简介区紧凑显示一个图标和一段公开元数据。
class _DetailMeta extends StatelessWidget {
  /// 创建不可点击的只读详情元数据。
  const _DetailMeta({required this.icon, required this.text});

  final IconData icon;
  final String text;

  /// 创建水平排列的图标与文字。
  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(icon, size: 16),
        const SizedBox(width: 4),
        Text(text, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}

/// 在固定两行高度内竖向循环标题，避免超长分P名称被横向截断。
class _PartTitleMarquee extends StatefulWidget {
  /// 创建一个会在两行内容溢出时自动竖向滚动的分P标题。
  const _PartTitleMarquee({super.key, required this.text, required this.style});

  final String text;
  final TextStyle style;

  /// 创建分P标题滚动组件的状态对象。
  @override
  State<_PartTitleMarquee> createState() => _PartTitleMarqueeState();
}

/// 测量两行标题的实际溢出高度，并管理竖向循环动画的生命周期。
class _PartTitleMarqueeState extends State<_PartTitleMarquee>
    with SingleTickerProviderStateMixin {
  static const double _textGap = 12;
  late final AnimationController _controller;
  double _travelDistance = 0;
  String? _animationSignature;
  bool _elementActive = true;

  /// 创建竖向标题动画控制器，只有内容超过两行时才会启动。
  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this);
  }

  /// 当标题文字或样式变化时清除旧的测量结果，等待下一帧重新判断溢出。
  @override
  void didUpdateWidget(covariant _PartTitleMarquee oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text || oldWidget.style != widget.style) {
      _stopAnimation();
    }
  }

  /// 组件重新进入树时重新允许动画在布局完成后启动。
  @override
  void activate() {
    super.activate();
    _elementActive = true;
  }

  /// 列表回收组件时停止动画，防止失活状态继续触发框架刷新。
  @override
  void deactivate() {
    _elementActive = false;
    _controller.stop();
    _animationSignature = null;
    super.deactivate();
  }

  /// 停止并清空旧动画状态，供短标题或新标题重新测量。
  void _stopAnimation() {
    _controller.stop();
    _controller.reset();
    _animationSignature = null;
    _travelDistance = 0;
  }

  /// 在布局完成后按实际竖向距离启动匀速循环，避免在 build 中直接改变动画状态。
  void _scheduleAnimation(double travelDistance) {
    final String signature = '${widget.text}:$travelDistance:${widget.style}';
    if (_animationSignature == signature) {
      return;
    }
    _animationSignature = signature;
    _travelDistance = travelDistance;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_elementActive || _animationSignature != signature) {
        return;
      }
      final int milliseconds = (travelDistance / 18 * 1000)
          .round()
          .clamp(5000, 28000)
          .toInt();
      _controller
        ..duration = Duration(milliseconds: milliseconds)
        ..repeat();
    });
  }

  /// 释放动画控制器，避免分P列表销毁后仍占用动画资源。
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 构建静态两行标题，或构建两份文字组成的无缝竖向循环标题。
  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        if (!constraints.hasBoundedWidth) {
          return Text(
            widget.text,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: widget.style,
          );
        }
        final TextPainter visiblePainter = TextPainter(
          text: TextSpan(text: widget.text, style: widget.style),
          maxLines: 2,
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        )..layout(maxWidth: constraints.maxWidth);
        if (!visiblePainter.didExceedMaxLines) {
          if (_animationSignature != null) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && _elementActive) {
                _stopAnimation();
              }
            });
          }
          return Text(
            widget.text,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: widget.style,
          );
        }
        final TextPainter completePainter = TextPainter(
          text: TextSpan(text: widget.text, style: widget.style),
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        )..layout(maxWidth: constraints.maxWidth);
        final double travelDistance =
            completePainter.height - visiblePainter.height + _textGap;
        _scheduleAnimation(travelDistance);
        return SizedBox(
          width: constraints.maxWidth,
          height: visiblePainter.height,
          child: ClipRect(
            child: AnimatedBuilder(
              animation: _controller,
              // 动画构建函数在两行裁剪区域内竖向移动两份完整标题，实现循环阅读。
              builder: (BuildContext context, Widget? child) {
                final double offset = _travelDistance * _controller.value;
                return Stack(
                  clipBehavior: Clip.none,
                  children: <Widget>[
                    Positioned(
                      top: -offset,
                      left: 0,
                      right: 0,
                      child: SizedBox(
                        width: constraints.maxWidth,
                        child: Text(widget.text, style: widget.style),
                      ),
                    ),
                    Positioned(
                      top: completePainter.height + _textGap - offset,
                      left: 0,
                      right: 0,
                      child: SizedBox(
                        width: constraints.maxWidth,
                        child: Text(widget.text, style: widget.style),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        );
      },
    );
  }
}

/// 在可用宽度不足时自动横向滚动标题，短标题保持静止。
class _AutoScrollingText extends StatefulWidget {
  /// 创建一条只在溢出时启动滚动动画的单行文字。
  const _AutoScrollingText({
    super.key,
    required this.text,
    required this.style,
    this.scrollAfterCharacters,
  });

  final String text;
  final TextStyle style;

  /// 可选字符上限；超过后即使像素宽度尚未溢出也启动循环滚动。
  final int? scrollAfterCharacters;

  /// 创建自动滚动文字的动画状态。
  @override
  State<_AutoScrollingText> createState() => _AutoScrollingTextState();
}

/// 测量标题宽度并管理循环横移距离与动画生命周期。
class _AutoScrollingTextState extends State<_AutoScrollingText>
    with SingleTickerProviderStateMixin {
  static const double _textGap = 36;
  late final AnimationController _controller;
  double _travelDistance = 0;
  String? _animationSignature;
  bool _elementActive = true;

  /// 创建标题滚动动画控制器，动画只在文字溢出后才启动。
  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this);
  }

  /// 标题内容变化时重置旧动画，等待下一次布局重新测量。
  @override
  void didUpdateWidget(covariant _AutoScrollingText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text ||
        oldWidget.style != widget.style ||
        oldWidget.scrollAfterCharacters != widget.scrollAfterCharacters) {
      _stopAnimation();
    }
  }

  /// 标题重新回到组件树时恢复活动标记，允许下一次布局重新启动动画。
  @override
  void activate() {
    super.activate();
    _elementActive = true;
  }

  /// 全屏旋转暂时移除标题时立即停止动画，防止失活组件继续触发框架重建。
  @override
  void deactivate() {
    _elementActive = false;
    _controller.stop();
    _animationSignature = null;
    super.deactivate();
  }

  /// 停止并清空当前横向滚动状态，供短标题或新标题重新计算。
  void _stopAnimation() {
    _controller.stop();
    _controller.reset();
    _animationSignature = null;
    _travelDistance = 0;
  }

  /// 在本帧布局完成后按标题长度启动匀速循环滚动。
  void _scheduleAnimation(double travelDistance) {
    final String signature =
        '${widget.text}:$travelDistance:${widget.scrollAfterCharacters}';
    if (_animationSignature == signature) {
      return;
    }
    _animationSignature = signature;
    _travelDistance = travelDistance;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_elementActive || _animationSignature != signature) {
        return;
      }
      final int milliseconds = (travelDistance / 28 * 1000)
          .round()
          .clamp(4200, 18000)
          .toInt();
      _controller
        ..duration = Duration(milliseconds: milliseconds)
        ..repeat();
    });
  }

  /// 释放动画控制器，避免离开全屏后继续消耗刷新资源。
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 测量文字是否溢出，并构建静态标题或无缝循环的双份标题。
  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final TextPainter painter = TextPainter(
          text: TextSpan(text: widget.text, style: widget.style),
          maxLines: 1,
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        )..layout();
        final int? characterLimit = widget.scrollAfterCharacters;
        final bool exceedsCharacterLimit =
            characterLimit != null && widget.text.runes.length > characterLimit;
        if (!constraints.hasBoundedWidth ||
            (!exceedsCharacterLimit && painter.width <= constraints.maxWidth)) {
          if (_animationSignature != null) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && _elementActive) {
                _stopAnimation();
              }
            });
          }
          return Text(
            widget.text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: widget.style,
          );
        }
        _scheduleAnimation(painter.width + _textGap);
        return SizedBox(
          width: constraints.maxWidth,
          height: painter.height,
          child: ClipRect(
            child: AnimatedBuilder(
              animation: _controller,
              // 动画构建函数在固定尺寸画布中移动两份标题，避免无限约束和横向溢出。
              builder: (BuildContext context, Widget? child) {
                final double offset = _travelDistance * _controller.value;
                return Stack(
                  clipBehavior: Clip.none,
                  children: <Widget>[
                    Positioned(
                      left: -offset,
                      top: 0,
                      child: Text(
                        widget.text,
                        maxLines: 1,
                        style: widget.style,
                      ),
                    ),
                    Positioned(
                      left: painter.width + _textGap - offset,
                      top: 0,
                      child: Text(
                        widget.text,
                        maxLines: 1,
                        style: widget.style,
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        );
      },
    );
  }
}
