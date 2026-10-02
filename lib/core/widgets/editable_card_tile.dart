part of 'editable_card_board.dart';

/// 承载业务内容、编辑操作和截图散片动画，业务点击在编辑时被吸收。
class _EditableCardTile extends StatefulWidget {
  /// 接收卡片定义和仅负责布局的操作回调。
  const _EditableCardTile({
    super.key,
    required this.card,
    required this.editing,
    required this.desktop,
    required this.wiggle,
    required this.dragging,
    required this.width,
    required this.onHide,
    required this.onRemovalFinished,
    required this.onMove,
    required this.onDragStarted,
    required this.onDragUpdate,
    required this.onDragEnd,
  });

  final DashboardCardDefinition card;
  final bool editing;
  final bool desktop;
  final Animation<double> wiggle;
  final bool dragging;
  final double width;
  final Future<bool> Function() onHide;
  final VoidCallback onRemovalFinished;
  final Future<bool> Function(int step) onMove;
  final VoidCallback onDragStarted;
  final DragUpdateCallback onDragUpdate;
  final DragEndCallback onDragEnd;

  /// 创建独立截图和移除动画状态。
  @override
  State<_EditableCardTile> createState() => _EditableCardTileState();
}

class _EditableCardTileState extends State<_EditableCardTile>
    with SingleTickerProviderStateMixin {
  final _boundary = GlobalKey();
  late AnimationController _burst;
  ui.Image? _image;
  VoidCallback? _pendingRemovalFinished;
  bool _removing = false;

  /// 为每次移除准备有限时长的动画，正常显示不消耗散片资源。
  @override
  void initState() {
    super.initState();
    _burst = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 360),
    );
  }

  /// 点击即保存隐藏，同时播放十二片散开；任一路径都释放截图并恢复占位。
  Future<void> _remove() async {
    if (_removing || widget.card.required) return;
    final reduced = MediaQuery.disableAnimationsOf(context);
    final pixelRatio = math.min(2.0, MediaQuery.devicePixelRatioOf(context));
    final onRemovalFinished = widget.onRemovalFinished;
    _pendingRemovalFinished = onRemovalFinished;
    setState(() => _removing = true);
    final saved = widget.onHide();
    if (!reduced) await _scatter(pixelRatio);
    await saved;
    if (!mounted) return;
    setState(() {
      _releaseImage();
      _removing = false;
      _burst.reset();
    });
    _pendingRemovalFinished = null;
    onRemovalFinished();
  }

  /// 等待一帧绘制完成再截图，不读取只在调试模式可用的渲染标记。
  Future<void> _scatter(double pixelRatio) async {
    ui.Image? captured;
    try {
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      final render = _boundary.currentContext?.findRenderObject();
      if (render is! RenderRepaintBoundary || !render.attached) return;
      captured = await render.toImage(pixelRatio: pixelRatio);
      if (!mounted) return;
      setState(() => _image = captured);
      captured = null;
      await _burst.forward(from: 0).orCancel;
    } on TickerCanceled {
      // 页面销毁会取消动画，已排入队列的隐藏写入继续执行。
    } catch (_) {
      // 截图不可用时仍完成已接受的隐藏操作。
    } finally {
      captured?.dispose();
    }
  }

  /// 拖动预览仅展示身份并保持实测尺寸，避免重复创建业务状态及 GlobalKey。
  Widget _feedback(BuildContext context) {
    final render = _boundary.currentContext?.findRenderObject();
    final height = render is RenderBox && render.hasSize
        ? render.size.height + 24
        : 100.0;
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      elevation: 8,
      borderRadius: BorderRadius.circular(16),
      child: SizedBox(
        width: widget.width,
        height: height,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(widget.card.icon),
                const SizedBox(height: 4),
                Flexible(
                  child: Text(
                    widget.card.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 桌面抓手提供即时鼠标拖动，触摸端仍使用整卡长按。
  Widget _handle(BuildContext context) => Draggable<String>(
    key: ValueKey('dashboard-drag-${widget.card.id}'),
    data: widget.card.id,
    maxSimultaneousDrags: _removing ? 0 : 1,
    feedback: _feedback(context),
    onDragStarted: widget.onDragStarted,
    onDragUpdate: widget.onDragUpdate,
    onDragEnd: widget.onDragEnd,
    child: Tooltip(
      message: '拖动${widget.card.title}调整顺序',
      child: const SizedBox(
        width: 44,
        height: 44,
        child: Icon(Icons.drag_indicator, size: 20),
      ),
    ),
  );

  /// 角落显示小红叉和桌面抓手，菜单提供键盘及无障碍顺序操作。
  Widget _controls(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => Stack(
      clipBehavior: Clip.none,
      children: [
        if (widget.desktop && constraints.maxWidth >= 132)
          Positioned(left: 0, top: 0, child: _handle(context)),
        Positioned(
          left: widget.desktop && constraints.maxWidth >= 132 ? 44 : 0,
          top: 0,
          child: PopupMenuButton<int>(
            key: ValueKey('dashboard-menu-${widget.card.id}'),
            tooltip: '调整${widget.card.title}顺序',
            enabled: !_removing,
            constraints: const BoxConstraints(minWidth: 120, maxWidth: 280),
            onSelected: widget.onMove,
            itemBuilder: (_) => [
              PopupMenuItem(
                key: ValueKey('dashboard-before-${widget.card.id}'),
                value: -1,
                child: const Text('向前移动'),
              ),
              PopupMenuItem(
                key: ValueKey('dashboard-after-${widget.card.id}'),
                value: 1,
                child: const Text('向后移动'),
              ),
            ],
            child: const SizedBox(
              width: 44,
              height: 44,
              child: Icon(Icons.more_horiz, size: 18),
            ),
          ),
        ),
        if (!widget.card.required)
          Positioned(
            right: 0,
            top: 0,
            child: IconButton(
              key: ValueKey('dashboard-hide-${widget.card.id}'),
              tooltip: '隐藏${widget.card.title}',
              onPressed: _removing ? null : _remove,
              constraints: const BoxConstraints.tightFor(width: 44, height: 44),
              padding: EdgeInsets.zero,
              icon: const Icon(Icons.cancel, color: Colors.red, size: 20),
            ),
          ),
      ],
    ),
  );

  /// 编辑时在角落叠加控件并错相抖动，散片保留占位直到动画与保存均完成。
  @override
  Widget build(BuildContext context) {
    final reduced = MediaQuery.disableAnimationsOf(context);
    final body = AnimatedBuilder(
      animation: Listenable.merge([widget.wiggle, _burst]),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Padding(
            padding: EdgeInsets.only(top: widget.editing ? 24 : 0),
            child: RepaintBoundary(
              key: _boundary,
              child: AbsorbPointer(
                absorbing: widget.editing || _removing,
                child: ExcludeSemantics(
                  excluding: widget.editing,
                  child: widget.card.builder(context),
                ),
              ),
            ),
          ),
          if (widget.editing)
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              height: 44,
              child: _controls(context),
            ),
        ],
      ),
      builder: (context, child) {
        final phase = (widget.card.id.hashCode & 255) / 256 * math.pi * 2;
        final angle = widget.editing && !reduced && !_removing
            ? math.sin(widget.wiggle.value * math.pi * 2 + phase) * .012
            : 0.0;
        return Transform.rotate(
          angle: angle,
          child: Opacity(
            opacity: widget.dragging ? .35 : 1,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Opacity(opacity: _image == null ? 1 : 0, child: child),
                if (_image != null)
                  Positioned.fill(
                    top: widget.editing ? 24 : 0,
                    child: IgnorePointer(
                      child: CustomPaint(
                        painter: _CardShardPainter(_image!, _burst.value),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
    if (!widget.editing) return body;
    return Semantics(
      container: true,
      label: '${widget.card.title}，可调整顺序${widget.card.required ? '，必需卡片' : ''}',
      child: LongPressDraggable<String>(
        data: widget.card.id,
        maxSimultaneousDrags: _removing ? 0 : 1,
        feedback: _feedback(context),
        onDragStarted: widget.onDragStarted,
        onDragUpdate: widget.onDragUpdate,
        onDragEnd: widget.onDragEnd,
        child: body,
      ),
    );
  }

  /// 释放由当前卡片持有的 GPU 图片，结束动画和销毁共用此路径。
  void _releaseImage() {
    _image?.dispose();
    _image = null;
  }

  /// 释放 GPU 截图与动画，取消等待中的动画回调。
  @override
  void dispose() {
    _burst.dispose();
    _releaseImage();
    final finishRemoval = _pendingRemovalFinished;
    if (finishRemoval != null) scheduleMicrotask(finishRemoval);
    _pendingRemovalFinished = null;
    super.dispose();
  }
}

/// 把真实卡片截图按三行四列拆开，各片独立向外位移、旋转和淡出。
class _CardShardPainter extends CustomPainter {
  /// 接收截图及零至一的动画进度，不拥有截图的生命周期。
  _CardShardPainter(this.image, this.progress);

  final ui.Image image;
  final double progress;

  /// 每片使用独立源矩形与方向，避免整体缩放冒充散开效果。
  @override
  void paint(Canvas canvas, Size size) {
    final t = Curves.easeOutCubic.transform(progress);
    final paint = Paint()..color = Colors.white.withValues(alpha: 1 - progress);
    for (var row = 0; row < 3; row++) {
      for (var column = 0; column < 4; column++) {
        final index = row * 4 + column;
        final piece = Size(size.width / 4, size.height / 3);
        final center = Offset(
          (column + .5) * piece.width,
          (row + .5) * piece.height,
        );
        final direction = Offset((column - 1.5) * 30, (row - 1.0) * 42 - 12);
        canvas.save();
        canvas.translate(
          center.dx + direction.dx * t,
          center.dy + direction.dy * t,
        );
        canvas.rotate((index.isEven ? 1 : -1) * (.12 + index * .015) * t);
        canvas.drawImageRect(
          image,
          Rect.fromLTWH(
            column * image.width / 4,
            row * image.height / 3,
            image.width / 4,
            image.height / 3,
          ),
          Rect.fromCenter(
            center: Offset.zero,
            width: piece.width,
            height: piece.height,
          ),
          paint,
        );
        canvas.restore();
      }
    }
  }

  /// 仅在动画进度或截图发生变化时重绘。
  @override
  bool shouldRepaint(covariant _CardShardPainter oldDelegate) =>
      oldDelegate.image != image || oldDelegate.progress != progress;
}
