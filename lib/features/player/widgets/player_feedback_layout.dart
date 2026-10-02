import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';

enum _FeedbackSlot { top, bottom, feedback }

/// 先测量真实上下播放栏，再把反馈限制在两栏之间。
class PlayerFeedbackViewport extends StatefulWidget {
  /// 接收实际控制栏和反馈；隐藏控制栏时只避开系统边缘。
  const PlayerFeedbackViewport({
    super.key,
    required this.topControls,
    required this.bottomControls,
    required this.feedback,
    required this.controlsVisible,
    this.edgeInsets = EdgeInsets.zero,
    this.sideInset = 16,
  });

  final Widget topControls;
  final Widget bottomControls;
  final Widget feedback;
  final bool controlsVisible;
  final EdgeInsets edgeInsets;
  final double sideInset;

  /// 创建保留控制栏淡出占位的状态。
  @override
  State<PlayerFeedbackViewport> createState() => _PlayerFeedbackViewportState();
}

class _PlayerFeedbackViewportState extends State<PlayerFeedbackViewport> {
  Timer? _fadeTimer;
  late bool _reserveControls;

  /// 初始占位与实际控制栏显隐保持一致。
  @override
  void initState() {
    super.initState();
    _reserveControls = widget.controlsVisible;
  }

  /// 等控制栏完全淡出再释放提示空间，避免过渡帧出现交叠。
  @override
  void didUpdateWidget(covariant PlayerFeedbackViewport oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.controlsVisible == oldWidget.controlsVisible) return;
    _fadeTimer?.cancel();
    if (widget.controlsVisible) {
      _reserveControls = true;
    } else {
      _fadeTimer = Timer(const Duration(milliseconds: 180), () {
        if (mounted) setState(() => _reserveControls = false);
      });
    }
  }

  /// 在同一布局帧取得控制栏高度，避免固定偏移和下一帧测量造成遮挡。
  @override
  Widget build(BuildContext context) => CustomMultiChildLayout(
    delegate: _FeedbackLayoutDelegate(
      controlsVisible: _reserveControls,
      edgeInsets: widget.edgeInsets,
      sideInset: widget.sideInset,
    ),
    children: [
      LayoutId(id: _FeedbackSlot.top, child: widget.topControls),
      LayoutId(id: _FeedbackSlot.bottom, child: widget.bottomControls),
      LayoutId(
        id: _FeedbackSlot.feedback,
        child: ClipRect(
          key: const Key('player-feedback-viewport'),
          child: widget.feedback,
        ),
      ),
    ],
  );

  /// 退出页面时取消淡出占位计时。
  @override
  void dispose() {
    _fadeTimer?.cancel();
    super.dispose();
  }
}

/// 用自然高度容纳换行、字体和进度旗标，再计算提示可用空间。
class _FeedbackLayoutDelegate extends MultiChildLayoutDelegate {
  /// 保存影响避让边界的显示状态和系统安全边距。
  _FeedbackLayoutDelegate({
    required this.controlsVisible,
    required this.edgeInsets,
    required this.sideInset,
  });

  final bool controlsVisible;
  final EdgeInsets edgeInsets;
  final double sideInset;

  /// 上下栏始终按真实尺寸布局，反馈不会绘制到控制栏或侧边入口上。
  @override
  void performLayout(Size size) {
    final barConstraints = BoxConstraints(
      minWidth: size.width,
      maxWidth: size.width,
      maxHeight: size.height,
    );
    final top = layoutChild(_FeedbackSlot.top, barConstraints);
    final bottom = layoutChild(_FeedbackSlot.bottom, barConstraints);
    positionChild(_FeedbackSlot.top, Offset.zero);
    positionChild(_FeedbackSlot.bottom, Offset(0, size.height - bottom.height));
    final upper = controlsVisible ? top.height : edgeInsets.top;
    final lower = controlsVisible ? bottom.height : edgeInsets.bottom + 2;
    final topEdge = math.min(size.height, upper + 8);
    final height = math.max(0.0, size.height - lower - 8 - topEdge);
    final left = math.min(size.width / 2, edgeInsets.left + sideInset);
    final right = math.min(size.width - left, edgeInsets.right + sideInset);
    layoutChild(
      _FeedbackSlot.feedback,
      BoxConstraints.tight(
        Size(math.max(0, size.width - left - right), height),
      ),
    );
    positionChild(_FeedbackSlot.feedback, Offset(left, topEdge));
  }

  /// 显隐、设备安全边距或侧边按钮大小变化时重新计算。
  @override
  bool shouldRelayout(covariant _FeedbackLayoutDelegate oldDelegate) =>
      controlsVisible != oldDelegate.controlsVisible ||
      edgeInsets != oldDelegate.edgeInsets ||
      sideInset != oldDelegate.sideInset;
}

/// 所有同时出现的提示按自然高度上下排列，短视口内可以滚动。
class PlayerFeedbackStack extends StatefulWidget {
  /// 接收已过滤的提示，正常短提示透传触摸，操作卡片保留点击。
  const PlayerFeedbackStack({
    super.key,
    required this.children,
    this.interactive = false,
    this.alignment = Alignment.topCenter,
  });

  final List<Widget> children;
  final bool interactive;
  final Alignment alignment;

  /// 创建只管理溢出状态的布局状态。
  @override
  State<PlayerFeedbackStack> createState() => _PlayerFeedbackStackState();
}

class _PlayerFeedbackStackState extends State<PlayerFeedbackStack> {
  bool _overflowing = false;

  /// 只在内容超过可用高度时开启滚动触摸，普通反馈不抢画面手势。
  bool _updateOverflow(ScrollMetricsNotification notification) {
    final overflowing = notification.metrics.maxScrollExtent > 0.5;
    if (_overflowing != overflowing) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _overflowing != overflowing) {
          setState(() => _overflowing = overflowing);
        }
      });
    }
    return false;
  }

  /// 限制在可用视口内；长提示自然换行，各条之间保留六像素空隙。
  @override
  Widget build(BuildContext context) {
    if (widget.children.isEmpty) return const SizedBox.shrink();
    return Align(
      alignment: widget.alignment,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620),
        child: IgnorePointer(
          ignoring: !widget.interactive && !_overflowing,
          child: NotificationListener<ScrollMetricsNotification>(
            onNotification: _updateOverflow,
            child: SingleChildScrollView(
              key: const Key('player-feedback-scroll'),
              primary: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < widget.children.length; i++) ...[
                    if (i > 0) const SizedBox(height: 6),
                    widget.children[i],
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 共用短提示外观，支持两行文字和辅助功能播报。
class PlayerNoticeCard extends StatelessWidget {
  /// 接收一条提示文字，不承担计时或覆盖其他提示的职责。
  const PlayerNoticeCard({
    super.key,
    required this.message,
    this.actionLabel,
    this.onAction,
  });
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  /// 文本支持换行，操作按钮只在有有效回调时显示。
  Widget _buildText() => Text(
    message,
    maxLines: 2,
    overflow: TextOverflow.ellipsis,
    textAlign: TextAlign.center,
    style: const TextStyle(color: Colors.white, fontSize: 13),
  );

  /// 以紧凑半透明背景显示文字，避免播放栏缩放连带放大提示。
  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.82),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        child: onAction == null || actionLabel == null
            ? _buildText()
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(child: _buildText()),
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: onAction,
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      visualDensity: VisualDensity.compact,
                    ),
                    child: Text(actionLabel!),
                  ),
                ],
              ),
      ),
    ),
  );
}
