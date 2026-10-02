import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'package:focubili/models/dashboard_layout.dart';
import 'package:focubili/services/dashboard_layout_service.dart';

export 'package:focubili/models/dashboard_layout.dart'
    show DashboardCardDefinition;

part 'editable_card_tile.dart';

/// 保存某次页面身份的成功布局，页面销毁后提交链仍可继续更新快照。
class _DashboardCommitState {
  /// 将已加载布局作为后续串行操作的起点。
  _DashboardCommitState(this.layout);

  DashboardLayout layout;
}

/// 在父页面的滚动区域中管理卡片；本组件不创建嵌套滚动视图。
class EditableCardBoard extends StatefulWidget {
  /// 指定页面独立编号、稳定卡片定义和可选的外层滚动控制器。
  const EditableCardBoard({
    super.key,
    required this.storageId,
    required this.items,
    this.service,
    this.scrollController,
    this.onEditingChanged,
    this.columnCount,
    this.spacing = 16,
  }) : assert(columnCount == null || columnCount > 0),
       assert(spacing >= 0);

  final String storageId;
  final List<DashboardCardDefinition> items;
  final DashboardLayoutService? service;
  final ScrollController? scrollController;
  final ValueChanged<bool>? onEditingChanged;

  /// 不指定时按宽度自动选择一至三列；全宽卡片始终独占一行。
  final int? columnCount;
  final double spacing;

  /// 创建维护布局、编辑状态和边缘滚动的状态对象。
  @override
  State<EditableCardBoard> createState() => _EditableCardBoardState();
}

