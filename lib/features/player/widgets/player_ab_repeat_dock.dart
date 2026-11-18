import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:flutter/services.dart';

import 'player_ab_repeat_sheet.dart';

/// Positions the non-modal fullscreen editor inside the actual feedback lane.
class PlayerAbRepeatDock extends StatefulWidget {
  const PlayerAbRepeatDock({
    super.key,
    required this.offset,
    required this.onMove,
    required this.child,
  });

  final Offset? offset;
  final ValueChanged<Offset> onMove;
  final Widget child;

  @override
  State<PlayerAbRepeatDock> createState() => _PlayerAbRepeatDockState();
}

class _PlayerAbRepeatDockState extends State<PlayerAbRepeatDock> {
  static const _step = 24.0;
  static const _gripWidth = 44.0;
  static const _compactHeight = 96.0;
  final _cardKey = GlobalKey();
  final _handleFocus = FocusNode(debugLabel: 'Move A–B editor');
  Offset? _dragStart;
  Offset? _actionOffset;
  double _heightAtPress = 0;
  bool _focusHighlighted = false;

  @override
  void didUpdateWidget(covariant PlayerAbRepeatDock oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Direction keys or accessibility actions can arrive in the same frame.
    // Once the parent rebuilds, the rendered offset becomes authoritative.
    _actionOffset = null;
  }

  @override
  void dispose() {
    _handleFocus.dispose();
    super.dispose();
  }

  Offset _bounded(Offset offset, Size lane, double width, double keepHeight) =>
      Offset(
        offset.dx.clamp(0.0, math.max(0, lane.width - width)),
        offset.dy.clamp(0.0, math.max(0, lane.height - keepHeight)),
      );

  void _finishDrag() {
    if (_dragStart != null) setState(() => _dragStart = null);
  }

  Widget _handle(Offset offset, Size lane, double width) {
    void move(Offset delta) {
      final height = math.max(
        _compactHeight,
        _cardKey.currentContext?.size?.height ?? 0,
      );
      final next = _bounded(
        (_actionOffset ?? offset) + delta,
        lane,
        width,
        height,
      );
      _actionOffset = next;
      widget.onMove(next);
    }

    return FocusableActionDetector(
      focusNode: _handleFocus,
      mouseCursor: _dragStart == null
          ? SystemMouseCursors.grab
          : SystemMouseCursors.grabbing,
      onShowFocusHighlight: (visible) =>
          setState(() => _focusHighlighted = visible),
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.arrowLeft): _MoveDock(
          Offset(-_step, 0),
        ),
        SingleActivator(LogicalKeyboardKey.arrowRight): _MoveDock(
          Offset(_step, 0),
        ),
        SingleActivator(LogicalKeyboardKey.arrowUp): _MoveDock(
          Offset(0, -_step),
        ),
        SingleActivator(LogicalKeyboardKey.arrowDown): _MoveDock(
          Offset(0, _step),
        ),
      },
      actions: {
        _MoveDock: CallbackAction<_MoveDock>(
          onInvoke: (intent) {
            move(intent.delta);
            return null;
          },
        ),
      },
      child: Semantics(
        label: '移动 A–B 控件',
        hint: '长按拖动，也可使用方向键',
        customSemanticsActions: {
          const CustomSemanticsAction(label: '左移'): () =>
              move(const Offset(-_step, 0)),
          const CustomSemanticsAction(label: '右移'): () =>
              move(const Offset(_step, 0)),
          const CustomSemanticsAction(label: '上移'): () =>
              move(const Offset(0, -_step)),
          const CustomSemanticsAction(label: '下移'): () =>
              move(const Offset(0, _step)),
        },
        child: Tooltip(
          message: '长按拖动 A–B 控件（也可用方向键）',
          excludeFromSemantics: true,
          child: GestureDetector(
            key: const Key('ab-repeat-move-handle'),
            behavior: HitTestBehavior.opaque,
            onTap: _handleFocus.requestFocus,
            onLongPressStart: (_) {
              _handleFocus.requestFocus();
              _actionOffset = null;
              _heightAtPress = math.max(
                _compactHeight,
                _cardKey.currentContext?.size?.height ?? 0,
              );
              setState(() => _dragStart = offset);
            },
            onLongPressMoveUpdate: (details) {
              final origin = _dragStart;
              if (origin == null) return;
              widget.onMove(
                _bounded(
                  origin + details.offsetFromOrigin,
                  lane,
                  width,
                  _heightAtPress,
                ),
              );
            },
            onLongPressEnd: (_) => _finishDrag(),
            onLongPressCancel: _finishDrag,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: _focusHighlighted || _dragStart != null
                    ? Theme.of(context).colorScheme.secondaryContainer
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Center(child: Icon(Icons.drag_indicator_rounded)),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final lane = constraints.biggest;
      if (lane.isEmpty) return const SizedBox.shrink();
      final width = math.min(lane.width, PlayerAbRepeatSheet.inlineWidth);
      final pos = _bounded(
        widget.offset ?? Offset((lane.width - width) / 2, 0),
        lane,
        width,
        _compactHeight,
      );
      final availableHeight = lane.height - pos.dy;
      return Stack(
        children: [
          Positioned(
            left: pos.dx,
            top: pos.dy,
            width: width,
            child: ConstrainedBox(
              key: _cardKey,
              constraints: BoxConstraints(maxHeight: availableHeight),
              child: Material(
                key: const Key('ab-repeat-floating-editor'),
                color: Theme.of(context).colorScheme.surface,
                borderRadius: BorderRadius.circular(12),
                clipBehavior: Clip.antiAlias,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: SingleChildScrollView(child: widget.child)),
                    SizedBox(
                      width: math.min(_gripWidth, width / 3),
                      height: math.min(_gripWidth, availableHeight),
                      child: _handle(pos, lane, width),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      );
    },
  );
}

class _MoveDock extends Intent {
  const _MoveDock(this.delta);
  final Offset delta;
}