class _EditableCardBoardState extends State<EditableCardBoard>
    with SingleTickerProviderStateMixin {
  late DashboardLayoutService _service;
  late AnimationController _wiggle;
  DashboardLayout _layout = DashboardLayout(order: const []);
  late _DashboardCommitState _commitState;
  final Set<String> _hiding = {};
  final GlobalKey _footerKey = GlobalKey();
  int _footerVisibilityRevision = 0;
  static final Map<String, Future<void>> _pendingWrites = {};
  DashboardLayout? _dragLayout;
  Future<void> _operations = Future.value();
  Timer? _edgeTimer;
  Offset? _pointer;
  String? _dragging;
  String? _hoverTarget;
  bool _editing = false;
  bool _loading = true;
  bool _finishing = false;
  int _generation = 0;

  /// 去除错误登记和重复身份，始终采用同一编号的首个定义。
  List<DashboardCardDefinition> get _cards {
    final seen = <String>{};
    return widget.items
        .where((card) => card.id.trim().isNotEmpty && seen.add(card.id))
        .toList();
  }

  /// 初始化独立存储和统一动画时钟，再读取本机布局。
  @override
  void initState() {
    super.initState();
    _service = widget.service ?? DashboardLayoutService();
    _wiggle = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 920),
    );
    _load();
  }

  /// 根据系统减少动画偏好开启或暂停编辑抖动。
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncAnimation();
  }

  /// 页面身份变化时重读配置，条件卡变化时只重新协调登记表。
  @override
  void didUpdateWidget(covariant EditableCardBoard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.storageId != widget.storageId ||
        oldWidget.service != widget.service) {
      _service = widget.service ?? DashboardLayoutService();
      _stopDrag();
      _loading = true;
      _load();
    } else {
      _layout = _layout.reconcile(_cards);
      _dragLayout = _dragLayout?.reconcile(_cards);
    }
  }

  /// 只让当前页面的最新读取结果生效，损坏配置由服务安全恢复。
  Future<void> _load() async {
    final generation = ++_generation;
    final storageId = widget.storageId;
    final service = _service;
    final cards = _cards;
    final commitState = _DashboardCommitState(_layout);
    _commitState = commitState;
    _hiding.clear();
    try {
      await _pendingWrites[storageId];
      final layout = await service.load(storageId, cards);
      if (!mounted || generation != _generation) return;
      setState(() {
        _layout = layout.reconcile(_cards);
        commitState.layout = _layout;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _layout = DashboardLayout(order: const []).reconcile(_cards);
        commitState.layout = _layout;
        _loading = false;
      });
      _showError('暂时无法读取卡片布局');
    }
  }

  /// 保存失败时给出短提示，保持最后成功的可见顺序和隐藏状态。
  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(message)));
  }

  /// 点击即登记串行操作，销毁后继续落盘，后续操作沿用最后成功快照。
  Future<bool> _commit(DashboardLayout Function(DashboardLayout) change) {
    final result = Completer<bool>();
    final generation = _generation;
    final storageId = widget.storageId;
    final service = _service;
    final cards = _cards;
    final commitState = _commitState;
    _operations = _operations.then((_) async {
      try {
        final next = change(commitState.layout).reconcile(cards);
        await service.save(storageId, next);
        commitState.layout = next;
        if (mounted && generation == _generation) {
          setState(() => _layout = next.reconcile(_cards));
        }
        result.complete(true);
      } catch (_) {
        if (mounted && generation == _generation) {
          _showError('卡片布局保存失败，请重试');
        }
        result.complete(false);
      }
    });
    final pending = _operations;
    _pendingWrites[storageId] = pending;
    pending.whenComplete(() {
      if (identical(_pendingWrites[storageId], pending)) {
        _pendingWrites.remove(storageId);
      }
    });
    return result.future;
  }

  /// 通知页面暂停或恢复吸附，并启动符合系统偏好的动画。
  void _setEditing(bool value) {
    if (_editing == value) return;
    _keepFooterVisibleAfterLayout();
    setState(() => _editing = value);
    if (!value) _stopDrag();
    _syncAnimation();
    widget.onEditingChanged?.call(value);
  }

  /// 仅在切换前工具区可见时，布局后由它的直接父滚动区域校正一次可见性。
  void _keepFooterVisibleAfterLayout() {
    final revision = ++_footerVisibilityRevision;
    final footerContext = _footerKey.currentContext;
    if (footerContext == null) return;
    final scrollable = Scrollable.maybeOf(footerContext);
    final footer = footerContext.findRenderObject();
    final viewport = scrollable?.context.findRenderObject();
    if (scrollable == null || footer is! RenderBox || viewport is! RenderBox) {
      return;
    }
    final footerRect = footer.localToGlobal(Offset.zero) & footer.size;
    final viewportRect = viewport.localToGlobal(Offset.zero) & viewport.size;
    if (!footerRect.overlaps(viewportRect)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          revision != _footerVisibilityRevision ||
          _dragging != null) {
        return;
      }
      final target = _footerKey.currentContext?.findRenderObject();
      if (target == null || !target.attached || !scrollable.mounted) return;
      scrollable.position.ensureVisible(
        target,
        alignment: 1,
        alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 160),
        curve: Curves.easeOut,
      );
    });
  }

  /// 所有卡片共享时钟，但按稳定编号采用不同抖动相位。
  void _syncAnimation() {
    if (_editing && !MediaQuery.disableAnimationsOf(context)) {
      if (!_wiggle.isAnimating) _wiggle.repeat();
    } else {
      _wiggle.stop();
      _wiggle.value = 0;
    }
  }

  /// 完成前等待已点击的保存动作，防止快速离开造成操作遗漏。
  Future<void> _finish() async {
    if (_finishing) return;
    setState(() => _finishing = true);
    Future<void> pending;
    do {
      pending = _operations;
      await pending;
    } while (!identical(pending, _operations));
    if (!mounted) return;
    setState(() => _finishing = false);
    _setEditing(false);
  }

  /// 点击即排入隐藏写入，成功保存后仍保留散片动画的原始占位。
  Future<bool> _hide(String id) {
    final cards = _cards;
    setState(() => _hiding.add(id));
    return _commit((layout) => layout.setHidden(id, true, cards));
  }

  /// 散片结束后撤掉占位，写入失败则自然恢复最后成功的卡片布局。
  void _finishHide(String id, int generation) {
    if (!mounted || generation != _generation) return;
    setState(() => _hiding.remove(id));
  }

  /// 无障碍按钮按可见顺序移动一格，条件不可用卡片仍保留编号。
  Future<bool> _moveStep(String id, int step) {
    final cards = _cards;
    return _commit((layout) {
      final visible = layout.visibleCards(cards);
      final current = visible.indexWhere((card) => card.id == id);
      final target = current + step;
      if (current < 0 || target < 0 || target >= visible.length) return layout;
      return layout.move(id, visible[target].id, after: step > 0);
    });
  }

  /// 弹窗按屏幕可用高度限制列表，点击加号立即保存并刷新列表。
  Future<void> _showAddCards() async {
    final pending = <String>{};
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, rebuildDialog) {
          final hidden = _cards
              .where((card) => _layout.hidden.contains(card.id))
              .toList();
          return AlertDialog(
            title: const Text('添加卡片'),
            content: SizedBox(
              width: 380,
              height: math.min(
                MediaQuery.sizeOf(context).height * .5,
                math.max(80.0, hidden.length * 64.0),
              ),
              child: hidden.isEmpty
                  ? const Center(child: Text('所有卡片都已添加'))
                  : ListView.builder(
                      itemCount: hidden.length,
                      itemBuilder: (context, index) {
                        final card = hidden[index];
                        return ListTile(
                          leading: Icon(card.icon),
                          title: Text(card.title),
                          subtitle: card.available
                              ? null
                              : const Text('添加后在条件满足时显示'),
                          trailing: IconButton(
                            key: ValueKey('dashboard-add-${card.id}'),
                            tooltip: '添加${card.title}',
                            onPressed: pending.contains(card.id)
                                ? null
                                : () async {
                                    final cards = _cards;
                                    rebuildDialog(() => pending.add(card.id));
                                    await _commit(
                                      (layout) =>
                                          layout.addLast(card.id, cards),
                                    );
                                    if (dialogContext.mounted) {
                                      rebuildDialog(
                                        () => pending.remove(card.id),
                                      );
                                    }
                                  },
                            icon: const Icon(Icons.add_circle_outline),
                          ),
                        );
                      },
                    ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('关闭'),
              ),
            ],
          );
        },
      ),
    );
  }

  /// 恢复登记顺序和全部卡片的默认显示状态，成功后保持底部工具可见。
  Future<void> _restoreDefaultLayout() async {
    final cards = _cards;
    final saved = await _commit(
      (_) => DashboardLayout(order: const []).reconcile(cards),
    );
    if (!mounted || !saved) return;
    _keepFooterVisibleAfterLayout();
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(
        content: Text('已恢复默认布局'),
        duration: Duration(seconds: 2),
        persist: false,
      ),
    );
  }

  /// 拖动开始时建立临时预览；实际布局仅在放置并保存成功后更新。
  void _startDrag(String id) {
    setState(() {
      _dragging = id;
      _hoverTarget = null;
      _dragLayout = _layout;
    });
    _edgeTimer?.cancel();
    _edgeTimer = Timer.periodic(
      const Duration(milliseconds: 16),
      (_) => _scrollAtEdge(),
    );
  }

  /// 记录真实指针位置，让自动滚动不依赖拖动截图的锚点。
  void _updateDrag(DragUpdateDetails details) {
    _pointer = details.globalPosition;
  }

  /// 使用外层视口的位置和边界，在指针靠近上下边缘时持续滚动。
  void _scrollAtEdge() {
    if (!mounted || _pointer == null || _dragging == null) return;
    final controller = widget.scrollController;
    final position = controller != null && controller.hasClients
        ? controller.position
        : Scrollable.maybeOf(context)?.position;
    if (position == null || !position.hasContentDimensions) return;
    final render = position.context.notificationContext?.findRenderObject();
    if (render is! RenderBox || !render.hasSize) return;
    final top = render.localToGlobal(Offset.zero).dy;
    final bottom = top + render.size.height;
    const zone = 72.0;
    final y = _pointer!.dy;
    final speed = y < top + zone
        ? -12 * ((top + zone - y) / zone).clamp(0.0, 1.0)
        : y > bottom - zone
        ? 12 * ((y - bottom + zone) / zone).clamp(0.0, 1.0)
        : 0.0;
    if (speed == 0) return;
    final next = (position.pixels + speed).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if (next != position.pixels) position.jumpTo(next);
  }

  /// 进入另一张卡片时按可见顺序预览插入，允许跨列和跨行移动。
  void _previewDrop(String target) {
    final id = _dragging;
    if (id == null ||
        id == target ||
        _dragLayout == null ||
        _hoverTarget == target) {
      return;
    }
    _hoverTarget = target;
    final order = _dragLayout!.order;
    final after = order.indexOf(id) < order.indexOf(target);
    setState(() => _dragLayout = _dragLayout!.move(id, target, after: after));
  }

  /// 将当前拖动预览提交一次，写入失败自动恢复最后保存的布局。
  void _acceptDrop(DragTargetDetails<String> details) {
    final preview = _dragLayout;
    if (preview == null) return;
    _commit(
      (layout) => DashboardLayout(order: preview.order, hidden: layout.hidden),
    );
    _stopDrag();
  }

  /// 拖动结束或取消时释放边缘定时器及临时预览。
  void _stopDrag() {
    _edgeTimer?.cancel();
    _edgeTimer = null;
    _pointer = null;
    if (!mounted) return;
    setState(() {
      _dragging = null;
      _hoverTarget = null;
      _dragLayout = null;
    });
  }

  /// 构建响应式卡片和始终可达的底部自定义操作。
  @override
  Widget build(BuildContext context) {
    final generation = _generation;
    final displayLayout = _dragLayout ?? _layout;
    final visible = DashboardLayout(
      order: displayLayout.order,
      hidden: displayLayout.hidden.difference(_hiding),
    ).visibleCards(_cards);
    final desktop = switch (defaultTargetPlatform) {
      TargetPlatform.windows ||
      TargetPlatform.linux ||
      TargetPlatform.macOS => true,
      _ => false,
    };
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_loading)
          const Padding(
            padding: EdgeInsets.all(16),
            child: LinearProgressIndicator(),
          ),
        LayoutBuilder(
          builder: (context, constraints) {
            final columns =
                widget.columnCount ??
                (constraints.maxWidth >= 1100
                    ? 3
                    : constraints.maxWidth >= 720
                    ? 2
                    : 1);
            final width = math.max(
              1.0,
              (constraints.maxWidth - widget.spacing * (columns - 1)) / columns,
            );
            return Wrap(
              spacing: widget.spacing,
              runSpacing: widget.spacing,
              children: [
                for (final card in visible)
                  SizedBox(
                    key: ValueKey('dashboard-card-${card.id}'),
                    width: card.fullWidth ? constraints.maxWidth : width,
                    child: DragTarget<String>(
                      onWillAcceptWithDetails: (details) =>
                          _editing && details.data == _dragging,
                      onMove: (_) => _previewDrop(card.id),
                      onAcceptWithDetails: _acceptDrop,
                      builder: (context, candidates, rejected) =>
                          _EditableCardTile(
                            key: ValueKey(card.id),
                            card: card,
                            editing: _editing,
                            desktop: desktop,
                            wiggle: _wiggle,
                            dragging: _dragging == card.id,
                            width: card.fullWidth
                                ? constraints.maxWidth
                                : width,
                            onHide: () => _hide(card.id),
                            onRemovalFinished: () =>
                                _finishHide(card.id, generation),
                            onMove: (step) => _moveStep(card.id, step),
                            onDragStarted: () => _startDrag(card.id),
                            onDragUpdate: _updateDrag,
                            onDragEnd: (_) => _stopDrag(),
                          ),
                    ),
                  ),
              ],
            );
          },
        ),
        Padding(
          key: _footerKey,
          padding: const EdgeInsets.only(top: 12, bottom: 8),
          child: Wrap(
            alignment: WrapAlignment.center,
            spacing: 12,
            children: _editing
                ? [
                    TextButton.icon(
                      onPressed: _showAddCards,
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('添加卡片'),
                    ),
                    TextButton.icon(
                      key: const Key('dashboard-reset-layout'),
                      onPressed: _finishing ? null : _restoreDefaultLayout,
                      icon: const Icon(Icons.restore_rounded, size: 18),
                      label: const Text('恢复默认布局'),
                    ),
                    TextButton(
                      onPressed: _finishing ? null : _finish,
                      child: const Text('完成'),
                    ),
                  ]
                : [
                    TextButton.icon(
                      onPressed: _loading ? null : () => _setEditing(true),
                      icon: const Icon(Icons.tune, size: 16),
                      label: const Text('自定义'),
                    ),
                  ],
          ),
        ),
      ],
    );
  }

  /// 页面退出时关闭拖动与动画资源，并通知父页结束编辑状态。
  @override
  void dispose() {
    _generation++;
    _edgeTimer?.cancel();
    _wiggle.dispose();
    super.dispose();
  }
}
